# 努比亚 Z60 Ultra · Droidspaces 内核

![release](https://img.shields.io/github/v/release/HANPU5838/Nubia-Z60-Ultra-Droidspaces-Kernel?style=flat&color=blue)
![build](https://img.shields.io/github/actions/workflow/status/HANPU5838/Nubia-Z60-Ultra-Droidspaces-Kernel/build.yml?style=flat&label=build)
![license](https://img.shields.io/badge/license-GPL--2.0-red?style=flat)
![device](https://img.shields.io/badge/device-NX721J-green?style=flat)
![soc](https://img.shields.io/badge/soc-sm8650-blue?style=flat)
![kernel](https://img.shields.io/badge/kernel-6.1.68-orange?style=flat)
![android](https://img.shields.io/badge/android-14-brightgreen?style=flat)

---

## 📌 这是什么

给 **努比亚 Z60 Ultra（NX721J / 骁龙 8 Gen3 / sm8650）** 编译的 **GKI 内核**，替换手机 boot 分区里的内核。

**它首先是给"系统"用的内核**：保持与原厂完全一致的 kABI（内核符号版本），因此原厂系统里的 **434 个厂商闭源模块**（GPU、显示、摄像头、音频、WiFi、蓝牙、USB、充电、传感器等）全部照常加载，系统功能与原厂内核无异。

在保证系统完整可用的前提下，额外开启了 **Droidspaces**（Linux 容器方案）所需的全部内核特性，让手机可以跑完整 Linux 系统（如 Kali / Debian / Ubuntu 容器）。

> 一句话：**一个内核文件，系统功能不缩水，额外获得容器能力。**

## 📱 支持的系统

| 项目 | 说明 |
|---|---|
| **设备** | 努比亚 Z60 Ultra（NX721J / PQ83A01） |
| **SoC** | 高通骁龙 8 Gen3（sm8650 / 平台代号 pineapple） |
| **Android 版本** | Android 14 |
| **已验证系统** | MyOS 14.5.6MR2（NX721J 官方固件） |
| **内核版本** | 6.1.68（GKI android14-6.1） |
| **版本字符串** | `6.1.68-android14-11-g716498f88d0f-ab11695701`（与原厂逐字符一致） |

> ⚠️ 由于保持原厂 kABI 与版本字符串，理论上任何基于 **同一内核基线（6.1.68-ab11695701）** 的 NX721J 固件都能直接使用；换其他内核基线的固件需重新适配。

## ✅ 支持的硬件 / 系统功能

| 子系统 | 状态 | 说明 |
|---|---|---|
| 🖥️ GPU（Adreno 750） | ✅ | msm_kgsl 加载，OpenGL ES 3.2 实测正常 |
| 📱 显示（DSI / DP） | ✅ | msm_drm、DP 正常 |
| 📷 摄像头 | ✅ | camera 模块全部加载 |
| 🔊 音频 | ✅ | audio 相关模块正常 |
| 📶 WiFi（QCA） | ✅ | qca_cld3_kiwi_v2 正常 |
| 🔵 蓝牙 | ✅ | 正常 |
| 🔌 USB / OTG / 充电 | ✅ | 正常 |
| 🎯 触摸 / 传感器 | ✅ | zte_tpd 等正常 |
| 🔐 安全（TEE / SMMU） | ✅ | qcom_scm、SMMU 等正常 |

## 🐧 支持的软件（Droidspaces）

| 功能 | 状态 | 依赖配置 |
|---|---|---|
| 容器运行（Kali / Debian / Ubuntu） | ✅ | SYSVIPC、IPC_NS、PID_NS、USER_NS、DEVTMPFS |
| 网络（NAT / Bridge / Veth / MACVLAN） | ✅ | 已开启 |
| 内存限制 | ✅ | CONFIG_MEMCG |
| 沙箱（user namespace） | ✅ | CONFIG_USER_NS |
| HID 攻击（BadUSB） | ✅ | CONFIG_USB_CONFIGFS_F_HID=y |
| CPU 带宽限制（--cpus） | ❌ | 见下方原因 |
| 进程数限制（--pids-limit） | ❌ | 见下方原因 |

## ❌ 不支持的功能及原因

### 1. CPU 带宽限制（`--cpus`）

- **需要**：`CONFIG_CFS_BANDWIDTH`
- **不开启原因**：该选项会改变调度器结构体（cfs_rq / cfs_bandwidth）的定义，导致内核导出符号的 genksyms CRC 变化。原厂 434 个预编译模块记录了旧的 CRC，校验不匹配 → 拒绝加载 → 系统无法启动（无限重启）。
- **已实测**：单独开启 → 无限重启；连同 CRC 校验一起破解 → 仍然无限重启。**不是校验问题，是结构体真的变了。**

### 2. 进程数限制（`--pids-limit`）

- **需要**：`CONFIG_CGROUP_PIDS`
- **不开启原因**：同上，改变 cgroup 结构体 → 模块 CRC 不匹配 → 无法启动。

### 3. WiFi 抓包 / 监听 / 数据包注入

- **需要**：支持 monitor 模式的外置网卡 + 对应驱动
- **不支持原因**：内置高通 QCA WiFi 驱动不支持 monitor 模式；内核未内置 ath9k_htc / rt2800usb / mt7601u 等外置网卡驱动。
- **可解决**：需要重新编译带这些驱动（内置进内核）的版本，并且需要外接 USB 网卡。

### 4. 其他未验证场景

- 其他 NX721J 固件版本（如 NebulaOS）——未测试
- 其他机型（Z60 Ultra 领先版等不同 SoC 版本）——不适用

## 🔧 构建配方

| 项目 | 值 |
|---|---|
| 源码 | Android Common Kernel `android14-6.1` @ `716498f88d0f`（与原厂同源） |
| 编译器 | AOSP clang `r487747c`（17.0.2，与原厂完全一致） |
| 基础配置 | 设备自身 `/proc/config.gz`（MyOS 14.5.6MR2） |
| kABI 补丁 | Droidspaces 官方 SYSVIPC 补丁（`3_4_5` 变体） |
| 模块签名 | 关闭 `MODULE_SIG_PROTECT` + 嵌入原厂公钥证书 |
| 符号裁剪 | 关闭 `TRIM_UNUSED_KSYMS` |

## 📦 刷入方法

### 方式一：9008（EDL）刷入（推荐，无需 root）

```bash
adb reboot edl
python3 edl.py --memory=UFS --loader=prog_ufs_firehose_sm8650_ddr.elf \
    w boot_a nx721j-final-kernel-boot.img
```

### 方式二：root 后刷入

用内核刷写工具写入 `boot_a` 分区。

> ⚠️ **刷入前务必备份原厂 boot 分区！** 出问题可随时回滚。

## 📊 已验证结果

```
✅ 开机正常（boot_completed=1）
✅ 434 个厂商模块全部加载
✅ GPU：Adreno 750 / OpenGL ES 3.2 正常
✅ Droidspaces 要求检查：全部必需项通过
✅ 无 CRC 错误、无 Unknown symbol 错误
✅ 版本字符串与原厂完全一致
```

## 🙏 致谢

- [Droidspaces-OSS](https://github.com/ravindu644/Droidspaces-OSS) — 容器方案与 kABI 补丁
- [Android Common Kernel](https://android.googlesource.com/kernel/common/) — 内核源码
- AOSP prebuilts — 原厂编译器

## 📄 许可证

[GPL-2.0](LICENSE)（与 Linux 内核一致）
