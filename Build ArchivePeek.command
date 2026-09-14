#!/bin/bash
cd "$(dirname "$0")"

export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin:${PATH:-}"
# shellcheck source=select-xcode-toolchain.sh
source "./select-xcode-toolchain.sh"

echo "======================================"
echo " ArchivePeek Builder"
echo "======================================"
echo ""

if ! command -v swift >/dev/null 2>&1; then
    echo "ERROR: Swift not found."
    echo "Install Xcode from the App Store (Command Line Tools alone cannot build this app)."
    echo ""
    read -r -p "Press Return to close..."
    exit 1
fi

if [[ -z "${DEVELOPER_DIR:-}" || "${DEVELOPER_DIR}" == *CommandLineTools* ]]; then
    echo "ERROR: Building ArchivePeek requires full Xcode, not Command Line Tools."
    echo "Install Xcode from the App Store, then retry."
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