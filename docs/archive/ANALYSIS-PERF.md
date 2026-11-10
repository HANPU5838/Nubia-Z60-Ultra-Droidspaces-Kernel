# NX721J 内核「ABI 安全」性能/功能增强分析

> 对象：NX721J（Z60 Ultra / sm8650 / Android 14 GKI 6.1.68，ACK `android14-6.1 @ 716498f88d0f`）
> 基线：`nx721j-stock.config`（原厂 /proc/config.gz）+ 已验证的 `config.fragment`（v1，434 厂商模块全部加载）
> 结论口径：**只推荐 =y（内置）选项**。原因见 §1.3——`=m` 编出来的 .ko 既不进 boot.img，又会与厂商 vendor_dlkm 里的同名模块冲突，实际不生效。
> 本文只读分析，未改任何其他文件；临时源码缓存 `~/.cache/kcfg-ack` 用完即删。

---

## 0. 一句话结论

原厂配置还有约 15 项「高收益 + ABI 安全」的空位可补，**最大头是容器/网络（BRIDGE_NETFILTER、VXLAN/IPVLAN、默认 fq_codel、BBR）、只读镜像文件系统（SQUASHFS/ISO9660/UDF）、USB（RAW_GADGET、RNDIS）**；
而任务清单里的 `CRC32_ARM64_CE` **在 6.1 树里根本不存在**，`ZRAM_DEF_COMP_LZ4`/`ZRAM_WRITEBACK` **因为 zram 是厂商模块而无效**，`NF_TABLES` 系则会动 `struct net` 布局 → **必须排除**。

---

## 1. ABI 判定方法（先看这节，后面所有结论都基于它）

### 1.1 三个独立的破坏面

| 机制 | 源码位置（ACK 6.1） | 触发条件 | 后果 |
|---|---|---|---|
| **① 符号 CRC（genksyms）** | 模块 `__versions` vs 内核 `__kcrctab`；`kernel/module/version.c` `check_version()` 的 `bad_version` | 导出符号的**类型签名**变化（genksyms 会把原型里出现的 struct 定义展开进 CRC） | 引用了该符号的厂商模块报 `disagrees about version of symbol X` 拒载 |
| **② 全局锚点 `module_layout`** | `kernel/module/version.c`：`void module_layout(struct module*, struct modversion_info*, struct kernel_param*, struct kernel_symbol*, struct tracepoint * const *)` + `EXPORT_SYMBOL(module_layout)` | `struct module`/`struct kernel_param`/`struct tracepoint` 布局变化 | **全部 434 个模块**报 `module_layout` 版本不符 → 无法开机 |
| **③ 结构体偏移（inline 访问器）** | 例：`include/net/net_namespace.h` 里 `net_generic()` 读 `net->gen`；`include/linux/skbuff.h`、`include/linux/netdevice.h` 大量 inline | 厂商模块编译时把字段偏移写死；内核里该结构体字段增删导致偏移平移 | 模块运行中读到垃圾指针 → 随机崩溃/黑屏，pstore 可能无 panic |

**ACK 自己就在防这件事**：`include/net/net_namespace.h` 里有一段注释，为把 `hooks_bridge[]` 加进 `struct netns_nf`（内嵌于 `struct net`）会导致 KMI 问题，于是改成外挂 `struct ext_net { struct net net; ... }`——**struct net 必须逐字节不变**。
实测锚点：`EXPORT_SYMBOL(dev_get_by_name)` 的原型是 `struct net_device *dev_get_by_name(struct net *net, ...)`（`net/core/dev.c:792/802`），说明 `struct net` 直接出现在导出符号签名里 → 动它 = 动一大批 CRC。

### 1.2 风险分级

| 级别 | 含义 | 典型 |
|---|---|---|
| **A（安全）** | 只新增文件/算法/文件系统/驱动，不碰任何 core struct | SQUASHFS、SM4 CE、VXLAN、USB_RAW_GADGET |
| **B（低风险）** | 只动内核内部结构（模块/内核自身用），不出现在导出原型 | DAMON、FANOTIFY、NTFS3 |
| **C（禁止）** | 在导出原型可达的结构里增删字段（`struct net`、`task_struct`、`sk_buff`、`struct module`、`struct proto`、`struct net_device`…） | NF_TABLES、TLS_DEVICE、CFS_BANDWIDTH |

### 1.3 `=m` 为什么一律不列

`/vendor_dlkm/lib/modules` 有 **305 个厂商 .ko**（含 `zram.ko`、`zsmalloc.ko`、`cfg80211.ko`、`mac80211.ko`）。我们编出的同名 `.ko` 不会进 boot.img，设备加载的仍是厂商版本；把它改成 `=y` 则会和厂商 `.ko` 重复注册。**所以：配置改动只有 `=y` 有意义**；`=m` 项若确实想要，只能「=y 内置」或「单独打包 .ko 手动 insmod」二选一。

---

## 2. 性能方向（ABI 安全）

### 2.1 网络队列 / 拥塞控制

| 配置名 | 作用 | 收益 | ABI 风险 | 优先级 |
|---|---|---|---|---|
| `CONFIG_NET_SCH_DEFAULT=y` + `CONFIG_DEFAULT_FQ_CODEL=y` | 把全系统默认 qdisc 从 pfifo_fast 改为 fq_codel（`NET_SCH_DEFAULT` 是 menuconfig，子项 `DEFAULT_FQ_CODEL` 依赖 `NET_SCH_FQ_CODEL`，原厂已 =y） | **所有网卡**（rmnet/WiFi/USB 网络共享/VPN）默认抗 bufferbloat，延迟抖动明显下降；不需要 tc 脚本 | **A**：只改默认值，无结构体变化 | **高** |
| `CONFIG_TCP_CONG_ADVANCED=y` + `CONFIG_TCP_CONG_BBR=y` | 暴露高级拥塞控制选项并内置 BBR（**父项 TCP_CONG_ADVANCED 原厂 =n，单独写 BBR 会被 kconfig 丢弃**） | 弱信号/丢包链路上吞吐显著提升（BBR 不把丢包当拥塞）；运行时 `sysctl net.ipv4.tcp_congestion_control=bbr` 切换 | **A**：只注册新的 `tcp_congestion_ops` 实例，struct 不变 | **中**（建议默认仍留 cubic，只提供选项） |
| `CONFIG_NET_SCH_CAKE=y`（v2 已加） | CAKE 智能队列 | `tc qdisc add ... cake` 手动用于热点/USB 共享，延迟最低 | **A** | 中（保持，无需改） |
| `CONFIG_NET_SCH_FQ=y` / `FQ_CODEL=y` | 原厂已开启 | BBR 的 pacing 依赖 fq | — | 已满足 |
| `CONFIG_NETFILTER_XT_TARGET_CHECKSUM=y` | 修正 NAT/转发路径校验和 | 热点/NAT 下个别驱动的坏校验和包可通 | **A**（新模块代码） | 低 |

> `fq_codel` 与 `BBR` 组合是移动网络最稳的「低延迟 + 高吞吐」方案；**不建议**把 CAKE 设为默认（CPU 开销比 fq_codel 高，WiFi 自身队列会重复整形）。

### 2.2 I/O 调度

| 项 | 现状 | 说明 / 建议 | 风险 | 优先级 |
|---|---|---|---|---|
| `MQ_IOSCHED_DEADLINE=y / KYBER=y / IOSCHED_BFQ=y / BFQ_GROUP_IOSCHED=y` | 原厂已全部内置 | 无 Kconfig 可加；**默认调度器不是 Kconfig 项** | — | — |
| 默认改用 BFQ | — | 用内核 cmdline `elevator=bfq`（重新打包 boot.img）或 init 脚本写 `/sys/block/*/queue/scheduler`；UFS 上 BFQ 提升交互/随机写响应，代价是吞吐略降 | 运行时，**零 ABI 风险** | 中 |
| `CONFIG_HZ` 改动 | `HZ=250` | **不要改**（jiffies 常量被厂商模块 inline 使用；收益也很小） | 禁止 | — |

### 2.3 加密加速（重点更正）

| 配置名 | 是否存在 | 作用 / 收益 | ABI 风险 | 优先级 |
|---|---|---|---|---|
| `CONFIG_CRYPTO_CRC32_ARM64_CE` | **❌ 6.1 树中不存在**（`arch/arm64/crypto/Kconfig` 294 行全文无 CRC32；`lib/Kconfig` 的 CRC32 只有 slice-by-8 实现） | — 写了也是空操作 | — | **排除** |
| `CONFIG_CRYPTO_SM4_ARM64_CE=y` + `_CE_BLK=y` + `CRYPTO_SM4=y`；`CONFIG_CRYPTO_SM3_ARM64_CE=y` + `CRYPTO_SM3=y` | ✅ 存在 | SM4/SM3 国密算法走 ARMv8.2 加密扩展（sm8650 支持），可用于 IPsec(ESP)/dm-crypt/LUKS 的国密模式 | **A**：只注册算法 | 中（国内合规/功能向） |
| `CONFIG_CRYPTO_NHPOLY1305_NEON=y` | ✅ 存在（generic `CRYPTO_NHPOLY1305=y`，NEON 版未开；`POLY1305_NEON` 已 =y） | Adiantum（dm-crypt/fscrypt 的 XChaCha+Poly1305 组合）提速数倍 | **A** | 低（设备默认用 AES-XTS，只有手动 Adiantum 才用得上） |
| `CONFIG_CRYPTO_AES_ARM64_CE_CCM=y` | ✅ 存在 | AES-CCM（IPsec/Matter/部分 VPN）硬件加速；CE 已有 BLK/XTS/ECB/CBC | **A** | 低 |
| `CONFIG_CRYPTO_AES_ARM64_BS=y` | ✅ 存在，但 **收益≈0**：原厂 `CRYPTO_AES_ARM64_CE_BLK=y` 已经用硬件 AES 指令，bitslice 是软件实现（更慢） | 不推荐 | A | **排除**（无收益） |
| `CONFIG_CRYPTO_LZ4HC=y` | ✅ 存在（原厂未开；`LZ4HC_COMPRESS` 已是库） | 只对 zswap 有意义；zram 是厂商模块用不上 → 实际价值低 | A | 低 |
| `CONFIG_CRYPTO_USER=y`（AF_ALG） | ✅ 存在，但 **禁止** | 会在 `struct net` 里加 `struct sock *crypto_nlsk`（net_namespace.h:182） | **C** | **排除** |

### 2.4 文件系统/存储性能

| 配置名 | 作用 | 收益 | ABI 风险 | 优先级 |
|---|---|---|---|---|
| `CONFIG_EROFS_FS_PCPU_KTHREAD=y` + `_HIPRI=y` | **原厂已 =y**（无需改动） | 压缩 EROFS 系统分区多核并行解压 | — | 无 |
| `CONFIG_EROFS_FS_ZIP_LZMA=y` | 挂载 microLZMA 压缩的 EROFS 镜像（`select XZ_DEC, XZ_DEC_MICROLZMA`） | 功能向：部分第三方 ROM/镜像用 LZMA | **A** | 低 |
| `CONFIG_DAMON_PADDR=y` + `CONFIG_DAMON_RECLAIM=y` / `CONFIG_DAMON_LRU_SORT=y` | DAMON 主动回收/LRU 排序（原厂 `DAMON=y, DAMON_VADDR=y, DAMON_SYSFS=y`，但 `DAMON_PADDR=n`，所以子项不可见） | 轻内存压力下提前回收冷页，减少 lmkd 杀后台 | **B**（DAMON 内部结构不出现在导出原型） | 低-中（需 cmdline 参数，收益依赖调参） |
| `CONFIG_ZRAM_WRITEBACK=y` / `ZRAM_DEF_COMP_LZ4/ZSTD=y` / `ZSWAP=y` | **无效** | zram/zsmalloc 是厂商 `.ko`（vendor_dlkm 实测存在），这些是 zram 模块的编译期选项，改内核配置不影响厂商 .ko；`ZSWAP` 又 `select ZPOOL` 但本树 `ZBUD=Z3FOLD=n、ZSMALLOC=m` → 没有可用 zpool，等于白开 | — | **排除**（见 §5 运行时替代） |

### 2.5 IOMMU / DM

| 配置名 | 作用 | 收益 | ABI 风险 | 优先级 |
|---|---|---|---|---|
| `CONFIG_IOMMU_DEFAULT_DMA_LAZY=y` | DMA 映射改为 lazy（`drivers/iommu/Kconfig` 存在此符号，原厂未开=strict） | 减少 map/unmap 开销；但 **厂商 GPU/显示驱动的 DMA 生命周期假设未必安全** | A（配置层面），但**行为风险中** | 低：先用 cmdline `iommu.strict=0` 实测再考虑入配置；`IOMMU_DEFAULT_PASSTHROUGH` 绝对不要开 |
| `CONFIG_DM_CRYPT=y` / `DM_VERITY=y` / `DM_SNAPSHOT=y` | **原厂已开** | LUKS 容器、dm-verity 校验、快照都可用 | — | 无需 |
| `CONFIG_DM_THIN_PROVISIONING` / `DM_MIRROR` / `DM_RAID` / `DM_CACHE` | LVM thin/镜像/RAID/缓存 | 只对「手机内跑 LVM」有用，场景极少；DM 内部结构 ABI 安全 | B | 低（可不加） |
| `CONFIG_DM_VERITY_VERIFY_ROOTHASH_SIG` | verity 根哈希签名校验 | 需要 kernel keyring 里放公钥，Android 不用 | B | 排除（无用） |

---

## 3. 功能方向（ABI 安全）

### 3.1 文件系统 / 只读镜像

| 配置名 | 作用 | 收益 | ABI 风险 | 优先级 |
|---|---|---|---|---|
| `CONFIG_SQUASHFS=y` + `SQUASHFS_FILE_DIRECT=y` + `SQUASHFS_DECOMP_MULTI_PERCPU=y` + `SQUASHFS_XATTR=y` + `SQUASHFS_ZLIB/LZ4/LZO/XZ/ZSTD=y` | 只读压缩文件系统 + 全部解压器 | 挂载发行版 squashfs 根/镜像（容器、Live 系统、只读数据盘）；解压库 `ZLIB_INFLATE/LZO/LZ4_DECOMPRESS/XZ_DEC/ZSTD_DECOMPRESS` 原厂全 =y，不额外引依赖 | **A**（新文件系统） | **高** |
| `CONFIG_ISO9660_FS=y` + `JOLIET=y` + `ZISOFS=y`；`CONFIG_UDF_FS=y` | 挂 ISO9660/UDF（UDF 自动 `select CRC_ITU_T/NLS`） | 挂 Windows/Linux 安装 ISO、DVD 镜像，写 UDF U 盘 | **A** | 中 |
| `CONFIG_NTFS3_FS=y`（v2 已加） | NTFS 读写（`select NLS`） | 外接 NTFS 硬盘/U 盘读写（原厂只有 EXFAT/FAT） | **A** | 中（保持） |
| `CONFIG_FANOTIFY=y` + `CONFIG_FANOTIFY_ACCESS_PERMISSIONS=y` | 全文件系统级通知/访问许可（`select FSNOTIFY, EXPORTFS`，二者原厂已 =y） | 备份工具（rsync）、实时病毒扫描、EDR 类工具必备；inotify 不够用 | **B**（`struct fsnotify_mark` 内部结构） | 中 |
| `CONFIG_CIFS=y` | SMB2/3 客户端 | 容器/Termux 直接 `mount -t cifs` 挂 NAS；自动 select 一堆 CRYPTO（原厂多数已 y）、DNS_RESOLVER | **A**（fs.h 无该开关的条件字段） | 中（体积 +~1MB） |
| `CONFIG_NET_9P=y` + `CONFIG_NET_9P_FD=y` + `CONFIG_9P_FS=y` | 9P2000 over TCP/Unix socket | 与 QEMU/VM 宿主共享目录，Droidspaces/KVM 玩法的常用通道 | **A** | 中 |
| `CONFIG_NFS_FS=y` + `NFS_V3/4` | NFS 客户端（`depends on INET && FILE_LOCKING && MULTIUSER`，均满足；select LOCKD/SUNRPC） | 挂 NAS/NFS 共享 | **A** | 低-中（体积较大） |

### 3.2 容器网络（重点）

| 配置名 | 作用 | 收益 | ABI 风险 | 优先级 |
|---|---|---|---|---|
| `CONFIG_BRIDGE_NETFILTER=y` | iptables/nft 能看到桥接的 IPv4/ARP 流量（`select NETFILTER_FAMILY_BRIDGE, SKB_EXTENSIONS`） | **Docker/VM 网桥过滤的硬需求**；热点桥接/容器桥接的 NAT 与防火墙规则才能生效 | **A（本机型特殊结论）**：`NETFILTER_FAMILY_BRIDGE=y` 与 `SKB_EXTENSIONS=y` **原厂已经开启**，且 ACK 已把 bridge hooks 挪进 `struct ext_net` 保住 `struct net` → 本项不改变任何布局 | **高** |
| `CONFIG_NF_CONNTRACK_BRIDGE=y` | 桥上的连接跟踪（`depends on NF_CONNTRACK=y`） | 桥接流量的 stateful 过滤（Docker 场景） | **A**（hook 注册，不动 netns_ct 字段；注意 `NF_CONNTRACK_LABELS` 才动 struct net） | 中 |
| `CONFIG_VXLAN=y` | VXLAN 隧道（`select NET_UDP_TUNNEL, GRO_CELLS`，二者原厂已 =y） | K8s/Calico/Flannel、Docker overlay 网络 | **A** | 中 |
| `CONFIG_GENEVE=y` | GENEVE 隧道（同上） | 同上（较新 CNI） | **A** | 低-中 |
| `CONFIG_IPVLAN=y` | IPVLAN（L2/L3） | 容器直接拿同网段 IP（macvlan 的替代，支持与宿主通信） | **A** | 中 |
| `CONFIG_MACVLAN=y`（v1 已加） | MACVLAN | 容器独立 MAC | A（已实测通过） | 已满足 |
| `CONFIG_BRIDGE_VLAN_FILTERING=y` | 桥的 VLAN 过滤 | 多 VLAN 容器/虚拟网络 | **A**（VLAN 结构在 bridge 内部头） | 低 |
| `CONFIG_NETFILTER_XT_TARGET_TEE=y` | 包复制 | 抓包/IDS（配合容器） | **A** | 低 |
| `CONFIG_IP_SET` 系（v1 已加） | ipset | fail2ban/大规则集 | A（已实测） | 已满足 |

### 3.3 USB gadget / 串口

| 配置名 | 作用 | 收益 | ABI 风险 | 优先级 |
|---|---|---|---|---|
| `CONFIG_USB_RAW_GADGET=y` | 用户态完全控制 USB gadget（`raw_gadget`） | **USB 研究/NetHunter 高级玩法**（USBProxy、模拟任意设备、fuzzing）；比 configfs-F_HID 灵活得多 | **A**（新 driver） | **高** |
| `CONFIG_USB_CONFIGFS_RNDIS=y` | RNDIS gadget 功能 | Windows 免驱 USB 网络共享（README 声称支持，实际**原厂该项 =n**，只有 NCM/ECM/EEM） | **A** | **高**（补齐宣称能力） |
| `CONFIG_USB_SERIAL=y`（原厂 =m，厂商也没发 usbserial.ko）+ `USB_SERIAL_CH341/CP210X/PL2303=y`、`USB_FTDI_SIO=y` | USB-TTL/串口芯片内置 | 手机直连路由器/单片机/工控设备刷机调试（OTG） | **A**（tty/usb-serial 内部结构） | 中 |
| `CONFIG_USB_CONFIGFS_F_PRINTER=y` / `F_MIDI` | — | `F_MIDI/UAC2/HID` 原厂已 =y；printer 场景少 | A | 低 |
| 外接 WiFi 网卡（ath9k_htc / mt7601u / rtl8xxxu / rt2800usb） | NetHunter 抓包/注入的最后一块拼图 | **本次不可行**：`cfg80211.ko`、`mac80211.ko` 是**厂商 vendor_dlkm 模块**；内置的网卡驱动 =y 无法链接模块符号，而把 cfg80211/mac80211 也 =y 会与厂商 .ko 重复注册 → 破坏 WiFi。需要「替换 vendor_dlkm 模块集」的大工程 | **C（工程风险）** | 排除（记为后续独立课题） |

### 3.4 BPF / 追踪 / 其它内核能力

| 配置名 | 作用 | 收益 | ABI 风险 | 优先级 |
|---|---|---|---|---|
| `CONFIG_BPF_LSM=y` | BPF LSM 钩子 | 无内核模块即可做安全策略/观测（`CONFIG_LSM` 原厂串里已含 `bpf`，开了即生效） | **B**（bpf_prog/aux 内部） | 中 |
| `CONFIG_CHECKPOINT_RESTORE=y`（+ 自动 `select PROC_CHILDREN`，`KCMP` 原厂已 =y） | CRIU 所需的 syscall/sysctl（`ns_last_pid` 等） | 容器内进程热迁移/快照（Droidspaces 进阶） | **A**（include/ 下无该开关的条件字段） | 低-中 |
| `CONFIG_SYN_COOKIES=y` | SYN cookie（`net.ipv4.tcp_syncookies`） | 抗 SYN flood；只加函数指针到内部 `tcp_request_sock_ops` | **A/B**（该结构不在导出原型） | 低 |
| `CONFIG_FUNCTION_TRACER` / `DYNAMIC_FTRACE` / 各类 tracer | ftrace | 内核调试/性能剖析 | **C：禁止**——`CONFIG_FTRACE_MCOUNT_RECORD` 会给 `struct module` 加 `ftrace_callsites` 字段（module.h:498）→ `module_layout` CRC 变 → **434 模块全灭** | **排除** |
| `KPROBES/BPF/JIT/DEBUG_INFO_BTF/io_uring/USERFAULTFD/BINFMT_MISC` | — | 原厂已开（BPF_PRELOAD 未开但无实用价值） | — | 无需 |
| `CONFIG_TLS=y`（kTLS，不含 TLS_DEVICE） | 内核 TLS | 用户态 TLS 记录层交给内核（少数 VPN/代理可受益） | **A**（核心 TLS 不新增 sk_buff/sock 字段；`TLS_DEVICE` 才危险） | 低 |
| `CONFIG_SECURITY_PATH=y` | 路径型 LSM 钩子 | AppArmor 类方案的依赖；SELinux/landlock 不需要 | **A**（LSM hook 表） | 低 |

---

## 4. ❌ 绝对不要开（附机制）

| 配置 | 机制（为什么死） | 后果 |
|---|---|---|
| `CFS_BANDWIDTH` / `CGROUP_PIDS` | 已实测：单开、双开、连 CRC 校验容错补丁都试过 | **无限重启**（本项目 v1 阶段实证，pstore 无 panic → 非纯 CRC 问题，但同样不可用） |
| 其它新 cgroup 控制器（`CGROUP_DEVICE`/`RDMA`/`MISC`/`PERF`） | 与上同源的 cgroup/调度器面；动 `cgroup_subsys`/调度结构 | 未测，按红线处理 |
| `SCHED_CORE` | `struct task_struct` 条件字段（sched.h:805）、`cgroup_base_stat` | 导出原型可达 → CRC/偏移双杀 |
| `SCHED_AUTOGROUP` / `SCHED_CLUSTER` / `SCHEDSTATS` / `TASK_XACCT` / `TASK_DELAY_ACCT` | `task_struct`/`sched_entity`/内部调度结构条件字段 | 同类风险 |
| `ARM64_16K_PAGES` / `ARM64_64K_PAGES` / `ARM64_VA_BITS_48` | 页大小/虚拟地址位宽是编译期全局契约（厂商模块按 4K+39bit 编译） | 全部模块不可用 |
| `CONFIG_HZ` 改动、`PREEMPT` 模式改动 | jiffies/抢占模型常量被 inline 进模块 | 时序错乱/崩溃 |
| **`NF_TABLES` + `NF_TABLES_INET/NETDEV` + `NFT_*`** | net_namespace.h:145 在 `struct net` 中**插入** `struct netns_nftables nft`（位于 `net->gen` 之前）→ ①`dev_get_by_name` 等导出符号 CRC 变；②`net_generic()` 的 `net->gen` 偏移平移，厂商模块 inline 失效 | 高风险；**v2 片段里的 nftables 项建议删除** |
| `CRYPTO_USER`（AF_ALG） | net_namespace.h:182 加 `struct sock *crypto_nlsk` 到 `struct net` | 同上 |
| `IP_VS` | net_namespace.h:167 加 `struct netns_ipvs *ipvs` 到 `struct net` | 同上（且手机无场景） |
| `NF_CONNTRACK_LABELS` | `struct netns_ct.labels_used`（netns/conntrack.h，内嵌于 struct net） | 同上 |
| `IP_ROUTE_MULTIPATH` / `IP_MROUTE` / `IP_ROUTE_CLASSID` / `IPV6_SUBTREES` / `IPV6_MROUTE` | `struct netns_ipv4/ipv6` 条件字段（内嵌于 struct net） | 同上 |
| `TLS_DEVICE` | netdevice.h:2144 给 `struct net_device` 加 `tlsdev_ops`；skbuff.h:994/1588 改 sk_buff bitfield | 双杀，禁止（`TLS` 本身可开） |
| `MPTCP` | sock.h:1325/1418 给 `struct proto` 加字段；skbuff.h 加 mptcp 字段 | 禁止 |
| `MACSEC` / `GARP` / `MRP` / `NET_DROP_MONITOR` / `CGROUP_NET_PRIO` 变更 | 均在 `struct net_device` 内有条件字段（原厂 `CGROUP_NET_PRIO=y` 已含，勿动） | 禁止新增 |
| `MODULE_SIG_FORCE`、`TRIM_UNUSED_KSYMS=y`、`MODVERSIONS=n`、改 `LOCALVERSION`/版本串、关 `MODULE_SIG_PROTECT` 后开 `LOCKDOWN` | 直接决定模块能否加载/符号是否被裁掉（原厂 `TRIM_UNUSED_KSYMS=y` + abi whitelist，本项目必须显式关闭裁剪） | 434 模块拒载 |
| `KASAN`/`KCSAN`/`DEBUG_*` 大批调试项、`LIVEPATCH`、`KEXEC` | `struct module`/`module_layout` 或性能 | 全灭或性能崩 |
| `TRANSPARENT_HUGEPAGE_ALWAYS` / `KSM` / `READ_ONLY_THP_FOR_FS` / `PER_VMA_LOCK` | `struct mm_struct`/`address_space`/`vm_area_struct` 条件字段 | 禁止 |
| 6.12/6.18 新基线（EEVDF、sched_ext、PREEMPT_RT、mTHP、mseal、Rust Binder） | 换内核代际，不是改配置 | 不可回移 |

---

## 5. 对现有 v1/v2 片段的核对（重要修正）

| 片段项 | 判定 | 建议 |
|---|---|---|
| `CONFIG_MEMCG_SWAP=y` | **6.1 无此符号**（`mm/Kconfig`/`init/Kconfig` 均无） | 删除（无害但无效） |
| `CONFIG_ZRAM_WRITEBACK=y`、`ZRAM_DEF_COMP_*`、`ZSWAP=y` | zram/zsmalloc 是厂商 `.ko` → 编译期选项不影响；ZSWAP 还缺 zpool 后端（`ZBUD/Z3FOLD=n`、`ZSMALLOC=m`） | 删除 (ZSWAP)；zram 参数用运行时办法 |
| `NF_TABLES / NF_TABLES_INET / NETDEV / NFT_NAT / NFT_MASQ` | **高风险（struct net）**，见 §4 | 删除；容器防火墙继续用 iptables/xtables + ipset（原厂 Android 用户态也是这套） |
| `TCP_CONG_BBR=y` | 父项 `TCP_CONG_ADVANCED=n` → 被 kconfig 丢弃 | 必须同时 `CONFIG_TCP_CONG_ADVANCED=y`，并把其它高级算法显式 =n |
| `NETFILTER_XT_TARGET_REJECT=y` | **符号不存在**（6.1 里是 `IP_NF_TARGET_REJECT` / `IP6_NF_TARGET_REJECT`，原厂已 =y） | 删除（无效行，无副作用） |
| `INIT_ON_FREE_DEFAULT_ON=y` | ABI 安全，但每次 free 清零 → **明显性能代价**（约 1~5%，且与 zram/内存回收叠加） | 性能向构建建议关闭；仅「安全演示」构建保留 |
| `LANDLOCK/YAMA/BPF_UNPRIV_DEFAULT_OFF` | 正确：原厂 `CONFIG_LSM` 串已含 `landlock,yama,bpf`，开了即生效 | 保留 |
| `IP_SET_HASH_NET=y` | 与 fragment 重复一行 | 无害，可去重 |
| 依赖可见性 | 一次性 `cat fragment >> .config` 后 `olddefconfig` 只解析一遍时，父项刚开的子项可能被丢 | 用 `scripts/kconfig/merge_config.sh` 或 olddefconfig 跑两遍，并 `grep` 最终 `.config` 确认 |

---

## 6. 推荐 v3 配置（按优先级，直接追加即可）

```makefile
# ---- P0：网络/容器（ABI 安全，收益最大）----
CONFIG_BRIDGE_NETFILTER=y
CONFIG_NF_CONNTRACK_BRIDGE=y
CONFIG_VXLAN=y
CONFIG_GENEVE=y
CONFIG_IPVLAN=y
CONFIG_NET_SCH_DEFAULT=y
CONFIG_DEFAULT_FQ_CODEL=y

# ---- P0：只读镜像 / 文件系统 ----
CONFIG_SQUASHFS=y
CONFIG_SQUASHFS_FILE_DIRECT=y
CONFIG_SQUASHFS_DECOMP_MULTI_PERCPU=y
CONFIG_SQUASHFS_XATTR=y
CONFIG_SQUASHFS_ZLIB=y
CONFIG_SQUASHFS_LZ4=y
CONFIG_SQUASHFS_LZO=y
CONFIG_SQUASHFS_XZ=y
CONFIG_SQUASHFS_ZSTD=y
CONFIG_ISO9660_FS=y
CONFIG_JOLIET=y
CONFIG_ZISOFS=y
CONFIG_UDF_FS=y

# ---- P1：USB ----
CONFIG_USB_RAW_GADGET=y
CONFIG_USB_CONFIGFS_RNDIS=y
CONFIG_USB_SERIAL=y
CONFIG_USB_SERIAL_CH341=y
CONFIG_USB_SERIAL_CP210X=y
CONFIG_USB_SERIAL_PL2303=y
CONFIG_USB_FTDI_SIO=y

# ---- P1：网络栈 ----
CONFIG_TCP_CONG_ADVANCED=y
CONFIG_TCP_CONG_BBR=y
CONFIG_TCP_CONG_BIC=n
CONFIG_TCP_CONG_HTCP=n
CONFIG_TCP_CONG_HSTCP=n
CONFIG_TCP_CONG_HYBLA=n
CONFIG_TCP_CONG_VEGAS=n
CONFIG_TCP_CONG_NV=n
CONFIG_TCP_CONG_SCALABLE=n
CONFIG_TCP_CONG_LP=n
CONFIG_TCP_CONG_VENO=n
CONFIG_TCP_CONG_YEAH=n
CONFIG_TCP_CONG_ILLINOIS=n
CONFIG_TCP_CONG_DCTCP=n
CONFIG_TCP_CONG_CDG=n

# ---- P2：监控/安全/文件系统补充 ----
CONFIG_FANOTIFY=y
CONFIG_FANOTIFY_ACCESS_PERMISSIONS=y
CONFIG_BPF_LSM=y
CONFIG_CHECKPOINT_RESTORE=y
CONFIG_EROFS_FS_ZIP_LZMA=y
CONFIG_CRYPTO_SM4=y
CONFIG_CRYPTO_SM4_ARM64_CE=y
CONFIG_CRYPTO_SM4_ARM64_CE_BLK=y
CONFIG_CRYPTO_SM3=y
CONFIG_CRYPTO_SM3_ARM64_CE=y
CONFIG_CRYPTO_NHPOLY1305_NEON=y
CONFIG_CRYPTO_AES_ARM64_CE_CCM=y
CONFIG_NETFILTER_XT_TARGET_CHECKSUM=y
# 可选（体积换功能）：CIFS / 9P / NFS
# CONFIG_CIFS=y
# CONFIG_NET_9P=y
# CONFIG_NET_9P_FD=y
# CONFIG_9P_FS=y
```

> 上面每一项都属于 §1.2 的 A 或 B 级；**没有 C 级项**。预计 Image 增长 ~3–6MB（当前 Image 34.9MB、boot.img 96MB，余量充足）。

---

## 7. 不改内核也能拿到的一部分收益（运行时）

| 项 | 做法 | 说明 |
|---|---|---|
| zram 算法/大小 | `echo zstd > /sys/block/zram0/comp_algorithm`（重配前先 `swapoff`/reset） | 厂商 zram.ko 由原厂 `CRYPTO_LZO/LZ4/ZSTD=y` 编译，运行时可选 lzo/lzo-rle/lz4/**zstd**（lz4hc/842 不可用） |
| BBR | `sysctl -w net.ipv4.tcp_congestion_control=bbr` | 前提：v3 内置了 BBR |
| I/O 调度 | `echo bfq > /sys/block/sda/queue/scheduler` 或 cmdline `elevator=bfq` | 原厂已内置 BFQ/KYBER/mq-deadline |
| CAKE | `tc qdisc replace dev wlan0 root cake bandwidth 100mbit` | v2 已内置 sch_cake |
| IOMMU lazy | cmdline 加 `iommu.strict=0` 先实测 | 不行就保持默认 |

---

## 8. 验证清单（刷入前/后）

1. 构建后 `.config` 里逐项 `grep` 确认**没有被 kconfig 丢弃**（尤其 v2 的 BBR/NFT 子项）。
2. 确认 `TRIM_UNUSED_KSYMS` 关闭、`MODULE_SIG_PROTECT` 关闭、版本串逐字符一致。
3. 刷入后：`boot_completed=1`、`dmesg | grep -iE "disagrees about version|Unknown symbol|module_layout"` 为 0、434 模块全加载、GPU/相机/WiFi 正常。
4. **灰度顺序**：先 P0 网络/FS 一批 → 验证 → 再加 P1/USB → 验证 → 最后 P2。不要一次全开（否则出问题无法定位是哪一项）。
5. 若想验证「struct net 类开关是否真的破坏 ABI」，单独一版只加 NF_TABLES 构建，`nm vmlinux | grep __crc_dev_get_by_name` 与基线版对比即可判定，不必刷机。
