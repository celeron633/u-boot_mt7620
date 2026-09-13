# MT7620 U-Boot

这是一个面向 MT7620 路由器的旧版 Ralink/MediaTek U-Boot 源码树，当前主要维护
SPI NOR 启动、串口/TFTP 升级和 Web failsafe。仓库已经补充现代 WSL 构建脚本，
不需要原项目使用的老 Buildroot 工具链，也不需要 Docker。

原版 U-Boot 说明文档保存在 [`README.old`](README.old)，更完整的 WSL 构建与设备
分区说明见 [`BUILDING_WSL.md`](BUILDING_WSL.md)。

## 支持的设备

以下配置均为 MT7620、DDR2、16-bit DRAM 总线和 SPI NOR，链接地址为
`0xBC000000`。

| 配置文件 | 设备 | 内存 | Flash | U-Boot 分区镜像 | Firmware 布局 |
| --- | --- | ---: | ---: | ---: | --- |
| `Ai-BR100` | Ai-BR100（默认配置） | 64 MiB | 启动时探测 | 128 KiB | 从 `0x40000` 开始 |
| `PSG1218` | PSG1218、斐讯 K2 v22.4 或更早版本 | 64 MiB | 8 MiB | 192 KiB | `0x50000`，大小 `0x7b0000` |
| `PSG1218-V22.5` | 斐讯 K2 v22.5 或更新版本 | 64 MiB | 8 MiB | 192 KiB | `0xa0000`，大小 `0x760000` |
| `HC5761` | 极路由 2 / HiWiFi HC5761 | 128 MiB | 16 MiB | 192 KiB | `0x50000`，大小 `0xf70000` |
| `YK-L1` | 优酷路由宝 YK-L1 | 128 MiB | 32 MiB | 192 KiB | `0x50000`，大小 `0x1fb0000` |

设备相关注意事项：

- K2 必须根据原厂版本选择配置。v22.5 及更新版本在 Firmware 前保留
  `0x50000` 字节的 Permanent config，不能与旧布局混用。
- HC5761 的 Web 和 Shell 升级会拒绝超过 `0xf70000` 的固件，`erase linux`
  也不会擦除从 `0xfc0000` 开始的 OEM、`bdinfo` 和 Backup 区域。以太网 MAC
  从 `bdinfo + 0x18a` 的文本地址读取。
- HC5761 将原厂 `hw_panic` 所在的 `0x30000`～`0x3ffff` 作为 U-Boot 环境区；
  执行 `saveenv` 会改写这一区域。
- YK-L1 配置支持 W25Q256/MX25L256 的 4 字节地址和 `0x12291000` uImage
  magic，不适用于只有 16 MiB Flash 的 YK-L1c。

## 仓库结构

```text
.
├── board/rt2880/       MT7620/Ralink 板级初始化与链接脚本
├── cpu/ralink_soc/     MIPS 启动、CPU 和 Cache 代码
├── common/             U-Boot 命令、控制台和环境变量
├── drivers/            SPI/NAND Flash、以太网、USB 等驱动
├── lib_mips/           MIPS 板级启动菜单和升级流程
├── net/                网络栈、TFTP 和 Web failsafe 接入
├── httpd/              uIP HTTP 服务及内置网页
├── include/            公共头文件和 MT7620 布局配置
├── tools/              在宿主机编译运行的 mkimage 等工具
├── Ai-BR100            Ai-BR100 保存配置
├── PSG1218             PSG1218/K2 旧分区保存配置
├── PSG1218-V22.5       K2 v22.5+ 分区保存配置
├── HC5761              HC5761 保存配置
├── YK-L1               YK-L1 保存配置
└── build-wsl.sh        推荐的 WSL/Linux 构建入口
```

`build-wsl.sh` 会将选定的保存配置复制为 `.config`，重新生成 `autoconf.h` 和
HTTP 内置文件，然后使用单线程构建。`.config`、`autoconf.h`、目标文件和最终
镜像均为生成物，不需要提交。

## 在 WSL 中编译

### 1. 安装依赖

在 Debian/Ubuntu WSL 中执行：

```sh
sudo apt-get update
sudo apt-get install -y \
  build-essential gcc-mipsel-linux-gnu binutils-mipsel-linux-gnu \
  zlib1g-dev
```

宿主 GCC 只用于编译 `tools/mkimage`，`mipsel-linux-gnu-gcc` 用于编译 U-Boot。
Java 是可选依赖；存在时会压缩内置网页的 CSS，不存在时仍可正常构建。

### 2. 选择设备并构建

进入仓库后执行：

```sh
# 默认：Ai-BR100
bash ./build-wsl.sh

# PSG1218 / K2 v22.4 或更早版本
CONFIG_FILE=PSG1218 bash ./build-wsl.sh

# K2 v22.5 或更新版本
CONFIG_FILE=PSG1218-V22.5 bash ./build-wsl.sh

# 极路由 2 / HC5761
CONFIG_FILE=HC5761 bash ./build-wsl.sh

# 优酷路由宝 YK-L1
CONFIG_FILE=YK-L1 bash ./build-wsl.sh
```

也可以从 Windows PowerShell 直接调用；请按实际 WSL 发行版和仓库路径调整：

```powershell
wsl -d Debian --cd /mnt/d/code/u-boot_mt7620 bash ./build-wsl.sh
wsl -d Debian --cd /mnt/d/code/u-boot_mt7620 env CONFIG_FILE=HC5761 bash ./build-wsl.sh
```

需要使用其他工具链时，可以覆盖脚本默认值：

```sh
CROSS_COMPILE=/opt/toolchain/bin/mipsel-linux- \
HOSTCC=gcc \
CONFIG_FILE=HC5761 \
bash ./build-wsl.sh
```

不要给构建命令增加 `-j`。这个旧版顶层 Makefile 将 `clean` 和多个输出声明为
并列依赖，并行执行会产生竞态。也不要运行 `make rt2880_config`，旧 `mkconfig`
会错误处理仓库中已经存在的 `include/asm` 目录。

## 构建产物

| 文件 | 用途 |
| --- | --- |
| `uboot.bin` | 原始 U-Boot 二进制，编程器或按实际长度写入时使用 |
| `uboot_128k.bin` | 补齐到 128 KiB，供 Ai-BR100 的固定大小 Web 升级使用 |
| `uboot_192k.bin` | 补齐到 192 KiB，供 PSG1218/K2、HC5761、YK-L1 使用 |
| `uboot.img` | 带旧 MTK `mkimage` 头的镜像，当前 SPI ROM 配置通常不使用 |
| `u-boot` | 含符号的 ELF 文件，用于调试和反汇编 |
| `u-boot.map` / `System.map` | 链接映射和符号表 |

烧写前应检查 `uboot.bin` 小于对应的 128 KiB 或 192 KiB U-Boot 分区，并再次
核对设备的内存、Flash 容量和分区版本。写错布局可能覆盖环境、Factory、无线
校准或板级信息，建议先完整备份 Flash。

## 网络与 Web failsafe

默认网络参数为：

```text
U-Boot IP:   192.168.1.1
TFTP Server: 192.168.1.32
Netmask:     255.255.255.0
```

Web failsafe 会校验 U-Boot/Factory 镜像的固定大小以及固件分区上限。固件过大时
会显示专用错误页并停止升级，不会擦写 Flash。Flash 中已经保存的环境变量优先于
上述编译默认值；需要修改现有设备地址时，请同时检查 `ipaddr` 和 `serverip`。

首页还提供“Restore default environment”操作。确认后，U-Boot 会将编译默认值
写入持久化环境；成功页面显示后需要重启设备。该操作通过现有 `saveenv()` 路径
保留环境扇区中的其他内容，不会直接擦除整个扇区。

## 许可证

本项目沿用原 U-Boot 源码的 GNU GPL 许可，详情见 [`COPYING`](COPYING)。
