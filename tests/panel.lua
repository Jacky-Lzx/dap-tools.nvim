dofile("tests/minimal.lua")
local tools = require("dap_tools")
tools.setup({ ui = { auto_open = false, max_lines = 5 } })
local dap, ui = tools.backend(), require("dap_tools.ui")
local pending = {}
local frame = {
  id = 1,
  name = "first",
  line = 4,
  source = { path = "/tmp/a.py" },
  scopes = { { name = "Locals", variablesReference = 11 } },
}
local session =
  { id = 99, config = { name = "Mock" }, stopped_thread_id = 1, current_frame = frame, threads = {}, on_close = {} }
function session:request(command, args, done)
  pending[#pending + 1] = { command, args, done }
end
function session:evaluate(args, done)
  pending[#pending + 1] = { "evaluate", args, done }
end
dap.session = function()
  return session
end
local function has(text)
  return table.concat(ui.snapshot().lines, "\n"):find(text, 1, true) ~= nil
end
local function flush()
  vim.wait(30)
end
local source = vim.api.nvim_get_current_win()
ui.open("scopes", false)
assert(vim.api.nvim_get_current_win() == source and #pending == 1)
local stale = pending[1][3]
session.current_frame = vim.tbl_extend("force", {}, frame, { id = 2, name = "second" })
dap.listeners.after.scopes["dap-tools.panel"]()
flush()
assert(#pending == 2)
stale(nil, { variables = { { name = "STALE", value = "bad", variablesReference = 0 } } })
flush()
assert(not has("STALE"), "previous frame response painted current panel")
pending[2][3](nil, { variables = { { name = "answer", value = "42", variablesReference = 0 } } })
flush()
assert(has("answer = 42"))
ui.watch("answer + 1")
local watch_request = pending[#pending]
assert(watch_request[1] == "evaluate" and watch_request[2].frameId == 2)
session.stopped_thread_id = nil
dap.listeners.after.event_continued["dap-tools.panel"]()
watch_request[3](nil, { result = "STALE_WATCH", variablesReference = 0 })
flush()
assert(not has("STALE_WATCH"))
for i = 1, 10 do
  dap.listeners.after.event_output["dap-tools.panel"](session, { output = "line" .. i .. "\n" })
end
ui.open("output")
assert(has("line10") and not has("line1\n"), "output must be bounded")
dap.listeners.after.event_output["dap-tools.panel"](session, { output = "frag" })
dap.listeners.after.event_output["dap-tools.panel"](session, { output = "mented\n" })
flush()
assert(has("fragmented"), "fragmented output changed line boundaries")
ui.close()
assert(not ui.is_open())
ui.open("output", true)
assert(has("line10"), "hiding destroyed retained output")
session.stopped_thread_id = 1
dap.listeners.after.event_terminated["dap-tools.panel"](session)
local before = #pending
ui.open("scopes", true)
flush()
assert(#pending == before, "panel requested variables from a terminated debuggee")
tools.dispose()
assert(not dap.listeners.after.scopes["dap-tools.panel"])
print("panel: focus, stale variable/watch guards, bounded output, hide/reopen and listener cleanup passed")
