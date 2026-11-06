dofile("tests/minimal.lua")
local api = vim.api
local folder = assert(vim.env.DAP_TOOLS_TEST_DIR)
local finished, source, tools, ui, dap = false
local function finish(err)
  if finished then
    return
  end
  finished = true
  local screen = {}
  for row = 1, vim.o.lines do
    local cells = {}
    for col = 1, vim.o.columns do
      cells[#cells + 1] = vim.fn.screenstring(row, col)
    end
    screen[#screen + 1] = table.concat(cells)
  end
  vim.fn.writefile(screen, folder .. "/screen.txt")
  vim.fn.writefile({
    err
      or "PASS real debugpy PTY: quoted args/environment, breakpoint, variable expansion, watches, frame navigation, step, hide/reopen, output and restart",
  }, folder .. "/result")
  if dap and dap.session() then
    dap.disconnect({ terminateDebuggee = true })
  end
  vim.defer_fn(function()
    vim.cmd(err and "cquit 1" or "qa!")
  end, 100)
end
local function safe(fn)
  local ok, err = xpcall(fn, debug.traceback)
  if not ok then
    finish(err)
  end
end
local function await(predicate, next)
  local deadline = vim.uv.hrtime() + 15e9
  local function poll()
    if finished then
      return
    end
    safe(function()
      if predicate() then
        next()
      elseif vim.uv.hrtime() > deadline then
        error("Timed out: " .. (vim.fn.readfile(folder .. "/stage")[1] or "startup"))
      else
        vim.defer_fn(poll, 20)
      end
    end)
  end
  vim.defer_fn(poll, 20)
end
local function stage(name, keys)
  vim.fn.writefile({ name, vim.json.encode(keys or "") }, folder .. "/stage")
end
local function has(text)
  return table.concat(ui.snapshot().lines, "\n"):find(text, 1, true) ~= nil
end
local function row(text)
  for i, line in ipairs(ui.snapshot().lines) do
    if line:find(text, 1, true) then
      return i
    end
  end
  error("Missing row: " .. text)
end
local function visible(text)
  vim.cmd.redraw()
  local screen = {}
  for r = 1, vim.o.lines do
    local cells = {}
    for c = 1, vim.o.columns do
      cells[#cells + 1] = vim.fn.screenstring(r, c)
    end
    screen[#screen + 1] = table.concat(cells)
  end
  vim.fn.writefile(screen, folder .. "/panel-" .. ui.snapshot().section .. ".txt")
  return table.concat(screen, "\n"):find(text, 1, true) ~= nil
end
local function stopped(line)
  local session = dap.session()
  return session and session.stopped_thread_id and session.current_frame and session.current_frame.line == line
end
local function end_run()
  stage("continue", "c")
  await(function()
    return not dap.session()
  end, function()
    ui.open("output", true)
    await(function()
      return has("RESULT 41")
    end, function()
      assert(has("two words"), "quoted arguments were split")
      assert(has("ENV active"), "selected environment was lost")
      stage("restart", ":DapToolsRunLast\r")
      await(function()
        return stopped(4)
      end, function()
        ui.open("scopes", false)
        await(function()
          return has("seed = 40")
        end, function()
          assert(not package.loaded["dap-view"] and not package.loaded.dapui)
          tools.action("terminate")
          await(function()
            return not dap.session()
          end, function()
            finish()
          end)
        end)
      end)
    end)
  end)
end
local function step()
  ui.open("scopes", true)
  stage("step", "n")
  await(function()
    return stopped(5)
  end, function()
    await(function()
      return has("marker = 41")
    end, function()
      tools.close()
      assert(not ui.is_open() and dap.session(), "hiding terminated the session")
      tools.open("scopes", true)
      await(function()
        return has("marker = 41")
      end, end_run)
    end)
  end)
end
local function frames()
  ui.open("stack", true)
  await(function()
    return has("<module>")
  end, function()
    api.nvim_win_set_cursor(ui.snapshot().win, { row("<module>"), 0 })
    stage("caller", "\r")
    await(function()
      return stopped(6) and has("<module>")
    end, function()
      ui.open("stack", true)
      api.nvim_win_set_cursor(ui.snapshot().win, { row("compute"), 0 })
      stage("callee", "\r")
      await(function()
        return stopped(4) and has("seed = 40")
      end, step)
    end)
  end)
end
local function watch()
  stage("watch", ":DapToolsWatch seed+2\r")
  await(function()
    return has("seed+2 = 42")
  end, function()
    api.nvim_win_set_cursor(ui.snapshot().win, { row("seed+2"), 0 })
    stage("delete-watch", "d")
    await(function()
      return #ui.snapshot().watches == 0
    end, frames)
  end)
end

vim.schedule(function()
  safe(function()
    vim.o.hidden = true
    tools = require("dap_tools")
    tools.setup({
      presets = {
        python = {
          adapter_python = assert(vim.env.DAP_TOOLS_DEBUGPY_PYTHON),
          python = vim.env.DAP_TOOLS_DEBUGGEE_PYTHON,
          env = { DAP_TOOLS_CASE = "active" },
        },
      },
      ui = { height = 0.45 },
    })
    vim.cmd.edit(folder .. "/example.py")
    vim.bo.filetype = "python"
    source = api.nvim_get_current_buf()
    api.nvim_win_set_cursor(0, { 4, 0 })
    tools.breakpoint()
    dap, ui = tools.backend(), require("dap_tools.ui")
    dap.set_log_level("TRACE")
    stage("arguments", ":DapToolsRun!\r")
    await(function()
      return vim.fn.mode() == "c" and vim.fn.getcmdtype() == "@"
    end, function()
      stage("type-arguments", '--name "two words"\r')
      await(function()
        return stopped(4)
      end, function()
        await(function()
          return has("seed = 40") and has("values")
        end, function()
          assert(api.nvim_get_current_buf() == source, "automatic panel stole source focus")
          assert(visible("1:scopes") and visible("seed = 40"), "variables were not rendered in the terminal")
          ui.open("scopes", true)
          api.nvim_win_set_cursor(ui.snapshot().win, { row("values ="), 0 })
          stage("expand", "\r")
          await(function()
            return has("'answer' = 41") or has('"answer" = 41')
          end, watch)
        end)
      end)
    end)
  end)
end)
