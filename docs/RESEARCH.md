# 📚 调研资料汇总（NX721J Droidspaces / NetHunter 内核）

> 本文档汇总了来自 Droidspaces 官方仓库、AOSP 文档、Qualcomm qcacld 源码、Kali 官方文档及社区项目的相关资料，以及本项目的实测记录。

---

## 1. Droidspaces 官方内核要求（GKI）

来源：[Droidspaces-OSS / Documentation / Kernel-Configuration.md](https://github.com/ravindu644/Droidspaces-OSS/blob/main/Documentation/Kernel-Configuration.md)

### 1.1 核心结论

> Google 的 GKI 保持固定内核 ABI，以便针对原厂内核构建的厂商模块继续加载。`CONFIG_SYSVIPC`、`CONFIG_IPC_NS`、`CONFIG_POSIX_MQUEUE` 会向核心结构体添加字段并移动 ABI。直接开启它们，厂商模块会拒绝加载，手机无限重启。**必须配合 kABI 补丁**（把字段移入 ABI 预留的填充区）。

### 1.2 GKI 推荐配置（来自官方）

```makefile
# IPC
CONFIG_SYSVIPC=y
CONFIG_POSIX_MQUEUE=y
# 命名空间
CONFIG_IPC_NS=y
CONFIG_PID_NS=y
# 硬件访问
CONFIG_DEVTMPFS=y
# 网络增强
CONFIG_NETFILTER_XT_MATCH_ADDRTYPE=y
# 可选推荐
CONFIG_USER_NS=y
CONFIG_IP6_NF_NAT=y
CONFIG_IP6_NF_TARGET_MASQUERADE=y
CONFIG_MACVLAN=y              # 官方注明：kABI 安全（5.15 上未改变任何导出符号）
CONFIG_IP_NF_TARGET_REJECT=y
CONFIG_IP6_NF_TARGET_REJECT=y
CONFIG_NETFILTER_XT_TARGET_LOG=y
CONFIG_NETFILTER_XT_MATCH_RECENT=y
CONFIG_IP_SET=y
CONFIG_IP_SET_HASH_IP=y
CONFIG_IP_SET_HASH_NET=y
CONFIG_NETFILTER_XT_SET=y
CONFIG_TMPFS_POSIX_ACL=y      # NixOS 支持
CONFIG_TMPFS_XATTR=y
```

### 1.3 绝对不能开启的两项（官方原文）

> `CONFIG_CFS_BANDWIDTH`（`--cpus` 需要）和 `CONFIG_CGROUP_PIDS`（`--pids-limit` 需要）会改变调度器和 cgroup 结构体的大小，而几乎所有导出的内核函数都会引用这些结构体。**在 5.15 GKI 树上，它们改变了大约四千个导出符号的校验和，没有任何填充技巧能覆盖。** 原厂厂商模块随后会拒绝加载，设备无限重启。
>
> 只有当你能够用同一份源码树和配置重新构建设备上的每一个内核模块，并把它们放进 `vendor_boot`、`vendor_dlkm` 和 `system_dlkm`，与新 `boot.img` 一起一次性刷入时，才开启它们。
>
> **不要通过禁用 CONFIG_MODVERSIONS 或强制加载模块来绕过检查；结构体确实变了。**

### 1.4 kABI 补丁变体

- 5.4 ~ 6.6：使用 `001.GKI-below-6.12-fix_sysvipc_kabi_*.patch`
- 官方建议先试 `6_7_8` 变体，失败再换其他填充槽变体
- 本项目实测：**3_4_5 变体在本机（6.1.68）上成功**；1_2_3 变体 Hunk 失败；6_7_8 变体可应用但实测卡死（后被证明是其他原因）

---

## 2. kABI / MODVERSIONS 机制

### 2.1 核心机制

```
内核编译时：
  每个导出符号 → genksyms 根据类型签名计算 CRC
  → 写入内核的 __kcrctab 表

厂商模块编译时：
  记录它引用的每个内核符号 + 当时的 CRC
  → 写入模块的 __versions 段

模块加载时：
  内核 check_version() 比对
  ├─ 一致 → 加载
  └─ 不一致 → "disagrees about version of symbol" → 拒绝加载
```

### 2.2 源码位置

- `kernel/module/version.c`：`check_version()`，bad_version 分支返回 0（拒绝）
- `kernel/module/main.c`：`verify_exported_symbols()`，受保护符号导出检查（`gki_is_module_protected_export`）
- `certs/system_keyring.c`：内置证书加载（`CONFIG_MODULE_SIG` 时包含模块签名证书）
- 相关文档：[AOSP ABI 监控](https://source.android.com/docs/core/architecture/kernel/abi-monitor)

### 2.3 实测结论（本项目）

| 实验 | 配置 | 结果 |
|---|---|---|
| 1 | 原厂内核 | ✅ 正常 |
| 2 | SYSVIPC + 命名空间 + 6_7_8 补丁 | ❌ 卡死（真正原因：MODULE_SIG_PROTECT） |
| 3 | 关闭 MODULE_SIG_PROTECT | ✅ **成功（434 模块加载）** |
| 4 | + 嵌入原厂公钥证书 | ✅ 成功 |
| 5 | CGROUP_PIDS（单开） | ❌ 无限重启 |
| 6 | CFS_BANDWIDTH + CGROUP_PIDS | ❌ 无限重启 |
| 7 | 两项 + CRC 校验容忍补丁 | ❌ 仍然无限重启 |
| 8 | 仅证书 | ✅ 成功 |

**关键推论**：实验 7 中 pstore 无记录（无内核 panic），说明失败可能是用户态 init 层面，而非驱动崩溃；但实验 5/6/7 已足够证明这两项在此机型上不可行。

---

## 3. Kali NetHunter 相关资料

### 3.1 Kali 官方说明（Wireless Cards）

来源：[Kali Docs - Wireless Cards and NetHunter](https://www.kali.org/docs/nethunter/wireless-cards/)

> External wireless cards are necessary because **Android devices do not support monitor mode on most devices apart from some Qualcomm chips used in modern Snapdragon SOC**. There are some devices that can support monitor mode with a modified firmware and kernel...

**结论**：部分高通芯片（现代骁龙）原生支持 monitor 模式 → 本机 WCN6750（kiwi_v2）属于此类。

### 3.2 QCACLD monitor 模式的正确开启方法

来源：[kimocoder/qualcomm_android_monitor_mode](https://github.com/kimocoder/qualcomm_android_monitor_mode)

```sh
# 开启 monitor 模式
ip link set wlan0 down
echo "4" > /sys/module/wlan/parameters/con_mode     # 本机对应 qca_cld3_kiwi_v2
ip link set wlan0 up

# 关闭 monitor 模式
ip link set wlan0 down
echo "0" > /sys/module/wlan/parameters/con_mode
ip link set wlan0 up
```

> 该项目说明：现代 QCACLD 驱动"someone over at CodeAurora actually flipped the switch on monitor mode"，所以无需内核补丁，直接设置 `con_mode=4` 即可。
>
> 帧注入：仅部分老设备（QCACLD-2，如 OnePlus 3T + LineageOS 17.1）支持帧注入；QCACLD-3 一般只有 monitor。

### 3.3 本机实测记录

```
✅ iw phy 显示支持 monitor 模式（Supported interface modes: ... * monitor ...）
✅ iw phy phy0 interface add mon0 type monitor 创建成功
✅ iw dev mon0 info → type monitor
❌ iw dev mon0 set channel 6 → Device or resource busy（wlan0 已连接占用）
❌ iw dev wlan0 set type monitor → Operation not supported
⚠️ 尝试 WiFi 关闭/驱动重载时设备重启（操作顺序错误，见 3.2 正确方法）
```

**正确做法（待设备连接后验证）**：
```sh
ip link set wlan0 down
echo 4 > /sys/module/qca_cld3_kiwi_v2/parameters/con_mode
ip link set wlan0 up
# 然后用 tcpdump -i wlan0 或 iw dev wlan0 info 验证
```

### 3.4 NetHunter 内核功能清单

| 功能 | 内核需求 | 本机状态 |
|---|---|---|
| HID 攻击（BadUSB） | `CONFIG_USB_CONFIGFS_F_HID` | ✅ 内置 |
| WiFi monitor | QCACLD `con_mode=4` | ⚠️ 有能力，待正确启用 |
| WiFi 注入 | QCACLD 帧注入支持 | ❓ 需实测 |
| 外接网卡 | ath9k_htc/rt2800usb/mt7601u 等驱动 | ❌ 未内置 |
| 蓝牙 HID | 标准蓝牙栈 | ✅ |

---

## 4. Android 内核模块相关文档

- [Android 模块化内核（Modular Kernels）](https://source.android.com/docs/core/architecture/kernel/modular-kernels)：内核模块必须与内核一起编译，否则内核拒绝加载
- [AOSP ABI 监控](https://source.android.com/docs/core/architecture/kernel/abi-monitor)：GKI 使用 `TRIM_UNUSED_KSYMS` + `UNUSED_KSYMS_WHITELIST` 构建 ABI 符号列表
- qcacld monitor 提交（CodeAurora）：[gitiles diff](https://android.googlesource.com/kernel/msm-modules/qcacld/+/59f861d11d0daf043e33b23f2e3a050453ca6cb0%5E%21/)（`hdd_set_mon_rx_cb`、`hdd_mon_set_ch_info` 等）

---

## 5. 本机关键技术事实

| 项目 | 值 |
|---|---|
| 设备 | 努比亚 Z60 Ultra（NX721J / PQ83A01） |
| SoC | 骁龙 8 Gen3（sm8650 / pineapple） |
| WiFi 芯片 | WCN6750 系列（驱动 kiwi_v2 / qca_cld3_kiwi_v2） |
| GPU | Adreno 750（Adreno750v2） |
| 内核 | 6.1.68-android14-11-g716498f88d0f-ab11695701 |
| 内核源码 | ACK android14-6.1 @ 716498f88d0f |
| 厂商模块 | 434 个（vendor_boot 297 + vendor_dlkm/system_dlkm 其余） |
| 模块签名保护 | MODULE_SIG_PROTECT（可用原厂公钥证书满足） |
| 原厂公钥证书 | CN="Build time autogenerated kernel key"，位于 stock kernel 偏移 ~32,508,672 |
| ramoops | ✅ 已启用（CONFIG_PSTORE_RAM=y，dtb 有节点） |

---

## 6. 参考资料汇总

| 资料 | 链接 |
|---|---|
| Droidspaces 官方仓库 | https://github.com/ravindu644/Droidspaces-OSS |
| Droidspaces 内核配置文档（中文） | https://github.com/ravindu644/Droidspaces-OSS/blob/main/Documentation/zh-CN/Kernel-Configuration.md |
| Droidspaces kABI 补丁 | https://github.com/ravindu644/Droidspaces-OSS/tree/main/Documentation/resources/kernel-patches/GKI |
| Kali NetHunter 无线网卡文档 | https://www.kali.org/docs/nethunter/wireless-cards/ |
| Qualcomm monitor mode 项目 | https://github.com/kimocoder/qualcomm_android_monitor_mode |
| qcacld monitor 提交 | https://android.googlesource.com/kernel/msm-modules/qcacld/ |
| AOSP ABI 监控 | https://source.android.com/docs/core/architecture/kernel/abi-monitor |
| Android 模块化内核 | https://source.android.com/docs/core/architecture/kernel/modular-kernels |
| Android Common Kernel | https://android.googlesource.com/kernel/common/ |
| AOSP clang 预编译包 | https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/ |
