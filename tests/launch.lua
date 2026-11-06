dofile("tests/minimal.lua")
local tools = require("dap_tools")
local configs = {
  { name = "First", type = "fake", request = "launch", program = "${file}", cwd = "${workspaceFolder}" },
  { name = "Second", type = "fake", request = "launch", program = "${file}" },
}
tools.setup({ configurations = { python = configs } })
vim.cmd("edit /tmp/dap-tools-launch-source.py")
vim.bo.filetype = "python"
local source = vim.api.nvim_get_current_buf()
local dap, selections, inputs, runs = tools.backend(), {}, {}, {}
dap.run = function(config)
  runs[#runs + 1] = config
end
vim.ui.select = function(items, _, callback)
  selections[#selections + 1] = { items, callback }
end
vim.ui.input = function(_, callback)
  inputs[#inputs + 1] = callback
end
tools.run()
vim.cmd("enew")
tools.run("Second", { context = require("dap_tools.context").capture(source) })
assert(#runs == 1 and runs[1].program == vim.api.nvim_buf_get_name(source))
selections[1][2](selections[1][1][1])
assert(#runs == 1, "stale configuration picker launched")
tools.run("First", { context = require("dap_tools.context").capture(source), prompt_args = true })
inputs[1](nil)
assert(#runs == 1, "cancelled argument input launched")
tools.run("First", { context = require("dap_tools.context").capture(source), prompt_args = true })
inputs[2]([[--name "two words"]])
assert(#runs == 2 and vim.deep_equal(runs[2].args, { "--name", "two words" }))
assert(configs[1].args == nil)
tools.run_last()
assert(#runs == 3 and vim.deep_equal(runs[3].args, { "--name", "two words" }))
local completed
tools.setup({
  configurations = { python = configs },
  before_start = function(_, ctx, done)
    assert(ctx.buf == source)
    completed = done
  end,
})
tools.run("First", { context = require("dap_tools.context").capture(source) })
tools.cancel_launch()
completed()
vim.wait(20)
assert(#runs == 3, "cancelled asynchronous preparation launched")
local project = vim.fn.tempname()
vim.fn.mkdir(project .. "/.vscode", "p")
vim.fn.writefile({
  vim.json.encode({
    configurations = { { name = "First", type = "fake", request = "launch", program = "/project/override" } },
  }),
}, project .. "/.vscode/launch.json")
local project_configs = tools.configurations({ root = project, filetype = "python" })
assert(#project_configs == 2 and project_configs[1].program == "/project/override")
vim.fn.delete(project, "rf")
local child = { id = 12, config = { name = "Child" } }
local root = { id = 11, config = { name = "Root" }, children = { [12] = child } }
dap.sessions = function()
  return { [11] = root }
end
local chosen
dap.set_session = function(session)
  chosen = session
end
tools.sessions()
local picker = selections[#selections]
assert(#picker[1] == 2 and picker[1][2] == child)
root.children[12] = nil
picker[2](child)
assert(not chosen, "closed child session was selected")
tools.dispose()
print("launch: source capture, stale picker rejection, argument cancellation, run-last and prepare cancellation passed")
