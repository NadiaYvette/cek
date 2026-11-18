#!/usr/bin/env bash
set -euo pipefail

echo "=== [TP-CEK-002B-mercury Verification Gate] ==="
bin/cek-verify
cabal v2-test cek-examples
echo "=== [TP-CEK-002B-mercury Verification Gate PASSED] ==="
