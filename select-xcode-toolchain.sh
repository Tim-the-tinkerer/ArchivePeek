#!/bin/bash
# Prefer full Xcode over Command Line Tools.
# CLT's swift-frontend does not load SwiftUIMacros, so @State / @AppStorage fail.
# /usr/bin/swift is a shim: setting DEVELOPER_DIR is enough to use Xcode's toolchain.
# Do not require Developer/usr/bin/swift — recent Xcode keeps the compiler under Toolchains/.

xcode_developer_is_usable() {
    local root="$1"
    [[ -x "${root}/usr/bin/xcodebuild" ]] \
        || [[ -x "${root}/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift" ]]
}

if [[ -n "${DEVELOPER_DIR:-}" ]] && xcode_developer_is_usable "${DEVELOPER_DIR}"; then
    export PATH="${DEVELOPER_DIR}/usr/bin:${PATH}"
    echo "Using Xcode toolchain: ${DEVELOPER_DIR}"
    return 0 2>/dev/null || true
fi

XCODE_DEVELOPER=""
for candidate in \
    "/Applications/Xcode.app/Contents/Developer" \
    "/Applications/Xcode-beta.app/Contents/Developer"
do
    if xcode_developer_is_usable "${candidate}"; then
        XCODE_DEVELOPER="${candidate}"
        break
    fi
done

if [[ -z "${XCODE_DEVELOPER}" ]]; then
    selected="$(xcode-select -p 2>/dev/null || true)"
    if [[ -n "${selected}" ]] && xcode_developer_is_usable "${selected}"; then
        XCODE_DEVELOPER="${selected}"
    fi
fi

if [[ -n "${XCODE_DEVELOPER}" ]]; then
    export DEVELOPER_DIR="${XCODE_DEVELOPER}"
    export PATH="${XCODE_DEVELOPER}/usr/bin:${PATH}"
    echo "Using Xcode toolchain: ${XCODE_DEVELOPER}"
else
    echo "Warning: usable Xcode toolchain not found. Command Line Tools cannot compile SwiftUI macros (@State)." >&2
    echo "Install Xcode from the App Store, then retry." >&2
fi
