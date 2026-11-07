# dap-tools.nvim

Configuration and debugging interactions for **Neovim 0.11+**, backed by
[nvim-dap](https://github.com/mfussenegger/nvim-dap).

The panel is implemented here: scopes and expandable variables, threads and stack
frames, watches, breakpoints, and bounded output. It does not require nvim-dap-view,
nvim-dap-ui, or a picker plugin. nvim-dap owns protocol communication, sessions,
breakpoints, terminals, REPL and expression hovers. Adapter installation stays with
your package manager or toolchain plugin.

## Setup

Put both this plugin and nvim-dap on `runtimepath`. For lazy.nvim:

```lua
{
  dir = '~/Documents/Github/nvim_plugins/dap-tools.nvim',
  main = 'dap_tools',
  dependencies = { 'mfussenegger/nvim-dap' },
  opts = {
    presets = {
      python = {
        adapter_python = '/path/to/debugpy/venv/bin/python',
        python = function(ctx) return '/path/to/project/.venv/bin/python' end,
        env = function(ctx) return { VIRTUAL_ENV = ctx.root .. '/.venv' } end,
      },
      cpp = true,
      rust = true,
      swift = true,
    },
  },
}
```

Each preset is opt-in. Python separates the interpreter containing debugpy from
the interpreter and environment of the debuggee. Rust runs `cargo build
--message-format=json` asynchronously and offers emitted executables. C/C++ and
Swift prompt for an executable; for an Xcode app select
`Your.app/Contents/MacOS/Your`. codelldb and lldb-dap must already be installed.

`setup()` and native command registration do not load nvim-dap or the panel.
The backend initializes on first use. Native nvim-dap configuration and registered
adapters remain usable. Project `.vscode/launch.json` entries are read from the
captured project root; entries with the same name override the filetype choices
for that launch. VS Code tasks and extension-specific commands are not executed.

No global keymaps are installed. For example:

```lua
vim.keymap.set('n', '<F5>', '<cmd>DapToolsContinue<cr>')
vim.keymap.set('n', '<F6>', '<cmd>DapToolsStepOver<cr>')
vim.keymap.set('n', '<leader>b', '<cmd>DapToolsBreakpoint<cr>')
vim.keymap.set('n', '<leader>du', '<cmd>DapToolsToggle<cr>')
```

## Commands and panel

| Command | Action |
| --- | --- |
| `:DapTools` / `:DapToolsToggle` | Focus / toggle the independent panel |
| `:DapToolsRun [name]` | Choose a configuration and launch it |
| `:DapToolsRun! [name]` | Prompt for quoted command-line arguments before launching |
| `:DapToolsContinue` | Continue the current session, or choose a launch |
| `:DapToolsRunLast[!]` | Repeat the previous launch; `!` prompts for new arguments |
| `:DapToolsStepOver`, `StepInto`, `StepOut` | Step in the active session (all prefixed `DapTools`) |
| `:DapToolsPause`, `Terminate`, `Disconnect` | Control the active session (all prefixed `DapTools`) |
| `:DapToolsBreakpoint [condition\|log]` | Toggle a breakpoint, or prompt for a condition/log message |
| `:DapToolsWatch [expression]` | Add a watch; omitted expression opens a prompt |
| `:DapToolsSessions` | Switch among active sessions |
| `:DapToolsRepl` | Open nvim-dap's interactive REPL |
| `:DapToolsClose` | Hide the panel, preserving the session |
| `:checkhealth dap_tools` | Check backend and adapter availability |

Panel keys: `1` scopes, `2` stack, `3` watches, `4` breakpoints, `5` output.
`Enter` expands a variable or jumps to a frame/breakpoint; `d` removes a watch or
breakpoint. `c` continues, `n` steps over, `i` steps into, `o` steps out, `p` pauses,
`x` terminates, `s` switches sessions, `a` adds a watch, `e` evaluates an expression,
`r` opens the REPL, and `q` hides the panel. Automatic opening keeps source focus;
manual opening focuses the panel. Output includes adapter events and a read-only
view of the current or last debuggee terminal. Use the original terminal window
for program input.

Argument syntax supports single/double quotes, backslash escaping and empty
arguments. It performs no shell expansion. Canceling a selection/input does not
launch. Source buffer and project context are captured before opening prompts.

## Configuration and API

```lua
local tools = require('dap_tools')
tools.setup({
  adapters = {},       -- nvim-dap adapter definitions
  configurations = {}, -- filetype -> list of nvim-dap configurations
  aliases = {},        -- e.g. { c = 'cpp' }; no chained aliases
  presets = {},
  ui = {
    position = 'bottom', -- or 'right'
    height = 0.28,      -- fraction <= 1, otherwise rows/columns
    auto_open = true,
    auto_close = false,
    max_lines = 2000,   -- retained adapter lines; terminal tail is also bounded
    max_children = 200, -- displayed variables per node
  },
  -- Optional integration for a package manager that mounts nvim-dap on demand:
  backend_loader = nil,
  -- Optional asynchronous preparation. Call done() on success or done(error).
  before_start = nil, -- function(config, ctx, done) ... end
})

tools.run('Python: launch file', { args = { '--name', 'two words' } })
tools.run({ name = 'Attach', type = 'python', request = 'attach',
  connect = { host = '127.0.0.1', port = 5678 } })
tools.open('stack', true)
tools.close()
tools.watch('answer')
tools.breakpoint('condition')
tools.action('step_over')
tools.run_last()
tools.cancel_launch() -- cancels pending configuration/argument/preparation choices
local state = tools.status() -- does not initialize the backend
local backend = tools.backend() -- explicitly initializes it
tools.dispose()
```

`ctx` contains `buf`, `win`, `file`, `filetype`, `cwd`, and `root`. Root discovery
uses `.git`, `Cargo.toml`, `pyproject.toml`, `Package.swift`, or `package.json`, falling
back to cwd. Top-level configuration callbacks receive this captured context as an
optional argument. Preset options accept callbacks for Python interpreters/env.
Explicit `adapters` and per-filetype `configurations` replace the respective preset
definitions. `cpp` and `rust` share `codelldb`; customize that adapter through
`adapters.codelldb` when enabling both.

Reconfiguration validates before changing live options. It replaces plugin-owned
registrations and preserves unrelated native configurations and user replacements.
`dispose()` removes owned commands/listeners/panel resources and restores replaced
adapter/configuration entries; it does not terminate nvim-dap sessions. Pending
native nvim-dap resolution (such as an already-started Cargo build) belongs to
nvim-dap and is not canceled by `cancel_launch()`.

Variable and watch responses are checked against session, frame and stop epoch,
so previous requests cannot paint a newer stop. Variables are expanded on demand;
large trees are capped, rather than fully materialized.

## Validation

```sh
export DAP_TOOLS_DAP_PATH=/path/to/nvim-dap
sh tests/run.sh
DAP_TOOLS_REAL=1 DAP_TOOLS_DEBUGPY_PYTHON=/path/to/debugpy/python sh tests/run.sh acceptance --filter tui
```

The first command covers registry/command ownership, cold startup, arguments,
launch cancellation, stale panel responses and Cargo artifact selection. The
second also runs a real debugpy session in a PTY, with actual keys for prompts,
variable expansion, watches, frame navigation, stepping and restarting. Terminal
transcripts and rendered screen text are retained under the printed artifact path.
Select `acceptance --filter native` with `DAP_TOOLS_CODELLDB=/path/to/codelldb` for real codelldb and
`lldb-dap` checks against a compiled C fixture (requires clang and lldb-dap).

## Health and inspection

Health reports actionable failures and a compact result for applicable checks. Disabled,
optional and not-yet-activated features do not warn solely because they are inactive.
Inspection does not configure plugins, start services or install dependencies.
Use `:DapToolsInfo` for detailed configuration and runtime information.

[Test workflow](tests/README.md): registered suites, filtering, required fixtures and retained failure evidence.
