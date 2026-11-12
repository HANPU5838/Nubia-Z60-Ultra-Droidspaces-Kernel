# 努比亚 Z60 Ultra · Droidspaces 内核（Android 16）

![release](https://img.shields.io/github/v/release/HANPU5838/Nubia-Z60-Ultra-Droidspaces-Kernel?style=flat&color=blue)
![build](https://img.shields.io/github/actions/workflow/status/HANPU5838/Nubia-Z60-Ultra-Droidspaces-Kernel/build.yml?style=flat&label=build)
![license](https://img.shields.io/badge/license-GPL--2.0-red?style=flat)
![device](https://img.shields.io/badge/device-NX721J-green?style=flat)
![soc](https://img.shields.io/badge/soc-sm8650-blue?style=flat)
![kernel](https://img.shields.io/badge/kernel-6.1.145-orange?style=flat)
![android](https://img.shields.io/badge/android-16-brightgreen?style=flat)

---

## 📥 下载

### 版本对照（两个版本内核不通用，请按系统选择）

| 版本 | 适用系统 | 内核基线 | 厂商模块 | 下载 |
|---|---|---|---|---|
| **v2.0.0（最新）** | 星云OS 2.0.8（**Android 16**） | 6.1.145 | 429 个 | [Release v2.0.0](https://github.com/HANPU5838/Nubia-Z60-Ultra-Droidspaces-Kernel/releases/tag/v2.0.0) |
| v1.0（旧版） | MyOS 14.5.6MR2（**Android 14**） | 6.1.68 | 434 个 | [Release v1.0](https://github.com/HANPU5838/Nubia-Z60-Ultra-Droidspaces-Kernel/releases/tag/v1.0) |

### 文件说明

| 文件 | 适用系统 | 说明 |
|---|---|---|
| `nx721j-a16-droidspaces-boot.img` | Android 16 | 完整 boot 镜像（推荐，直接刷 boot 分区） |
| `nx721j-a16-droidspaces-Image.img` | Android 16 | 纯内核镜像（给会用工具的人） |
| `nx721j-final-kernel-boot.img` | Android 14 | 完整 boot 镜像（旧版） |
| `nx721j-final-kernel-Image.img` | Android 14 | 纯内核镜像（旧版） |

> ⚠️ **A14 内核不能用于 Android 16，反之亦然**（内核版本与厂商模块必须匹配）。
> 刷入前请先看 [刷入方法](#-刷入方法) 并**备份原厂 boot 分区**。

## 📌 这是什么

给 **努比亚 Z60 Ultra（NX721J / 骁龙 8 Gen3 / sm8650）** 编译的 **GKI 内核**，替换手机 boot 分区里的内核。

**它首先是给"系统"用的内核**：保持与原厂完全一致的 kABI（内核符号版本），因此原厂系统里的 **429 个厂商闭源模块**（GPU、显示、摄像头、音频、WiFi、蓝牙、USB、充电、传感器等）全部照常加载，系统功能与原厂内核无异。

在保证系统完整可用的前提下，额外开启了 **Droidspaces**（Linux 容器方案）所需的全部内核特性，让手机可以跑完整 Linux 系统（如 Kali / Debian / Ubuntu 容器）。

同时，内核**内置支持 Kali NetHunter 的 HID 攻击（BadUSB）能力**，`monitor` 模式（WiFi 抓包）也已确认可用（见下文）。

> 一句话：**一个内核文件，系统功能不缩水，额外获得容器 + Kali NetHunter（HID / 监听）能力。**

## 📱 支持的系统

| 项目 | 说明 |
|---|---|
| **设备** | 努比亚 Z60 Ultra（NX721J / PQ83A01） |
| **SoC** | 高通骁龙 8 Gen3（sm8650 / 平台代号 pineapple） |
| **Android 版本** | **Android 16**（SDK 36） |
| **已验证系统** | **星云OS 2.0.8（NebulaAIOS2.0.8_NX721J）** |
| **内核版本** | **6.1.145**（GKI android14-6.1） |
| **版本字符串** | `6.1.145-android14-11-g11c274d0441f-ab14259673`（与原厂逐字符一致） |

> ⚠️ 由于保持原厂 kABI 与版本字符串，任何基于 **同一内核基线（6.1.145-ab14259673）** 的 NX721J 固件都能直接使用。换其他内核基线的固件需重新适配（见 [legacy/](legacy/) 中的 Android 14 配置）。

## ✅ 支持的硬件 / 系统功能

| 子系统 | 状态 | 说明 |
|---|---|---|
| 🖥️ GPU（Adreno 750） | ✅ | msm_kgsl 加载正常 |
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

> 星云OS 2.0.8 原厂内核**没有** SYSVIPC / IPC_NS / PID_NS / USER_NS / DEVTMPFS，Droidspaces 无法运行；本内核已补齐全部必需项。

## 🐉 Kali NetHunter 支持

| NetHunter 功能 | 支持 | 说明 |
|---|---|---|
| **Kali Linux 容器**（Droidspaces） | ✅ | 完整 Kali 环境，nmap / metasploit / sqlmap / hydra 等工具可用 |
| **HID 攻击**（BadUSB、键盘注入、Rucky） | ✅ | 内核内置 `CONFIG_USB_CONFIGFS_F_HID=y` |
| **WiFi 监听 / 抓包**（tcpdump / airodump-ng） | ✅ | 驱动支持 monitor 模式（实测 con_mode=4 成功，radiotap） |
| **WiFi 数据包注入**（aireplay-ng） | ❌ | 内置高通 QCA 驱动不支持注入 |
| **WiFi 破解**（aircrack-ng 握手包捕获） | ⚠️ | 可抓包，但需手动设置信道（见下） |
| **USB 网络共享**（RNDIS） | ⚠️ | 原厂内核未开启；开启会破坏 WiFi（见 FINDINGS） |

### 如何开启 WiFi monitor 模式（实测有效）

```sh
# root 下执行
ip link set wlan0 down
echo 4 > /sys/module/qca_cld3_kiwi_v2/parameters/con_mode
ip link set wlan0 up
# 内核日志会显示：Driver mode successfully changed to 4
tcpdump -i wlan0 -nn        # link-type IEEE802_11_RADIO (radiotap)
```

> 抓包需要设置信道（`iw dev wlan0 set channel 6`，需要 iw 工具，可在 Kali 容器内完成）；帧注入不支持（驱动限制）。

### 当前可用的 NetHunter 玩法

- ✅ 容器内运行完整 Kali 系统与工具
- ✅ 手机当 BadUSB（插电脑后模拟键盘输入命令）
- ✅ WiFi 监听抓包（monitor 模式）
- ❌ WiFi 数据包注入（需外接网卡 + 驱动）

## ❌ 不支持的功能及原因

### 1. CPU 带宽限制（`--cpus`）

- **需要**：`CONFIG_CFS_BANDWIDTH`
- **不开启原因**：该选项会改变调度器结构体（cfs_rq / cfs_bandwidth）的定义，导致内核导出符号的 genksyms CRC 变化。原厂 429 个预编译模块记录了旧的 CRC，校验不匹配 → 拒绝加载 → 系统无法启动（无限重启）。
- **已实测**：单独开启 → 无限重启；连同 CRC 校验一起破解 → 仍然无限重启。**不是校验问题，是结构体真的变了。**

### 2. 进程数限制（`--pids-limit`）

- **需要**：`CONFIG_CGROUP_PIDS`
- **不开启原因**：同上，改变 cgroup 结构体 → 模块 CRC 不匹配 → 无法启动。

### 3. WiFi 数据包注入

- **不支持原因**：内置高通 QCA 驱动不支持帧注入。
- **可解决**：需要外接 USB WiFi 网卡（AR9271 / RT3070 / MT7601 等）+ 对应驱动（当前内核未内置）。

### 4. RNDIS（USB 网络共享）

- **不开启原因**：实测开启 `CONFIG_USB_CONFIGFS_RNDIS` 后厂商 `usb_f_gsi.ko` 不加载 → `ipam` 缺符号 → WiFi 驱动失败、WiFi 完全不可用。详见 [docs/FINDINGS.md](docs/FINDINGS.md)。

## 🔧 构建配方

| 项目 | 值 |
|---|---|
| 源码 | Android Common Kernel `android14-6.1` @ `11c274d0441f287e4c37ec7a353cbc3cd169bff9`（与原厂同源） |
| 编译器 | AOSP clang `r487747c`（17.0.2，与原厂完全一致） |
| 基础配置 | 设备自身 `/proc/config.gz`（星云OS 2.0.8 / Android 16） |
| kABI 补丁 | 为 6.1.145 重制的 SYSVIPC 补丁（KABI 槽位 3/4/5） |
| 模块签名 | 关闭 `MODULE_SIG_PROTECT` + 嵌入原厂公钥证书（从 boot.img 偏移 33299712 提取，1357 字节） |
| 符号裁剪 | 关闭 `TRIM_UNUSED_KSYMS` |

构建方式：GitHub Actions（`.github/workflows/build.yml`）自动完成，产物为 `out/Image`。

## 📦 刷入方法

### 方式一：9008（EDL）刷入（推荐，无需 root）

```bash
adb reboot edl
python3 edl.py --memory=UFS --loader=prog_ufs_firehose_sm8650_ddr.elf \\
    w boot_a nx721j-a16-droidspaces-boot.img
```

### 方式二：root 后刷入

用内核刷写工具写入 `boot_a` / `boot_b` 分区。

> ⚠️ **刷入前务必备份原厂 boot 分区！** 出问题可随时回滚。

## 📊 已验证结果（星云OS 2.0.8 / Android 16）

```
✅ 开机正常（boot_completed=1）
✅ 429 个厂商模块全部加载
✅ 无 CRC 错误、无 Unknown symbol 错误
✅ WiFi（wlan0）正常，GPU / 相机 / 显示正常
✅ Droidspaces 必需项全部就绪（SYSVIPC / IPC_NS / PID_NS / USER_NS / DEVTMPFS）
✅ 版本字符串与原厂完全一致
✅ Magisk 31.1 root 保留
```

## 📚 相关资料

- [关键实测发现](docs/FINDINGS.md) — WiFi monitor、USB gadget 陷阱、ABI 禁区、A16 适配记录
- [调研资料汇总](docs/RESEARCH.md) — Droidspaces 官方要求、kABI 机制、NetHunter 资料
- [疑难解答与恢复指南](docs/TROUBLESHOOTING.md) — 刷机失败恢复、EDL 回滚、monitor 模式开启

## 👤 联系方式

| 平台 | 账号 | 名称 |
|---|---|---|
| 🌐 网站 | [hanpuhan.cn](https://hanpuhan.cn) | 清崖文存 |
| 📧 邮箱 | [640615397@qq.com](mailto:640615397@qq.com) | — |
| 📱 快手 | QQ640615397 | 涵清 |
| 🎵 抖音 | qingyawencun | 清崖文存 |
| 💬 QQ 群 | 959116552 | 清崖文存 |

## 🙏 致谢

- [Droidspaces-OSS](https://github.com/ravindu644/Droidspaces-OSS) — 容器方案与 kABI 补丁
- [Android Common Kernel](https://android.googlesource.com/kernel/common/) — 内核源码
- AOSP prebuilts — 原厂编译器

## 📄 许可证

[GPL-2.0](LICENSE)（与 Linux 内核一致）
