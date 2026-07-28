#!/bin/sh
set -eu

. "$(dirname "$0")/lib.sh"
require_root

STORK_VERSION="${STORK_VERSION:-2.5.0}"
STORK_AGENT_PACKAGES_ENABLE="${STORK_AGENT_PACKAGES_ENABLE:-yes}"
STORK_AGENT_PACKAGE_ARCH="${STORK_AGENT_PACKAGE_ARCH:-}"
STORK_PACKAGES_DIR="${STORK_PACKAGES_DIR:-/usr/local/share/stork/www/assets/pkgs}"

case "$STORK_AGENT_PACKAGES_ENABLE" in
    yes|no) ;;
    *) die "STORK_AGENT_PACKAGES_ENABLE must be yes or no" ;;
esac
case "$STORK_PACKAGES_DIR" in
    /*) ;;
    *) die "STORK_PACKAGES_DIR must be an absolute path" ;;
esac

if [ -z "$STORK_AGENT_PACKAGE_ARCH" ]; then
    case "$(uname -m)" in
        amd64|x86_64) STORK_AGENT_PACKAGE_ARCH=amd64 ;;
        arm64|aarch64) STORK_AGENT_PACKAGE_ARCH=arm64 ;;
        *) die "set STORK_AGENT_PACKAGE_ARCH to amd64 or arm64" ;;
    esac
fi
case "$STORK_AGENT_PACKAGE_ARCH" in
    amd64|arm64) ;;
    *) die "STORK_AGENT_PACKAGE_ARCH must be amd64 or arm64" ;;
esac

install -d -m 0755 "$STORK_PACKAGES_DIR"
[ "$STORK_AGENT_PACKAGES_ENABLE" = yes ] || exit 0
[ "$STORK_VERSION" = 2.5.0 ] || \
    die "no pinned Cloudsmith agent package manifest for Stork ${STORK_VERSION}"
require_commands curl sha256

tmp_file=""
trap '[ -z "$tmp_file" ] || rm -f "$tmp_file"' EXIT HUP INT TERM

download_package()
{
    expected_sha256=$1
    package_filename=$2
    package_url=$3
    package_path="${STORK_PACKAGES_DIR}/${package_filename}"

    if [ -r "$package_path" ] && \
        [ "$(sha256 -q "$package_path")" = "$expected_sha256" ]; then
        echo "[*] Stork agent package already verified: ${package_filename}"
        return
    fi

    tmp_file="${package_path}.tmp.$$"
    rm -f "$tmp_file"
    curl --fail --location --retry 3 --retry-delay 2 \
        --output "$tmp_file" "$package_url"
    actual_sha256=$(sha256 -q "$tmp_file")
    if [ "$actual_sha256" != "$expected_sha256" ]; then
        die "checksum mismatch for Stork agent package ${package_filename}"
    fi
    chmod 0644 "$tmp_file"
    mv -f "$tmp_file" "$package_path"
    tmp_file=""
    echo "[+] Installed Stork agent package: ${package_filename}"
}

case "$STORK_AGENT_PACKAGE_ARCH" in
    amd64)
        download_package \
            0dbc0367a701071a7bae45b02bf536167453a5dad9d9c61aabebc4a22a38655c \
            isc-stork-agent_2.5.0.260529162649_amd64.deb \
            https://dl.cloudsmith.io/public/isc/stork-dev/deb/any-distro/pool/any-version/main/i/is/isc-stork-agent_2.5.0.260529162649/isc-stork-agent_2.5.0.260529162649_amd64.deb
        download_package \
            ef543db5fca0e6fbd6e80386ccbf14bc5076d97d87380cea65848a214746aff6 \
            isc-stork-agent-2.5.0.260529162646-1.x86_64.rpm \
            https://dl.cloudsmith.io/public/isc/stork-dev/rpm/any-distro/any-version/x86_64/isc-stork-agent-2.5.0.260529162646-1.x86_64.rpm
        download_package \
            b576c9ce6a17641d7659f249048db60144fd562a4ea7391dc9684e4d96743efd \
            isc-stork-agent-2.5.0.260529161924.apk \
            https://dl.cloudsmith.io/public/isc/stork-dev/alpine/main/any-version/x86_64/isc-stork-agent-2.5.0.260529161924.apk
        ;;
    arm64)
        download_package \
            2f753648a51cc3e2f883cf5644733d0371430ad9eca940c86d13b93effa2b51c \
            isc-stork-agent_2.5.0.260529162544_arm64.deb \
            https://dl.cloudsmith.io/public/isc/stork-dev/deb/any-distro/pool/any-version/main/i/is/isc-stork-agent_2.5.0.260529162544/isc-stork-agent_2.5.0.260529162544_arm64.deb
        download_package \
            1e1d7e407f5b8916945ac4a4545e205ad0cb340f057d863ff22cc3cbc9723a7e \
            isc-stork-agent-2.5.0.260529162544-1.aarch64.rpm \
            https://dl.cloudsmith.io/public/isc/stork-dev/rpm/any-distro/any-version/aarch64/isc-stork-agent-2.5.0.260529162544-1.aarch64.rpm
        download_package \
            2a22bd9c3312e9c061095010b3d9d36223831b34e9531e78903a15d67b802ef8 \
            isc-stork-agent-2.5.0.260529161907.apk \
            https://dl.cloudsmith.io/public/isc/stork-dev/alpine/main/any-version/aarch64/isc-stork-agent-2.5.0.260529161907.apk
        ;;
esac

echo "[+] Stork ${STORK_VERSION} ${STORK_AGENT_PACKAGE_ARCH} Linux agent packages are ready."
