# markdown-clip-image.nvim

One job: paste screenshots from clipboard into markdown files. Wayland-first.

`wl-paste` → `assets/screenshot-<timestamp>.png` → `![alt](assets/...)` at cursor. No dependencies.

![Neovim >= 0.10](https://img.shields.io/badge/Neovim-%3E%3D0.10-green)
![License: MIT](https://img.shields.io/badge/License-MIT-blue)

## Features

- Wayland `wl-paste` primary, `xclip` (X11) and `pngpaste` (macOS) fallbacks
- Saves next to the markdown file (`./assets/`), creates dir if missing
- `markdown` (`![alt](path)`) and `obsidian` (`![[path]]` / `![[path|alt]]`) styles
- Timestamped, collision-safe filenames (`-2`, `-3` on same-second paste)
- Filename sanitization (no `../` traversal), absolute `assets_dir` support
- `<leader>p` + `:PasteImage[!] [markdown|obsidian]`, `:checkhealth markdown-clip-image`

## Requirements

- Neovim >= 0.10 (`vim.system`, `vim.fs`, `vim.uv`)
- One clipboard tool:
  - Wayland: `wl-clipboard` (`sudo pacman -S wl-clipboard` / `apt install wl-clipboard`)
  - X11: `xclip`
  - macOS: `pngpaste` (`brew install pngpaste`)

## Install (lazy.nvim)

```lua
{
  "your-username/markdown-clip-image.nvim",
  ft = { "markdown", "mdx", "quarto", "rmd", "vimwiki" },
  cmd = { "PasteImage" },
  keys = {
    { "<leader>p", function() require("markdown-clip-image").paste_image() end, ft = "markdown", desc = "Paste clipboard image" },
  },
  ---@type ClipImageConfig
  opts = {
    assets_dir = "assets", -- relative to md file, or absolute path
    filename_prefix = "screenshot-",
    filename_format = "%Y-%m-%d-%H-%M-%S", -- os.date format
    embed_style = "markdown", -- or "obsidian"
    prompt_filename = false, -- vim.fn.input for name
    prompt_alt_text = false, -- vim.fn.input for alt
  },
  config = function(_, opts)
    require("markdown-clip-image").setup(opts)
  end,
}
```

Local dev:

```lua
{ dir = "~/Work/markdown-clip-image.nvim", name = "markdown-clip-image", ft = { "markdown" }, config = true }
```

## Usage

1. Screenshot to clipboard (`grim + slurp`, Flameshot, GNOME screenshot…)
2. In a markdown buffer:
   - `<leader>p`, or
   - `:PasteImage` (configured style), `:PasteImage obsidian`, `:PasteImage markdown`
   - `:PasteImage!` bypasses the filetype guard

Empty line → replaced. Non-empty line → image block inserted below.

## Config reference

| key | default | notes |
|-----|---------|-------|
| `assets_dir` | `"assets"` | relative to md file, or absolute |
| `filename_prefix` | `"screenshot-"` | sanitized `[A-Za-z0-9._-]` |
| `filename_format` | `"%Y-%m-%d-%H-%M-%S"` | `os.date` |
| `embed_style` | `"markdown"` | `"markdown"` or `"obsidian"` |
| `prompt_filename` | `false` | empty input cancels |
| `prompt_alt_text` | `false` | empty keeps filename stem |
| `keymap` | `"<leader>p"` | `nil` disables |
| `filetypes` | markdown, mdx, quarto, rmd, vimwiki | keymap + guard |

## Health / Tests / Lint

```vim
:checkhealth markdown-clip-image
```

```sh
nvim --headless -l tests/minimal.lua
stylua --check .
```

## How it works

- `wl-paste --list-types` must contain `image/png|jpeg|webp`
- Binary-safe `vim.system({ "wl-paste", "--type", mime })` (no shell redirect), writes `wb` to `assets/…`
- Verifies non-empty file, inserts `vim.fs.relpath(md_dir, dest)` for portability
