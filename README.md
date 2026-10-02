# Raphael Debian 13 cache IMG

GitHub Actions 直接生成可刷入 cache 分区的 256 MiB IMG，不需要下载 EFI、initramfs 等组件后再在本地组装。构建使用 Debian 13 ARM64 容器和已发布的内核包，不重新编译内核。

在 Actions 的 **Run workflow** 中选择 `kernel_tag`。默认使用 `test-raphael-7.1-7.1.0-sm8150-g04e1c779f901`；`dtb_mode=kernel` 使用该发布包的 Raphael DTB，`preserve-base` 保留底图 DTB。

完成后下载 `raphael-cache-debian13-<内核版本>` artifact，解压得到 IMG、`.img.sha256` 和 `build-info.txt`。在 fastboot 中刷入：

```text
fastboot flash cache xiaomi-k20pro-boot-<内核版本>.img
```

固定底图保留原有 EFI bootloader 与启动项；Actions 写入新 EFI 内核、匹配 initramfs 和所选 DTB，并校验内核配置、文件内容及 FAT 文件系统。initramfs 会在首次启动时将匹配的完整模块目录放进根文件系统，避免内核与旧模块不匹配。

面向当前未加密 ext4 userdata 的 Debian 13 系统。模板启动项保留原底图的根分区 UUID；其他根分区布局需要单独适配。CI 校验通过不代表已经完成实机启动验证。
