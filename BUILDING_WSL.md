# 在 WSL 中编译 MT7620 U-Boot

这份代码可以用 Debian/Ubuntu 当前的 MIPS little-endian 交叉编译器构建，
不需要 Docker，也不需要让 `HOSTCC` 使用老交叉工具链。已经验证的组合是
Debian 13、宿主 GCC 14 和 `mipsel-linux-gnu-gcc` 14。

## 安装依赖

在 WSL 内执行：

```sh
sudo apt-get update
sudo apt-get install -y \
  build-essential gcc-mipsel-linux-gnu binutils-mipsel-linux-gnu \
  zlib1g-dev
```

其中宿主 GCC 只编译 `tools/mkimage`，MIPS GCC 编译 U-Boot 本体。Java 是
可选的；存在时会用仓库自带的 YUI Compressor 压缩内置 HTTP 页面的 CSS，
不存在时生成器会自动使用未压缩内容。

## 构建

从 Windows PowerShell 执行（按实际发行版名和路径调整）：

```powershell
wsl -d Debian --cd /mnt/d/code/u-boot_mt7620 bash ./build-wsl.sh
```

也可以先进入 WSL，再在仓库根目录执行：

```sh
bash ./build-wsl.sh
```

脚本默认使用仓库中的 `Ai-BR100` 配置。编译斐讯 K2/PSG1218 时：

```sh
CONFIG_FILE=PSG1218 bash ./build-wsl.sh
```

保留原厂固件 v22.5 或更新版本的分区布局时：

```sh
CONFIG_FILE=PSG1218-V22.5 bash ./build-wsl.sh
```

编译极路由 2/HC5761 时：

```sh
CONFIG_FILE=HC5761 bash ./build-wsl.sh
```

使用其他保存配置时：

```sh
CONFIG_FILE=my-board.config bash ./build-wsl.sh
```

不要加 `-j`：顶层旧 Makefile 把 `clean` 和各输出声明成并列依赖，并行构建
会发生竞态。也不要执行 `make rt2880_config`；仓库把 `include/asm` 提交成了
真实目录，而旧 `mkconfig` 仍试图把它当符号链接删除。仓库现有的
`include/config.h` 和 `include/config.mk` 已经是正确的 Ralink MIPS 配置。

## 输出

`Ai-BR100` 配置选择 SPI flash 和 `UBOOT_ROM`，因此实际烧写文件是
`uboot.bin`。`uboot_128k.bin` 是补齐到 128 KiB 的版本；`uboot.img` 带有
旧 MTK `mkimage` 头，当前 SPI ROM 配置并不使用它。

`PSG1218` 配置同样使用 `uboot.bin`；网页救援升级要求上传完整分区镜像时，
使用补齐到 192 KiB 的 `uboot_192k.bin`。该配置采用以下 8 MiB flash 布局：

| 分区 | 偏移 | 大小 |
| --- | ---: | ---: |
| U-Boot | `0x00000` | `0x30000` |
| U-Boot env | `0x30000` | `0x10000` |
| Factory | `0x40000` | `0x10000` |
| Firmware | `0x50000` | `0x7b0000` |

这个布局对应 PSG1218 和 K2 v22.4 或更早版本。OpenWrt 对 K2 v22.5 或更新
版本使用从 `0xa0000` 开始的固件分区；这种情况应使用 `PSG1218-V22.5`：

| 分区 | 偏移 | 大小 |
| --- | ---: | ---: |
| U-Boot | `0x00000` | `0x30000` |
| U-Boot env | `0x30000` | `0x10000` |
| Factory | `0x40000` | `0x10000` |
| Permanent config | `0x50000` | `0x50000` |
| Firmware | `0xa0000` | `0x760000` |

`HC5761` 使用 16 MiB flash，U-Boot 输出同样补齐到 192 KiB。分区布局按
OpenWrt 当前设备树配置，并保留 flash 尾部的 OEM、板级信息和备份区域：

| 分区 | 偏移 | 大小 |
| --- | ---: | ---: |
| U-Boot | `0x000000` | `0x030000` |
| hw_panic | `0x030000` | `0x010000` |
| Factory | `0x040000` | `0x010000` |
| Firmware | `0x050000` | `0xf70000` |
| OEM | `0xfc0000` | `0x020000` |
| bdinfo | `0xfe0000` | `0x010000` |
| Backup | `0xff0000` | `0x010000` |

U-Boot 会把 `0x030000` 的 64 KiB 区域作为环境区使用，而原厂布局将它命名为
`hw_panic`；执行 `saveenv` 会改写该区域。固件升级和 `erase linux` 的上限已限制
到 `0xfc0000`，不会覆盖尾部 OEM、`bdinfo` 和 Backup。以太网 MAC 从
`bdinfo + 0x18a` 的 17 字节文本地址读取。

烧写前仍需核对实际硬件参数：PSG1218/K2 配置为 DDR2 64 MiB，HC5761 配置为
DDR2 128 MiB；二者都是 MT7620、16-bit DRAM 总线、SPI NOR，链接地址
`0xBC000000`。参数不符时不要直接写入 flash。
