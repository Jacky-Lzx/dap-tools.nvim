dofile("tests/minimal.lua")
local tools = require("dap_tools")
assert(not package.loaded.dap and not package.loaded["dap_tools.ui"])
local original = { presets = { cpp = true }, ui = { auto_open = false } }
tools.setup(original)
assert(not package.loaded.dap and not package.loaded["dap_tools.ui"], "setup must remain cold")
assert(original.ui.max_lines == nil and original.adapters == nil, "setup mutated caller options")
dofile("plugin/dap-tools.lua")
local dap = tools.backend()
assert(dap.configurations.cpp[1].type == "codelldb", "native runtime erased configured presets")
assert(dap.configurations.c[1].type == "codelldb")
local external = { name = "User config", type = "codelldb", request = "launch", program = "/tmp/user" }
table.insert(dap.configurations.cpp, external)
tools.setup({ presets = { swift = true }, ui = { auto_open = false } })
assert(dap.configurations.cpp[1] == external and dap.adapters.codelldb == nil)
assert(dap.adapters.lldb.command == (vim.fn.has("mac") == 1 and "xcrun" or "lldb-dap"))
local snapshot = dap.adapters.lldb
for _, bad in ipairs({
  { ui = { height = 0 } },
  { presets = { invented = true } },
  { configurations = { cpp = { { name = "x" } } } },
}) do
  local ok = pcall(tools.setup, bad)
  assert(not ok and dap.adapters.lldb == snapshot, "invalid setup changed live backend")
end
dap.adapters.lldb = { type = "executable", command = "user-lldb" }
tools.dispose()
assert(dap.adapters.lldb.command == "user-lldb", "dispose erased a user's replacement")
assert(dap.configurations.cpp[1] == external)
assert(vim.fn.exists(":DapTools") == 0)
vim.api.nvim_create_user_command("DapTools", function() end, {})
assert(not pcall(tools.setup), "setup overwrote a conflicting command")
vim.api.nvim_del_user_command("DapTools")
tools.setup()
vim.api.nvim_create_user_command("DapTools", function() end, { force = true })
tools.dispose()
assert(vim.fn.exists(":DapTools") == 2)
vim.api.nvim_del_user_command("DapTools")

local parse = require("dap_tools.prompt").parse_args
assert(
  vim.deep_equal(
    parse([[one "two words" '' three\ four '$HOME' "$(pwd)"]]),
    { "one", "two words", "", "three four", "$HOME", "$(pwd)" }
  )
)
assert(not parse([["unterminated]]))
assert(not parse("tail\\"))
assert(vim.deep_equal(parse("  "), {}))
print("contracts: cold setup, validation, registry/command ownership, argument parsing passed")
