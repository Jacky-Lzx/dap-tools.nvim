local M = {}
local api = vim.api
local dap, opts, win, buf, section = nil, nil, nil, nil, "scopes"
local epoch, queued, active = 0, false, false
local rows, expanded, values, watches, outputs = {}, {}, {}, {}, {}
local sections = { "scopes", "stack", "watches", "breakpoints", "output" }
local key = "dap-tools.panel"
local listeners = {}
local source_context
local last_terminal, observed_terminals = nil, {}
local observer_lifetime = 0
local ended = setmetatable({}, { __mode = "k" })
local function is_stopped(session)
  return session and session.stopped_thread_id ~= nil and not session.closed and not ended[session]
end

local function notify(text)
  vim.notify(tostring(text), vim.log.levels.WARN, { title = "DAP Tools" })
end
local function clean(text)
  return tostring(text or ""):gsub("[\r\n]", " "):gsub("%z", "")
end
function M.is_open()
  return win ~= nil and api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == buf
end
local function invalidate()
  epoch, expanded, values = epoch + 1, {}, {}
end
local function guard(session, frame, version)
  return active
    and dap.session() == session
    and session.current_frame == frame
    and epoch == version
    and is_stopped(session)
end
local function request_variables(reference)
  if values[reference] then
    return values[reference]
  end
  local session = dap.session()
  if not is_stopped(session) then
    return {}
  end
  local frame, version = session.current_frame, epoch
  local entry = { loading = true }
  values[reference] = entry
  session:request(
    "variables",
    { variablesReference = reference, start = 0, count = opts.max_children },
    function(err, response)
      if not guard(session, frame, version) then
        return
      end
      entry.loading = false
      entry.error = err and tostring(err) or nil
      entry.children = response and response.variables or {}
      M.refresh()
    end
  )
  return entry
end

local function render()
  if not M.is_open() then
    return
  end
  local session = dap.session()
  if session and session.term_buf and api.nvim_buf_is_valid(session.term_buf) then
    last_terminal = session.term_buf
    if not observed_terminals[last_terminal] then
      local terminal = last_terminal
      local lifetime = observer_lifetime
      observed_terminals[terminal] = lifetime
      api.nvim_buf_attach(terminal, false, {
        on_lines = function()
          if not active or lifetime ~= observer_lifetime then
            if observed_terminals[terminal] == lifetime then
              observed_terminals[terminal] = nil
            end
            return true
          end
          M.refresh()
        end,
        on_detach = function()
          if observed_terminals[terminal] == lifetime then
            observed_terminals[terminal] = nil
          end
        end,
      })
    end
  end
  local lines, next_rows = {}, {}
  local function add(text, row)
    lines[#lines + 1], next_rows[#lines + 1] = text, row or {}
  end
  local status = session and (ended[session] and "ending" or is_stopped(session) and "stopped" or "running") or "idle"
  add(
    (session and ("#" .. session.id .. " " .. clean(session.config.name)) or "No active session")
      .. "  ["
      .. status
      .. "]"
  )
  add("c continue  n next  i into  o out  p pause  x terminate  a watch  e eval  r REPL  q hide")
  add("")
  local function tree(name, value, reference, path, depth)
    local can_expand = reference and reference > 0
    local prefix = can_expand and (expanded[path] and "▾ " or "▸ ") or "  "
    add(string.rep("  ", depth) .. prefix .. clean(name) .. (value and (" = " .. clean(value)) or ""), {
      toggle = can_expand and function()
        expanded[path] = not expanded[path]
        M.refresh()
      end or nil,
    })
    if can_expand and expanded[path] then
      local data = request_variables(reference)
      if data.loading then
        add(string.rep("  ", depth + 1) .. "Loading…")
      elseif data.error then
        add(string.rep("  ", depth + 1) .. data.error)
      else
        for i, child in ipairs(data.children or {}) do
          if i > opts.max_children then
            add(string.rep("  ", depth + 1) .. "… more variables omitted")
            break
          end
          if depth < 20 then
            tree(child.name, child.value, child.variablesReference, path .. "/" .. i, depth + 1)
          end
        end
      end
    end
  end
  if section == "scopes" then
    local frame = session and session.current_frame
    if not is_stopped(session) then
      add("Stop at a breakpoint to inspect variables")
    elseif not frame or not frame.scopes then
      add("Waiting for stack frame and scopes…")
    else
      add(clean(frame.name) .. "  " .. clean((frame.source or {}).path) .. ":" .. (frame.line or 0))
      for i, scope in ipairs(frame.scopes) do
        local path = "scope/" .. i
        if expanded[path] == nil then
          expanded[path] = not scope.expensive
        end
        tree(scope.name, nil, scope.variablesReference, path, 0)
      end
    end
  elseif section == "stack" then
    if not session then
      add("No active session")
    end
    local threads = session and session.threads or {}
    local thread_ids = vim.tbl_keys(threads)
    table.sort(thread_ids)
    for _, id in ipairs(thread_ids) do
      local thread = threads[id]
      add((id == session.stopped_thread_id and "▶ " or "  ") .. "Thread " .. id .. ": " .. clean(thread.name))
      for _, frame in ipairs(thread.frames or {}) do
        add(
          (session.current_frame == frame and "  > " or "    ")
            .. clean(frame.name)
            .. "  "
            .. clean((frame.source or {}).path)
            .. ":"
            .. (frame.line or 0),
          {
            activate = function()
              if dap.session() == session and is_stopped(session) and thread.stopped then
                invalidate()
                -- Same frame-selection entry point used by nvim-dap's own widgets.
                session:_frame_set(frame)
                section = "scopes"
                M.refresh()
              end
            end,
          }
        )
      end
    end
  elseif section == "watches" then
    if #watches == 0 then
      add("Press a to add a watch expression")
    end
    for i, watch in ipairs(watches) do
      local path = "watch/" .. i
      local cached = values[path]
      if is_stopped(session) and session.current_frame and not cached then
        local frame, version = session.current_frame, epoch
        cached = { loading = true }
        values[path] = cached
        session:evaluate({ expression = watch, context = "watch", frameId = frame.id }, function(err, result)
          if not guard(session, frame, version) then
            return
          end
          cached.loading, cached.error, cached.result = false, err and tostring(err), result
          M.refresh()
        end)
      end
      local result = cached and cached.result
      local watch_row = #lines + 1
      tree(
        watch,
        cached and (cached.loading and "Loading…" or cached.error or (result or {}).result) or "<not stopped>",
        result and result.variablesReference,
        path,
        0
      )
      next_rows[watch_row].delete = function()
        table.remove(watches, i)
        invalidate()
        M.refresh()
      end
    end
  elseif section == "breakpoints" then
    local bps = require("dap.breakpoints").get()
    local buffers = vim.tbl_keys(bps)
    table.sort(buffers)
    if #buffers == 0 then
      add("No breakpoints. Use :DapToolsBreakpoint in a source buffer")
    end
    for _, source in ipairs(buffers) do
      for _, bp in ipairs(bps[source]) do
        local label = bp.condition and (" if " .. bp.condition) or bp.logMessage and (" log " .. bp.logMessage) or ""
        local path = api.nvim_buf_is_valid(source) and api.nvim_buf_get_name(source) or "<deleted>"
        if bp.state and bp.state.verified == false then
          label = label .. " [unverified: " .. clean(bp.state.message or "adapter rejected breakpoint") .. "]"
        end
        add(path .. ":" .. bp.line .. label, {
          activate = function()
            if not api.nvim_buf_is_valid(source) then
              return
            end
            vim.cmd("wincmd p")
            if api.nvim_get_current_win() == win then
              vim.cmd("aboveleft new")
            end
            api.nvim_set_current_buf(source)
            api.nvim_win_set_cursor(0, { math.min(bp.line, api.nvim_buf_line_count(source)), 0 })
          end,
          delete = function()
            require("dap.breakpoints").remove(source, bp.line)
            local current = dap.session()
            if current then
              current:set_breakpoints(require("dap.breakpoints").get())
            end
            M.refresh()
          end,
        })
      end
    end
  elseif section == "output" then
    local output = outputs[session and session.id or "last"] or {}
    if #output == 0 then
      add("No debug adapter output")
    end
    for _, line in ipairs(output) do
      add(line)
    end
    if last_terminal and api.nvim_buf_is_valid(last_terminal) then
      add("── Debuggee terminal ──")
      local count = api.nvim_buf_line_count(last_terminal)
      for _, line in ipairs(api.nvim_buf_get_lines(last_terminal, math.max(0, count - opts.max_lines), -1, false)) do
        add(clean(line):sub(1, 16384))
      end
    end
  end
  rows = next_rows
  local cursor = api.nvim_win_get_cursor(win)
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  api.nvim_win_set_cursor(win, { math.min(cursor[1], #lines), 0 })
  local tabs = {}
  for i, name in ipairs(sections) do
    tabs[#tabs + 1] = (name == section and "%#DapToolsSelected#" or "%#DapToolsTab#") .. " " .. i .. ":" .. name .. " "
  end
  vim.wo[win].winbar = table.concat(tabs) .. "%*"
end

function M.refresh()
  if queued or not active then
    return
  end
  queued = true
  vim.schedule(function()
    queued = false
    if active then
      render()
    end
  end)
end

function M.close()
  if M.is_open() then
    if #api.nvim_tabpage_list_wins(0) == 1 then
      api.nvim_win_set_buf(win, api.nvim_create_buf(true, false))
    else
      api.nvim_win_close(win, true)
    end
  end
  win = nil
end

local function with_action(action)
  return function()
    local ok, err = pcall(action)
    if not ok then
      notify(err)
    end
  end
end

function M.open(target, focus)
  assert(not target or vim.list_contains(sections, target), "Unknown panel section: " .. tostring(target))
  section = target or section
  local previous = api.nvim_get_current_win()
  if vim.bo.buftype == "" then
    source_context = require("dap_tools.context").capture()
  end
  if not M.is_open() then
    if not buf or not api.nvim_buf_is_valid(buf) then
      buf = api.nvim_create_buf(false, true)
      api.nvim_buf_set_name(buf, "dap-tools://panel")
      vim.bo[buf].bufhidden, vim.bo[buf].filetype = "hide", "daptools"
      local function map(lhs, fn)
        vim.keymap.set("n", lhs, with_action(fn), { buffer = buf, silent = true, nowait = true })
      end
      map("q", M.close)
      for i, name in ipairs(sections) do
        local selected = name
        map(tostring(i), function()
          section = selected
          M.refresh()
        end)
      end
      map("<CR>", function()
        local row = rows[api.nvim_win_get_cursor(win)[1]] or {}
        (row.activate or row.toggle or function() end)()
      end)
      map("d", function()
        local row = rows[api.nvim_win_get_cursor(win)[1]] or {}
        if row.delete then
          row.delete()
        end
      end)
      map("a", function()
        M.watch()
      end)
      map("e", M.evaluate)
      map("r", function()
        require("dap_tools").repl()
      end)
      map("s", function()
        require("dap_tools").sessions()
      end)
      map("c", function()
        require("dap_tools").continue()
      end)
      for lhs, action in pairs({ n = "step_over", i = "step_into", o = "step_out", p = "pause", x = "terminate" }) do
        local method = action
        map(lhs, function()
          require("dap_tools").action(method)
        end)
      end
    end
    vim.cmd(opts.position == "right" and "botright vsplit" or "botright split")
    win = api.nvim_get_current_win()
    api.nvim_win_set_buf(win, buf)
    if opts.position == "right" then
      api.nvim_win_set_width(
        win,
        math.max(
          20,
          math.min(vim.o.columns - 4, math.floor(opts.height <= 1 and vim.o.columns * opts.height or opts.height))
        )
      )
    else
      api.nvim_win_set_height(
        win,
        math.max(
          3,
          math.min(vim.o.lines - 4, math.floor(opts.height <= 1 and vim.o.lines * opts.height or opts.height))
        )
      )
    end
    for name, value in pairs({
      number = false,
      relativenumber = false,
      signcolumn = "no",
      wrap = false,
      cursorline = true,
      winfixheight = true,
      winfixwidth = true,
    }) do
      vim.wo[win][name] = value
    end
    if not focus and api.nvim_win_is_valid(previous) then
      api.nvim_set_current_win(previous)
    end
  elseif focus then
    api.nvim_set_current_win(win)
  end
  render()
end

function M.watch(expression)
  local function add(value)
    if not active or not value or value == "" then
      return
    end
    if not vim.list_contains(watches, value) then
      watches[#watches + 1] = value
    end
    invalidate()
    M.open("watches", true)
  end
  if expression then
    add(expression)
  else
    vim.ui.input({ prompt = "Watch expression: " }, add)
  end
end

function M.evaluate()
  local session = dap.session()
  if not is_stopped(session) then
    notify("Stop the debuggee before evaluating")
    return
  end
  local frame, version = session.current_frame, epoch
  vim.ui.input({ prompt = "Evaluate expression: " }, function(expression)
    if not expression or expression == "" or not guard(session, frame, version) then
      return
    end
    session:evaluate({ expression = expression, context = "repl", frameId = frame and frame.id }, function(err, result)
      if not guard(session, frame, version) then
        return
      end
      notify(err or expression .. " = " .. ((result or {}).result or "<no result>"))
    end)
  end)
end

local function listen(group, name, callback)
  group[name][key] = callback
  listeners[#listeners + 1] = { group[name], callback }
end

function M.attach(backend, config)
  M.detach()
  dap, opts, active = backend, vim.deepcopy(config), true
  api.nvim_set_hl(0, "DapToolsSelected", { default = true, link = "TabLineSel" })
  api.nvim_set_hl(0, "DapToolsTab", { default = true, link = "TabLine" })
  local function track(session)
    if not session or not session.on_close or session.on_close[key] then
      return
    end
    local callback = function()
      if outputs[session.id] then
        outputs.last = outputs[session.id]
        outputs[session.id] = nil
      end
      vim.schedule(function()
        if not active then
          return
        end
        invalidate()
        if opts.auto_close and not next(dap.sessions()) then
          M.close()
        else
          M.refresh()
        end
      end)
      for i = #listeners, 1, -1 do
        if listeners[i][1] == session.on_close then
          table.remove(listeners, i)
        end
      end
    end
    session.on_close[key] = callback
    listeners[#listeners + 1] = { session.on_close, callback }
  end
  for _, session in pairs(dap.sessions()) do
    track(session)
  end
  listen(dap.listeners, "on_session", function(_, new)
    track(new)
    invalidate()
    M.refresh()
  end)
  for _, event in ipairs({
    "event_continued",
    "scopes",
    "event_thread",
    "event_process",
    "event_breakpoint",
    "setBreakpoints",
  }) do
    listen(dap.listeners.after, event, function()
      invalidate()
      M.refresh()
    end)
  end
  listen(dap.listeners.after, "event_stopped", function(session)
    ended[session] = nil
    invalidate()
    M.refresh()
  end)
  for _, event in ipairs({ "event_terminated", "event_exited" }) do
    listen(dap.listeners.after, event, function(session)
      M.suspend(session)
    end)
  end
  listen(dap.listeners.after, "event_initialized", function(session)
    ended[session] = nil
    track(session)
    if opts.auto_open then
      vim.schedule(function()
        if active and dap.session() == session then
          M.open(nil, false)
        end
      end)
    end
  end)
  listen(dap.listeners.after, "event_output", function(session, event)
    if not event.output or event.category == "telemetry" then
      return
    end
    local output = outputs[session.id] or {}
    outputs[session.id], outputs.last = output, output
    local parts = vim.split(event.output, "\n", { plain = true })
    for i, line in ipairs(parts) do
      if i == 1 and output.partial and #output > 0 then
        output[#output] = clean(output[#output] .. line):sub(1, 16384)
      elseif i < #parts or line ~= "" then
        output[#output + 1] = clean(line):sub(1, 16384)
      end
    end
    output.partial = event.output:sub(-1) ~= "\n"
    while #output > opts.max_lines do
      table.remove(output, 1)
    end
    M.refresh()
  end)
end

function M.detach()
  active = false
  observer_lifetime, observed_terminals = observer_lifetime + 1, {}
  invalidate()
  M.close()
  for _, entry in ipairs(listeners) do
    if entry[1][key] == entry[2] then
      entry[1][key] = nil
    end
  end
  listeners = {}
end

function M.dispose()
  M.detach()
  if buf and api.nvim_buf_is_valid(buf) and api.nvim_buf_get_name(buf) == "dap-tools://panel" then
    api.nvim_buf_delete(buf, { force = true })
  end
  buf, win, source_context, last_terminal = nil, nil, nil, nil
  rows, watches, outputs = {}, {}, {}
end

function M.suspend(session)
  if session then
    ended[session] = true
  end
  invalidate()
  M.refresh()
end

function M.snapshot()
  return {
    section = section,
    open = M.is_open(),
    buf = buf,
    win = win,
    watches = vim.deepcopy(watches),
    lines = buf and api.nvim_buf_is_valid(buf) and api.nvim_buf_get_lines(buf, 0, -1, false) or {},
  }
end

function M.source_context()
  return source_context and api.nvim_buf_is_valid(source_context.buf) and vim.deepcopy(source_context) or nil
end

return M
