#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "$repo_root/frontend"
jac install --quiet
jac install -e "$repo_root" --no-save --quiet

exec jac start --dev main.jac "$@"
