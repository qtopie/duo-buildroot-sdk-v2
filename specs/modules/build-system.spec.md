# Spec: duo-buildroot-sdk-v2 Build System (Ubuntu 26.04)

## Status
- **状态:** Draft (待 Sign-off)
- **适用范围:** `build.sh milkv-duos-musl-riscv64-emmc` 全流程
- **分支:** `custom-v2.0.1-ubuntu26`

## Background
基于官方 v2.0.1 release tag，叠加自定义功能（eBPF/iptables/TUN/蓝牙）与 Ubuntu 26.04 兼容修复。
官方文档要求 Ubuntu 20.04/22.04，本机为 26.04，需要环境适配。

## Requirements

### R1: 构建环境
- [ ] R1.1 需要 cmake >= 3.5（本机用 `/home/qtopierw/opt-cmake/bin`，3.30.3）
- [ ] R1.2 打包阶段需要 Ubuntu 18.04 runtime 提供 `libpcre.so.3`（make_ext4fs 依赖）
- [ ] R1.3 构建用 `riscv64-linux-musl` 交叉工具链（host-tools/gcc 下）

### R2: 构建产物（eMMC）
- [ ] R2.1 产出 `out/milkv-duos-musl-riscv64-emmc-custom-<date>.zip`
- [ ] R2.2 `out/rom/fip.bin` 与官方 v1.1.4 (424960B) 行为一致，可被 ROM 识别并跳转第二阶段
- [ ] R2.3 固件启用 netfilter/iptables/nftables/eBPF/TUN/VETH/BRIDGE

### R3: 烧录验证
- [ ] R3.1 `usb_dl -s linux -c 181x -i <rom_dir>` 完整烧录成功
- [ ] R3.2 烧录后设备启动，`ping 192.168.42.1` 可达
- [ ] R3.3 SSH `root@192.168.42.1` (密码 milkv) 可登录

## Mapped Test (Harness)
| # | 断言 | 命令 |
|---|------|------|
| T1 | 构建脚本可运行 | `source build/envsetup_milkv.sh $DUO_BOARD` |
| T2 | 产物存在 | `ls out/*emmc-custom*.zip` |
| T3 | 烧录工具存在且可执行 | `test -x build/tools/common/usb_dl/Linux/usb_dl` |
| T4 | 内核开启 BPF | `grep CONFIG_BPF=y build/boards/cv181x/*emmc*/linux/*emmc_defconfig` |

## Out of Scope
- SD 卡固件（`milkv-duos-musl-riscv64-sd`）的构建验证
- Windows 端烧录
