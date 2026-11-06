local M = {}
local function resolve(value, ctx)
  return type(value) == "function" and value(ctx or require("dap_tools.context").capture()) or value
end
local function path(prompt, suffix)
  return function(ctx)
    ctx = ctx or require("dap_tools.context").capture()
    return require("dap_tools.prompt").input({
      prompt = prompt,
      default = ctx.root .. (suffix or "/"),
      completion = "file",
    })
  end
end

function M.python(opts)
  opts = opts or {}
  return {
    adapters = {
      python = function(cb, config)
        if config.request == "attach" then
          local connect = config.connect or config
          assert(tonumber(connect.port), "Python attach requires connect.port")
          cb({ type = "server", host = connect.host or "127.0.0.1", port = tonumber(connect.port) })
        else
          local python = resolve(opts.adapter_python)
          assert(
            type(python) == "string" and python ~= "",
            "debugpy is unavailable; configure presets.python.adapter_python"
          )
          cb({ type = "executable", command = python, args = { "-m", "debugpy.adapter" } })
        end
      end,
    },
    configurations = {
      python = {
        {
          name = "Python: launch file",
          type = "python",
          request = "launch",
          program = "${file}",
          cwd = function(ctx)
            return (ctx or require("dap_tools.context").capture()).root
          end,
          pythonPath = function(ctx)
            return resolve(opts.python, ctx) or vim.fn.exepath("python3")
          end,
          env = function(ctx)
            return resolve(opts.env, ctx) or {}
          end,
          console = "integratedTerminal",
          justMyCode = opts.just_my_code ~= false,
        },
      },
    },
  }
end

function M.cpp(opts)
  opts = opts or {}
  return {
    adapters = { codelldb = { type = "executable", command = opts.command or "codelldb" } },
    configurations = {
      cpp = {
        {
          name = "C/C++: launch executable",
          type = "codelldb",
          request = "launch",
          program = path("Executable: "),
          cwd = "${workspaceFolder}",
          stopOnEntry = false,
        },
      },
    },
    aliases = { c = "cpp" },
  }
end

function M.cargo_program(opts)
  opts = opts or {}
  return function(ctx)
    ctx = ctx or require("dap_tools.context").capture()
    return coroutine.create(function(co)
      local function finish(value, err)
        if err then
          vim.notify(err, vim.log.levels.ERROR, { title = "DAP Tools" })
        end
        local ok, message = coroutine.resume(co, value or require("dap").ABORT)
        if not ok then
          vim.notify(tostring(message), vim.log.levels.ERROR, { title = "DAP Tools" })
        end
      end
      local ok, err = pcall(
        vim.system,
        opts.build or { "cargo", "build", "--message-format=json" },
        { cwd = ctx.root, text = true },
        function(result)
          vim.schedule(function()
            if result.code ~= 0 then
              finish(nil, "cargo build failed:\n" .. (result.stderr or "") .. (result.stdout or ""))
              return
            end
            local paths, seen = {}, {}
            for line in (result.stdout or ""):gmatch("[^\r\n]+") do
              local decoded, item = pcall(vim.json.decode, line)
              if not decoded or type(item) ~= "table" then
                finish(nil, "cargo build returned invalid JSON: " .. line)
                return
              end
              if
                item.reason == "compiler-artifact"
                and type(item.executable) == "string"
                and not seen[item.executable]
              then
                seen[item.executable] = true
                paths[#paths + 1] = item.executable
              end
            end
            if #paths == 0 then
              finish(nil, "cargo build emitted no executable artifacts")
            elseif #paths == 1 then
              finish(paths[1])
            else
              vim.ui.select(paths, { prompt = "Rust executable:" }, function(selected)
                finish(selected)
              end)
            end
          end)
        end
      )
      if not ok then
        vim.schedule(function()
          finish(nil, "Could not start cargo build: " .. tostring(err))
        end)
      end
    end)
  end
end

function M.rust(opts)
  opts = opts or {}
  return {
    adapters = { codelldb = { type = "executable", command = opts.command or "codelldb" } },
    configurations = {
      rust = {
        {
          name = "Rust: build and launch",
          type = "codelldb",
          request = "launch",
          program = M.cargo_program(opts),
          cwd = "${workspaceFolder}",
          stopOnEntry = false,
        },
      },
    },
  }
end

function M.swift(opts)
  opts = opts or {}
  local mac = vim.fn.has("mac") == 1
  return {
    adapters = {
      lldb = {
        type = "executable",
        command = opts.command or (mac and "xcrun" or "lldb-dap"),
        args = opts.args or (mac and { "lldb-dap" } or nil),
      },
    },
    configurations = {
      swift = {
        {
          name = "Swift: launch executable",
          type = "lldb",
          request = "launch",
          program = path("Executable (app: Contents/MacOS/<name>): ", "/.build/debug/"),
          cwd = "${workspaceFolder}",
          stopOnEntry = false,
        },
      },
    },
  }
end

function M.build(opts)
  local result = { adapters = {}, configurations = {}, aliases = {} }
  for _, name in ipairs({ "python", "cpp", "rust", "swift" }) do
    local value = (opts.presets or {})[name]
    if value then
      local preset = M[name](type(value) == "table" and value or {})
      for _, key in ipairs({ "adapters", "configurations", "aliases" }) do
        result[key] = vim.tbl_extend("force", result[key], preset[key] or {})
      end
    end
  end
  for _, key in ipairs({ "adapters", "configurations", "aliases" }) do
    result[key] = vim.tbl_extend("force", result[key], opts[key] or {})
  end
  return result
end

return M
