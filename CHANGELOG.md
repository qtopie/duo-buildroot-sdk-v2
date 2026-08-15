# Changelog

All notable changes to the custom Milk-V Duo S buildroot SDK (`duo-buildroot-sdk-v2`) will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).
Base upstream version: [milkv-duo/duo-buildroot-sdk-v2](https://github.com/milkv-duo/duo-buildroot-sdk-v2) tag `v2.0.1`.

---

## [custom-v2.0.1-ubuntu26] - 2026-08-15

### Added
- **Kernel Networking Enhancements**:
  - Enabled **eBPF** support (`CONFIG_BPF`, `CONFIG_BPF_SYSCALL`).
  - Enabled **Netfilter / iptables / nftables / NAT** stack (`CONFIG_NETFILTER`, `CONFIG_IP_NF_IPTABLES`, `CONFIG_NF_NAT`, etc.).
  - Enabled **TUN/TAP**, **VETH**, and **Bridge** virtual network devices.
  - Enabled **NET_CORE** throughput optimizations.
  - Enabled `BR2_PACKAGE_IPTABLES=y` in Buildroot defconfig.
- **Rootfs Overlay & Runtime Optimization**:
  - **WiFi MAC Persistence** (`device/generic/rootfs_overlay/duos/mnt/system/duo-init.sh`):
    - Auto-generates and persists a unique `88:00:33:77:XX:XX` MAC address to `/mnt/system/firmware/aic8800/rwnx_settings.ini` on first boot, preventing random MAC generation and DHCP IP drifting.
  - **TCP & Network Buffer Tuning** (`device/generic/rootfs_overlay/duos/etc/sysctl.d/99-network.conf` + `S94sysctl`):
    - Expands TCP socket buffers up to 4MB (`rmem_max` / `wmem_max = 4194304`).
    - Enables TCP Fast Open (`tcp_fastopen = 3`), TCP window scaling, timestamps, and SACK for high-latency proxy traffic.
  - **Bluetooth Low-Power Daemon**:
    - Automatically loads `aic8800_btlpm.ko` in `duo-init.sh`.
- **Modern Host Build Compatibility (Ubuntu 26.04 / GCC 14+ / C23)**:
  - **make_ext4fs dependency isolation**:
    - Bundled local `libpcre.so.3` in `build/tools/common/prebuild/` and configured `RUNPATH=$ORIGIN` on `make_ext4fs`, eliminating global `LD_LIBRARY_PATH` pollution.
  - **m4 upgrade**:
    - Upgraded `buildroot/package/m4` from 1.4.19 to 1.4.21 to fix build failures with modern glibc.
  - **D-Bus Glib C23 Patch**:
    - Added `0001-dbus-gvalue-c23-bool.patch` to resolve C23 `bool` keyword conflicts.
  - **cvi_mpi paths**:
    - Fixed sensor and audio build paths and pkgconfig files.
- **SDD & Harness Engineering Infrastructure**:
  - Added `.agents/` and `AGENTS.md` specification rules.
  - Added `specs/modules/build-system.spec.md` for reproducible build verification.
  - Added `harness/` environment and test runner scripts (`scripts/check.sh`, `scripts/check-harness.sh`, `scripts/check-spec-drift.sh`).
