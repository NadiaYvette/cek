#!/usr/bin/env bash
set -euo pipefail

echo "=== [TP-CEK-001C Verification Gate] ==="
bin/cek-verify
cabal v2-test cek-polytropos
echo "=== [TP-CEK-001C Verification Gate PASSED] ==="
