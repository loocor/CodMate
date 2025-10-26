#!/usr/bin/env bash
set -euo pipefail

# Guard against accidentally double-escaping Swift typed KeyPaths when patching.
# Looks for patterns like \\TypeName\.property inside Swift sources, which indicate
# a literal "\\" in the code. In Swift, KeyPaths should start with a single backslash.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
cd "$ROOT_DIR"

if ! command -v rg >/dev/null 2>&1; then
  echo "ripgrep (rg) not found; skipping keypath check" >&2
  exit 0
fi

set +e
matches=$(rg -n "\\\\[A-Za-z_][A-Za-z0-9_]*\\." --glob 'Sources/**/*.swift' 2>/dev/null)
rc=$?
set -e

if [ $rc -eq 0 ] && [ -n "$matches" ]; then
  echo "ERROR: Found likely double-escaped Swift KeyPaths (\\Type.property)." >&2
  echo "$matches" >&2
  echo "Hint: Use a single backslash in Swift, e.g., \\ProvidersVM.codexBaseURL" >&2
  exit 1
fi

echo "Swift KeyPath check passed."
exit 0

