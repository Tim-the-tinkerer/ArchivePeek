#!/bin/bash
# Download and bundle the official 7-Zip macOS console binary into the app.
set -euo pipefail

cd "$(dirname "$0")"

APP="${1:-ArchivePeek.app}"
TOOLS_DIR="${APP}/Contents/Resources/Tools"

# Pinned to the official 7-Zip 26.02 macOS release.
SEVENZIP_VERSION="26.02"
SEVENZIP_RELEASE_TAG="26.02"
SEVENZIP_ARCHIVE="7z2602-mac.tar.xz"
SEVENZIP_URL="https://github.com/ip7z/7zip/releases/download/${SEVENZIP_RELEASE_TAG}/${SEVENZIP_ARCHIVE}"
SEVENZIP_SHA256="1cf6760579502f87e591ff5c73a005ec50b3e4d6f507e8b038382d563c3175b9"

CACHE_ROOT=".cache/sevenzip-${SEVENZIP_VERSION}"
ARCHIVE_PATH="${CACHE_ROOT}/${SEVENZIP_ARCHIVE}"
EXTRACT_DIR="${CACHE_ROOT}/extracted"

mkdir -p "${TOOLS_DIR}" "${CACHE_ROOT}"

verify_sha256() {
    local file="$1"
    local expected="$2"
    local actual
    actual="$(shasum -a 256 "${file}" | awk '{print $1}')"
    [[ "${actual}" == "${expected}" ]]
}

download_sevenzip() {
    if [[ -f "${ARCHIVE_PATH}" ]] && verify_sha256 "${ARCHIVE_PATH}" "${SEVENZIP_SHA256}"; then
        echo "  Using cached ${SEVENZIP_ARCHIVE}"
        return 0
    fi

    echo "  Downloading 7-Zip ${SEVENZIP_VERSION} for macOS..."
    rm -f "${ARCHIVE_PATH}"
    if ! curl -fsSL --retry 3 --retry-delay 2 -o "${ARCHIVE_PATH}" "${SEVENZIP_URL}"; then
        echo "  Download failed." >&2
        rm -f "${ARCHIVE_PATH}"
        return 1
    fi

    if ! verify_sha256 "${ARCHIVE_PATH}" "${SEVENZIP_SHA256}"; then
        echo "  Error: SHA-256 mismatch for ${SEVENZIP_ARCHIVE}" >&2
        rm -f "${ARCHIVE_PATH}"
        return 1
    fi

    return 0
}

extract_sevenzip() {
    rm -rf "${EXTRACT_DIR}"
    mkdir -p "${EXTRACT_DIR}"
    tar -xJf "${ARCHIVE_PATH}" -C "${EXTRACT_DIR}"
}

bundle_from_download() {
    local source_7zz="${EXTRACT_DIR}/7zz"
    local source_license="${EXTRACT_DIR}/License.txt"

    if [[ ! -x "${source_7zz}" ]]; then
        echo "  Error: 7zz not found in downloaded archive" >&2
        return 1
    fi

    cp "${source_7zz}" "${TOOLS_DIR}/7zz"
    chmod +x "${TOOLS_DIR}/7zz"
    xattr -cr "${TOOLS_DIR}/7zz" 2>/dev/null || true

    if [[ -f "${source_license}" ]]; then
        cp "${source_license}" "${TOOLS_DIR}/7-Zip-LICENSE.txt"
        mkdir -p "ThirdParty"
        cp "${source_license}" "ThirdParty/7-Zip-LICENSE.txt"
    fi

    echo "  Bundled official 7zz ${SEVENZIP_VERSION} (universal arm64 + x86_64)"

    if ! "${TOOLS_DIR}/7zz" >/dev/null 2>&1; then
        echo "  Warning: bundled 7zz failed smoke test" >&2
    fi

    return 0
}

bundle_from_system_fallback() {
    echo "  Trying local system install as fallback..." >&2

    for candidate in \
        "/opt/homebrew/bin/7zz" \
        "/usr/local/bin/7zz" \
        "$(command -v 7zz 2>/dev/null || true)"; do
        if [[ -n "${candidate}" && -x "${candidate}" ]]; then
            cp "${candidate}" "${TOOLS_DIR}/7zz"
            chmod +x "${TOOLS_DIR}/7zz"
            if [[ -f "ThirdParty/7-Zip-LICENSE.txt" ]]; then
                cp "ThirdParty/7-Zip-LICENSE.txt" "${TOOLS_DIR}/7-Zip-LICENSE.txt"
            fi
            echo "  Bundled 7zz from ${candidate} (fallback)"
            return 0
        fi
    done

    return 1
}

echo "Vendoring archive tools into ${TOOLS_DIR}..."

if download_sevenzip && extract_sevenzip && bundle_from_download; then
    echo "Done."
    exit 0
fi

ALLOW_SYSTEM_FALLBACK="${ALLOW_SYSTEM_FALLBACK:-false}"
if [[ "${ALLOW_SYSTEM_FALLBACK}" == "true" ]] && bundle_from_system_fallback; then
    echo "Done (fallback)."
    exit 0
fi

echo "  Error: could not download or locate 7zz." >&2
echo "  Check your network connection." >&2
exit 1