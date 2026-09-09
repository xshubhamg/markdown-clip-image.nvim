local M = {}

function M.check()
  vim.health.start("markdown-clip-image")
  if vim.fn.has("nvim-0.10") == 1 then
    vim.health.ok("Neovim >= 0.10")
  else
    vim.health.error("Neovim >= 0.10 required (vim.system, vim.fs)")
  end

  local available, hint = require("markdown-clip-image").is_available()
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
end

return M
