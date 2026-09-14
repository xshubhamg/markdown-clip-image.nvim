--- markdown-clip-image: paste clipboard screenshots into markdown files.
--- Wayland-first (wl-paste), with X11 (xclip) and macOS (pngpaste) fallbacks.
---@module "markdown-clip-image"

---@alias ClipImageEmbedStyle "markdown"|"obsidian"
---@alias ClipImageBackend "wl-paste"|"xclip"|"pngpaste"
---@alias ClipImageCursorMode "auto"|"alt"|"end"

---@class ClipImageConfig
---@field assets_dir string Subdir next to the markdown file, or absolute path. Default: "assets"
---@field filename_prefix string Prefix for generated files. Default: "screenshot-"
---@field filename_format string os.date format for the timestamp. Default: "%Y-%m-%d-%H-%M-%S"
---@field embed_style ClipImageEmbedStyle Markup to insert. Default: "markdown"
---@field prompt_filename boolean Ask for filename on each paste. Default: false
---@field prompt_alt_text boolean Ask for alt text on each paste. Default: false
---@field default_alt string Alt text when not prompting. "" for empty, "{filename}" for the file stem. Default: ""
---@field url_encode_spaces boolean Insert "%20" for spaces so strict renderers stay happy. Default: true
---@field use_absolute_path boolean Insert the absolute path instead of a relative one. Default: false
---@field add_blank_lines boolean Pad the inserted block with blank lines (without doubling). Default: true
---@field cursor_after_paste ClipImageCursorMode Where to put the cursor: "auto", "alt", or "end". Default: "auto"
---@field notify_on_success boolean Notify on successful paste. Default: true
---@field show_progress boolean Notify while the image is being saved. Default: true
---@field keymap string|nil Buffer-local keymap for markdown filetypes, nil disables. Default: "<leader>p"
---@field filetypes string[] Filetypes where keymap applies and paste is allowed. Default: markdown family

---@class ClipImagePasteOverride
---@field embed_style ClipImageEmbedStyle?
---@field assets_dir string?
---@field prompt_filename boolean?
---@field prompt_alt_text boolean?
---@field allow_any_filetype boolean? Bypass the filetype guard (for :PasteImage! style flows).

local M = {}

---@type ClipImageConfig
M.defaults = {
  assets_dir = "assets",
  filename_prefix = "screenshot-",
  filename_format = "%Y-%m-%d-%H-%M-%S",
  embed_style = "markdown",
  prompt_filename = false,
  prompt_alt_text = false,
  default_alt = "",
  url_encode_spaces = true,
  use_absolute_path = false,
  add_blank_lines = true,
  cursor_after_paste = "auto",
  notify_on_success = true,
  show_progress = true,
  keymap = "<leader>p",
  filetypes = { "markdown", "mdx", "quarto", "rmd", "vimwiki" },
}

---@type ClipImageConfig
M.config = vim.deepcopy(M.defaults)

local augroup = vim.api.nvim_create_augroup("MarkdownClipImage", { clear = true })

local function notify(msg, level)
  vim.notify("[markdown-clip-image] " .. msg, level or vim.log.levels.INFO)
end

---@return string Actionable install hint for the current OS.
local function install_hint()
  if vim.fn.has("mac") == 1 then
    return "install pngpaste (brew install pngpaste)"
  elseif vim.fn.executable("wl-paste") == 1 or vim.env.WAYLAND_DISPLAY then
    return "install wl-clipboard (pacman -S wl-clipboard / apt install wl-clipboard)"
  end
  return "install wl-clipboard (Wayland), xclip (X11), or pngpaste (macOS)"
end

---@param cfg table
local function validate_config(cfg)
  vim.validate("assets_dir", cfg.assets_dir, "string")
  vim.validate("filename_prefix", cfg.filename_prefix, "string")
  vim.validate("filename_format", cfg.filename_format, "string")
  vim.validate("embed_style", cfg.embed_style, "string")
  vim.validate("prompt_filename", cfg.prompt_filename, "boolean")
  vim.validate("prompt_alt_text", cfg.prompt_alt_text, "boolean")
  vim.validate("default_alt", cfg.default_alt, "string")
  vim.validate("url_encode_spaces", cfg.url_encode_spaces, "boolean")
  vim.validate("use_absolute_path", cfg.use_absolute_path, "boolean")
  vim.validate("add_blank_lines", cfg.add_blank_lines, "boolean")
  vim.validate("cursor_after_paste", cfg.cursor_after_paste, "string")
  vim.validate("notify_on_success", cfg.notify_on_success, "boolean")
  vim.validate("show_progress", cfg.show_progress, "boolean")
  if cfg.keymap ~= nil then
    vim.validate("keymap", cfg.keymap, "string")
  end
  vim.validate("filetypes", cfg.filetypes, "table")
  assert(
    cfg.embed_style == "markdown" or cfg.embed_style == "obsidian",
    "embed_style must be 'markdown' or 'obsidian'"
  )
  assert(
    cfg.cursor_after_paste == "auto"
      or cfg.cursor_after_paste == "alt"
      or cfg.cursor_after_paste == "end",
    "cursor_after_paste must be 'auto', 'alt', or 'end'"
  )
end

---@return ClipImageConfig
function M.get_config()
  return vim.deepcopy(M.config)
end

-- ---------------------------------------------------------------------------
-- Clipboard backends
-- ---------------------------------------------------------------------------

local IMAGE_MIMES = { "image/png", "image/jpeg", "image/webp" }

---@param lines string|string[]
---@return string|nil first supported image mime found in wl-paste/xclip TARGETS output
local function first_image_mime(lines)
  local text = type(lines) == "table" and table.concat(lines, "\n") or (lines or "")
  for _, mime in ipairs(IMAGE_MIMES) do
    if text:find(mime, 1, true) then
      return mime
    end
  end
  return nil
end

---@param args string[]
---@param timeout_ms integer?
---@return boolean ok
---@return string out_or_err
local function system_sync(args, timeout_ms)
  if vim.system == nil then
    -- Neovim < 0.10 fallback (should not happen; we require >= 0.10)
    local out = vim.fn.system(vim.fn.shellescape(args[1]) .. " " .. table.concat(args, " ", 2))
    return vim.v.shell_error == 0, out or ""
  end
  local res = vim.system(args, { text = true, timeout = timeout_ms or 5000 }):wait()
  if res == nil then
    return false, "timed out"
  end
  return res.code == 0, res.stdout or ""
end

---@class ClipImageClipboard
---@field backend ClipImageBackend
---@field mime string

---Detect backend + mime together so save() never uses the wrong tool.
---Priority: wl-paste -> xclip -> pngpaste.
---@return ClipImageClipboard|nil
local function detect_clipboard()
  if vim.fn.executable("wl-paste") == 1 then
    local ok, out = system_sync({ "wl-paste", "--list-types" }, 3000)
    if ok then
      local mime = first_image_mime(out)
      if mime then
        return { backend = "wl-paste", mime = mime }
      end
      return nil -- wl-paste works but clipboard has no image: don't fall through to stale X11
    end
    -- wl-paste failed (no Wayland seat): fall through to xclip
  end

  if vim.fn.executable("xclip") == 1 then
    local ok, out = system_sync({ "xclip", "-selection", "clipboard", "-t", "TARGETS", "-o" }, 3000)
    if ok then
      local mime = first_image_mime(out)
      if mime == "image/webp" then
        mime = nil -- xclip rarely serves webp reliably; treat as absent
      end
      if mime then
        return { backend = "xclip", mime = mime }
      end
      return nil
    end
  end

  if vim.fn.executable("pngpaste") == 1 then
    -- pngpaste has no list-types; probe by decoding to a temp file.
    local tmp = vim.fn.tempname() .. ".png"
    local ok = system_sync({ "pngpaste", tmp }, 5000)
    vim.fn.delete(tmp)
    if ok then
      return { backend = "pngpaste", mime = "image/png" }
    end
    return nil
  end

  return nil
end

---@return boolean available
---@return string hint Human-readable hint for :checkhealth and error messages.
function M.is_available()
  if vim.fn.executable("wl-paste") == 1 then
    return true, "wl-paste"
  end
  if vim.fn.executable("xclip") == 1 then
    return true, "xclip"
  end
  if vim.fn.executable("pngpaste") == 1 then
    return true, "pngpaste"
  end
  return false, "none (" .. install_hint() .. ")"
end

---@param dest string absolute path to write
---@param clip ClipImageClipboard
---@param cb fun(ok: boolean, err: string?) async completion (always called via vim.schedule)
local function save_clipboard_image_async(dest, clip, cb)
  local function done(ok, err)
    vim.schedule(function()
      cb(ok, err)
    end)
  end

  if vim.system == nil then
    done(false, "requires Neovim >= 0.10 (vim.system)")
    return
  end

  if clip.backend == "pngpaste" then
    vim.system({ "pngpaste", dest }, { text = true, timeout = 10000 }, function(res)
      if res.code ~= 0 then
        done(false, "pngpaste failed (clipboard has no image?)")
        return
      end
      local stat = vim.uv.fs_stat(dest)
      if not stat or stat.size == 0 then
        pcall(vim.fn.delete, dest)
        done(false, "clipboard image was empty")
        return
      end
      done(true)
    end)
    return
  end

  local args
  if clip.backend == "wl-paste" then
    args = { "wl-paste", "--type", clip.mime }
  else
    args = { "xclip", "-selection", "clipboard", "-t", clip.mime, "-o" }
  end
  -- Binary-safe: text=false keeps stdout as raw bytes.
  vim.system(args, { text = false, timeout = 10000 }, function(res)
    if res.code ~= 0 or res.stdout == nil or #res.stdout == 0 then
      done(false, string.format("%s failed (code %s)", clip.backend, res.code or "timeout"))
      return
    end
    local fh, open_err = io.open(dest, "wb")
    if not fh then
      done(false, "cannot write " .. dest .. ": " .. tostring(open_err))
      return
    end
    fh:write(res.stdout)
    fh:close()
    local stat = vim.uv.fs_stat(dest)
    if not stat or stat.size == 0 then
      pcall(vim.fn.delete, dest)
      done(false, "clipboard image was empty")
      return
    end
    done(true)
  end)
end

-- ---------------------------------------------------------------------------
-- Paths / filenames / markup
-- ---------------------------------------------------------------------------

---@param path string
---@return boolean
local function is_absolute(path)
  return path:sub(1, 1) == "/" or path:match("^%a:[\\/]") ~= nil
end

---@param name string raw user input or timestamp
---@return string sanitized basename without extension or directory parts
local function sanitize_basename(name)
  local s = name:gsub("[\\/]", "-"):gsub("%.%.", "-")
  s = s:gsub("[%c%z]", "")
  s = s:gsub("[^A-Za-z0-9._-]", "-"):gsub("%-+", "-"):gsub("^[.-]+", ""):gsub("[.-]+$", "")
  s = s:sub(1, 100)
  return s
end

---@param alt string
---@return string
local function escape_alt(alt)
  return alt:gsub("%]", "\\]"):gsub("\n", " ")
end

---@param path string relative path with forward slashes
---@param url_encode_spaces boolean?
---@return string
local function escape_path(path, url_encode_spaces)
  local p = path:gsub("\n", "")
  if url_encode_spaces then
    p = p:gsub(" ", "%%20")
  end
  return p:gsub("%(", "\\("):gsub("%)", "\\)")
end

---@param mime string
---@return string ext including dot
local function mime_to_ext(mime)
  if mime == "image/jpeg" then
    return ".jpg"
  elseif mime == "image/webp" then
    return ".webp"
  end
  return ".png"
end

---@param md_dir string absolute dir of the markdown file
---@param assets_dir string configured (relative or absolute)
---@param fname string filename with ext
---@param use_absolute boolean? insert absolute path instead of relative
---@return string assets_abs absolute dir to write to
---@return string insert_path path to insert (forward slashes)
local function resolve_paths(md_dir, assets_dir, fname, use_absolute)
  local assets_abs = is_absolute(assets_dir) and assets_dir or vim.fs.joinpath(md_dir, assets_dir)
  local dest = vim.fs.joinpath(assets_abs, fname)
  if use_absolute then
    return assets_abs, dest:gsub("\\", "/")
  end
  local rel = vim.fs.relpath(md_dir, dest) or (assets_dir .. "/" .. fname)
  rel = rel:gsub("\\", "/")
  return assets_abs, rel
end

---@param rel_path string
---@param alt string
---@param style ClipImageEmbedStyle
---@param url_encode_spaces boolean?
---@return string
local function make_markup(rel_path, alt, style, url_encode_spaces)
  local path = escape_path(rel_path, url_encode_spaces)
  if style == "obsidian" then
    local stem = vim.fn.fnamemodify(rel_path, ":t:r")
    if alt ~= "" and alt ~= stem then
      return string.format("![[%s|%s]]", path, escape_alt(alt))
    end
    return string.format("![[%s]]", path)
  end
  return string.format("![%s](%s)", escape_alt(alt), path)
end

---@param markup string
---@param style ClipImageEmbedStyle
---@return integer 0-based cursor column for the "alt" position
local function alt_cursor_col(markup, style)
  if style == "obsidian" then
    local pipe = markup:find("|", 1, true)
    if pipe then
      return pipe -- alias starts right after "|"
    end
    return #markup
  end
  local open = markup:find("[", 1, true)
  if open then
    return open -- first char inside "[...]"
  end
  return #markup
end

---@class ClipImageInsertOpts
---@field alt string?
---@field style ClipImageEmbedStyle?
---@field add_blank_lines boolean?
---@field cursor_after_paste ClipImageCursorMode?

---@param buf integer
---@param markup string
---@param opts ClipImageInsertOpts?
local function insert_markup(buf, markup, opts)
  opts = opts or {}
  local style = opts.style or "markdown"
  local alt = opts.alt or ""
  local add_blanks = opts.add_blank_lines ~= false
  local cursor_mode = opts.cursor_after_paste or "auto"

  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local ok_cursor, cursor = pcall(vim.api.nvim_win_get_cursor, 0)
  if not ok_cursor or not cursor then
    return
  end
  local row_1based = cursor[1]
  local line_count = vim.api.nvim_buf_line_count(buf)
  if row_1based < 1 then
    row_1based = 1
  elseif row_1based > line_count then
    row_1based = line_count
  end

  local cur_line = ""
  pcall(function()
    cur_line = vim.api.nvim_get_current_line()
  end)

  local function place_cursor(markup_row)
    local col
    if cursor_mode == "end" then
      col = #markup
    elseif cursor_mode == "alt" then
      col = alt_cursor_col(markup, style)
    else -- "auto": jump into empty alt so you can type, else end of line
      col = alt == "" and alt_cursor_col(markup, style) or #markup
    end
    pcall(vim.api.nvim_win_set_cursor, 0, { markup_row, col })
  end

  -- Keep the whole paste a single undo step with the save that preceded it.
  pcall(vim.cmd, "undojoin")

  if cur_line:match("^%s*$") then
    vim.api.nvim_buf_set_lines(buf, row_1based - 1, row_1based, false, { markup })
    place_cursor(row_1based)
  elseif not add_blanks then
    vim.api.nvim_buf_set_lines(buf, row_1based, row_1based, false, { markup })
    place_cursor(row_1based + 1)
  else
    local next_line = vim.api.nvim_buf_get_lines(buf, row_1based, row_1based + 1, false)[1]
    local block
    if next_line == nil or next_line:match("^%s*$") then
      block = { "", markup } -- trailing blank already exists (or EOF): don't double it
    else
      block = { "", markup, "" }
    end
    vim.api.nvim_buf_set_lines(buf, row_1based, row_1based, false, block)
    place_cursor(row_1based + 2)
  end
end

-- ---------------------------------------------------------------------------
-- Prompts (vim.ui.input when available, so dressing/snacks/telescope work)
-- ---------------------------------------------------------------------------

---@param prompt_opts { prompt: string, default: string }
---@param cb fun(input: string?) async completion; nil means cancelled
local function prompt_input(prompt_opts, cb)
  if vim.ui and vim.ui.input then
    vim.ui.input(prompt_opts, function(input)
      cb(input)
    end)
    return
  end
  -- Sync fallback (plain headless / minimal UI).
  local input = vim.fn.input(prompt_opts.prompt, prompt_opts.default or "")
  if input == "" then
    cb(nil)
    return
  end
  cb(input)
end

---@param alt string
---@param fname string filename with ext
---@return string resolved alt text ("{filename}" expands to the file stem)
local function resolve_alt(alt, fname)
  if alt == "{filename}" then
    return vim.fn.fnamemodify(fname, ":r")
  end
  return alt
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

---Paste clipboard screenshot into the current markdown buffer (async, non-blocking).
---@param override ClipImagePasteOverride?
function M.paste_image(override)
  override = override or {}
  local cfg = vim.tbl_deep_extend("force", M.config, {
    embed_style = override.embed_style,
    assets_dir = override.assets_dir,
    prompt_filename = override.prompt_filename,
    prompt_alt_text = override.prompt_alt_text,
  })

  if not override.allow_any_filetype then
    local ft = vim.bo.filetype
    if not vim.tbl_contains(M.config.filetypes, ft) then
      notify(
        string.format("Not a markdown filetype (%s). Save as .md or use :PasteImage!", ft),
        vim.log.levels.WARN
      )
      return
    end
  end

  local buf = vim.api.nvim_get_current_buf()
  local md_path = vim.api.nvim_buf_get_name(buf)
  if md_path == "" then
    notify("Save the markdown file first (unnamed buffer has no ./assets).", vim.log.levels.WARN)
    return
  end
  local md_dir = vim.fn.fnamemodify(md_path, ":p:h")

  local available, hint = M.is_available()
  if not available then
    notify("No clipboard tool found (" .. hint .. ")", vim.log.levels.ERROR)
    return
  end

  local clip = detect_clipboard()
  if not clip then
    notify(
      "No image in clipboard. Copy a screenshot first (check :checkhealth markdown-clip-image).",
      vim.log.levels.WARN
    )
    return
  end

  local ext = mime_to_ext(clip.mime)

  local function with_basename(cb)
    if cfg.prompt_filename then
      prompt_input({
        prompt = "Image filename (without ext): ",
        default = cfg.filename_prefix .. os.date(cfg.filename_format),
      }, function(input)
        if input == nil or input == "" then
          notify("Cancelled.", vim.log.levels.INFO)
          return
        end
        -- Strip a trailing image ext the user may have typed (case-insensitive).
        local basename = sanitize_basename(
          input
            :gsub("%.[Pp][Nn][Gg]$", "")
            :gsub("%.[Jj][Pp][Ee]?[Gg]$", "")
            :gsub("%.[Ww][Ee][Bb][Pp]$", "")
        )
        if basename == "" then
          notify("Invalid filename.", vim.log.levels.WARN)
          return
        end
        cb(basename)
      end)
    else
      cb(sanitize_basename(cfg.filename_prefix .. os.date(cfg.filename_format)))
    end
  end

  local function with_alt(fname, cb)
    if cfg.prompt_alt_text then
      local fallback = cfg.default_alt ~= "" and resolve_alt(cfg.default_alt, fname)
        or vim.fn.fnamemodify(fname, ":r")
      prompt_input({ prompt = "Alt text: ", default = fallback }, function(input)
        if input == nil then
          notify("Cancelled.", vim.log.levels.INFO)
          return
        end
        cb(resolve_alt(input, fname))
      end)
    else
      cb(resolve_alt(cfg.default_alt, fname))
    end
  end

  with_basename(function(basename)
    -- Reserve a non-colliding filename before saving (same-second pastes).
    local assets_abs, _ =
      resolve_paths(md_dir, cfg.assets_dir, basename .. ext, cfg.use_absolute_path)
    if vim.fn.isdirectory(assets_abs) == 0 then
      local ok, err = pcall(vim.fn.mkdir, assets_abs, "p")
      if not ok or vim.fn.isdirectory(assets_abs) == 0 then
        notify(
          "Could not create assets dir: " .. assets_abs .. " " .. tostring(err),
          vim.log.levels.ERROR
        )
        return
      end
    end

    local fname = basename .. ext
    local dest = vim.fs.joinpath(assets_abs, fname)
    local counter = 1
    while vim.fn.filereadable(dest) == 1 do
      counter = counter + 1
      fname = string.format("%s-%d%s", basename, counter, ext)
      dest = vim.fs.joinpath(assets_abs, fname)
    end

    if cfg.show_progress then
      notify("Saving clipboard image…", vim.log.levels.INFO)
    end

    save_clipboard_image_async(dest, clip, function(ok, err)
      if not ok then
        notify("Failed to save clipboard image: " .. tostring(err), vim.log.levels.ERROR)
        return
      end

      local _, insert_path = resolve_paths(md_dir, cfg.assets_dir, fname, cfg.use_absolute_path)

      with_alt(fname, function(alt)
        local current = vim.api.nvim_get_current_buf()
        local target = vim.api.nvim_buf_is_valid(buf) and buf or current
        local markup = make_markup(insert_path, alt, cfg.embed_style, cfg.url_encode_spaces)
        insert_markup(target, markup, {
          alt = alt,
          style = cfg.embed_style,
          add_blank_lines = cfg.add_blank_lines,
          cursor_after_paste = cfg.cursor_after_paste,
        })
        if cfg.notify_on_success then
          notify("Saved " .. insert_path, vim.log.levels.INFO)
        end
      end)
    end)
  end)
end

---@param opts ClipImageConfig?
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  local ok, err = pcall(validate_config, M.config)
  if not ok then
    notify("Invalid config: " .. tostring(err), vim.log.levels.ERROR)
    M.config = vim.deepcopy(M.defaults)
  end

  vim.api.nvim_create_user_command("PasteImage", function(cmd_opts)
    local override = { allow_any_filetype = cmd_opts.bang }
    if cmd_opts.args == "obsidian" or cmd_opts.args == "markdown" then
      override.embed_style = cmd_opts.args
    elseif cmd_opts.args ~= "" then
      notify("Usage: :PasteImage[!] [markdown|obsidian]", vim.log.levels.WARN)
      return
    end
    M.paste_image(override)
  end, {
    nargs = "?",
    bang = true,
    force = true,
    complete = function(arg)
      return vim.tbl_filter(function(c)
        return c:find(arg, 1, true) == 1
      end, { "markdown", "obsidian" })
    end,
    desc = "Paste clipboard image into markdown file (:PasteImage! bypasses filetype guard)",
  })

  vim.api.nvim_clear_autocmds({ group = augroup })
  if M.config.keymap then
    vim.api.nvim_create_autocmd("FileType", {
      group = augroup,
      pattern = M.config.filetypes,
      callback = function(ev)
        vim.keymap.set("n", M.config.keymap, function()
          M.paste_image()
        end, {
          buffer = ev.buf,
          desc = "Paste clipboard image",
          silent = true,
        })
      end,
    })
  end
end

-- Exposed for headless tests only; not public API.
M._test = {
  sanitize_basename = sanitize_basename,
  escape_alt = escape_alt,
  escape_path = escape_path,
  mime_to_ext = mime_to_ext,
  resolve_paths = resolve_paths,
  make_markup = make_markup,
  resolve_alt = resolve_alt,
  alt_cursor_col = alt_cursor_col,
}

return M
