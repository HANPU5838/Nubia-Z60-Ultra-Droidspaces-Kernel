# 🧠 内核全面增强分析（对标 Android 16/17）

> 目标：在 **不破坏 GKI kABI** 的前提下，把 NX721J（6.1.68）内核的能力、性能和功能尽可能补满，并明确哪些 Android 16/17 的特性无法回移。

## 一、当前内核已具备的能力（原厂默认）

| 类别 | 已启用 |
|---|---|
| 调度 | PREEMPT（完整抢占）、UCLAMP、ENERGY_MODEL、schedutil、SCHED_MC |
| 内存 | MGLRU、THP、DAMON、COMPACTION、MIGRATION、ZONE_DEVICE、PSI |
| 安全 | KASLR、CFI、Shadow Call Stack、MTE、BTI、PAN/EPAN、INIT_ON_ALLOC、HARDENED_USERCOPY、RANDOMIZE_KSTACK、FORTIFY、STACKPROTECTOR |
| 加密 | AES/SHA2/GHASH ARM64 CE、CHACHA20_NEON、LSE atomics、CNP |
| 存储 | F2FS（含压缩）、EROFS、EXFAT、FS_ENCRYPTION、DM_CRYPT、DM_VERITY |
| I/O | BFQ、KYBER、MQ-DEADLINE、FQ_CODEL、FQ |
| 网络 | WireGuard（内建）、NF_CONNTRACK/NAT、VETH、BRIDGE |
| 其他 | io_uring、binderfs、userfaultfd、USB gadget（HID/MassStorage/RNDIS部分） |

## 二、v2 已补（构建中）

LANDLOCK、YAMA、BPF_UNPRIV_DEFAULT_OFF、INIT_ON_FREE、BBR、CAKE、NF_TABLES、NTFS3、ZSWAP、ZRAM_WRITEBACK、MEMCG_SWAP、IP_SET_HASH_NET

## 三、v3 建议补充（ABI 安全，收益明确）

### 3.1 加密性能（直接提升文件读写/网络吞吐）

| 配置 | 作用 | 收益 | 风险 |
|---|---|---|---|
| `CONFIG_CRYPTO_CRC32_ARM64_CE=y` | ARMv8 CRC32 硬件指令 | 文件系统校验、网络校验大幅加速 | 极低 |
| `CONFIG_CRYPTO_AES_ARM64_BS=y` | 位切片 AES | 小包加密更快 | 极低 |
| `CONFIG_CRYPTO_SM4_ARM64_CE` | SM4 硬件加速 | 国内应用加密加速 | 低 |

### 3.2 文件系统/存储

| 配置 | 作用 | 收益 |
|---|---|---|
| `CONFIG_SQUASHFS=y` + LZ4/XZ/ZSTD | 只读压缩文件系统 | 容器镜像、只读挂载 |
| `CONFIG_ISO9660_FS=y` / `CONFIG_UDF_FS=y` | ISO/UDF | 挂载光盘镜像 |
| `CONFIG_9P_FS=y` | 9P 文件系统 | 虚拟机共享目录 |
| `CONFIG_CIFS=y` | SMB/CIFS | 访问网络共享 |
| `CONFIG_ZRAM_DEF_COMP_LZ4=y` | zram 默认 LZ4 | 内存压缩更快 |

### 3.3 容器/网络增强

| 配置 | 作用 |
|---|---|
| `CONFIG_BRIDGE_NETFILTER=y` | 桥接 + netfilter（Droidspaces 官方推荐） |
| `CONFIG_VXLAN=y` | VXLAN 隧道（Docker Swarm/K8s） |
| `CONFIG_IPVLAN=y` | IPVLAN（容器网络模式） |
| `CONFIG_NETFILTER_XT_MATCH_* 补充` | iptables 匹配扩展 |

### 3.4 USB / NetHunter

| 配置 | 作用 |
|---|---|
| `CONFIG_USB_CONFIGFS_RNDIS=y` | RNDIS（Windows USB 网络共享） |
| `CONFIG_USB_CONFIGFS_F_MIDI=y` | MIDI gadget（可选） |

### 3.5 绝对不要开启（ABI 破坏 / 不可回移）

| 配置 | 原因 |
|---|---|
| `CONFIG_CFS_BANDWIDTH` | 改调度器结构体 → 厂商模块 CRC 不匹配（已实测 bootloop） |
| `CONFIG_CGROUP_PIDS` | 同上（已实测） |
| `CONFIG_SCHED_CORE` | 向 task_struct 添加字段 → ABI 破坏 |
| 16KB 页面（`CONFIG_ARM64_16K_PAGES`） | 页面大小改变 → 所有厂商模块不兼容 |
| 内核 6.12/6.18 新子系统（新 Binder、新 BPF、新调度器） | 无法回移，ABI 不兼容 |
| `CONFIG_KASAN`、`CONFIG_DEBUG_*` 大量调试项 | 性能严重下降 |

## 四、Android 16 / 17 内核对比

| 项目 | Android 16（GKI 6.12） | Android 17（GKI 6.18） | 本机（6.1.68） |
|---|---|---|---|
| 16KB 页面支持 | ✅ | ✅ | ❌ 无法实现 |
| MTE 内存标记 | ✅ | ✅ | ✅ 已有 |
| Landlock | ✅ | ✅ | ✅ v2 补 |
| nftables | ✅ | ✅ | ✅ v2 补 |
| BBR | ✅ | ✅ | ✅ v2 补 |
| 新 Binder | ✅ | ✅ | ❌ 无法回移 |
| eBPF 新验证器 | ✅ | ✅ | ❌ 部分无法回移 |
| MGLRU | ✅ | ✅ | ✅ 已有 |
| DAMON | ✅ | ✅ | ✅ 已有 |
| 新调度器 | ✅ | ✅ | ❌ 无法回移 |

> **结论**：Android 16/17 的核心新特性大多依赖内核版本本身（6.12/6.18），无法在不破坏 ABI 的前提下回移到 6.1.68。能做的只有「配置级」功能补齐。

## 五、运行时性能调优（不需要改内核）

| 调优项 | 方法 | 收益 |
|---|---|---|
| I/O 调度器 | cmdline `elevator=bfq` 或 sysfs | 存储响应 |
| CPU governor | schedutil（已默认） | 能效平衡 |
| TCP 拥塞控制 | `sysctl net.ipv4.tcp_congestion_control=bbr` | 网络吞吐 |
| 网络队列 | `tc qdisc add dev wlan0 root cake` | 降低延迟 |
| zram 参数 | `/sys/block/zram0/*` | 内存压缩 |
| VM 参数 | `/proc/sys/vm/*`（swappiness 等） | 内存管理 |
| GPU 调频 | vendor 模块参数（不可改） | — |

## 六、验证方案

1. 构建 v3 → 刷入 → 开机验证（boot_completed）
2. 检查 434 个厂商模块是否全部加载
3. 检查 GPU / 显示 / 相机 / WiFi 正常
4. 跑一次 Droidspaces 要求检查
5. 对比 v1/v2/v3 的实际体验（开机速度、IO、网络）
