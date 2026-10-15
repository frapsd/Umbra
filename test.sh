#!/bin/bash
# Builds and runs the hardware-free tests. --selftest covers the hardware.
set -euo pipefail
cd "$(dirname "$0")"

OUT="$(mktemp -d)/umbra-tests"
xcrun swiftc \
  -swift-version 5 \
  Sources/BrightnessLedger.swift \
  Tests/main.swift \
  -o "$OUT"
"$OUT"
