#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
secret_file="${WIREJAC_JWT_SECRET_FILE:-${HOME}/.wirejac/jwt-secret}"

if [[ -z "${WIREJAC_JWT_SECRET:-}" ]]; then
    umask 077
    mkdir -p "$(dirname "$secret_file")"
    if [[ ! -s "$secret_file" ]]; then
        temporary="${secret_file}.tmp.$$"
        if command -v openssl >/dev/null 2>&1; then
            openssl rand -hex 32 > "$temporary"
        else
            od -An -N32 -tx1 /dev/urandom | tr -d ' \n' > "$temporary"
            printf '\n' >> "$temporary"
        fi
        chmod 600 "$temporary"
        mv "$temporary" "$secret_file"
    fi
    export WIREJAC_JWT_SECRET="$(<"$secret_file")"
fi

cd "$repo_root"
python_bin="${repo_root}/.jac/venv/bin/python"
if [[ ! -x "$python_bin" ]]; then
    python_bin="$(command -v python3)"
fi
exec "$python_bin" scripts/serve_loopback.py "$@"
