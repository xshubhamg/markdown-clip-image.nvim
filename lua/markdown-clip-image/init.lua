--- markdown-clip-image: paste clipboard screenshots into markdown files.
--- Wayland-first (wl-paste), with X11 (xclip) and macOS (pngpaste) fallbacks.
---@module "markdown-clip-image"

---@alias ClipImageEmbedStyle "markdown"|"obsidian"
---@alias ClipImageBackend "wl-paste"|"xclip"|"pngpaste"

---@class ClipImageConfig
---@field assets_dir string Subdir next to the markdown file, or absolute path. Default: "assets"
---@field filename_prefix string Prefix for generated files. Default: "screenshot-"
---@field filename_format string os.date format for the timestamp. Default: "%Y-%m-%d-%H-%M-%S"
---@field embed_style ClipImageEmbedStyle Markup to insert. Default: "markdown"
---@field prompt_filename boolean Ask for filename via vim.fn.input()? Default: false
---@field prompt_alt_text boolean Ask for alt text? Default: false
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
  keymap = "<leader>p",
  filetypes = { "markdown", "mdx", "quarto", "rmd", "vimwiki" },
}

---@type ClipImageConfig
M.config = vim.deepcopy(M.defaults)

local augroup = vim.api.nvim_create_augroup("MarkdownClipImage", { clear = true })

local function notify(msg, level)
  vim.notify("[markdown-clip-image] " .. msg, level or vim.log.levels.INFO)
end

---@param cfg table
local function validate_config(cfg)
  vim.validate("assets_dir", cfg.assets_dir, "string")
  vim.validate("filename_prefix", cfg.filename_prefix, "string")
  vim.validate("filename_format", cfg.filename_format, "string")
  vim.validate("embed_style", cfg.embed_style, "string")
  vim.validate("prompt_filename", cfg.prompt_filename, "boolean")
  vim.validate("prompt_alt_text", cfg.prompt_alt_text, "boolean")
  if cfg.keymap ~= nil then
    vim.validate("keymap", cfg.keymap, "string")
  end
  vim.validate("filetypes", cfg.filetypes, "table")
  assert(
    cfg.embed_style == "markdown" or cfg.embed_style == "obsidian",
    "embed_style must be 'markdown' or 'obsidian'"
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
  return false, "none (install wl-clipboard, xclip, or pngpaste)"
end

---@param dest string absolute path to write
---@param clip ClipImageClipboard
---@return boolean ok
---@return string? err
local function save_clipboard_image(dest, clip)
  if clip.backend == "pngpaste" then
    local ok, _ = system_sync({ "pngpaste", dest }, 10000)
    if not ok then
      return false, "pngpaste failed (clipboard has no image?)"
    end
  else
    local args
    if clip.backend == "wl-paste" then
      args = { "wl-paste", "--type", clip.mime }
    else
      args = { "xclip", "-selection", "clipboard", "-t", clip.mime, "-o" }
    end
    if vim.system == nil then
      return false, "requires Neovim >= 0.10 (vim.system)"
    end
    -- Binary-safe: text=false keeps stdout as raw bytes.
    local res = vim.system(args, { text = false, timeout = 10000 }):wait()
    if res == nil or res.code ~= 0 or res.stdout == nil or #res.stdout == 0 then
      return false,
        string.format("%s failed (code %s)", clip.backend, res and res.code or "timeout")
    end
    local fh, open_err = io.open(dest, "wb")
    if not fh then
      return false, "cannot write " .. dest .. ": " .. tostring(open_err)
    end
    fh:write(res.stdout)
    fh:close()
  end

  local stat = vim.uv.fs_stat(dest)
  if not stat or stat.size == 0 then
    pcall(vim.fn.delete, dest)
    return false, "clipboard image was empty"
  end
  return true
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
---@return string
local function escape_path(path)
  return path:gsub("%)", "\\)"):gsub("\n", "")
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
---@return string assets_abs absolute dir to write to
---@return string rel_path path to insert (relative to md file, forward slashes)
local function resolve_paths(md_dir, assets_dir, fname)
  local assets_abs = is_absolute(assets_dir) and assets_dir or vim.fs.joinpath(md_dir, assets_dir)
  local dest = vim.fs.joinpath(assets_abs, fname)
  local rel = vim.fs.relpath(md_dir, dest) or (assets_dir .. "/" .. fname)
  rel = rel:gsub("\\", "/")
  return assets_abs, rel
end

---@param rel_path string
---@param alt string
---@param style ClipImageEmbedStyle
---@return string
local function make_markup(rel_path, alt, style)
  local path = escape_path(rel_path)
  if style == "obsidian" then
    local stem = vim.fn.fnamemodify(rel_path, ":t:r")
    if alt ~= "" and alt ~= stem then
      return string.format("![[%s|%s]]", path, escape_alt(alt))
    end
    return string.format("![[%s]]", path)
  end
  return string.format("![%s](%s)", escape_alt(alt), path)
end

---@param buf integer
---@param markup string
local function insert_markup(buf, markup)
  -- Cursor row is 1-based; buf lines are 0-based.
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row_1based = cursor[1]
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local line = vim.api.nvim_get_current_line()
  if line:match("^%s*$") then
    vim.api.nvim_set_current_line(markup)
    -- keep cursor on the inserted line
    vim.api.nvim_win_set_cursor(0, { row_1based, 0 })
  else
    vim.api.nvim_buf_set_lines(buf, row_1based, row_1based, false, { "", markup, "" })
    vim.api.nvim_win_set_cursor(0, { row_1based + 2, 0 })
  end
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

---Paste clipboard screenshot into the current markdown buffer.
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
    notify("No image in clipboard. Copy a screenshot first.", vim.log.levels.WARN)
    return
  end

  local ext = mime_to_ext(clip.mime)
  local basename
  if cfg.prompt_filename then
    local default_name = cfg.filename_prefix .. os.date(cfg.filename_format)
    local input = vim.fn.input("Image filename (without ext): ", default_name)
    if input == "" then -- <Esc> and empty both yield ""
      notify("Cancelled.", vim.log.levels.INFO)
      return
    end
    -- Strip a trailing image ext the user may have typed (case-insensitive).
    basename = sanitize_basename(
      input
        :gsub("%.[Pp][Nn][Gg]$", "")
        :gsub("%.[Jj][Pp][Ee]?[Gg]$", "")
        :gsub("%.[Ww][Ee][Bb][Pp]$", "")
    )
    if basename == "" then
      notify("Invalid filename.", vim.log.levels.WARN)
      return
    end
  else
    basename = sanitize_basename(cfg.filename_prefix .. os.date(cfg.filename_format))
  end

  -- Reserve a non-colliding filename before saving (same-second pastes).
  local assets_abs, _ = resolve_paths(md_dir, cfg.assets_dir, basename .. ext)
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

  local ok, err = save_clipboard_image(dest, clip)
  if not ok then
    notify("Failed to save clipboard image: " .. tostring(err), vim.log.levels.ERROR)
    return
  end

  local _, rel_path = resolve_paths(md_dir, cfg.assets_dir, fname)

  local alt = vim.fn.fnamemodify(fname, ":r")
  if cfg.prompt_alt_text then
    local input = vim.fn.input("Alt text: ", alt)
    if input ~= "" then
      alt = input
    end
  end

  insert_markup(buf, make_markup(rel_path, alt, cfg.embed_style))
  notify("Saved " .. rel_path, vim.log.levels.INFO)
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

return M
