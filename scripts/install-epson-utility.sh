#!/usr/bin/env bash
# Downloads and unpacks Epson's binary "epson-printer-utility" RPM,
# keeping only the CUPS backend (rastertoepson filter) and the ecbd
# network-discovery daemon — the pieces printing actually needs — and
# discarding the Qt5 setup/maintenance GUI. Output tree the
# Containerfile COPYs straight into the final Dakota image, mirroring
# how build-nvidia.sh packages the NVIDIA driver via a filesystem diff
# instead of running an installer directly against the final image.
#
# Adapted from lbssousa/bluefin's build_files/20-epson.sh (the
# "Install epson-printer-utility" section only — this repo doesn't
# install the epson-inkjet-printer-escpr driver, which needs building
# from source against cups-devel/autotools not present on Dakota).
#
# The GUI (/opt/epson-printer-utility/bin/epson-printer-utility) is
# dropped on purpose: it's a Qt5 binary (libQt5Core/Gui/Widgets.so.5),
# and Dakota (GNOME OS) ships no Qt5 runtime at all — confirmed on
# real hardware (2026-09-22) that launching it fails with
# "libQt5Core.so.5: cannot open shared object file". Bundling a full
# Qt5 stack just for an optional setup/maintenance utility isn't worth
# the image-size cost; printing itself doesn't need it — the CUPS
# filter and ecbd both link only against libraries Dakota already
# ships (confirmed via `ldd` against the running system), and ecbd
# starts cleanly as a systemd service. Printer setup/maintenance is
# available via GNOME Settings › Printers or the CUPS web UI instead.
#
# We don't use 'rpm -i' (Dakota's builder stage is Fedora, but the
# RPM's cpio payload has duplicate directory entries that make rpm/cpio
# fail with "mkdir failed - File exists" once /opt exists).
#
# Usage: install-epson-utility.sh <output-dir>
#   <output-dir>  directory to populate with the final tree
#                  (usr/bin/..., usr/lib/epson-backend/, ...)
set -euo pipefail

out_dir="$1"

# renovate: datasource=custom.epson-printer-utility
UTILITY_VERSION="1.2.2"
UTILITY_RPM_URL="https://download-center.epson.com/f/module/0fd7dd73-92c2-451e-88cf-cf385e0f6db7/epson-printer-utility-${UTILITY_VERSION}-1.x86_64.rpm"
UTILITY_FALLBACK_VERSION="1.1.3"
UTILITY_FALLBACK_URL="https://download3.ebz.epson.net/dsc/f/03/00/15/43/24/e0c56348985648be318592edd35955672826bf2c/epson-printer-utility-${UTILITY_FALLBACK_VERSION}-1.x86_64.rpm"

# Epson's download domains sit behind Akamai's CDN/WAF, which blocks
# generic User-Agents ('curl', 'Mozilla') but allows a plain browser
# name. The CDN fallback has no such check but may lag behind the
# latest version. See lbssousa/bluefin's scripts/check-epson-updates.sh
# for the full rationale.
download_epson() {
    local output="$1" primary_url="$2" fallback_url="$3"

    echo "==> Downloading epson-printer-utility ${UTILITY_VERSION}..."
    if curl -L --fail --retry 3 --retry-delay 5 -A 'Firefox' \
            --output "${output}" "${primary_url}"; then
        return 0
    fi

    echo "WARN: Primary download failed (Akamai may be blocking this IP)." >&2
    echo "WARN: Falling back to CDN URL (may be an older version)." >&2
    if curl -L --fail --retry 3 --retry-delay 5 \
            --output "${output}" "${fallback_url}"; then
        return 0
    fi

    echo "ERROR: All download sources failed for epson-printer-utility!" >&2
    echo "  Primary:  ${primary_url}" >&2
    echo "  Fallback: ${fallback_url}" >&2
    return 1
}

workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT

utility_rpm="${workdir}/epson-printer-utility.x86_64.rpm"
download_epson "${utility_rpm}" "${UTILITY_RPM_URL}" "${UTILITY_FALLBACK_URL}"

extract_dir="${workdir}/extract"
mkdir -p "${extract_dir}"
(cd "${extract_dir}" && rpm2cpio "${utility_rpm}" | cpio -idmu)

echo "==> Assembling output tree in ${out_dir}..."

# /usr content (CUPS backend, ecbd daemon + its service file, docs)
# goes straight to /usr. Nothing under /opt/epson-printer-utility (the
# Qt5 GUI and its resources) is copied — see the header comment above.
mkdir -p "${out_dir}/usr"
cp -a "${extract_dir}/usr/." "${out_dir}/usr/"

# Udev rules: ship in the immutable system path instead of
# /etc/udev/rules.d/ (the RPM scriptlet's target, not replicated here).
# USB permission handling for Epson devices, unrelated to the GUI.
install -Dm0644 \
    "${extract_dir}/opt/epson-printer-utility/rules/79-udev-epson.rules" \
    "${out_dir}/usr/lib/udev/rules.d/79-udev-epson.rules"

# Move service file from /usr/lib/epson-backend/ to the standard
# systemd unit path so the final stage's 'systemctl enable' can find
# it (the original copy is left in place; harmless duplicate).
install -Dm0644 \
    "${out_dir}/usr/lib/epson-backend/ecbd.service" \
    "${out_dir}/usr/lib/systemd/system/ecbd.service"

echo "==> install-epson-utility.sh done."
