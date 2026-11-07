# dap-tools.nvim

Debugger launch workflows and an independent panel backed by nvim-dap.

## Features

- Inspect scopes, variables, threads, stacks, watches and breakpoints.
- Launch Python, C/C++, Rust and Swift with explicit presets.
- Preserve native nvim-dap sessions, configurations and terminals.

## Requirements

Neovim **0.11+**. `nvim-dap` is required. Install debug adapters separately; presets are opt-in.

## Installation

With lazy.nvim:

```lua
{
  "Jacky-Lzx/dap-tools.nvim",
  main = "dap_tools",
  dependencies = { "mfussenegger/nvim-dap" },
  opts = { presets = { cpp = true, rust = true, swift = true } },
}
```

Or put this repository and its required dependencies on `runtimepath`, then call:

```lua
require("dap_tools").setup({
  presets = { cpp = true, rust = true, swift = true },
})
```

## Usage

```vim
:DapToolsContinue
:DapToolsToggle
:DapToolsInfo
```

## Documentation

- [Complete reference](doc/dap-tools.txt) — `:help dap-tools`.
- [Workflow and integration guide](doc/guide.md).
- Diagnose availability with `:checkhealth dap_tools`.

## Development

Run from the repository root:

```sh
python3 tests/run.py unit --filter docs
python3 tests/run.py default
```

See [the test workflow](tests/README.md) for dependencies, optional suites and
retained failure evidence. Local development overrides belong in your package
manager configuration; public installation uses the repository above.

[License](LICENSE).
