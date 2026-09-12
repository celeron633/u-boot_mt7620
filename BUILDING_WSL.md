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

编译优酷路由宝 YK-L1 时：

```sh
CONFIG_FILE=YK-L1 bash ./build-wsl.sh
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

`YK-L1` 配置使用 32 MiB SPI NOR、128 MiB DDR2 和 192 KiB U-Boot 分区：

| 分区 | 偏移 | 大小 |
| --- | ---: | ---: |
| U-Boot | `0x000000` | `0x030000` |
| U-Boot env | `0x030000` | `0x010000` |
| Factory | `0x040000` | `0x010000` |
| Firmware | `0x050000` | `0x1fb0000` |

该配置支持 W25Q256/MX25L256 的 4 字节地址，并使用 YK-L1 OpenWrt 镜像所需的
`0x12291000` uImage magic。不要用于只有 16 MiB flash 的 YK-L1c。

烧写前仍需核对实际硬件参数：PSG1218/K2 配置为 DDR2 64 MiB、8 MiB flash；
YK-L1 配置为 DDR2 128 MiB、32 MiB flash。它们都是 MT7620、16-bit DRAM
总线、SPI NOR、链接地址 `0xBC000000`。参数不符时不要直接写入 flash。
