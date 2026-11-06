dofile("tests/minimal.lua")
local folder = vim.fn.tempname()
vim.fn.mkdir(folder, "p")
folder = assert(vim.uv.fs_realpath(folder))
local file, binary = folder .. "/main.c", folder .. "/native-test"
vim.fn.writefile({
  "#include <stdio.h>",
  "int main(void) {",
  "  int seed = 40;",
  "  int result = seed + 2;",
  '  printf("RESULT %d\\n", result);',
  "  return 0;",
  "}",
}, file)
local build = vim.system({ "clang", "-g", "-O0", file, "-o", binary }, { text = true }):wait()
assert(build.code == 0, build.stderr)
local tools = require("dap_tools")
tools.setup({
  presets = { cpp = true, swift = true },
  adapters = { codelldb = { type = "executable", command = assert(vim.env.DAP_TOOLS_CODELLDB) } },
  ui = { auto_open = false },
})
local dap = tools.backend()
dap.set_log_level("TRACE")
vim.cmd.edit(file)
vim.bo.filetype = "c"
vim.api.nvim_win_set_cursor(0, { 4, 0 })
tools.breakpoint()
local function check(ft)
  local configs = tools.configurations({ filetype = ft, root = folder })
  configs[1].program = binary
  tools.run(configs[1])
  assert(
    vim.wait(15000, function()
      local s = dap.session()
      return s and s.stopped_thread_id and s.current_frame and s.current_frame.line == 4 and s.current_frame.scopes
    end, 20),
    "Native debugger did not stop: " .. ft
  )
  tools.open("scopes", false)
  assert(
    vim.wait(5000, function()
      return table.concat(require("dap_tools.ui").snapshot().lines, "\n"):find("seed = 40", 1, true)
    end, 20),
    "Native variable not rendered: " .. ft
  )
  dap.continue()
  assert(
    vim.wait(10000, function()
      return not dap.session()
    end, 20),
    "Native debugger did not exit: " .. ft
  )
  tools.close()
  print("native adapter passed: " .. ft)
end
check("cpp")
check("swift")
tools.dispose()
vim.fn.delete(folder, "rf")
print("native: codelldb and lldb-dap launch/breakpoint/variables/continue with a real compiled C fixture passed")
