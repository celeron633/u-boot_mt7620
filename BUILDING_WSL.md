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

编译极路由 2/HC5761 时：

```sh
CONFIG_FILE=HC5761 bash ./build-wsl.sh
```

使用其他保存配置时：

```sh
CONFIG_FILE=my-board.config bash ./build-wsl.sh
```

一次编译全部机型（输出到 `dist/<型号>/`，每个机型同时给出 128 KiB 和
192 KiB 两种补齐尺寸）：

```sh
bash ./build-all.sh
```

GitHub Actions 的 `.github/workflows/build.yml` 调用的就是这个脚本，因此本地
跑出来的目录结构和 CI 产物完全一致。注意 `build-all.sh` 把镜像先收集到仓库
外的临时目录再拷回 `dist/`：顶层 Makefile 的 `clean` 会用
`find . -name '*.bin'` 递归删除整个仓库里的 `.bin`，直接写在仓库内会被下一个
机型的构建清掉。

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

`HC5761` 使用 16 MiB flash、128 MiB DDR2，U-Boot 输出同样补齐到 192 KiB。
分区布局按 OpenWrt 当前设备树配置，并保留 flash 尾部的 OEM、板级信息和备份区域：

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
`hw_panic`；执行 `saveenv` 会改写该区域。Web 和 Shell 固件升级会拒绝大于
`0xf70000` 的镜像，`erase linux` 也只擦除到 `0xfc0000`，不会覆盖尾部 OEM、
`bdinfo` 和 Backup。以太网 MAC 从
`bdinfo + 0x18a` 的 17 字节文本地址读取。

烧写前仍需核对实际硬件参数：PSG1218/K2 配置为 DDR2 64 MiB、8 MiB flash；
YK-L1 配置为 DDR2 128 MiB、32 MiB flash；HC5761 配置为 DDR2 128 MiB、
16 MiB flash。它们都是 MT7620、16-bit DRAM 总线、SPI NOR，链接地址
`0xBC000000`。参数不符时不要直接写入 flash。

## 用模拟器排查启动问题

`tools/mt7620emu.py` 是一个基于 Unicorn 的 MT7620 模拟器，用来判断一个镜像到底能
不能跑起来、卡在哪里，不用接串口也不用拆机。需要 Python 3 和 Unicorn：

```sh
pip install unicorn
```

跑一个镜像（`--symbols` 可选，有对应构建的 `System.map` 时能把地址翻成符号名）：

```sh
python3 tools/mt7620emu.py dist/HC5761/HC5761_uboot_192k.bin \
	--symbols System.map
```

镜像跑飞时用 `--step` 分块执行，这样即使 Unicorn 自己崩掉，之前刷出来的串口输出
和跳飞位置也已经打印出来了：

```sh
python3 tools/mt7620emu.py 可疑镜像.bin --step 500000
```

它模拟的东西：SPI flash 映射在物理 `0x1C000000`（Unicorn 会做 MIPS 的 KSEG 地址
转换，所以映射的是物理地址）、128 MiB DDR 并带真实的回绕别名（`get_ram_size()`
靠回绕探测容量）、Ralink 寄存器打桩、以及 UART Lite 控制台，所以 U-Boot 自己的
输出会直接打出来。

两个关键结论：串口输出停在哪一行，以及 `escaped` 这一行——`no` 表示始终在合法代
码里执行，`yes` 表示跳到了代码段外面（那就是不会启动的镜像）。

外设只是打桩，所以启动后期的一些行为是模拟器的产物而非真实现象（例如会打印
`Watchdog Reset Occurred`，也会在某个轮询循环里停住）。这个工具用来对比"好镜像
跑到哪 / 坏镜像死在哪"，不是周期精确的仿真。

## 为什么必须用验证过的工具链

只有本文顶部那套工具链（Debian 13 / GCC 14 / binutils 2.44）经过验证。

`cpu/ralink_soc/config.mk` 用 `-mabicalls` 把整棵树编成 PIC，`start.S` 的
`relocate_code` 把镜像从 `0xBC000000` 的 flash 窗口搬到内存再跳过去执行。MIPS 的
`jal` 是**区域内绝对跳转**，目标地址等于 `(PC & 0xF0000000) | (imm26 << 2)`，只有
在 flash 窗口里执行才算得对；搬到 `0x87FB0000` 之后高四位变了，同一条 `jal` 就会
跳到别处。所以跨函数调用必须走 GOT（`lw t9,off(gp)` + `jalr t9`），这也是
`relocate_code` 之后要在 `in_ram` 里重定位 GOT 的原因。

2026-09-26 用 Ubuntu 24.04 自带的 GCC 13 交叉工具链编出的 HC5761 镜像不是 PIC：

| | GCC 14（验证过） | GCC 13 |
| --- | ---: | ---: |
| 绝对 `jal 0x…` | 0 | 315 |
| PIC 序言 `addu gp,gp,t9` | 242 | 0 |
| 绝对 `lui gp,0xbc..` | 0 | 157 |
| `num_got_entries` | 305 | 192 |

它能打印版本横幅、认出 128 MB 内存、完成 relocate_code，然后在 `0x87FBEB04`
（链接地址 `0xBC00EB04`）执行 `jal 0xbc00ea90` 时跳到 `0x8C00EA90`，落进刚清零的
内存里一路执行 `nop`，板子就此变砖。用 `tools/mt7620emu.py` 可以复现这个过程。

所以 `.github/workflows/build.yml` 固定在 `debian:trixie` 容器里构建，并在编译前
断言宿主和交叉 GCC 主版本号都是 14，不符就让构建失败、不产出任何固件。

钉住工具链只能防住已知的那一种情况，所以 `build-wsl.sh` 在链接完成后还会直接检查
产物本身：ELF 标志必须同时含 `pic` 和 `cpic`，且 `.text` 里不能出现绝对 `jal`
（`jalr t9` 这种走 GOT 的间接调用不算）。任何工具链只要掉了 PIC 就会在这里失败，
不会走到产出固件那一步。
