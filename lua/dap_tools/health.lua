local M = {}
function M.check()
  vim.health.start("dap-tools")
  if vim.fn.has("nvim-0.11") == 1 then
    vim.health.ok("Neovim >= 0.11")
  else
    vim.health.error("Neovim >= 0.11 required")
  end
  local ok, dap = pcall(require("dap_tools").backend)
  if not ok then
    vim.health.error(tostring(dap))
    return
  end
  vim.health.ok("nvim-dap backend available; panel uses no UI plugin dependencies")
  for name, adapter in pairs(dap.adapters) do
    if type(adapter) == "function" then
      vim.health.info(name .. ": resolved when launching")
    elseif adapter.type == "executable" then
      if vim.fn.executable(adapter.command) == 1 then
        vim.health.ok(name .. ": " .. adapter.command)
      else
        vim.health.warn(name .. ": executable unavailable: " .. tostring(adapter.command))
      end
    else
      vim.health.info(name .. ": " .. tostring(adapter.type))
    end
  end
end
return M
