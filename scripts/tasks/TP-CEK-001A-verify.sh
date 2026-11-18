#!/usr/bin/env bash
set -euo pipefail

echo "=== [TP-CEK-001A Verification Gate] ==="
bin/cek-verify
cabal v2-test cek-core
echo "=== [TP-CEK-001A Verification Gate PASSED] ==="
