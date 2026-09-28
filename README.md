# Raphael Debian 13 cache 恢复组件

GitHub Actions 使用原生 ARM64 runner 的 Debian 13 容器，安装 `gc0d0d7d7dbb8` 内核包和 Raphael 固件，并用 `update-initramfs` 生成匹配的 initramfs。构建不重新编译内核。

initramfs 中额外包含该内核的完整模块目录。在第一次启动、挂载 `userdata` 根分区后，它把模块放进 `/usr/lib/modules/7.1.0-sm8150-gc0d0d7d7dbb8`。此步骤会写入手机的根文件系统，避免旧 `ge358973bb9f2` 模块与新内核版本不符。

Actions artifact 提供 `linux.efi`、`initramfs`、Raphael DTB、内核 deb 和 `SHA256SUMS`。最终 cache 镜像须以设备原本**能启动**的 `xiaomi-k20pro-boot.img` 为底，只替换 EFI 内核和 initramfs；保留原 bootloader、DTB 与启动项。不要直接把 Actions artifact 当作 fastboot 镜像刷入。

针对未加密 ext4 `userdata` 的 Debian 13 系统。文件完整性可在打包后校验；实际设备启动仍需验证。

参考：[上游 initramfs 生成步骤](https://github.com/GengWei1997/linux-xiaomi-raphael-uboot/blob/master/scripts/09-install-kernel.sh)。
