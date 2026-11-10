# 🔬 关键实测发现（2026-11-10）

## 一、内置 WiFi 支持 monitor 模式（已验证）

运行中的 v1 内核即可切换 monitor 模式，**无需任何内核改动**：

```sh
ip link set wlan0 down
echo 4 > /sys/module/qca_cld3_kiwi_v2/parameters/con_mode
ip link set wlan0 up
```

内核日志确认：

```
kiwi_v2: __hdd_driver_mode_change: Driver mode successfully changed to 4
kiwi_v2: __hdd_mon_open: hdd_wlan_start_modules() successful !
```

`tcpdump -i wlan0` 显示 `link-type IEEE802_11_RADIO`（radiotap）。
**注意**：需要设置信道（需要 iw 工具，用户态解决）；帧注入支持取决于固件。

## 二、USB gadget 配置会破坏厂商模块链（已实测）

**结论：不要开启 `CONFIG_USB_CONFIGFS_F_RNDIS` / `CONFIG_USB_RAW_GADGET`。**

### 失败链条

```
启用内置 RNDIS/RAW_GADGET
  → 厂商 usb_f_gsi.ko 未加载
  → ipam.ko 找不到 ipa_ready_callback（该符号由 usb_f_gsi 导出）
  → qca_cld3_kiwi_v2.ko 加载失败
  → WiFi 完全不可用（无 wlan0）
  → 模块总数 434 → 420
```

### 对照实验

| 内核 | 模块数 | WiFi |
|---|---|---|
| v1（原配置） | 434 | ✅ 正常 |
| v1 + USB gadget 增强 | 420 | ❌ 不可用 |

## 三、ABI 禁区（实测/源码确认）

| 配置 | 后果 |
|---|---|
| `CONFIG_CFS_BANDWIDTH` / `CONFIG_CGROUP_PIDS` | 模块 CRC 不匹配 → 无限重启 |
| `CONFIG_NF_TABLES` / `NFT_*` | `struct net` 偏移变化 → 导出符号 CRC 变 |
| `CONFIG_SCHED_CORE`、`CRYPTO_USER`、`MPTCP`、`TLS_DEVICE`、`IP_VS` | 改核心结构体 |
| `CONFIG_FUNCTION_TRACER` / `DYNAMIC_FTRACE` | 改 `struct module` → `module_layout` 失效 |

## 四、当前可靠配置（v1 = 推荐）

```
CONFIG_SYSVIPC=y        CONFIG_POSIX_MQUEUE=y
CONFIG_IPC_NS=y         CONFIG_PID_NS=y
CONFIG_USER_NS=y        CONFIG_DEVTMPFS=y
CONFIG_TMPFS_POSIX_ACL=y CONFIG_TMPFS_XATTR=y
CONFIG_MACVLAN=y        CONFIG_IP6_NF_NAT=y
CONFIG_IP_SET=y         CONFIG_NETFILTER_XT_MATCH_ADDRTYPE=y
CONFIG_USB_CONFIGFS_F_HID=y
# CONFIG_MODULE_SIG_PROTECT is not set
```
