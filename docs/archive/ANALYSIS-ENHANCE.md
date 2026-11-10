# 🧠 内核全面增强分析（对标 Android 16/17）

> 目标：在 **不破坏 GKI kABI** 的前提下，把 NX721J（6.1.68）内核的能力尽可能补满，并明确哪些 Android 16/17 特性无法回移。
>
> 详细分析见：[ANALYSIS-A16.md](ANALYSIS-A16.md)（Android 16/17 特性回移）与 [ANALYSIS-PERF.md](ANALYSIS-PERF.md)（性能/功能增强清单）。

## 一、ABI 判定的三重机制（决定哪些配置能开）

| 机制 | 源码位置 | 后果 |
|---|---|---|
| 1. genksyms CRC | `kernel/module/version.c` `check_version()` | 导出原型里引用的 struct 定义变化 → CRC 变 → 模块拒绝加载 |
| 2. 全局锚点 `module_layout()` | `version.c:94` | 参数含 `struct module/kernel_param/tracepoint`，任一布局变 → 434 模块全灭 |
| 3. inline 偏移 | 如 `net_generic()` 读 `net->gen` | 结构体字段偏移变化 → 运行时不匹配（ACK 用 `ext_net` 绕开，证明必须保 `struct net` 不变） |

## 二、可安全开启（v3.1 已启用）

### 容器 / 网络（P0）
```
CONFIG_BRIDGE_NETFILTER=y      CONFIG_NF_CONNTRACK_BRIDGE=y
CONFIG_VXLAN=y                 CONFIG_GENEVE=y
CONFIG_IPVLAN=y                CONFIG_NET_SCH_DEFAULT=y
CONFIG_DEFAULT_FQ_CODEL=y      CONFIG_TCP_CONG_ADVANCED=y
CONFIG_TCP_CONG_BBR=y          CONFIG_NET_SCH_CAKE=y
```

### 文件系统（P0）
```
CONFIG_SQUASHFS=y（+LZ4/LZO/XZ/ZSTD/FILE_DIRECT/DECOMP_MULTI_PERCPU）
CONFIG_ISO9660_FS=y（+JOLIET/ZISOFS）   CONFIG_UDF_FS=y
CONFIG_NTFS3_FS=y                        CONFIG_FANOTIFY=y
```

### 安全（ABI 安全）
```
CONFIG_SECURITY_LANDLOCK=y   CONFIG_SECURITY_YAMA=y
CONFIG_BPF_LSM=y             CONFIG_BPF_UNPRIV_DEFAULT_OFF=y
```

### Android 16 可配置项
```
CONFIG_DAMON_PADDR=y  CONFIG_DAMON_RECLAIM=y  CONFIG_DAMON_LRU_SORT=y
CONFIG_READ_ONLY_THP_FOR_FS=y
CONFIG_RCU_NOCB_CPU=y  CONFIG_RCU_NOCB_CPU_DEFAULT_ALL=y
```

## 三、❌ 绝对禁止（ABI 破坏，已实测或已确认）

| 配置 | 原因 |
|---|---|
| `CONFIG_CFS_BANDWIDTH` / `CONFIG_CGROUP_PIDS` | 改调度器/cgroup 结构体 → 模块 CRC 不匹配（已实测 bootloop） |
| `CONFIG_NF_TABLES` / `NFT_*` | `net_namespace.h:145` 在 `net->gen` 前插入 `netns_nftables` → `dev_get_by_name` 等 CRC + `net_generic()` 偏移双杀 |
| `CONFIG_SCHED_CORE` | 向 task_struct 加字段 |
| `CONFIG_CRYPTO_USER` | 在 struct net 加 `crypto_nlsk` |
| `CONFIG_FUNCTION_TRACER` / `DYNAMIC_FTRACE` | 改 `struct module` → `module_layout` 失效 |
| `CONFIG_IP_VS`、`NF_CONNTRACK_LABELS`、`TLS_DEVICE`、`MPTCP` | 改 core 结构体/锚点 |
| 16KB 页 / 48-bit VA | 页面大小/地址空间改变 → 全部模块不兼容 |
| `IP_ROUTE_MULTIPATH`、`IPV6_SUBTREES` | 改 net 结构偏移 |

## 四、Android 16/17 对比（GKI 6.12 / 6.18）

| 能力 | A16（6.12） | A17（6.18） | 本机（6.1.68） |
|---|---|---|---|
| 16KB 页面 | ✅ | ✅ | ❌ 无法回移（AOSP 16KB GKI 不覆盖 android14-6.1） |
| MTE | ✅ | ✅ | ✅ 已有 |
| MGLRU / DAMON | ✅ | ✅ | ✅ 已有 |
| Landlock | ✅ | ✅ | ✅ v3.1 |
| BPF LSM | ✅ | ✅ | ✅ v3.1 |
| BBR / CAKE | ✅ | ✅ | ✅ v3.1 |
| nftables | ✅ | ✅ | ❌ ABI 风险（排除） |
| 新 Binder / sched_ext / EEVDF / mseal / mTHP | ✅ | ✅ | ❌ 无法回移 |
| 8 大版本差距 | — | — | 6.1 → 6.12/6.18（11~17 个上游版本） |

## 五、灰度构建计划（避免一次全开无法定位）

| 阶段 | 内容 | 状态 |
|---|---|---|
| v3.1 | P0 网络/文件系统 + A16 可配置项 + 安全 | 🔄 构建中 |
| v3.2 | P1：USB（RAW_GADGET、RNDIS、USB_SERIAL、CH341/CP210X/PL2303/FTDI） | ⏳ 待 v3.1 验证 |
| v3.3 | P2：CRYPTO SM4/SM3 CE、NHPOLY1305_NEON、CHECKPOINT_RESTORE | ⏳ 待 v3.2 验证 |

## 六、运行时调优（无需改内核）

| 项 | 命令 | 说明 |
|---|---|---|
| BBR | `sysctl -w net.ipv4.tcp_congestion_control=bbr` | v3.1 内置 BBR 后可启用 |
| I/O 调度 | `echo bfq > /sys/block/sda/queue/scheduler` | 原厂已内置 BFQ |
| CAKE | `tc qdisc replace dev wlan0 root cake bandwidth 100mbit` | v3.1 内置 CAKE |
| zram 算法 | `echo zstd > /sys/block/zram0/comp_algorithm` | 厂商 zram.ko 支持 zstd |
| IOMMU lazy | cmdline `iommu.strict=0` | 先实测 |

## 七、验证清单

1. 构建日志中检查 `MISSING:` 提示（配置是否被 kconfig 丢弃）
2. 刷入后：`boot_completed=1`
3. `dmesg | grep -iE "disagrees about version|Unknown symbol|module_layout"` 应为 0
4. 434 个厂商模块全部加载
5. GPU / 相机 / WiFi / 显示正常
6. Droidspaces 要求检查通过
