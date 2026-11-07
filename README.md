<div align="center">

# 🇨🇳 努比亚 Z60 Ultra Droidspaces 完美内核

**Nubia Z60 Ultra (NX721J) · Droidspaces Kernel**

[![Release](https://img.shields.io/github/v/release/HANPU5838/Nubia-Z60-Ultra-Droidspaces-Kernel?style=flat-square&color=blue&label=最新版本)](https://github.com/HANPU5838/Nubia-Z60-Ultra-Droidspaces-Kernel/releases)
[![Build](https://img.shields.io/github/actions/workflow/status/HANPU5838/Nubia-Z60-Ultra-Droidspaces-Kernel/build.yml?style=flat-square&label=云端构建)](https://github.com/HANPU5838/Nubia-Z60-Ultra-Droidspaces-Kernel/actions)
[![License](https://img.shields.io/badge/许可证-GPL--2.0-red?style=flat-square)](LICENSE)

[![设备](https://img.shields.io/badge/设备-努比亚%20Z60%20Ultra%20(NX721J)-green?style=flat-square)]()
[![平台](https://img.shields.io/badge/平台-骁龙%208%20Gen3%20(sm8650)-blue?style=flat-square)]()
[![内核](https://img.shields.io/badge/内核-6.1.68-orange?style=flat-square)]()
[![Android](https://img.shields.io/badge/Android-14-brightgreen?style=flat-square)]()
[![Droidspaces](https://img.shields.io/badge/Droidspaces-v7.1.0-purple?style=flat-square)](https://github.com/ravindu644/Droidspaces-OSS)

基于 Android Common Kernel 构建 · 保持原生 kABI · 全部硬件可用

</div>

---

## ✨ 项目简介

为 **努比亚 Z60 Ultra（NX721J）** 定制的 GKI 内核，在**不破坏原厂 kABI** 的前提下开启 [Droidspaces](https://github.com/ravindu644/Droidspaces-OSS) 所需的全部内核特性，同时保证 **434 个厂商预编译模块**（GPU、显示、摄像头、音频、WiFi、蓝牙等）正常加载。

> 目标：在不重建厂商模块的前提下，把能开的功能开满，做到"单文件内核，即刷即用"。

## 🚀 支持功能

| 功能 | 状态 | 说明 |
|---|---|---|
| 🐧 **Droidspaces 容器** | ✅ 完整支持 | SYSVIPC / IPC_NS / PID_NS / USER_NS / DEVTMPFS |
| 🖥️ **GPU（Adreno 750）** | ✅ 完美 | msm_kgsl 加载，OpenGL ES 3.2 正常渲染 |
| 📱 **显示（DSI/DP）** | ✅ 完美 | msm_drm 正常 |
| 📷 **摄像头** | ✅ 正常 | camera 模块加载 |
| 📶 **WiFi / 蓝牙** | ✅ 正常 | QCA 驱动加载 |
| 🔊 **音频** | ✅ 正常 | 全部厂商模块加载 |
| 🔌 **USB / 充电** | ✅ 正常 | |
| ⌨️ **HID 攻击（BadUSB）** | ✅ 内置支持 | `CONFIG_USB_CONFIGFS_F_HID=y` |
| 🌐 **网络增强** | ✅ 内置 | MACVLAN / IP6_NF_NAT / IP_SET / Netfilter 扩展 |
| 🧩 **厂商模块签名信任** | ✅ 已嵌入 | 原厂公钥证书内置于内核 |

### ❌ 无法启用的功能（架构限制）

| 功能 | 原因 |
|---|---|
| `--cpus`（CPU 带宽限制） | 需要 `CONFIG_CFS_BANDWIDTH`，会破坏厂商模块 CRC → 无限重启 |
| `--pids-limit`（进程数限制） | 需要 `CONFIG_CGROUP_PIDS`，同上 |

> **已通过 5 次对照实验验证**：这两个选项会改变调度器/cgroup 结构体布局，导致 434 个厂商模块因 CRC 校验失败而拒绝加载，系统无法启动。除非重建全部厂商模块（努比亚未开源），否则无法启用。

## 🔧 构建配方

| 项目 | 值 |
|---|---|
| **源码** | Android Common Kernel `android14-6.1` @ `716498f88d0f`（与设备原厂内核同源） |
| **编译器** | AOSP clang `r487747c`（17.0.2，与原厂完全一致） |
| **基础配置** | 设备自身 `/proc/config.gz`（MyOS 14.5.6MR2） |
| **kABI 补丁** | Droidspaces 官方 SYSVIPC 补丁（`3_4_5` 变体） |
| **版本字符串** | `6.1.68-android14-11-g716498f88d0f-ab11695701`（与原厂逐字符一致） |
| **模块保护** | 关闭 `MODULE_SIG_PROTECT` + 嵌入原厂公钥证书 |
| **符号裁剪** | 关闭 `TRIM_UNUSED_KSYMS` |

## 📦 产物与刷入

### 方式一：9008（EDL）刷入（推荐，无需 root）

```bash
# 1. 设备进入 9008
adb reboot edl

# 2. 刷入 boot 分区（注意替换为实际路径）
python3 edl.py --memory=UFS --loader=prog_ufs_firehose_sm8650_ddr.elf \
    w boot_a nx721j-final-kernel-boot.img
```

### 方式二：root 后刷入

用任意内核刷写工具/9008 写入 `boot_a`。

> ⚠️ **刷入前务必备份原厂 boot 分区！** 出问题可用备份回滚。

## 📊 已验证信息

```
✅ 开机正常（boot_completed=1）
✅ 434 个厂商模块全部加载
✅ GPU：Adreno 750 / OpenGL ES 3.2 正常
✅ Droidspaces 要求检查：全部必需项通过
✅ 无 CRC 错误、无符号错误
✅ 版本字符串与原厂完全一致
```

## 🙏 致谢

- [Droidspaces-OSS](https://github.com/ravindu644/Droidspaces-OSS) — 容器方案与 kABI 补丁
- [Android Common Kernel](https://android.googlesource.com/kernel/common/) — 内核源码
- AOSP prebuilts — 原厂编译器

## 📄 许可证

本项目的构建脚本与文档遵循 [GPL-2.0](LICENSE)（与内核一致）。
