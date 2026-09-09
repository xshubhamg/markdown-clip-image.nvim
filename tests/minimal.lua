-- Minimal headless tests (no plenary needed): nvim --headless -l tests/minimal.lua
-- Asserts pure helpers indirectly via public API + config validation.

vim.opt.rtp:prepend(vim.fn.getcwd())

local mod = require("markdown-clip-image")
local failures = 0
local function assert_eq(name, got, want)
  if got ~= want then
    failures = failures + 1
    print(string.format("FAIL %s: got %s want %s", name, vim.inspect(got), vim.inspect(want)))
  else
    print("PASS " .. name)
  end
end

-- 1. defaults
mod.setup({})
assert_eq("default assets_dir", mod.get_config().assets_dir, "assets")
assert_eq("default embed_style", mod.get_config().embed_style, "markdown")

-- 2. invalid config falls back to defaults (no throw)
mod.setup({ embed_style = "bogus" })
assert_eq("invalid embed_style falls back", mod.get_config().embed_style, "markdown")

-- 3. setup is idempotent (no E1741 on re-setup, no duplicate autocmds)
mod.setup({})
mod.setup({ embed_style = "obsidian" })
assert_eq("re-setup ok", mod.get_config().embed_style, "obsidian")
assert_eq("command exists", vim.fn.exists(":PasteImage"), 2)

-- 4. is_available returns bool + string
local avail, hint = mod.is_available()
assert(type(avail) == "boolean", "is_available bool")
assert(type(hint) == "string", "is_available hint")
print("INFO clipboard: " .. tostring(avail) .. " (" .. hint .. ")")

-- 5. unnamed buffer refuses (no crash)
vim.cmd("enew")
vim.bo.filetype = "markdown"
mod.paste_image() -- should notify "Save the markdown file first", not throw
print("PASS unnamed buffer no-throw")

if failures > 0 then
  print(failures .. " FAILURES")
  os.exit(1)
end
print("ALL PASS")
