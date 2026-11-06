local M = {}
local options, dap, installed, pending, last = nil, nil, false, 0, nil
local commands = {}
local api = vim.api
local function notify(message, level)
  vim.notify(tostring(message), level or vim.log.levels.WARN, { title = "DAP Tools" })
end
local function safe(fn)
  local ok, result = xpcall(fn, debug.traceback)
  if not ok then
    notify(result, vim.log.levels.ERROR)
  end
  return ok and result or nil
end

local defaults = {
  adapters = {},
  configurations = {},
  aliases = {},
  presets = {},
  ui = {
    height = 0.28,
    position = "bottom",
    auto_open = true,
    auto_close = false,
    max_lines = 2000,
    max_children = 200,
  },
}

local function validate(opts)
  assert(opts == nil or type(opts) == "table", "dap-tools options must be a table")
  local result = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
  for _, key in ipairs({ "adapters", "configurations", "aliases", "presets", "ui" }) do
    assert(type(result[key]) == "table", key .. " must be a table")
  end
  for name, value in pairs(result.presets) do
    assert(vim.list_contains({ "python", "cpp", "rust", "swift" }, name), "Unknown preset: " .. name)
    assert(type(value) == "boolean" or type(value) == "table", "Preset must be a table or boolean: " .. name)
  end
  for name, value in pairs(result.adapters) do
    assert(type(name) == "string" and (type(value) == "table" or type(value) == "function"), "Invalid adapter")
  end
  for ft, entries in pairs(result.configurations) do
    assert(type(ft) == "string" and vim.islist(entries), "Configurations must be lists keyed by filetype")
    local seen = {}
    for _, entry in ipairs(entries) do
      assert(
        type(entry) == "table" and type(entry.name) == "string" and type(entry.type) == "string",
        "Configuration needs name and type"
      )
      assert(entry.request == "launch" or entry.request == "attach", "Configuration needs launch/attach request")
      assert(not seen[entry.name], "Duplicate configuration: " .. entry.name)
      seen[entry.name] = true
    end
  end
  for ft, source in pairs(result.aliases) do
    assert(type(ft) == "string" and type(source) == "string" and ft ~= source, "Invalid filetype alias")
    assert(not result.aliases[source], "Chained filetype aliases are unsupported")
  end
  for _, name in ipairs({ "backend_loader", "before_start" }) do
    assert(result[name] == nil or type(result[name]) == "function", name .. " must be a function")
  end
  assert(type(result.ui.height) == "number" and result.ui.height > 0, "ui.height must be positive")
  assert(result.ui.position == "bottom" or result.ui.position == "right", "ui.position must be bottom or right")
  for _, name in ipairs({ "max_lines", "max_children" }) do
    assert(
      type(result.ui[name]) == "number" and result.ui[name] >= 1 and result.ui[name] % 1 == 0,
      "ui." .. name .. " must be a positive integer"
    )
  end
  for _, name in ipairs({ "auto_open", "auto_close" }) do
    assert(type(result.ui[name]) == "boolean", "ui." .. name .. " must be boolean")
  end
  return result
end

function M.backend()
  if not options then
    M.setup()
  end
  if not dap then
    if options.backend_loader then
      options.backend_loader()
    end
    local ok, backend = pcall(require, "dap")
    assert(ok, "dap-tools requires nvim-dap on runtimepath: " .. tostring(backend))
    dap = backend
  end
  if not installed then
    require("dap_tools.registry").install(dap, require("dap_tools.presets").build(options))
    require("dap_tools.ui").attach(dap, options.ui)
    installed = true
  end
  return dap
end

function M.configurations(ctx)
  ctx = ctx or require("dap_tools.context").capture()
  local backend = M.backend()
  local result = vim.deepcopy(backend.configurations[ctx.filetype] or {})
  local project = require("dap.ext.vscode").getconfigs(ctx.root .. "/.vscode/launch.json")
  for _, entry in ipairs(project) do
    local replaced = false
    for i, current in ipairs(result) do
      if current.name == entry.name then
        result[i], replaced = entry, true
        break
      end
    end
    if not replaced then
      result[#result + 1] = entry
    end
  end
  return result
end

local function bind(value, ctx)
  if type(value) == "function" then
    return function()
      return require("dap_tools.context").call(ctx, function()
        return value(ctx)
      end)
    end
  elseif type(value) == "string" then
    local vars = {
      ["${file}"] = ctx.file,
      ["${fileDirname}"] = vim.fs.dirname(ctx.file),
      ["${workspaceFolder}"] = ctx.root,
      ["${workspaceFolderBasename}"] = vim.fs.basename(ctx.root),
    }
    return (value:gsub("%${[%w_]+}", function(key)
      return vars[key] or key
    end))
  elseif type(value) == "table" then
    local result = {}
    for k, v in pairs(value) do
      result[k] = bind(v, ctx)
    end
    local mt = getmetatable(value)
    if mt and type(mt.__call) == "function" then
      mt = vim.tbl_extend("force", {}, mt, {
        __call = function()
          local expanded = require("dap_tools.context").call(ctx, function()
            return getmetatable(value).__call(value)
          end)
          return bind(setmetatable(expanded, nil), ctx)
        end,
      })
    end
    return setmetatable(result, mt)
  end
  return value
end

function M.cancel_launch()
  pending = pending + 1
end

function M.run(name, opts)
  opts = vim.deepcopy(opts or {})
  local ctx = opts.context
    or (package.loaded["dap_tools.ui"] and require("dap_tools.ui").source_context())
    or require("dap_tools.context").capture()
  if vim.bo.filetype ~= "daptools" and not opts.context then
    ctx = require("dap_tools.context").capture()
  end
  local backend = M.backend()
  M.cancel_launch()
  local token = pending
  local function valid()
    return token == pending and api.nvim_buf_is_valid(ctx.buf)
  end
  local function launch(config)
    if not valid() or not config then
      return
    end
    local resolved = bind(vim.deepcopy(config), ctx)
    local function start()
      if not valid() then
        return
      end
      local function done(err)
        if not valid() then
          return
        end
        if err then
          notify(err, vim.log.levels.ERROR)
          return
        end
        last = { config = vim.deepcopy(config), context = vim.deepcopy(ctx) }
        if opts.args then
          last.config.args = vim.deepcopy(opts.args)
        end
        safe(function()
          require("dap_tools.context").call(ctx, function()
            backend.run(resolved, { filetype = ctx.filetype, new = opts.new })
          end)
        end)
      end
      if options.before_start then
        local called = false
        local ok, err = pcall(options.before_start, resolved, ctx, function(message)
          if called then
            return
          end
          called = true
          vim.schedule(function()
            done(message)
          end)
        end)
        if not ok and not called then
          done(err)
        end
      else
        done()
      end
    end
    if opts.prompt_args then
      vim.ui.input({ prompt = "Debug arguments (quotes supported): " }, function(text)
        if text == nil or not valid() then
          return
        end
        local args, err = require("dap_tools.prompt").parse_args(text)
        if not args then
          notify(err)
          return
        end
        resolved.args, opts.args = args, args
        start()
      end)
    else
      if opts.args then
        resolved.args = vim.deepcopy(opts.args)
      end
      start()
    end
  end
  if type(name) == "table" then
    launch(name)
    return
  end
  local configs = M.configurations(ctx)
  if name and name ~= "" then
    for _, config in ipairs(configs) do
      if config.name == name then
        launch(config)
        return
      end
    end
    notify("Unknown configuration: " .. name)
  elseif #configs == 0 then
    notify(
      "No debug configurations for "
        .. ctx.filetype
        .. "; configure dap_tools.setup({ presets = ..., configurations = ... })"
    )
  elseif #configs == 1 then
    launch(configs[1])
  else
    vim.ui.select(configs, {
      prompt = "Debug configuration:",
      format_item = function(item)
        return item.name
      end,
    }, launch)
  end
end

function M.run_last(opts)
  if not last then
    notify("No previous dap-tools launch")
    return
  end
  opts = vim.tbl_extend("force", { context = last.context }, opts or {})
  if not api.nvim_buf_is_valid(opts.context.buf) then
    notify("The previous source buffer was deleted")
    return
  end
  return M.run(last.config, opts)
end

function M.continue()
  if M.backend().session() then
    return dap.continue()
  end
  return M.run()
end

function M.action(name)
  local backend = M.backend()
  if not backend.session() then
    notify("No active debug session")
    return
  end
  assert(type(backend[name]) == "function", "Unknown debug action: " .. tostring(name))
  if name == "terminate" or name == "disconnect" then
    require("dap_tools.ui").suspend(backend.session())
  end
  return backend[name]()
end

function M.breakpoint(kind)
  if vim.bo.buftype ~= "" then
    notify("Set breakpoints in a source buffer")
    return
  end
  local backend = M.backend()
  if kind == nil then
    backend.toggle_breakpoint()
    require("dap_tools.ui").refresh()
    return
  end
  assert(kind == "condition" or kind == "log", "Breakpoint kind must be condition or log")
  local ctx, line = require("dap_tools.context").capture(), api.nvim_win_get_cursor(0)[1]
  vim.ui.input(
    { prompt = kind == "log" and "Log message ({expression}): " or "Breakpoint condition: " },
    function(value)
      if value == nil or value == "" or not api.nvim_buf_is_valid(ctx.buf) then
        return
      end
      require("dap_tools.context").call(ctx, function()
        local bp = require("dap.breakpoints")
        bp.set(kind == "log" and { logMessage = value } or { condition = value }, ctx.buf, line)
        local session = backend.session()
        if session then
          session:set_breakpoints(bp.get())
        end
      end)
      require("dap_tools.ui").refresh()
    end
  )
end

local function session_map(backend)
  local result = {}
  local function visit(session)
    if result[session.id] then
      return
    end
    result[session.id] = session
    for _, child in pairs(session.children or {}) do
      visit(child)
    end
  end
  for _, session in pairs(backend.sessions()) do
    visit(session)
  end
  return result
end

function M.sessions()
  local backend = M.backend()
  local items = vim.tbl_values(session_map(backend))
  table.sort(items, function(a, b)
    return a.id < b.id
  end)
  if #items == 0 then
    notify("No active debug sessions")
    return
  end
  vim.ui.select(items, {
    prompt = "Debug session:",
    format_item = function(s)
      return (s == backend.session() and "* " or "  ") .. s.id .. ": " .. s.config.name
    end,
  }, function(selected)
    if selected and session_map(backend)[selected.id] == selected then
      backend.set_session(selected)
    end
  end)
end

function M.open(section, focus)
  M.backend()
  return require("dap_tools.ui").open(section, focus)
end
function M.close()
  if package.loaded["dap_tools.ui"] then
    require("dap_tools.ui").close()
  end
end
function M.toggle()
  M.backend()
  local ui = require("dap_tools.ui")
  if ui.is_open() then
    ui.close()
  else
    ui.open(nil, true)
  end
end
function M.watch(expression)
  M.backend()
  return require("dap_tools.ui").watch(expression)
end
function M.hover()
  M.backend()
  return require("dap.ui.widgets").hover()
end
function M.repl()
  return M.backend().repl.open()
end
function M.status()
  local session = dap and dap.session()
  return {
    initialized = installed,
    session = session and { id = session.id, name = session.config.name, stopped = session.stopped_thread_id ~= nil }
      or nil,
    panel = package.loaded["dap_tools.ui"] and require("dap_tools.ui").is_open() or false,
  }
end

local definitions = {
  DapTools = {
    function()
      M.open(nil, true)
    end,
    "Open debug panel",
  },
  DapToolsRun = {
    function(a)
      M.run(a.args, { prompt_args = a.bang })
    end,
    "Choose and launch configuration (! prompts for arguments)",
    nargs = "?",
    bang = true,
    complete = function()
      local names = {}
      for _, c in ipairs(M.configurations()) do
        names[#names + 1] = c.name
      end
      return names
    end,
  },
  DapToolsContinue = { M.continue, "Launch or continue debugging" },
  DapToolsRunLast = {
    function(a)
      M.run_last({ prompt_args = a.bang })
    end,
    "Repeat last launch",
    bang = true,
  },
  DapToolsToggle = { M.toggle, "Toggle debug panel" },
  DapToolsClose = { M.close, "Hide debug panel" },
  DapToolsBreakpoint = {
    function(a)
      M.breakpoint(a.args ~= "" and a.args or nil)
    end,
    "Toggle breakpoint or prompt for condition/log",
    nargs = "?",
    complete = function()
      return { "condition", "log" }
    end,
  },
  DapToolsWatch = {
    function(a)
      M.watch(a.args ~= "" and a.args or nil)
    end,
    "Add watch expression",
    nargs = "?",
  },
  DapToolsSessions = { M.sessions, "Choose active debug session" },
  DapToolsRepl = { M.repl, "Open nvim-dap REPL" },
}
for command, action in pairs({
  StepOver = "step_over",
  StepInto = "step_into",
  StepOut = "step_out",
  Pause = "pause",
  Terminate = "terminate",
  Disconnect = "disconnect",
}) do
  local method = action
  definitions["DapTools" .. command] = {
    function()
      M.action(method)
    end,
    "Debug " .. method,
  }
end

function M.setup(opts)
  local next_options = validate(opts)
  local current = api.nvim_get_commands({})
  for name in pairs(definitions) do
    assert(
      not current[name] or commands[name] and vim.deep_equal(current[name], commands[name]),
      "Command already exists: " .. name
    )
  end
  options = next_options
  M.cancel_launch()
  if installed then
    require("dap_tools.registry").install(dap, require("dap_tools.presets").build(options))
    require("dap_tools.ui").attach(dap, options.ui)
  end
  for name, def in pairs(definitions) do
    api.nvim_create_user_command(name, function(args)
      safe(function()
        def[1](args)
      end)
    end, {
      desc = def[2],
      nargs = def.nargs or 0,
      bang = def.bang or false,
      complete = def.complete,
      force = commands[name] ~= nil,
    })
    commands[name] = api.nvim_get_commands({})[name]
  end
  return M
end

function M.dispose()
  M.cancel_launch()
  if installed then
    require("dap_tools.ui").dispose()
    require("dap_tools.registry").release(dap)
  end
  local current = api.nvim_get_commands({})
  for name, owned in pairs(commands) do
    if vim.deep_equal(current[name], owned) then
      api.nvim_del_user_command(name)
    end
  end
  commands, options, installed, dap, last = {}, nil, false, nil, nil
end

function M._bootstrap()
  if not options then
    M.setup()
  end
end

return M
