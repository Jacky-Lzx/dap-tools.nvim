local M = {}

function M.check()
  vim.health.start("dap-tools.nvim")
  if vim.fn.has("nvim-0.11") == 0 then
    vim.health.error("Neovim 0.11+ is required", { "Upgrade Neovim" })
    return
  end
  local issues = {}
  local function problem(level, message, advice)
    issues[#issues + 1] = { level = level, message = message, advice = advice }
  end
  local dap = package.loaded.dap
  if not dap then
    if
      #vim.api.nvim_get_runtime_file("lua/dap.lua", false) == 0
      and #vim.api.nvim_get_runtime_file("lua/dap/init.lua", false) == 0
    then
      problem("error", "nvim-dap is unavailable; debugging cannot start.", { "Install/mount nvim-dap" })
    else
      vim.health.info("Backend not initialized; adapter checks deferred until launch. Details: :DapToolsInfo")
      return
    end
  else
    for name, adapter in pairs(dap.adapters) do
      if
        type(adapter) == "table"
        and adapter.type == "executable"
        and type(adapter.command) == "string"
        and vim.fn.executable(adapter.command) == 0
      then
        problem(
          "warn",
          name .. ": executable unavailable: " .. adapter.command .. "; this adapter cannot launch.",
          { "Install the adapter or correct its command" }
        )
      end
    end
  end

  table.sort(issues, function(a, b)
    if a.level ~= b.level then
      return a.level == "error"
    end
    return a.message < b.message
  end)
  for _, issue in ipairs(issues) do
    vim.health[issue.level](issue.message, issue.advice)
  end
  if #issues == 0 then
    vim.health.ok("Loaded debug adapter requirements are available.")
  end
  vim.health.info("Details: :DapToolsInfo")
end

return M
