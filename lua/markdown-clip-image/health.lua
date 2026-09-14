local M = {}

function M.check()
  vim.health.start("markdown-clip-image")

  if vim.fn.has("nvim-0.10") == 1 then
    vim.health.ok("Neovim >= 0.10")
  else
    vim.health.error("Neovim >= 0.10 required (vim.system, vim.fs, vim.uv)")
  end

  local mod_ok, mod = pcall(require, "markdown-clip-image")
  if not mod_ok then
    vim.health.error("Could not require('markdown-clip-image'): " .. tostring(mod))
    return
  end

  -- Config sanity (setup() already falls back to defaults, but surface it here).
  local ok_cfg, cfg_or_err = pcall(mod.get_config)
  if not ok_cfg then
    vim.health.error("get_config() failed: " .. tostring(cfg_or_err))
  else
    local cfg = cfg_or_err
    vim.health.info(
      string.format(
        "config: style=%s assets_dir=%s keymap=%s filetypes=%s",
        cfg.embed_style,
        cfg.assets_dir,
        tostring(cfg.keymap),
        table.concat(cfg.filetypes, ",")
      )
    )
    if cfg.keymap then
      local maps = vim.api.nvim_get_keymap("n")
      local found = false
      for _, m in ipairs(maps) do
        if m.lhs == cfg.keymap then
          found = true
          break
        end
      end
      if found then
        vim.health.warn(
          "A global normal mapping already uses " .. cfg.keymap .. " (buffer maps still apply)"
        )
      end
    end
  end

  -- Clipboard tools.
  local available, hint = mod.is_available()
  if available then
    vim.health.ok("Clipboard tool: " .. hint)
  else
    vim.health.error("No clipboard tool (" .. hint .. ")")
  end
  for _, tool in ipairs({ "wl-paste", "xclip", "pngpaste" }) do
    if vim.fn.executable(tool) == 1 then
      vim.health.info(tool .. " found at " .. vim.fn.exepath(tool))
    end
  end

  -- Wayland session hints (most common "it worked yesterday" cause).
  if vim.fn.executable("wl-paste") == 1 then
    if not vim.env.WAYLAND_DISPLAY and not vim.env.WAYLAND_SOCKET then
      vim.health.warn("wl-paste exists but WAYLAND_DISPLAY is unset (SSH/no Wayland seat?)")
    end
    local res = vim.system({ "wl-paste", "--list-types" }, { text = true, timeout = 3000 }):wait()
    if res == nil then
      vim.health.warn("wl-paste --list-types timed out")
    elseif res.code ~= 0 then
      vim.health.warn("wl-paste --list-types failed (no Wayland seat in this shell?)")
    else
      local out = res.stdout or ""
      local mime = out:match("image/png") or out:match("image/jpeg") or out:match("image/webp")
      if mime then
        vim.health.ok("Clipboard holds an image (" .. mime .. ") — ready to :PasteImage")
      else
        vim.health.info("Clipboard has no image right now (copy a screenshot, then re-run)")
      end
    end
  elseif vim.fn.executable("xclip") == 1 and not vim.env.DISPLAY then
    vim.health.warn("xclip exists but DISPLAY is unset (X11 session missing?)")
  end

  -- Assets dir writability for the current buffer.
  local name = vim.api.nvim_buf_get_name(0)
  if name == "" then
    vim.health.info("Open a saved markdown file to check its assets dir")
  else
    local cfg = mod.get_config()
    local md_dir = vim.fn.fnamemodify(name, ":p:h")
    local first = mod._test ~= nil
    if first then
      local assets_abs = select(
        1,
        mod._test.resolve_paths(md_dir, cfg.assets_dir, "health-check.tmp", cfg.use_absolute_path)
      )
      if vim.fn.isdirectory(assets_abs) == 1 then
        local probe = assets_abs .. "/.health-write-check"
        local fh = io.open(probe, "w")
        if fh then
          fh:close()
          vim.fn.delete(probe)
          vim.health.ok("Assets dir writable: " .. assets_abs)
        else
          vim.health.error("Assets dir not writable: " .. assets_abs)
        end
      else
        vim.health.info("Assets dir will be created on paste: " .. assets_abs)
      end
    end
  end
end

return M
