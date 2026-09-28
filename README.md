# Raphael Debian 13 cache 镜像

此项目仅生成 Redmi K20 Pro（Raphael）的 `cache` 启动镜像，不编译内核，也不刷写设备。GitHub Actions 使用原生 ARM64 runner 运行 Debian 13 容器，在其中安装已发布的 `d771f251` 内核包和 Raphael 固件，调用 `update-initramfs` 生成完整的 `initramfs`，再把 EFI 内核、initramfs 与 DTB 写入 256 MiB FAT32 cache 模板。

在 Actions 的 **Build Debian 13 Raphael cache image** 中运行工作流，下载 `raphael-cache-d771f251-debian13` artifact。校验镜像 SHA256 后，在能识别手机的 fastboot 环境使用：

```sh
fastboot flash cache raphael-cache-d771f251-debian13.img
fastboot reboot
```

此镜像针对 `userdata` 上的未加密 ext4 Debian 13 根文件系统。文件完整性由工作流验证；实机启动和设备驱动仍需刷入后确认。

参考：[GengWei1997 的 initramfs 生成脚本](https://github.com/GengWei1997/linux-xiaomi-raphael-uboot/blob/master/scripts/09-install-kernel.sh) 与 [cache 镜像刷写说明](https://github.com/GengWei1997/linux-xiaomi-raphael-uboot)。
