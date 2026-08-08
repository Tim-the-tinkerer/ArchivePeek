#!/bin/bash
cd "$(dirname "$0")"

export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin:${PATH:-}"

echo "======================================"
echo " ArchivePeek Builder"
echo "======================================"
echo ""

if ! command -v swift >/dev/null 2>&1; then
    echo "ERROR: Swift not found."
    echo "Install Xcode Command Line Tools:"
    echo "  xcode-select --install"
    echo ""
    read -r -p "Press Return to close..."
    exit 1
fi

chmod +x build-app.sh vendor-tools.sh verify-build.sh 2>/dev/null || true

if ./build-app.sh --no-launch; then
    echo ""
    echo "SUCCESS: ArchivePeek.app is ready."
    echo "Double-click ArchivePeek.app to launch."
else
    echo ""
    echo "BUILD FAILED."
    echo "See messages above for details."
fi

echo ""
read -r -p "Press Return to close..."