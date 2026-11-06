local M = {}

function M.capture(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local file = vim.api.nvim_buf_get_name(buf)
  local cwd = vim.fn.getcwd()
  local root = file ~= ""
      and vim.fs.root(file, { ".git", "Cargo.toml", "pyproject.toml", "Package.swift", "package.json" })
    or nil
  return {
    buf = buf,
    win = vim.api.nvim_get_current_win(),
    file = file,
    filetype = vim.bo[buf].filetype,
    cwd = cwd,
    root = root or cwd,
  }
end

function M.call(ctx, fn)
  if vim.api.nvim_buf_is_valid(ctx.buf) then
    return vim.api.nvim_buf_call(ctx.buf, fn)
  end
  error("The source buffer was deleted")
end

return M
