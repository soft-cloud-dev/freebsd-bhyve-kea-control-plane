#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
FETCH_SCRIPT="${FETCH_SCRIPT:-${ROOT}/scripts/fetch_freebsd_cloud_image.sh}"

sha256_file() {
    if command -v sha256 >/dev/null 2>&1; then
        sha256 -q "$1"
    else
        sha256sum "$1" | awk '{print $1}'
    fi
}

command -v xz >/dev/null 2>&1 || {
    echo "SKIP: xz is unavailable" >&2
    exit 0
}
command -v curl >/dev/null 2>&1 || {
    echo "SKIP: curl is unavailable" >&2
    exit 0
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM
source_dir="${work}/source"
cache_dir="${work}/cache"
mkdir -p "$source_dir" "$cache_dir"

printf 'verified FreeBSD cloud image fixture\n' > "${source_dir}/image.raw"
xz -c "${source_dir}/image.raw" > "${source_dir}/image.raw.xz"
compressed_sha=$(sha256_file "${source_dir}/image.raw.xz")
printf 'SHA256 (image.raw.xz) = %s\n' "$compressed_sha" > "${source_dir}/CHECKSUM.SHA256"

cache="${cache_dir}/freebsd-cloud.raw"
FREEBSD_CLOUD_IMAGE_URL="file://${source_dir}/image.raw.xz" \
FREEBSD_CLOUD_IMAGE_CHECKSUM_URL="file://${source_dir}/CHECKSUM.SHA256" \
FREEBSD_CLOUD_IMAGE_CACHE="$cache" \
    sh "$FETCH_SCRIPT"

cmp "${source_dir}/image.raw" "$cache"
[ -s "${cache}.verified" ]

printf 'tampered\n' > "$cache"
FREEBSD_CLOUD_IMAGE_URL="file://${source_dir}/image.raw.xz" \
FREEBSD_CLOUD_IMAGE_CHECKSUM_URL="file://${source_dir}/CHECKSUM.SHA256" \
FREEBSD_CLOUD_IMAGE_CACHE="$cache" \
    sh "$FETCH_SCRIPT"
cmp "${source_dir}/image.raw" "$cache"

wrong_cache="${cache_dir}/wrong.raw"
if FREEBSD_CLOUD_IMAGE_URL="file://${source_dir}/image.raw.xz" \
    FREEBSD_CLOUD_IMAGE_SHA256="0000000000000000000000000000000000000000000000000000000000000000" \
    FREEBSD_CLOUD_IMAGE_CACHE="$wrong_cache" \
        sh "$FETCH_SCRIPT" >"${work}/wrong.out" 2>&1; then
    echo "ERROR: image fetcher accepted an invalid checksum" >&2
    exit 1
fi
[ ! -e "$wrong_cache" ]
[ ! -e "${wrong_cache}.verified" ]

echo "PASS: verified and atomic FreeBSD cloud image cache"
