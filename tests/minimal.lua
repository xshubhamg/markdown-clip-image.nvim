-- Minimal headless tests (no plenary needed): nvim --headless -l tests/minimal.lua
-- Asserts public API, config validation, and pure markup/path helpers.

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
assert_eq("default default_alt", mod.get_config().default_alt, "")
assert_eq("default url_encode_spaces", mod.get_config().url_encode_spaces, true)
assert_eq("default add_blank_lines", mod.get_config().add_blank_lines, true)
assert_eq("default cursor_after_paste", mod.get_config().cursor_after_paste, "auto")
assert_eq("default notify_on_success", mod.get_config().notify_on_success, true)
assert_eq("default show_progress", mod.get_config().show_progress, true)

-- 2. invalid config falls back to defaults (no throw)
mod.setup({ embed_style = "bogus" })
assert_eq("invalid embed_style falls back", mod.get_config().embed_style, "markdown")
mod.setup({ cursor_after_paste = "bogus" })
assert_eq("invalid cursor falls back", mod.get_config().cursor_after_paste, "auto")

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

-- 6. pure helpers
local t = mod._test
assert_eq("sanitize traversal", t.sanitize_basename("../../etc/passwd"), "etc-passwd")
assert_eq("mime jpg", t.mime_to_ext("image/jpeg"), ".jpg")
assert_eq("mime webp", t.mime_to_ext("image/webp"), ".webp")
assert_eq("mime png fallback", t.mime_to_ext("image/png"), ".png")
assert_eq("escape parens", t.escape_path("a/b (1).png", false), "a/b \\(1\\).png")
assert_eq("encode spaces", t.escape_path("a/my shot.png", true), "a/my%20shot.png")
assert_eq("markdown empty alt", t.make_markup("assets/a.png", "", "markdown", true), "![](assets/a.png)")
assert_eq(
  "markdown with alt",
  t.make_markup("assets/a.png", "shot", "markdown", true),
  "![shot](assets/a.png)"
)
assert_eq("obsidian plain", t.make_markup("assets/a.png", "", "obsidian", true), "![[assets/a.png]]")
assert_eq(
  "obsidian alias",
  t.make_markup("assets/a.png", "shot", "obsidian", true),
  "![[assets/a.png|shot]]"
)
assert_eq("alt {filename}", t.resolve_alt("{filename}", "my-shot.png"), "my-shot")
assert_eq("alt passthrough", t.resolve_alt("", "my-shot.png"), "")

-- 7. resolve_paths: relative default, absolute opt-in
local abs_dir, rel = t.resolve_paths("/notes", "assets", "a.png", false)
assert_eq("rel assets_abs", abs_dir, "/notes/assets")
assert_eq("rel path", rel, "assets/a.png")
local _, ap = t.resolve_paths("/notes", "assets", "a.png", true)
assert_eq("absolute path", ap, "/notes/assets/a.png")

if failures > 0 then
  print(failures .. " FAILURES")
  os.exit(1)
end
print("ALL PASS")
