# markdown-clip-image.nvim

Paste clipboard screenshots into Markdown. Wayland-first, zero dependencies.

Copy a screenshot, press `<leader>p`, get `![](assets/screenshot-….png)` at your cursor.
Non-blocking, undo-friendly, and works with your `vim.ui` picker (dressing, snacks, Telescope).

![Neovim >= 0.10](https://img.shields.io/badge/Neovim-%3E%3D0.10-green)
![License: MIT](https://img.shields.io/badge/License-MIT-blue)
![No dependencies](https://img.shields.io/badge/deps-0-blue)

- [Features](#features)
- [Requirements](#requirements)
- [Install](#install)
- [Quickstart](#quickstart)
- [Usage](#usage)
- [Configuration](#configuration)
- [API](#api)
- [Troubleshooting](#troubleshooting)
- [Compare](#compare)
- [FAQ](#faq)
- [Contributing](#contributing)

## Features

- **Wayland-first**: `wl-paste`, with `xclip` (X11) and `pngpaste` (macOS) fallbacks
- **Async paste**: the editor never blocks, even on slow clipboards; optional progress notice
- **Smart insert**: empty line → replaced; other lines → padded block below (no doubled blanks, single undo step)
- **Smart cursor**: lands inside `![]` when alt text is empty so you can type, else end of line
- **Modern prompts**: `prompt_filename` / `prompt_alt_text` use `vim.ui.input` (dressing.nvim, snacks.nvim compatible)
- **Two markup styles**: `markdown` (`![alt](path)`) and `obsidian` (`![[path]]` / `![[path|alt]]`)
- **Portable paths**: relative to the Markdown file by default; spaces become `%20`; `(`/`)` escaped
- **Safe filenames**: timestamped, collision-proof (`-2`, `-3`), sanitized against `../` traversal
- **Quiet when you want**: `notify_on_success = false` for a silent flow
- **First-class diagnostics**: `:checkhealth markdown-clip-image` checks tools, clipboard, and assets dir

## Requirements

- Neovim >= 0.10 (`vim.system`, `vim.fs`, `vim.uv`, `vim.ui.input`)
- One clipboard backend:

| OS | Tool | Install |
|----|------|---------|
| Wayland | `wl-paste` | `sudo pacman -S wl-clipboard` / `sudo apt install wl-clipboard` |
| X11 | `xclip` | `sudo pacman -S xclip` / `sudo apt install xclip` |
| macOS | `pngpaste` | `brew install pngpaste` |

Supported image types: `image/png`, `image/jpeg`, `image/webp`.

## Install

### lazy.nvim (recommended)

```lua
{
  "your-username/markdown-clip-image.nvim",
  ft = { "markdown", "mdx", "quarto", "rmd", "vimwiki" },
  cmd = { "PasteImage" },
  keys = {
    { "<leader>p", function() require("markdown-clip-image").paste_image() end, desc = "Paste clipboard image" },
  },
  ---@type ClipImageConfig
  opts = {
    assets_dir = "assets",
    embed_style = "markdown", -- or "obsidian"
  },
  config = function(_, opts)
    require("markdown-clip-image").setup(opts)
  end,
}
```

### mini.deps

```lua
MiniDeps.add({ source = "your-username/markdown-clip-image.nvim" })
require("markdown-clip-image").setup({})
```

### packer.nvim

```lua
use({ "your-username/markdown-clip-image.nvim", config = function()
  require("markdown-clip-image").setup({})
end })
```

### vim-plug

```vim
Plug 'your-username/markdown-clip-image.nvim'
```

```lua
require("markdown-clip-image").setup({})
```

## Quickstart

1. Take a screenshot to the clipboard (`grim + slurp`, Flameshot, GNOME Screenshot…).
2. Open a **saved** Markdown file.
3. Press `<leader>p` (or run `:PasteImage`).

Result:

```markdown
![](assets/screenshot-2026-09-14-15-30-00.png)
```

The file lands in `./assets/` next to your note; the directory is created if missing.

## Usage

| Action | How |
|--------|-----|
| Paste with configured style | `<leader>p` or `:PasteImage` |
| Paste as Obsidian embed | `:PasteImage obsidian` |
| Paste as Markdown image | `:PasteImage markdown` |
| Bypass filetype guard | `:PasteImage!` (any filetype) |
| Diagnose setup | `:checkhealth markdown-clip-image` |

Insert behavior:

- Cursor on an **empty line** → the line becomes the image markup.
- Cursor on a **text line** → a padded block is inserted below (`text`, blank, image, blank).
- The paste is **one undo step** (`u` removes the whole block).
- With empty alt text the cursor lands **inside `![]`** so you can type immediately.

Prompted flow:

```lua
require("markdown-clip-image").setup({
  prompt_filename = true, -- rename each shot via vim.ui.input
  prompt_alt_text = true, -- set alt text via vim.ui.input
})
```

`<Esc>` (or empty filename) cancels cleanly — no file is written.

## Configuration

Full defaults — copy what you need:

```lua
---@type ClipImageConfig
require("markdown-clip-image").setup({
  assets_dir = "assets", -- relative to the md file, or absolute
  filename_prefix = "screenshot-",
  filename_format = "%Y-%m-%d-%H-%M-%S", -- os.date format
  embed_style = "markdown", -- "markdown" | "obsidian"

  prompt_filename = false, -- vim.ui.input for the filename
  prompt_alt_text = false, -- vim.ui.input for alt text
  default_alt = "", -- alt when not prompting; "{filename}" = file stem

  url_encode_spaces = true, -- "my shot.png" -> "my%20shot.png" in markup
  use_absolute_path = false, -- true inserts /abs/path instead of relative
  add_blank_lines = true, -- pad the block (never doubles existing blanks)
  cursor_after_paste = "auto", -- "auto" | "alt" | "end"

  notify_on_success = true, -- false for a silent flow
  show_progress = true, -- "Saving clipboard image…" while writing

  keymap = "<leader>p", -- nil disables the buffer-local mapping
  filetypes = { "markdown", "mdx", "quarto", "rmd", "vimwiki" },
})
```

| Key | Default | Notes |
|-----|---------|-------|
| `assets_dir` | `"assets"` | Relative to the Markdown file, or absolute. Created with `mkdir -p`. |
| `filename_prefix` / `filename_format` | `"screenshot-"` / `"%Y-%m-%d-%H-%M-%S"` | Sanitized to `[A-Za-z0-9._-]`; collisions get `-2`, `-3`. |
| `embed_style` | `"markdown"` | Per-paste override: `:PasteImage obsidian`. |
| `prompt_filename` | `false` | Trailing `.png/.jpg/.webp` you type is stripped; empty cancels. |
| `prompt_alt_text` | `false` | Empty input keeps the default. |
| `default_alt` | `""` | `""` → `![](…)` / `![[…]]`; `"{filename}"` → old stem behavior. |
| `url_encode_spaces` | `true` | Keeps strict renderers happy; files on disk keep real spaces. |
| `use_absolute_path` | `false` | Useful for some Obsidian vault setups. |
| `add_blank_lines` | `true` | `false` inserts a bare line below the cursor. |
| `cursor_after_paste` | `"auto"` | `"alt"` always jumps into alt/alias; `"end"` always goes to EOL. |
| `notify_on_success` / `show_progress` | `true` / `true` | Errors and warnings always notify. |
| `keymap` | `"<leader>p"` | Buffer-local for `filetypes`; `nil` disables. |
| `filetypes` | markdown family | Guards both the keymap and `:PasteImage` (without `!`). |

Per-paste Lua overrides (e.g. project autocmds):

```lua
require("markdown-clip-image").paste_image({ embed_style = "obsidian" })
```

## API

```lua
require("markdown-clip-image").setup(opts?: ClipImageConfig)
require("markdown-clip-image").paste_image(override?: ClipImagePasteOverride)
require("markdown-clip-image").get_config(): ClipImageConfig
require("markdown-clip-image").is_available(): boolean, string
```

`ClipImagePasteOverride`: `embed_style?`, `assets_dir?`, `prompt_filename?`,
`prompt_alt_text?`, `allow_any_filetype?` (what `:PasteImage!` sets).

## Troubleshooting

**`:checkhealth markdown-clip-image` first.** It reports the backend, whether the
clipboard currently holds an image, and whether the assets dir is writable.

| Symptom | Cause / Fix |
|---------|-------------|
| `No image in clipboard` | Copy a screenshot first. On Wayland, copy from a Wayland-native app; XWayland clipboard can be invisible to `wl-paste`. |
| `wl-paste --list-types failed` | No Wayland seat in this shell (SSH, tmux started outside the session, `sudo`). Run `echo $WAYLAND_DISPLAY`; re-attach inside the graphical session. |
| `No clipboard tool found` | Install per the [Requirements](#requirements) table. |
| `Save the markdown file first` | The buffer is unnamed — `./assets` is resolved relative to the file, so save it first. |
| `Could not create assets dir` | Parent isn't writable; point `assets_dir` at an absolute writable path. |
| Paste works but preview shows a broken image | The file is referenced relative to the note — expected when the note moves. Set `use_absolute_path = true` only if your setup needs it. |
| `xclip` finds nothing on Wayland | Don't mix backends: use `wl-paste` under Wayland, `xclip` under X11. The plugin never falls through to a stale X11 clipboard when `wl-paste` answers. |
| JPEG pastes as `.jpg` / WebP as `.webp` | Intended — the extension follows the clipboard MIME. |

## Compare

| | markdown-clip-image.nvim | img-clip.nvim | paste-image.nvim |
|---|---|---|---|
| Dependencies | 0 | 0 | 0–1 |
| Wayland-first | yes | yes | partial |
| Async paste | yes | yes | sync |
| Obsidian embeds | yes | yes | no |
| `vim.ui` prompts | yes | yes | no |
| Scope | one job: paste well | full image toolkit (crop, resize, templates) | minimal paste |

Pick this plugin if you want the smallest thing that pastes correctly on modern
Linux. Pick img-clip if you need image processing and templates.

## FAQ

**Where do images go?**
`./assets/screenshot-<timestamp>.png` next to the Markdown file (or your absolute `assets_dir`).

**Can I silence it?**
Yes: `setup({ notify_on_success = false, show_progress = false })`. Errors still notify.

**Does it work with Obsidian vaults?**
Yes: `embed_style = "obsidian"` inserts `![[path]]` (or `![[path|alt]]` when alt differs from the stem).

**Does it work over SSH?**
Only if the remote shell can reach your clipboard (`wl-paste` needs the Wayland seat). For SSH editing, screenshot locally or use a clipboard-forwarding setup.

**Is `vim.fn.input` still used?**
Only as a fallback. When `vim.ui.input` exists (stock Neovim has it), your picker UI (dressing/snacks) is used automatically.

## Contributing

```sh
nvim --headless -l tests/minimal.lua
stylua --check .
```

PRs welcome: keep the scope tight (paste well), add a test in `tests/minimal.lua`,
and update `README.md` + `doc/markdown-clip-image.txt`.

## License

MIT — see [LICENSE](LICENSE).
