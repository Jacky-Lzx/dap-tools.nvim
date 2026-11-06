if vim.g.loaded_dap_tools then
  return
end
vim.g.loaded_dap_tools = true
require("dap_tools")._bootstrap()
