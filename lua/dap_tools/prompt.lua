local M = {}

-- Argument syntax only: no shell expansion, substitution or execution.
function M.parse_args(text)
  local args, word, quote, escaped, started = {}, {}, nil, false, false
  for i = 1, #text do
    local c = text:sub(i, i)
    if escaped then
      word[#word + 1], escaped, started = c, false, true
    elseif c == "\\" and quote ~= "'" then
      escaped, started = true, true
    elseif quote then
      if c == quote then
        quote = nil
      else
        word[#word + 1] = c
      end
    elseif c == "'" or c == '"' then
      quote, started = c, true
    elseif c:match("%s") then
      if started then
        args[#args + 1], word, started = table.concat(word), {}, false
      end
    else
      word[#word + 1], started = c, true
    end
  end
  if quote then
    return nil, "Unclosed quote in arguments"
  end
  if escaped then
    return nil, "Trailing escape in arguments"
  end
  if started then
    args[#args + 1] = table.concat(word)
  end
  return args
end

function M.input(opts)
  return coroutine.create(function(co)
    vim.ui.input(opts, function(value)
      vim.schedule(function()
        local ok, err = coroutine.resume(co, value == nil and require("dap").ABORT or value)
        if not ok then
          vim.notify(tostring(err), vim.log.levels.ERROR, { title = "DAP Tools" })
        end
      end)
    end)
  end)
end

return M
