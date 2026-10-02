#!/usr/bin/env bash
set -Eeuo pipefail

KERNEL_REPOSITORY='snowf14k3/raphael-kernel-build'
KERNEL_TAG="${KERNEL_TAG:-test-raphael-7.1-7.1.0-sm8150-g04e1c779f901}"
DTB_MODE="${DTB_MODE:-kernel}"
BASE_URL='https://github.com/snowf14k3/raphael-cache-image/releases/download/cache-base-v1/raphael-cache-base-v1.img.xz'
BASE_XZ_SHA256='ef7ad478485576d0eacfe3987e28756fbff2d207aebc5bc29a58499211aadb5c'
BASE_SHA256='4b36d22972cdb248a483048f943f267d1016bc4e514fb7bfafc78aa3bacca34c'
FIRMWARE_URL='https://github.com/GengWei1997/kernel-deb/releases/download/kernel-v7.1/firmware-xiaomi-raphael.deb'
FIRMWARE_SHA256='7702e4547ceb25762e6fdf9e79d4161105040bd9c795a104c21db0c5403d8475'
WORK='/workspace/.work'
OUT='/workspace/out'

[[ "$(uname -m)" == aarch64 ]] || {
    echo 'This build requires a native ARM64 runner.' >&2
    exit 1
}
. /etc/os-release
[[ "${VERSION_CODENAME:-}" == trixie ]] || {
    echo 'This build requires Debian 13 (trixie).' >&2
    exit 1
}
[[ "$KERNEL_TAG" =~ ^[A-Za-z0-9._+-]+$ ]] || exit 1
case "$DTB_MODE" in kernel|preserve-base) ;; *) exit 1 ;; esac

mkdir -p "$WORK" "$OUT"
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates curl initramfs-tools busybox-static kmod udev file \
    python3 mtools dosfstools xz-utils
busybox --list > "${WORK}/busybox-applets.txt"
grep -qx tar "${WORK}/busybox-applets.txt"
grep -qx sha256sum "${WORK}/busybox-applets.txt"

API_HEADERS=(-H 'Accept: application/vnd.github+json')
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    API_HEADERS+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
fi
curl -fsSL --retry 3 "${API_HEADERS[@]}" \
    "https://api.github.com/repos/${KERNEL_REPOSITORY}/releases/tags/${KERNEL_TAG}" \
    -o "${WORK}/kernel-release.json"
python3 - "$WORK" <<'PY'
import json
from pathlib import Path
import re
import sys

work = Path(sys.argv[1])
release = json.loads((work / "kernel-release.json").read_text())
assets = release.get("assets", [])
bundles = [a for a in assets if re.fullmatch(r"raphael-[A-Za-z0-9._+-]+\.tar\.gz", a["name"])]
if release.get("draft") or len(bundles) != 1:
    raise SystemExit("Release must contain exactly one published Raphael bundle")
bundle = bundles[0]
checksums = [a for a in assets if a["name"] == bundle["name"] + ".sha256"]
if len(checksums) != 1:
    raise SystemExit("Release is missing the matching bundle checksum")
(work / "kernel-assets.txt").write_text(
    "\n".join((bundle["name"], bundle["browser_download_url"],
              checksums[0]["browser_download_url"])) + "\n")
PY
mapfile -t ASSETS < "${WORK}/kernel-assets.txt"
[[ "${#ASSETS[@]}" == 3 ]]
BUNDLE_NAME="${ASSETS[0]}"
curl -fL --retry 3 -o "${WORK}/${BUNDLE_NAME}" "${ASSETS[1]}"
curl -fL --retry 3 -o "${WORK}/${BUNDLE_NAME}.sha256" "${ASSETS[2]}"
python3 - "$WORK" "$BUNDLE_NAME" <<'PY'
import hashlib
from pathlib import Path, PurePosixPath
import re
import sys
import tarfile

work, name = Path(sys.argv[1]), sys.argv[2]
fields = (work / (name + ".sha256")).read_text().split()
if (len(fields) != 2 or not re.fullmatch(r"[0-9a-fA-F]{64}", fields[0])
        or fields[1].lstrip("*") != name):
    raise SystemExit("Invalid bundle checksum file")
digest = hashlib.sha256()
with (work / name).open("rb") as stream:
    for chunk in iter(lambda: stream.read(1024 * 1024), b""):
        digest.update(chunk)
if digest.hexdigest() != fields[0].lower():
    raise SystemExit("Kernel bundle checksum mismatch")
destination = work / "kernel"
destination.mkdir()
with tarfile.open(work / name) as archive:
    members = archive.getmembers()
    for member in members:
        path = PurePosixPath(member.name)
        if (path.is_absolute() or ".." in path.parts
                or not (member.isfile() or member.isdir())
                or member.size > 512 * 1024 * 1024):
            raise SystemExit("Unsafe kernel bundle member")
    archive.extractall(destination, filter="data")
(work / "kernel-bundle-sha256.txt").write_text(digest.hexdigest() + "\n")
PY
mapfile -t MANIFESTS < <(find "${WORK}/kernel" -mindepth 2 -maxdepth 2 -type f -name SHA256SUMS)
[[ "${#MANIFESTS[@]}" == 1 ]]
BUNDLE_DIR="$(dirname "${MANIFESTS[0]}")"
(cd "$BUNDLE_DIR" && sha256sum -c SHA256SUMS)
KERNEL="$(awk -F= '$1 == "kernel_release" {print $2; exit}' "${BUNDLE_DIR}/build-info.txt")"
[[ "$KERNEL" =~ ^[0-9]+\.[0-9]+\.[0-9]+-sm8150[-+A-Za-z0-9._]*$ ]]
mapfile -t IMAGE_DEBS < <(find "$BUNDLE_DIR" -maxdepth 1 -type f -name "linux-image-${KERNEL}_*_arm64.deb")
[[ "${#IMAGE_DEBS[@]}" == 1 ]]
DEB="${IMAGE_DEBS[0]}"
[[ "$(dpkg-deb -f "$DEB" Architecture)" == arm64 ]]
[[ "$(dpkg-deb -f "$DEB" Package)" == "linux-image-${KERNEL}" ]]
for setting in CONFIG_EFI_ZBOOT=y CONFIG_DRM_MSM=y \
    CONFIG_DRM_PANEL_SAMSUNG_AMS639RQ08=y CONFIG_QCOM_LLCC=y \
    CONFIG_SM_GPUCC_8150=y CONFIG_INTERCONNECT_QCOM_SM8150=y; do
    grep -Fxq "$setting" "${BUNDLE_DIR}/kernel.config"
done
dpkg-deb --fsys-tarfile "$DEB" |
    tar -xOf - "./boot/config-${KERNEL}" > "${WORK}/deb.config"
cmp "${WORK}/deb.config" "${BUNDLE_DIR}/kernel.config"

curl -fL --retry 3 -o "${WORK}/base.img.xz" "$BASE_URL"
printf '%s  %s\n' "$BASE_XZ_SHA256" "${WORK}/base.img.xz" | sha256sum -c -
xz -dc "${WORK}/base.img.xz" > "${WORK}/base.img"
printf '%s  %s\n' "$BASE_SHA256" "${WORK}/base.img" | sha256sum -c -

curl -fL --retry 3 -o "${WORK}/firmware-xiaomi-raphael.deb" "$FIRMWARE_URL"
printf '%s  %s\n' "$FIRMWARE_SHA256" "${WORK}/firmware-xiaomi-raphael.deb" | sha256sum -c -
mkdir -p "${WORK}/firmware-root"
dpkg-deb -x "${WORK}/firmware-xiaomi-raphael.deb" "${WORK}/firmware-root"
for subdir in lib/firmware usr/lib/firmware; do
    if [[ -d "${WORK}/firmware-root/${subdir}" ]]; then
        mkdir -p "/${subdir}"
        cp -a "${WORK}/firmware-root/${subdir}/." "/${subdir}/"
    fi
done
install -m 0755 /workspace/scripts/raphael-initramfs-hook /etc/initramfs-tools/hooks/raphael
printf '\nMODULES=most\nCOMPRESS=gzip\n' >> /etc/initramfs-tools/initramfs.conf
dpkg -i "$DEB"
depmod "$KERNEL"
MODDIR="/usr/lib/modules/${KERNEL}"
[[ -s "${MODDIR}/modules.dep" && -d "${MODDIR}/kernel" ]]
tar -C "$MODDIR" -czf "${WORK}/raphael-modules.tar.gz" .
MODULE_ARCHIVE_SHA256="$(sha256sum "${WORK}/raphael-modules.tar.gz" | cut -d' ' -f1)"
install -m 0755 /workspace/scripts/module-payload-hook /etc/initramfs-tools/hooks/raphael-module-payload
mkdir -p /etc/initramfs-tools/scripts/local-bottom
sed -e "s/@KERNEL@/${KERNEL}/g" -e "s/@ARCHIVE_SHA@/${MODULE_ARCHIVE_SHA256}/g" \
    /workspace/scripts/module-sync-local-bottom.in \
    > /etc/initramfs-tools/scripts/local-bottom/raphael-module-sync
chmod 0755 /etc/initramfs-tools/scripts/local-bottom/raphael-module-sync
if [[ -s "/boot/initrd.img-${KERNEL}" ]]; then
    update-initramfs -u -k "$KERNEL"
else
    update-initramfs -c -k "$KERNEL"
fi
EFI="/boot/vmlinuz-${KERNEL}"
INITRD="/boot/initrd.img-${KERNEL}"
[[ -s "$EFI" && -s "$INITRD" ]]
file "$EFI"
gzip -t "$INITRD"
lsinitramfs "$INITRD" > "${WORK}/initramfs-contents.txt"
grep -Fxq init "${WORK}/initramfs-contents.txt"
grep -Fxq raphael-modules.tar.gz "${WORK}/initramfs-contents.txt"
grep -Fxq scripts/local-bottom/raphael-module-sync "${WORK}/initramfs-contents.txt"
grep -Fq "${KERNEL}/" "${WORK}/initramfs-contents.txt"
mkdir -p "${WORK}/verify-initramfs"
unmkinitramfs "$INITRD" "${WORK}/verify-initramfs"
cmp "${WORK}/raphael-modules.tar.gz" "${WORK}/verify-initramfs/raphael-modules.tar.gz"
cp "${WORK}/raphael-modules.tar.gz" /raphael-modules.tar.gz
mkdir -p /root/usr/lib/modules
rootmnt=/root /etc/initramfs-tools/scripts/local-bottom/raphael-module-sync
[[ -s "/root/usr/lib/modules/${KERNEL}/modules.dep" ]]
rootmnt=/root /etc/initramfs-tools/scripts/local-bottom/raphael-module-sync

IMAGE="xiaomi-k20pro-boot-${KERNEL}.img"
PACK_ARGS=(--base "${WORK}/base.img" --efi "$EFI" --initramfs "$INITRD" --out "${OUT}/${IMAGE}")
if [[ "$DTB_MODE" == kernel ]]; then
    PACK_ARGS+=(--dtb "${BUNDLE_DIR}/sm8150-xiaomi-raphael.dtb")
fi
python3 /workspace/scripts/pack-cache.py "${PACK_ARGS[@]}"
printf '%s\n' "$KERNEL" > "${OUT}/kernel-release.txt"
cat > "${OUT}/build-info.txt" <<INFO
kernel_release=${KERNEL}
kernel_repository=${KERNEL_REPOSITORY}
kernel_tag=${KERNEL_TAG}
kernel_bundle_sha256=$(cat "${WORK}/kernel-bundle-sha256.txt")
kernel_config_sha256=$(sha256sum "${BUNDLE_DIR}/kernel.config" | cut -d' ' -f1)
base_template_sha256=${BASE_SHA256}
firmware_sha256=${FIRMWARE_SHA256}
dtb_mode=${DTB_MODE}
image=${IMAGE}
image_sha256=$(sha256sum "${OUT}/${IMAGE}" | cut -d' ' -f1)
build_repository=https://github.com/snowf14k3/raphael-cache-image
build_commit=${BUILD_COMMIT:-unknown}
initramfs_distribution=Debian 13 (trixie)
module_sync=matching full module tree installed at first boot
INFO
(cd "$OUT" && sha256sum -c "${IMAGE}.sha256")
ls -lh "$OUT"
