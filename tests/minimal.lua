vim.opt.rtp:prepend(vim.fn.getcwd())
local backend = vim.env.DAP_TOOLS_DAP_PATH or (vim.fn.stdpath("data") .. "/plugin-tools/nvim-dap")
assert(vim.fn.isdirectory(backend) == 1, "Set DAP_TOOLS_DAP_PATH to an nvim-dap checkout")
vim.opt.rtp:append(backend)
vim.g.loaded_wakatime = true
