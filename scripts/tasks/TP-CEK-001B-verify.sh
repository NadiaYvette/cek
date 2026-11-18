#!/usr/bin/env bash
set -euo pipefail

echo "=== [TP-CEK-001B Verification Gate] ==="
bin/cek-verify
cabal v2-test cek-pykinos
echo "=== [TP-CEK-001B Verification Gate PASSED] ==="
