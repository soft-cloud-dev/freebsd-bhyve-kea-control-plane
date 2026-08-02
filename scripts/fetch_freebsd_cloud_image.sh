#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "${SCRIPT_DIR}/lib.sh"

FREEBSD_CLOUD_IMAGE_URL="${FREEBSD_CLOUD_IMAGE_URL:-https://download.freebsd.org/releases/VM-IMAGES/14.3-RELEASE/amd64/Latest/FreeBSD-14.3-RELEASE-amd64-BASIC-CLOUDINIT-ufs.raw.xz}"
FREEBSD_CLOUD_IMAGE_CACHE="${FREEBSD_CLOUD_IMAGE_CACHE:-/var/cache/control-plane/freebsd-cloud.raw}"
FREEBSD_CLOUD_IMAGE_SHA256="${FREEBSD_CLOUD_IMAGE_SHA256:-}"
FREEBSD_CLOUD_IMAGE_CHECKSUM_URL="${FREEBSD_CLOUD_IMAGE_CHECKSUM_URL:-${FREEBSD_CLOUD_IMAGE_URL%/*}/CHECKSUM.SHA256}"
VERIFIED_MARKER="${FREEBSD_CLOUD_IMAGE_CACHE}.verified"

if [ -n "$FREEBSD_CLOUD_IMAGE_SHA256" ]; then
    case "$FREEBSD_CLOUD_IMAGE_SHA256" in
        *[!0-9A-Fa-f]*) die "invalid explicit cloud image SHA-256 digest" ;;
    esac
    [ "${#FREEBSD_CLOUD_IMAGE_SHA256}" -eq 64 ] || \
        die "invalid explicit cloud image SHA-256 digest length"
    FREEBSD_CLOUD_IMAGE_SHA256=$(printf '%s' "$FREEBSD_CLOUD_IMAGE_SHA256" | tr 'A-F' 'a-f')
fi

sha256_file() {
    file=$1
    if command -v sha256 >/dev/null 2>&1; then
        sha256 -q "$file"
    elif command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$file" | awk '{print $1}'
    else
        die "missing command: sha256 or sha256sum"
    fi
}

fetch_file() {
    url=$1
    destination=$2
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL -o "$destination" "$url"
    elif command -v fetch >/dev/null 2>&1; then
        fetch -o "$destination" "$url"
    else
        die "missing command: curl or fetch"
    fi
}

cache_is_verified() {
    [ -r "$FREEBSD_CLOUD_IMAGE_CACHE" ] || return 1
    [ -r "$VERIFIED_MARKER" ] || return 1

    marker_url=""
    marker_compressed=""
    marker_raw=""
    IFS='|' read -r marker_url marker_compressed marker_raw < "$VERIFIED_MARKER" || return 1

    [ "$marker_url" = "$FREEBSD_CLOUD_IMAGE_URL" ] || return 1
    [ -n "$marker_compressed" ] || return 1
    [ -n "$marker_raw" ] || return 1
    if [ -n "$FREEBSD_CLOUD_IMAGE_SHA256" ]; then
        [ "$marker_compressed" = "$FREEBSD_CLOUD_IMAGE_SHA256" ] || return 1
    fi

    current_raw=$(sha256_file "$FREEBSD_CLOUD_IMAGE_CACHE")
    [ "$current_raw" = "$marker_raw" ]
}

if cache_is_verified; then
    echo "[+] Verified cloud image cache: ${FREEBSD_CLOUD_IMAGE_CACHE}"
    exit 0
fi

cache_dir=$(dirname "$FREEBSD_CLOUD_IMAGE_CACHE")
install -d -m 0755 "$cache_dir"
tmp_dir=$(mktemp -d "${cache_dir}/.freebsd-cloud.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM

image_name=${FREEBSD_CLOUD_IMAGE_URL##*/}
image_name=${image_name%%\?*}
compressed_image="${tmp_dir}/${image_name}"
raw_image="${tmp_dir}/image.raw"
checksum_file="${tmp_dir}/CHECKSUM.SHA256"

expected_sha256=$FREEBSD_CLOUD_IMAGE_SHA256
if [ -z "$expected_sha256" ]; then
    fetch_file "$FREEBSD_CLOUD_IMAGE_CHECKSUM_URL" "$checksum_file"
    expected_sha256=$(awk -v image="$image_name" '
        $1 == "SHA256" && $2 == "(" image ")" && $3 == "=" {
            print $4
            exit
        }
    ' "$checksum_file")
    [ -n "$expected_sha256" ] || \
        die "checksum for ${image_name} not found in ${FREEBSD_CLOUD_IMAGE_CHECKSUM_URL}"
fi

case "$expected_sha256" in
    *[!0-9A-Fa-f]*|'') die "invalid SHA-256 digest for ${image_name}" ;;
esac
[ "${#expected_sha256}" -eq 64 ] || die "invalid SHA-256 digest length for ${image_name}"
expected_sha256=$(printf '%s' "$expected_sha256" | tr 'A-F' 'a-f')

fetch_file "$FREEBSD_CLOUD_IMAGE_URL" "$compressed_image"
actual_sha256=$(sha256_file "$compressed_image")
[ "$actual_sha256" = "$expected_sha256" ] || \
    die "SHA-256 mismatch for ${image_name}: expected ${expected_sha256}, got ${actual_sha256}"

unxz -c "$compressed_image" > "$raw_image"
raw_sha256=$(sha256_file "$raw_image")
chmod 0644 "$raw_image"
printf '%s|%s|%s\n' \
    "$FREEBSD_CLOUD_IMAGE_URL" \
    "$expected_sha256" \
    "$raw_sha256" > "${tmp_dir}/verified"
chmod 0644 "${tmp_dir}/verified"

mv "$raw_image" "$FREEBSD_CLOUD_IMAGE_CACHE"
mv "${tmp_dir}/verified" "$VERIFIED_MARKER"

echo "[+] Cached verified cloud image at ${FREEBSD_CLOUD_IMAGE_CACHE}"
