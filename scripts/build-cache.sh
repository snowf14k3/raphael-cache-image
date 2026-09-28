#!/usr/bin/env bash
set -Eeuo pipefail

KERNEL='7.1.0-sm8150-gd771f25178ba'
TAG="test-raphael-7.1-${KERNEL}"
BUNDLE="raphael-raphael-7.1-${KERNEL}"
BUNDLE_SHA256='61ce29b064fb8a8e11c8eba404d7d216f7c681d693865acabd69e135573b667b'
BASE='https://github.com/snowf14k3/raphael-kernel-build/releases/download'
BOOT_URL='https://github.com/GengWei1997/kernel-deb/releases/download/v1.0.0/xiaomi-k20pro-boot.img'
FIRMWARE_URL='https://github.com/GengWei1997/kernel-deb/releases/download/kernel-v7.1/firmware-xiaomi-raphael.deb'
WORK='/workspace/.work'
OUT='/workspace/out'
IMAGE="${OUT}/raphael-cache-d771f251-debian13.img"

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
    ca-certificates curl initramfs-tools busybox-static kmod udev \
    mtools dosfstools file

curl -fL --retry 3 --output "${WORK}/${BUNDLE}.tar.gz" \
    "${BASE}/${TAG}/${BUNDLE}.tar.gz"
echo "${BUNDLE_SHA256}  ${WORK}/${BUNDLE}.tar.gz" | sha256sum -c -
tar -xzf "${WORK}/${BUNDLE}.tar.gz" -C "$WORK"
IMAGE_DEB="${WORK}/${BUNDLE}/linux-image-${KERNEL}_7.1.0-gd771f25178ba-2_arm64.deb"
DTB="${WORK}/${BUNDLE}/sm8150-xiaomi-raphael.dtb"
[[ -s "$IMAGE_DEB" && -s "$DTB" ]]
[[ "$(dpkg-deb -f "$IMAGE_DEB" Architecture)" == arm64 ]]

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

dpkg -i "$IMAGE_DEB"
depmod "$KERNEL"
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
grep -Fq "${KERNEL}/" "${WORK}/initramfs-contents.txt"

cp "$EFI" "${OUT}/linux.efi"
cp "$INITRD" "${OUT}/initramfs"
cp "$DTB" "${OUT}/sm8150-xiaomi-raphael.dtb"
curl -fL --retry 3 --output "$IMAGE" "$BOOT_URL"
[[ "$(stat -c %s "$IMAGE")" == 268435456 ]]

cat > "${WORK}/ubuntu.conf" <<EOF
title Raphael Debian 13 (${KERNEL})
sort-key raphael
linux /linux.efi
initrd /initramfs
devicetree /dtbs/qcom/sm8150-xiaomi-raphael.dtb
options console=tty0 loglevel=3 root=PARTLABEL=userdata rootfstype=ext4 rootwait rw
EOF
mcopy -o -i "$IMAGE" "${OUT}/linux.efi" ::/linux.efi
mcopy -o -i "$IMAGE" "${OUT}/initramfs" ::/initramfs
mcopy -o -i "$IMAGE" "${OUT}/sm8150-xiaomi-raphael.dtb" ::/dtbs/qcom/sm8150-xiaomi-raphael.dtb
mcopy -o -i "$IMAGE" "${WORK}/ubuntu.conf" ::/loader/entries/ubuntu.conf

fsck.vfat -n "$IMAGE"
mkdir -p "${WORK}/verify"
mcopy -i "$IMAGE" ::/linux.efi "${WORK}/verify/linux.efi"
mcopy -i "$IMAGE" ::/initramfs "${WORK}/verify/initramfs"
mcopy -i "$IMAGE" ::/dtbs/qcom/sm8150-xiaomi-raphael.dtb \
    "${WORK}/verify/sm8150-xiaomi-raphael.dtb"
cmp "${OUT}/linux.efi" "${WORK}/verify/linux.efi"
cmp "${OUT}/initramfs" "${WORK}/verify/initramfs"
cmp "${OUT}/sm8150-xiaomi-raphael.dtb" \
    "${WORK}/verify/sm8150-xiaomi-raphael.dtb"

(cd "$OUT" && sha256sum "$(basename "$IMAGE")" > "$(basename "$IMAGE").sha256")
ls -lh "$OUT"
