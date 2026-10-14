#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

python_cmd="${PYTHON:-python}"
pip_args=(install --force-reinstall --no-cache-dir --no-deps --require-hashes --only-binary=:all: --index-url https://pypi.org/simple)
if [[ -z "${VIRTUAL_ENV:-}" ]]; then
  pip_args+=(--user)
fi
"$python_cmd" -m pip "${pip_args[@]}" -r tools/build-dependencies/requirements-lupa.txt

npm ci --ignore-scripts --prefix "$repo_root/tools/build-dependencies" --registry=https://registry.npmjs.org/
if command -v cygpath >/dev/null 2>&1; then
  export WOWRAVOX_FENGARI="$(cygpath -w "$repo_root/tools/build-dependencies/node_modules/fengari")"
else
  export WOWRAVOX_FENGARI="$repo_root/tools/build-dependencies/node_modules/fengari"
fi

"$python_cmd" tools/Test-LuaSyntax.py
for test in tools/Test-*.js; do
  echo "== $test"
  node "$test"
done
