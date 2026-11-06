local M = {}
local adapters, configurations = {}, {}

function M.release(dap)
  for name, slot in pairs(adapters) do
    if dap.adapters[name] == slot.value then
      dap.adapters[name] = slot.previous
    end
  end
  for ft, slots in pairs(configurations) do
    local list = dap.configurations[ft]
    if type(list) == "table" then
      for i = #list, 1, -1 do
        local slot = slots[list[i]]
        if slot then
          local previous = slot.previous
          table.remove(list, i)
          if previous then
            local replaced = false
            for _, entry in ipairs(list) do
              replaced = replaced or entry.name == previous.name
            end
            if not replaced then
              table.insert(list, i, previous)
            end
          end
        end
      end
      if #list == 0 and slots.was_nil then
        dap.configurations[ft] = nil
      end
    end
  end
  adapters, configurations = {}, {}
end

function M.install(dap, opts)
  M.release(dap)
  for name, value in pairs(opts.adapters or {}) do
    adapters[name] = { previous = dap.adapters[name], value = value }
    dap.adapters[name] = value
  end
  local lists = vim.deepcopy(opts.configurations or {})
  for ft, source in pairs(opts.aliases or {}) do
    lists[ft] = vim.deepcopy(lists[source] or dap.configurations[source] or {})
  end
  for ft, entries in pairs(lists) do
    local slots = { was_nil = dap.configurations[ft] == nil }
    configurations[ft] = slots
    local list = dap.configurations[ft] or {}
    dap.configurations[ft] = list
    for _, entry in ipairs(entries) do
      local index
      for i, current in ipairs(list) do
        if current.name == entry.name then
          index = i
          break
        end
      end
      local previous = index and list[index] or nil
      list[index or (#list + 1)] = entry
      slots[entry] = { previous = previous }
    end
  end
end

return M
