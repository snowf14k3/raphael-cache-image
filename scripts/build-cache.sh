#!/usr/bin/env bash
set -Eeuo pipefail

KERNEL='7.1.0-sm8150-gc0d0d7d7dbb8'
DEB="linux-image-${KERNEL}_7.1.0-gc0d0d7d7dbb8-1_arm64.deb"
DEB_SHA256='e5b4a398e2093b42d2ede8acff9f7923154f8b6d54386a1e7a91f79e35a5a0ca'
DTB_SHA256='3a38482077fd47ad2fd680ebb2c594e1c57ef5073b1173405d9d1f075290e6e7'
INPUT_BASE='https://github.com/snowf14k3/raphael-cache-image/releases/download/bootfix-input-gc0d0d7d7dbb8'
FIRMWARE_URL='https://github.com/GengWei1997/kernel-deb/releases/download/kernel-v7.1/firmware-xiaomi-raphael.deb'
WORK='/workspace/.work'
OUT='/workspace/out'

if [[ "$(uname -m)" != aarch64 ]]; then
    echo 'This build must run in a native Debian 13 ARM64 container.' >&2
    exit 1
fi
. /etc/os-release
if [[ "${VERSION_CODENAME:-}" != trixie ]]; then
    echo 'This build requires Debian 13 (trixie).' >&2
    exit 1
fi

mkdir -p "$WORK" "$OUT"
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates curl initramfs-tools busybox-static kmod udev file
busybox --list > "${WORK}/busybox-applets.txt"
grep -qx tar "${WORK}/busybox-applets.txt"
grep -qx sha256sum "${WORK}/busybox-applets.txt"

curl -fL --retry 3 --output "${WORK}/${DEB}" "${INPUT_BASE}/${DEB}"
curl -fL --retry 3 --output "${WORK}/sm8150-xiaomi-raphael.dtb" \
    "${INPUT_BASE}/sm8150-xiaomi-raphael.dtb"
echo "${DEB_SHA256}  ${WORK}/${DEB}" | sha256sum -c -
echo "${DTB_SHA256}  ${WORK}/sm8150-xiaomi-raphael.dtb" | sha256sum -c -
[[ "$(dpkg-deb -f "${WORK}/${DEB}" Architecture)" == arm64 ]]

curl -fL --retry 3 --output "${WORK}/firmware-xiaomi-raphael.deb" "$FIRMWARE_URL"
mkdir -p "${WORK}/firmware-root"
dpkg-deb -x "${WORK}/firmware-xiaomi-raphael.deb" "${WORK}/firmware-root"
for subdir in lib/firmware usr/lib/firmware; do
    if [[ -d "${WORK}/firmware-root/${subdir}" ]]; then
        mkdir -p "/${subdir}"
        cp -a "${WORK}/firmware-root/${subdir}/." "/${subdir}/"
    fi
done

install -m 0755 /workspace/scripts/raphael-initramfs-hook \
    /etc/initramfs-tools/hooks/raphael
printf '\nMODULES=most\nCOMPRESS=gzip\n' >> /etc/initramfs-tools/initramfs.conf

dpkg -i "${WORK}/${DEB}"
depmod "$KERNEL"
MODDIR="/usr/lib/modules/${KERNEL}"
[[ -s "${MODDIR}/modules.dep" && -d "${MODDIR}/kernel" ]]
tar -C "$MODDIR" -czf "${WORK}/raphael-modules.tar.gz" .
MODULE_ARCHIVE_SHA256="$(sha256sum "${WORK}/raphael-modules.tar.gz" | cut -d' ' -f1)"

install -m 0755 /workspace/scripts/module-payload-hook \
    /etc/initramfs-tools/hooks/raphael-module-payload
mkdir -p /etc/initramfs-tools/scripts/local-bottom
sed -e "s/@KERNEL@/${KERNEL}/g" \
    -e "s/@ARCHIVE_SHA@/${MODULE_ARCHIVE_SHA256}/g" \
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
[[ "$(head -c 2 "$EFI")" == MZ ]]
file "$EFI"
gzip -t "$INITRD"
lsinitramfs "$INITRD" > "${WORK}/initramfs-contents.txt"
grep -Fxq init "${WORK}/initramfs-contents.txt"
grep -Fxq raphael-modules.tar.gz "${WORK}/initramfs-contents.txt"
grep -Fxq scripts/local-bottom/raphael-module-sync "${WORK}/initramfs-contents.txt"
grep -Fq "${KERNEL}/" "${WORK}/initramfs-contents.txt"
mkdir -p "${WORK}/verify-initramfs"
unmkinitramfs "$INITRD" "${WORK}/verify-initramfs"
cmp "${WORK}/raphael-modules.tar.gz" \
    "${WORK}/verify-initramfs/raphael-modules.tar.gz"

# Exercise the exact first-boot script against a disposable root in this CI
# container. Its /root is not the user's device.
cp "${WORK}/raphael-modules.tar.gz" /raphael-modules.tar.gz
mkdir -p /root/usr/lib/modules
rootmnt=/root /etc/initramfs-tools/scripts/local-bottom/raphael-module-sync
[[ -s "/root/usr/lib/modules/${KERNEL}/modules.dep" ]]
rootmnt=/root /etc/initramfs-tools/scripts/local-bottom/raphael-module-sync

cp "$EFI" "${OUT}/linux.efi"
cp "$INITRD" "${OUT}/initramfs"
cp "${WORK}/sm8150-xiaomi-raphael.dtb" "${OUT}/sm8150-xiaomi-raphael.dtb"
cp "${WORK}/${DEB}" "${OUT}/${DEB}"
(cd "$OUT" && sha256sum linux.efi initramfs sm8150-xiaomi-raphael.dtb "$DEB" > SHA256SUMS)
ls -lh "$OUT"
