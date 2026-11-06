#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
dap_tools_test_tmp=$(mktemp -d)
trap 'dap_tools_test_status=$?; if [ "$dap_tools_test_status" = 0 ]; then rm -rf "$dap_tools_test_tmp"; else echo "Test state/logs retained: $dap_tools_test_tmp"; fi' EXIT
export XDG_STATE_HOME="$dap_tools_test_tmp/state"
export XDG_CACHE_HOME="$dap_tools_test_tmp/cache"
export NVIM_LOG_FILE="$dap_tools_test_tmp/nvim.log"
for test in contracts launch panel cargo; do
  "${NVIM:-nvim}" --headless -u NONE -i NONE --noplugin -n -l "tests/$test.lua"
done
if [ "${DAP_TOOLS_REAL:-0}" = 1 ]; then
  python3 tests/tui.py
  if [ -n "${DAP_TOOLS_CODELLDB:-}" ]; then
    "${NVIM:-nvim}" --headless -u NONE -i NONE --noplugin -n -l tests/native.lua
  fi
fi
