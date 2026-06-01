#!/bin/bash
# Quick dev build + run (foreground, for testing). Use Scripts/install.sh for real install.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
echo "Built: .build/release/Curtain"
echo "Run with:  .build/release/Curtain   (Ctrl-C to stop)"
