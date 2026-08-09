#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

LAUNCH=true
CLEAN=false
for arg in "$@"; do
    case "${arg}" in
        --no-launch) LAUNCH=false ;;
        --clean) CLEAN=true ;;
    esac
done

APP="ArchivePeek.app"

if [[ "${CLEAN}" == "true" ]]; then
    echo "Cleaning build artifacts..."
    rm -rf .build
fi

echo "Building ArchivePeek (release)..."
swift build -c release

if [[ -f generate-icon.swift ]] && { [[ ! -f AppIcon.icns ]] || [[ generate-icon.swift -nt AppIcon.icns ]]; }; then
    echo "Generating app icon..."
    swift generate-icon.swift || echo "Warning: icon generation failed; continuing without custom icon."
fi

echo "Assembling ${APP}..."
mkdir -p "${APP}/Contents/MacOS"
mkdir -p "${APP}/Contents/Resources"

cp .build/release/ArchivePeek "${APP}/Contents/MacOS/ArchivePeek"
chmod +x "${APP}/Contents/MacOS/ArchivePeek"
cp AppInfo.plist "${APP}/Contents/Info.plist"

if [[ -f AppIcon.icns ]]; then
    cp AppIcon.icns "${APP}/Contents/Resources/AppIcon.icns"
fi

for doc in CHANGELOG.md README.md; do
    if [[ -f "${doc}" ]]; then
        cp "${doc}" "${APP}/Contents/Resources/${doc}"
    fi
done

echo "Bundling archive tools..."
./vendor-tools.sh "${APP}"

touch "${APP}"

# Keep /Applications in sync so Launch Services does not prefer a stale ArchivePeek
# (older builds still mapped .cbz onto the generic archive type and wrong Finder icons).
if [[ -d /Applications ]]; then
    echo "Installing to /Applications/ArchivePeek.app..."
    rm -rf /Applications/ArchivePeek.app
    cp -R "${APP}" /Applications/ArchivePeek.app
    LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    if [[ -x "${LSREGISTER}" ]]; then
        "${LSREGISTER}" -f /Applications/ArchivePeek.app >/dev/null 2>&1 || true
    fi
fi

echo "Done: ${APP}"
if [[ "${LAUNCH}" == "true" ]]; then
    echo "Launching..."
    open "${APP}"
fi