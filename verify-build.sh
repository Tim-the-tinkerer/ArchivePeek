#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck source=select-xcode-toolchain.sh
source "./select-xcode-toolchain.sh"

rm -rf .build Tests
echo "Building ArchivePeek..."
if swift build -c release 2>&1 | tee build.log; then
    echo "BUILD OK" | tee -a build.log
    exit 0
else
    echo "BUILD FAILED — see build.log" >&2
    exit 1
fi