#!/usr/bin/env python3
"""Build and verify a Raphael cache image using its known-good FAT template."""

import argparse
import hashlib
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile

IMAGE_SIZE = 256 * 1024 * 1024
DTB_PATH = "/dtbs/qcom/sm8150-xiaomi-raphael.dtb"


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def run(program, *args):
    directory = os.environ.get("MTOOLS_BIN_DIR")
    executable = str(Path(directory) / program) if directory and program in ("mcopy", "mdir") else program
    result = subprocess.run(
        [executable, *map(str, args)], stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, check=False,
    )
    if result.returncode:
        raise RuntimeError(
            f"{program} failed ({result.returncode}): "
            + result.stderr.decode(errors="replace")
            + result.stdout.decode(errors="replace")
        )
    return result.stdout


def image_files(image):
    listing = run("mdir", "-i", image, "-a", "-b", "-s", "::/").decode()
    files = []
    for line in listing.splitlines():
        name = line.strip()
        if not name.startswith("::/") or name.endswith("/"):
            continue
        path = name[2:]
        if any(part in ("", ".", "..") for part in path[1:].split("/")):
            raise ValueError(f"Invalid FAT filename: {path}")
        files.append(path)
    return files


def snapshot(image, excluded, temporary):
    result = {}
    for index, name in enumerate(image_files(image)):
        key = name.casefold()
        if key in excluded:
            continue
        if key in result:
            raise ValueError(f"Duplicate FAT filename: {name}")
        extracted = Path(temporary) / f"file-{index}"
        run("mcopy", "-i", image, "::" + name, extracted)
        result[key] = sha256(extracted)
        extracted.unlink()
    return result


def validate_efi(path):
    with Path(path).open("rb") as stream:
        header = stream.read(64)
        if len(header) != 64 or header[:2] != b"MZ":
            raise ValueError("Kernel must be a PE/COFF EFI application")
        offset = struct.unpack_from("<I", header, 60)[0]
        if offset > Path(path).stat().st_size - 96:
            raise ValueError("Invalid PE header offset")
        stream.seek(offset)
        pe = stream.read(96)
    if (pe[:4] != b"PE\0\0"
            or struct.unpack_from("<H", pe, 4)[0] != 0xAA64
            or struct.unpack_from("<H", pe, 24)[0] != 0x20B
            or struct.unpack_from("<H", pe, 92)[0] != 10):
        raise ValueError("Kernel must be an AArch64 PE32+ EFI application")


def zero_unused_clusters(image):
    with Path(image).open("r+b") as stream:
        boot = stream.read(512)
        sector = struct.unpack_from("<H", boot, 11)[0]
        per_cluster = boot[13]
        reserved = struct.unpack_from("<H", boot, 14)[0]
        copies = boot[16]
        fat_sectors = struct.unpack_from("<I", boot, 36)[0]
        total_sectors = struct.unpack_from("<I", boot, 32)[0]
        info_sector = struct.unpack_from("<H", boot, 48)[0]
        backup_sector = struct.unpack_from("<H", boot, 50)[0]
        if (boot[510:512] != b"\x55\xaa"
                or sector not in (512, 1024, 2048, 4096)
                or not per_cluster or per_cluster & (per_cluster - 1)
                or copies != 2 or not fat_sectors
                or sector * total_sectors != IMAGE_SIZE
                or Path(image).stat().st_size != IMAGE_SIZE):
            raise ValueError("Unexpected cache FAT32 geometry")
        data_sector = reserved + copies * fat_sectors
        count = (total_sectors - data_sector) // per_cluster
        stream.seek(reserved * sector)
        fat = stream.read(fat_sectors * sector)
        if len(fat) < (count + 2) * 4 or stream.read(len(fat)) != fat:
            raise ValueError("FAT copies differ or are too short")
        free = [i for i in range(2, count + 2)
                if struct.unpack_from("<I", fat, i * 4)[0] & 0x0FFFFFFF == 0]
        if not free:
            raise ValueError("No free cache clusters")
        cluster_bytes = sector * per_cluster
        zero = b"\0" * (1024 * 1024)
        start = last = free[0]
        for cluster in free[1:] + [count + 3]:
            if cluster == last + 1:
                last = cluster
                continue
            stream.seek(data_sector * sector + (start - 2) * cluster_bytes)
            remaining = (last - start + 1) * cluster_bytes
            while remaining:
                size = min(remaining, len(zero))
                stream.write(zero[:size])
                remaining -= size
            start = last = cluster
        for number in (info_sector, backup_sector + info_sector):
            if not 0 < number < reserved:
                raise ValueError("FSInfo lies outside the reserved area")
            stream.seek(number * sector)
            info = stream.read(512)
            if info[:4] != b"RRaA" or info[484:488] != b"rrAa":
                raise ValueError("Invalid FAT32 FSInfo signature")
            stream.seek(number * sector + 488)
            stream.write(struct.pack("<II", len(free), free[0]))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", type=Path, required=True)
    parser.add_argument("--efi", type=Path, required=True)
    parser.add_argument("--initramfs", type=Path, required=True)
    parser.add_argument("--dtb", type=Path)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    if args.base.resolve() == args.out.resolve():
        raise ValueError("The input template must not be overwritten")
    if args.base.stat().st_size != IMAGE_SIZE:
        raise ValueError("The template must be exactly 256 MiB")
    validate_efi(args.efi)
    run("gzip", "-t", args.initramfs)
    replacements = {"/linux.efi": args.efi, "/initramfs": args.initramfs}
    if args.dtb:
        if args.dtb.read_bytes()[:4] != b"\xd0\x0d\xfe\xed":
            raise ValueError("Invalid kernel DTB")
        replacements[DTB_PATH] = args.dtb
    args.out.parent.mkdir(parents=True, exist_ok=True)
    excluded = {name.casefold() for name in replacements}
    with tempfile.TemporaryDirectory(prefix=".pack-", dir=args.out.parent) as directory:
        temporary = Path(directory)
        names = {name.casefold() for name in image_files(args.base)}
        if "/efi/boot/bootaa64.efi" not in names or not excluded <= names:
            raise ValueError("Template is missing a bootloader or replacement path")
        protected = snapshot(args.base, excluded, temporary)
        image = temporary / "cache.img"
        shutil.copyfile(args.base, image)
        for name, source in replacements.items():
            run("mcopy", "-o", "-i", image, source, "::" + name)
        zero_unused_clusters(image)
        print(run("fsck.fat", "-n", image).decode(), end="")
        if snapshot(image, excluded, temporary) != protected:
            raise ValueError("A protected boot file changed")
        for index, (name, source) in enumerate(replacements.items()):
            embedded = temporary / f"replacement-{index}"
            run("mcopy", "-i", image, "::" + name, embedded)
            if sha256(embedded) != sha256(source):
                raise ValueError(f"Embedded file does not match its source: {name}")
        if {name.casefold() for name in image_files(image)} != names:
            raise ValueError("FAT file list changed")
        image.replace(args.out)
    checksum = args.out.with_name(args.out.name + ".sha256")
    checksum.write_text(f"{sha256(args.out)}  {args.out.name}\n", encoding="ascii")
    print(f"Verified cache image: {args.out}")


if __name__ == "__main__":
    main()
