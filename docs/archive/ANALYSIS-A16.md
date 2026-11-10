# Android 16 / 17 内核特性差异分析与 6.1.68 回移可行性

> 设备：努比亚 Z60 Ultra（NX721J / sm8650），原厂内核 **6.1.68-android14-11-g716498f88d0f-ab11695701**  
> 对比对象：Android 16（GKI **6.12**）、Android 17（GKI **6.18**）相对 android14-6.1 的内核差异  
> 硬约束：**不破坏 GKI kABI**——434 个预编译厂商模块（GPU/显示/摄像头/音频/WiFi/蓝牙/USB/充电/传感器）必须继续加载  
> 编写日期：2026-11-10（数据截至 kernel.org 6.18.62 / 6.12.116 / 6.1.192、ACK android17-6.18-2026-06_r6）

---

## 0. 结论摘要

一句话：**Android 16/17 的内核新特性中，能在 6.1.68 上「纯配置」拿到的只有 6~9 项外围能力，且都不改导出结构体；真正的重头戏（16KB 页、sched_ext/EEVDF/PREEMPT_RT、新的 CFS_BANDWIDTH/CGROUP_PIDS 基线、Rust Binder、mTHP/mseal、io_uring 新语义、GCS）全部属于「换内核代际」而不是「改配置」。**

关键判断：

1. **版本前提需纠正**：Android 17 的 GKI 分支是 **android17-6.18（Linux 6.18 LTS）**，不是 6.13。6.13 不是 LTS、2025 年中已 EOL、从未作为 GKI 分支；6.13 的招牌特性 lazy preemption 已并入 6.18。详见 §1。
2. **原厂 6.1.68 已经吃到了 A16 的一部分内存红利**：MGLRU（LRU_GEN）、DAMON（VADDR/SYSFS）、per-VMA lock、PSI、uclamp、CFI/SCS/MTE、EROFS/F2FS 压缩、io_uring、binderfs 原厂就是开的。所谓「A16 的 MGLRU/DAMON 新特性」大部分不是配置，而是代码演进。详见 §3.3。
3. **6.12 GKI 打开了 CONFIG_CFS_BANDWIDTH / CONFIG_CGROUP_PIDS**，是因为 6.12 的 KMI **重新定了基线**；这两项在本机已实测（单开、双开、连 CRC 校验一起绕过）都会无限重启，**凡是以它们为前提的新特性都不能要**。详见 §2.3、§8-C。
4. **可纯配置启用（✅）**：Landlock（ABI v2）、DAMON_PADDR/RECLAIM/LRU_SORT、BPF_LSM、READ_ONLY_THP_FOR_FS、RCU_NOCB_CPU_DEFAULT_ALL、ZRAM_WRITEBACK；可选 NF_TABLES 系列。详见 §6。
5. **需要小补丁（⚠️）**：Landlock 新版 ABI（网络/ioctl/作用域）、EROFS zstd/deflate、DAMON_STAT、nftables 深度整合、hardlockup detector、ARM64_PSEUDO_NMI。详见 §7。
6. **无法回移（❌）**：16KB 页、sched_ext、EEVDF、PREEMPT_RT、lazy preemption、proxy execution、Rust Binder、mTHP、mseal、新版 io_uring/futex2、GCS、gendwarfksyms/AutoFDO 构建设施。详见 §8。
7. **任何 ✅/⚠️ 合入前必须过 CRC 差分闸门**（§10）：只要有一个导出符号的版本值变了就退回。

### 三分类统计

| 分类 | 数量 | 代表项 |
|---|---|---|
| ✅ 可直接配置启用 | 7（另 2 项可选） | Landlock、DAMON_RECLAIM/LRU_SORT、BPF_LSM、READ_ONLY_THP_FOR_FS、RCU_NOCB、ZRAM_WRITEBACK |
| ⚠️ 需要小补丁 | 6 | Landlock 新 ABI、EROFS zstd、DAMON_STAT、nftables 整合、hardlockup detector、PSEUDO_NMI |
| ❌ 无法回移 | 22 | 16KB 页、sched_ext、EEVDF、PREEMPT_RT、CFS_BANDWIDTH/CGROUP_PIDS、Rust Binder、mTHP、mseal、GCS 等 |

---

## 1. 版本基线澄清

### 1.1 Android ↔ GKI 分支 ↔ Linux 对照

| Android | GKI 分支 | 上游 Linux | 是否 LTS | 当前版本（2026-11） | 有无 16KB GKI 构建 |
|---|---|---|---|---|---|
| Android 14 | android14-6.1 | 6.1 | 是 | 6.1.192 | **无** |
| Android 15 | android15-6.6 | 6.6 | 是 | 6.6.162 | 有（2026-01 起） |
| Android 16 | android16-6.12 | 6.12 | 是 | 6.12.116 | 有（2026-03 起） |
| Android 17 | android17-6.18 | 6.18 | 是 | 6.18.62 | 有（2026-06 起） |
| —（不存在） | ~~android17-6.13~~ | 6.13 | **否** | 已 EOL | 无 |

数据来源：AOSP GKI 分支与 release builds 页面（android17-6.18 分支、16 KB GKI releases 仅覆盖 6.6/6.12/6.18）、kernel.org releases.json（6.18.62 longterm、6.12.116 longterm、6.1.192 longterm；6.13 已不在列表）。

### 1.2 为什么任务描述里的「GKI 6.13」不成立

- Google 的 GKI 只会选 **LTS** 内核做分支：5.10 / 5.15 / 6.1 / 6.6 / 6.12 / 6.18。6.13 是 2025-01 发布、2025 年中即 EOL 的非 LTS 版本，AOSP 从未建立 android*-6.13 分支。
- 6.13 唯一值得注意的调度改动是 **lazy preemption**（PREEMPT_LAZY），它已在 6.18 中继续演进；讨论「A17 = 6.13」会同时低估（漏掉 6.14–6.18 一整代）和误解（6.13 不是长期维护线）。
- 对本项目更实际的结论：**A17 的能力边界 = Linux 6.18 的能力边界**，而我们被钉死在 android14-6.1 的 KMI 上，跨越的是 **6.1 → 6.12/6.18 共 11~17 个上游版本**，不是 1~2 个。

### 1.3 对本项目的意义

KMI 不跨代：A14 的 vendor/system_dlkm 分区 + 434 个预编译模块只认 **android14-6.1 的 KMI 符号表**。
所以 A16/A17 的特性对我们只有两种关系：

- **能「抄下来」的**：独立子系统 / 纯配置开关 / 不影响导出原型的代码（本文 ✅、⚠️）；
- **只能「换个手机/换台设备」的**：任何改变导出符号签名的东西（本文 ❌）。

不存在「把 6.1 升成 6.12 还保留原厂模块」这条路：模块侧没有源码，无法重编。

---

## 2. 判定方法：什么算「不破坏 GKI kABI」

### 2.1 机制回顾

   内核编译时：每个 EXPORT_SYMBOL 的符号 → genksyms（6.12 起 GKI 改用 gendwarfksyms）
                根据其原型里出现的类型签名算出一个 CRC → 写进 __kcrctab
   厂商模块编译时：记录它引用的每个符号 + 当时的 CRC → 写进模块的 __versions 段
   加载时：kernel/module/version.c 的 check_version() 逐符号比对
           → 不一致即 "disagrees about version of symbol"，拒绝加载
   另外：内核里被标记为 GKI 保护的导出还受 MODULE_SIG_PROTECT 拦截（原厂开启）

关键点：**CRC 是由「类型」递归算出来的**。给一个结构体加字段，凡是原型里（直接或间接）出现该结构体的导出符号，CRC 全部变化——哪怕函数体一行没改。

### 2.2 三类风险模型（本文用它给每个特性定级）

| 风险 | 变更形态 | 典型例子 | 结论 |
|---|---|---|---|
| **低** | 只新增符号 / 新增模块 / 新增 sysfs，不碰任何已有类型 | DAMON_PADDR、Landlock LSM、NF_TABLES、BPF_LSM | 可试，仍要过 CRC 差分 |
| **中** | 给「只在内核内部使用」的结构体加字段，该结构体不出现在任何导出原型里 | struct zram、struct erofs_sb_info、damon 内部结构、struct mem_cgroup（多数场景） | 需 CRC 差分验证 |
| **高** | 给「导出原型可达」的结构体加/移字段：task_struct、task_group、cfs_rq、sched_entity、cred、file、vm_area_struct、page/folio | CFS_BANDWIDTH、CGROUP_PIDS、EEVDF、mTHP、mseal | 立即破坏 434 模块，禁止 |

注意：**只有「低/中」才有讨论价值**。「高」不是「打补丁能救」的问题，而是「模块的二进制代码里已经写死了旧偏移」——模块在内核里按旧布局读写结构体，改了就是内存踩踏，比 CRC 不匹配更致命。

### 2.3 为什么 6.12 能开 CFS_BANDWIDTH / CGROUP_PIDS，我们不能

| 维度 | android16-6.12 GKI | 我们的 android14-6.1 |
|---|---|---|
| KMI 基线 | **在 CFS_BANDWIDTH/CGROUP_PIDS 已开启的前提下重新定义**（defconfig 里两项均为 y） | 原厂基线是在**两项关闭**时定义的，434 模块按该基线编译 |
| 模块能否重编 | 能（Pixel 等有完整 vendor 源码） | **不能**，努比亚/高通模块是闭源预编译 |
| 结构体布局 | 新代际，全体一致 | 必须与 2024 年的原厂镜像逐字节一致 |

结论：**这是一个「基线」问题，不是「开关」问题**。6.12 的 KMI 天生带这两项；6.1 的 KMI 天生不带。

### 2.4 A14 实测证据（本项目历史记录）

| 实验 | 改动 | 结果 |
|---|---|---|
| 1 | 原厂内核 | ✅ 正常 |
| 2 | SYSVIPC + IPC_NS + PID_NS + POSIX_MQUEUE + 官方 kABI 填充补丁 | ✅ 需要同时处理 MODULE_SIG_PROTECT（关闭或嵌原厂证书）后才成功 |
| 3 | CONFIG_CFS_BANDWIDTH=y（单开） | ❌ 无限重启 |
| 4 | CONFIG_CGROUP_PIDS=y（单开） | ❌ 无限重启 |
| 5 | 两项同开 + 让 check_version() 容忍 CRC 漂移 | ❌ **仍然无限重启** → 说明不是纯 CRC 校验问题，是布局/语义真的变了 |

这条记录是本文判定「高」风险项的硬证据，也是对所有「加个 config 试试」的警告：**CRC 容忍补丁不能救布局变更**。

### 2.5 判定流程（每个候选特性都要走一遍）

    1) 6.1 源码树里有没有这个 CONFIG 符号？        → 没有：先归 ⚠️/❌（要补丁）
    2) 该符号开启后，是否给导出原型可达的类型加字段？ → 是：❌
    3) 是否只新增符号/模块？                        → 是：✅（待 CRC 差分）
    4) 差分 Module.symvers / __crc_*，有变化？      → 有：退回上一档
    5) 上机验证（先备份 boot_a，EDL 可回滚）        → 见 §10

---

## 3. Android 16（GKI 6.12）相对 6.1 的差异

### 3.1 GKI 6.12 defconfig 新增符号（相对 android14-6.1，实测差集 112 项）

以下为 `arch/arm64/configs/gki_defconfig` 的机器比对结果（android14-6.1 vs android16-6.12），按子系统归类，**这是「A16 内核新能力」最硬的证据**：

| 子系统 | 6.12 GKI 新增（代表项） | 性质 | 对 6.1 的可回移性 |
|---|---|---|---|
| 调度 | SCHED_CLASS_EXT、SCHED_PROXY_EXEC、CFS_BANDWIDTH、CGROUP_PIDS、CGROUP_FAVOR_DYNMODS | 新调度类 / 新基线 | ❌（核心代码 + 基线） |
| 内存 | DAMON_PADDR、MEM_ALLOC_PROFILING、READ_ONLY_THP_FOR_FS、CMA_SYSFS、GCMA、GKI_TASK_STRUCT_VENDOR_SIZE_MAX=1280 | 配置 / 代码 / GKI 机制 | DAMON_PADDR ✅，READ_ONLY_THP ✅，其余 ❌ |
| 安全 | SECURITY_LANDLOCK、BPF_LSM、ARM64_PSEUDO_NMI | LSM / 新配置 | ✅（Landlock 仅 v2） |
| 存储 | ZRAM_WRITEBACK、ZRAM_MULTI_COMP、ZRAM_BACKEND_LZ4/LZO/ZSTD、ZRAM_ANDROID_IOCTL、EROFS_FS_ZIP_ZSTD | 驱动 / fs 代码 | ZRAM_WRITEBACK ✅，其余 ❌/⚠️ |
| IPC/驱动基础 | ANDROID_BINDER_IPC_RUST、GENDWARFKSYMS、RUST、AUTOFDO_CLANG、MSEAL 相关 | 需新工具链/新内核 | ❌ |
| 网络 | TCP_CONG_ADVANCED+BBR、NETFILTER_XT_TARGET_LOG、IP_NF_MATCH_RPFILTER、NETFILTER_XTABLES_COMPAT、MACSEC | 纯配置（很多是 6.1 已有符号但默认关） | ✅（BBR/CAKE 等，注意依赖） |
| 虚拟化/其它 | VFIO、PKVM（ARM_PKVM_GUEST、VFIO_PKVM_IOMMU）、VIRTIO_*、GNSS、PTP_1588_CLOCK | 驱动 | 与本机无关 |
| 计时/看门狗 | DPM_WATCHDOG、HARDLOCKUP_DETECTOR、RCU_NOCB_CPU_DEFAULT_ALL | 配置/代码 | RCU_NOCB ✅，其余 ⚠️ |

> 说明：差集里还有大量 KUnit 测试、DRM/音频/USB 驱动、Tegra/Exynos 等无关项，完整清单见附录 A。
> 反向差集（6.12 GKI 删掉的）：MODULE_SIG_PROTECT、POSIX_MQUEUE、ZONE_DEVICE、EROFS_FS_ZIP_LZMA、BFQ、PER_VMA_LOCK_STATS 等——其中 **MODULE_SIG_PROTECT 在 6.12 被移除**，说明 6.12 起 GKI 不再用「受保护导出」这套机制，而改用符号表 + 模块签名，这是 6.12 KMI 与 6.1 的另一处结构性差异。

### 3.2 六大子系统变化（结合 Linux 6.7–6.12 changelog）

| 子系统 | 6.7→6.12 的实质变化 | 是否有 6.1 可用的开关 |
|---|---|---|
| 调度 | EEVDF 在 6.6 完成主体、6.12 补齐；**sched_ext（6.12）**；**PREEMPT_RT 进主线（6.12）**；proxy execution（6.12，Android 用于优先级反转）；deadline server（6.8） | 无（全部核心代码） |
| 内存 | mTHP 匿名页（6.8）/ shmem（6.11）、mTHP swap、DAMON 持续演进（PADDR/RECLAIM/LRU_SORT 在 6.1 已有符号）、MGLRU 常态化 + 6.12 起大量调优、mseal（6.10）、内存分配剖析（6.10） | 仅 DAMON 系与 MGLRU 已有开关 |
| 文件系统 | EROFS 增 zstd/deflate/backed-by-file；F2FS 压缩/检查点/大页持续演进；bcachefs（6.7） | EROFS/F2FS 均为代码演进 |
| 安全 | Landlock 网络（6.7）/ioctl（6.10）/作用域（6.12）；BPF LSM 在 GKI 默认开；CFI/SCS 已是 6.1 基线 | Landlock ✅、BPF_LSM ✅ |
| 网络 | nftables 功能持续扩张（6.9–6.12）；TCP-AO（6.7）；netdev TX shaping（6.13）；NAPI 挂起（6.13） | nftables ✅（但 Android 自己也没开） |
| 构建/ABI | **gendwarfksyms（6.12 GKI 使用，稳定 CRC 的工具链）**、AutoFDO 内核 PGO、task_struct vendor 预留区可配置到 1280 字节 | ❌（构建设施，且不会放宽 ABI） |

### 3.3 设备原厂配置现状对照（逐项核对 nx721j-stock.config）

| 能力 | 6.1 符号 | 原厂值 | A16 是否依赖 | 结论 |
|---|---|---|---|---|
| MGLRU | LRU_GEN / LRU_GEN_ENABLED | y / y | 是（默认开） | **已具备**，6.12+ 只是代码调优 |
| DAMON | DAMON / DAMON_VADDR / DAMON_SYSFS | y / y / y | 是 | 已具备；PADDR/RECLAIM/LRU_SORT 可选（§6.2） |
| per-VMA lock | PER_VMA_LOCK | y | 是 | 已具备 |
| PSI | PSI | y | 是 | 已具备 |
| uclamp | UCLAMP_TASK / UCLAMP_TASK_GROUP | y / y | 是 | 已具备 |
| CFI / SCS | CFI_CLANG / SHADOW_CALL_STACK | y / y | 是（6.18 改名 CONFIG_CFI） | 已具备 |
| MTE / KASAN | ARM64_MTE / KASAN / KASAN_HW_TAGS | y / y / y | 是 | 原厂 config 记录如此（若属实，内核态 MTE 已开） |
| EROFS | EROFS_FS + ZIP + XATTR/ACL/SECURITY + PCPU_KTHREAD | y | 是 | 已具备；6.12 新增 ZSTD/DEFLATE/BACKED_BY_FILE 无 |
| F2FS | F2FS_FS + COMPRESSION（LZO/LZ4/ZSTD）+ IOSTAT | y | 是 | 已具备 |
| io_uring | IO_URING | y | 是 | 已具备（但语义是 6.1 的） |
| binder | ANDROID_BINDER_IPC / BINDERFS | y / y | 是 | 已具备；Rust Binder 无 |
| Landlock | SECURITY_LANDLOCK | **n（符号存在）** | 是 | ✅ 可开（仅 ABI v2，§6.1） |
| nftables | NF_TABLES | **n（符号存在）** | 否（GKI 6.12 也没开） | 可选（§6.7） |
| BPF LSM | BPF_LSM | **n（符号存在）** | 是 | ✅ 可开（§6.3） |
| CFS_BANDWIDTH | CFS_BANDWIDTH | **n** | 是 | ❌ 实测不可开（§2.4） |
| CGROUP_PIDS | CGROUP_PIDS | **n** | 是 | ❌ 实测不可开（§2.4） |
| 16KB 页 | ARM64_PAGE_SHIFT=12（4K） | 4K | 是 | ❌（§8-A） |
| sched_ext | 无 SCHED_CLASS_EXT 符号 | — | 是 | ❌（§8-B） |

---

## 4. Android 17（GKI 6.18）相对 6.12 的差异

### 4.1 a16→a17 defconfig 差集（实测）

| 方向 | 代表符号 | 含义 |
|---|---|---|
| 6.18 新增 | **CONFIG_CFI**（取代 CFI_CLANG）、**IP_NF_IPTABLES_LEGACY / NETFILTER_XTABLES_LEGACY / IP6_NF_IPTABLES_LEGACY**、**MSEAL_SYSTEM_MAPPINGS**、NET_APF、PTSHARE、ZRAM_TRACK_ENTRY_ACTIME、RUST_FW_LOADER_ABSTRACTIONS、USB4、CORESIGHT、PCIE_PTM | 安全/网络/存储的下一代开关 |
| 6.18 移除 | DAMON_VADDR/PADDR/SYSFS（重构为默认行为）、MEMCG_V1、RCU_NOCB_CPU_DEFAULT_ALL、SCHED_MC、JUMP_LABEL、PCIEPORTBUS | 说明 6.18 把多项 6.12 的可选项固化/重组 |

要点：

- **CFI 在 6.18 变成单一 CONFIG_CFI**（KCFI 与 LTO 的整合），我们 6.1 用 CFI_CLANG，不受影响；
- **MSEAL_SYSTEM_MAPPINGS（6.15）** 是新 syscall mseal 的系统映射加固，属 ❌（新 syscall + vma 语义）；
- **xtables 被标记 LEGACY** 是 nftables 化的上游信号，但 **GKI 6.12/6.18 依然没有开 CONFIG_NF_TABLES**——Android 用户态仍在用 iptables/xtables + eBPF，nftables 只是「可开的能力」而非「A16/A17 的内核要求」。

### 4.2 Linux 6.14–6.18 里与 6.1 相关的点

| 版本 | 特性 | 对 6.1 回移 |
|---|---|---|
| 6.14 | binder 事务错误经 netlink 上报；FUSE io_uring 通信 | ❌ 代码 |
| 6.15 | 初次引入 mseal 系统映射（MSEAL_SYSTEM_MAPPINGS）；per-VMA lock 重构为 refcount | ❌（vma 语义） |
| 6.16 | MGLRU 增加 max 参数、SWAPPINESS_ANON_ONLY；zram 算法参数化 | ❌ 代码（MGLRU 已在开） |
| 6.17 | **DAMON_STAT（简单实用的访问统计）**；sched_ext cgroup 带宽接口；/proc/pid/maps 用 per-VMA lock | DAMON_STAT ⚠️（新文件，见 §7.3） |
| 6.18 | **Rust Binder 驱主线化**；memdescs（page 描述符重构）；mTHP 大页分配优化；大页/碎片改进 | ❌（Rust 需 6.12+、memdescs 改 page 类型） |

### 4.3 结论

**A17（6.18）没有给 6.1 带来任何新的「纯配置」机会**：新增开关（MSEAL_SYSTEM_MAPPINGS、NET_APF、PTSHARE、ZRAM_TRACK_ENTRY_ACTIME、CFI）在 6.1 树里要么没有符号、要么依赖 6.14+ 代码。A17 相对 A16 的差异对我们只有「认知价值」，没有「操作价值」。

---

## 5. 三分类总表

> 图例：✅ 可直接配置启用；⚠️ 需要小补丁；❌ 无法回移（附根因编号 A–F，见 §8）

| # | 特性（引入版本） | 6.1 有配置符号？ | 回移手段 | kABI 风险 | 判定 |
|---|---|---|---|---|---|
| 1 | 16KB 页（A15/A16，PAGE_SHIFT=14） | 有（ARM64_16K_PAGES） | 换页大小 = 全部模块/用户态重编 | 高 | ❌ A |
| 2 | MGLRU 本体（5.15+/6.1 已有） | 已开（LRU_GEN=y） | — | — | ✅ 已具备 |
| 3 | MGLRU 6.12–6.18 调优 | 无单独开关 | 回移 mm/vmscan 补丁 | 中 | ❌ E |
| 4 | DAMON_PADDR（6.1 已有符号） | 有（未开） | 纯配置 | 低 | ✅ |
| 5 | DAMON_RECLAIM / DAMON_LRU_SORT | 有（未开，依赖 DAMON_PADDR） | 纯配置 | 低 | ✅ |
| 6 | DAMON_STAT（6.17） | 无 | 回移 mm/damon 新文件 | 低-中 | ⚠️ |
| 7 | mTHP 匿名页（6.8）/ shmem（6.11） | 无 | 回移 mm 核心（folio、fault、swap） | **高** | ❌ B |
| 8 | mseal（6.10）/ MSEAL_SYSTEM_MAPPINGS（6.15） | 无 | 新 syscall + vm_area_struct 语义 | **高** | ❌ D |
| 9 | READ_ONLY_THP_FOR_FS（GKI 6.12 开启） | 有（未开，依赖 THP+SHMEM） | 纯配置（实验性） | 低 | ✅ |
| 10 | 内存分配剖析 MEM_ALLOC_PROFILING（6.10） | 无 | 回移 mm 核心 | 中-高 | ❌ E |
| 11 | zswap（6.8–6.12 演进） | 有（未开） | 纯配置可开，但收益取决于 swap 后端 | 中 | ⚠️ 选配 |
| 12 | ZRAM_WRITEBACK | 有（未开） | 纯配置 | 低-中 | ✅ |
| 13 | zram 多后端/压缩后端 API（6.12） | 无（ZRAM_MULTI_COMP 不存在于 6.1） | 回移 zram 驱动（模块级） | 低 | ⚠️（低优先） |
| 14 | EROFS zstd/deflate（6.12） | 无 | 回移 fs/erofs 压缩算法 | 低-中 | ⚠️ |
| 15 | EROFS backed-by-file（6.12） | 无 | 回移 fs/erofs | 低-中 | ⚠️（低优先） |
| 16 | F2FS 6.12–6.18 演进 | 已有压缩等 | 代码演进 | 低-中 | ❌ E |
| 17 | Landlock 本体（5.13+，ABI v2@6.1） | 有（未开） | 纯配置 | 低 | ✅ |
| 18 | Landlock 网络（6.7 ABIt4）/ioctl（6.10 ABIt5）/作用域（6.12 ABIt6） | 无 | 回移 security/landlock | 低 | ⚠️ |
| 19 | BPF_LSM（GKI 6.12 开启） | 有（未开） | 纯配置 | 低 | ✅ |
| 20 | ARM64_PSEUDO_NMI | 有（未开） | 纯配置，但 QCOM 平台需实测 | 低 | ⚠️ |
| 21 | RCU_NOCB_CPU_DEFAULT_ALL | 有（未开，RCU_NOCB_CPU=y） | 纯配置 | 低 | ✅ |
| 22 | hardlockup detector 通用实现（6.12） | 无 | 回移 kernel/watchdog | 中 | ⚠️（低优先） |
| 23 | nftables（NF_TABLES） | 有（未开） | 纯配置（+依赖链） | 低-中 | ⚠️ 选配 |
| 24 | TCP BBR / CAKE / NTFS3 等（6.12 GKI 开启） | 有（部分被父开关隐藏） | 纯配置（注意父依赖） | 低 | ✅ |
| 25 | sched_ext（6.12） | 无 | 新调度类 + BPF struct_ops | **高** | ❌ B |
| 26 | EEVDF 完整化（6.6/6.12） | 无 | fair.c 重写 + sched_entity 布局 | **高** | ❌ B |
| 27 | PREEMPT_RT（6.12） | 部分（PREEMPT 系列） | 整体抢占模型置换 | **高** | ❌ B |
| 28 | lazy preemption（6.13，并入 6.18） | 无 | 抢占模型核心 | **高** | ❌ B |
| 29 | proxy execution（6.12） | 无 | 调度核心 + 新结构 | **高** | ❌ B |
| 30 | CFS_BANDWIDTH / CGROUP_PIDS（6.12 GKI 开） | 有（未开） | 纯配置名义可行，**实测 bootloop** | **高** | ❌ C |
| 31 | Rust Binder（6.12 ACK / 6.18 主线） | 无 | 需 Rust 内核支持 + 6.12 binder | **高** | ❌ E |
| 32 | binder 事务 netlink 报告（6.14/6.18） | 无 | 代码 | 中 | ❌ E |
| 33 | io_uring 6.7–6.18 新语义 | 只有 IO_URING=y | 子系统整体回移 | 中-高 | ❌ D |
| 34 | futex2 完整（6.7+） | 无 | 新 syscall | 中-高 | ❌ D |
| 35 | GCS（ARM64 guarded control stack，6.13+/6.18） | 无 | 需 6.13 + FEAT_GCS 硬件 | 高 | ❌ F |
| 36 | gendwarfksyms / AutoFDO（6.12/6.18 GKI） | 无 | 构建设施 + 新 clang | —（不进运行时 ABI） | ❌ E |
| 37 | GKI task_struct vendor 预留区（6.12=1280B） | 无（有 ANDROID_VENDOR_* ） | 改 task_struct 大小 | **高** | ❌ C |

---

## 6. ✅ 可直接配置启用（逐项）

> 全部项都**不新增/不修改任何导出符号的原型**，但合入前仍须跑 §10 的 CRC 差分。
> 6.1 的 kconfig 依赖已从 ACK android14-6.1 源码逐条核对，见附录 C。

### 6.1 Landlock LSM（对应 A16 的 SECURITY_LANDLOCK=y）

    配置：CONFIG_SECURITY_LANDLOCK=y
    现状：原厂 config 里符号存在但未开；CONFIG_LSM 字符串里已经列了 landlock（排在第一位）
    收益：容器/沙箱工具可以用 unprivileged 沙箱（Droidspaces、部分 Kali 工具链）；A14 系统本身不用它，所以零系统风险
    限制：6.1 只有 **ABI v2**（LANDLOCK_LAST_ACCESS_FS = LANDLOCK_ACCESS_FS_REFER），无网络规则、无 ioctl 规则、无作用域
    ABI：LSM blob 是动态分配（struct cred 里只有 void *security 指针），加 LSM 不改 cred/task_struct 布局
    建议：**启用**；若需要网络/ioctl 规则见 §7.1

### 6.2 DAMON 全家桶（PADDR + RECLAIM + LRU_SORT）

    配置：CONFIG_DAMON_PADDR=y
          CONFIG_DAMON_RECLAIM=y      # 默认不启动，需 sysfs 打开
          CONFIG_DAMON_LRU_SORT=y     # 默认不启动
    依赖：两项都 depends on DAMON_PADDR（6.1 Kconfig 原文），PADDR 又 depends on DAMON && MMU（都满足）
    现状：原厂已开 DAMON + DAMON_VADDR + DAMON_SYSFS，仅缺 PADDR/RECLAIM/LRU_SORT
    收益：主动回收（轻压场景少触发 kswapd/lmkd）、LRU 冷热排序（热点页保护）；对 8~12GB 机型 + 容器场景有实测价值
    风险：DAMON_RECLAIM 默认参数激进会明显增加 CPU/功耗；**必须**用 sysfs 手工调 kdamonds（sampling/aggr interval、min_age）后再启用
    建议：编进内核但**默认不 enable**，仅作为可选能力（运行时 sysfs 开）

### 6.3 BPF LSM（对应 A16 的 CONFIG_BPF_LSM=y）

    配置：CONFIG_BPF_LSM=y
    依赖：CONFIG_BPF_SYSCALL=y、CONFIG_DEBUG_INFO_BTF=y（原厂均满足）
    收益：可用 eBPF 写 LSM 钩子做审计/拦截；安全研究、容器场景有用
    风险：需要 CAP_BPF/root 才能加载，SELinux 仍会限制；增加内核攻击面（可接受）
    ABI：BPF LSM 只增加静态调用点与 bpf_lsm_* 桩，不改导出结构体；仍建议 CRC 差分
    建议：**低优先级启用**（本机系统不依赖，纯能力储备）

### 6.4 READ_ONLY_THP_FOR_FS（对应 A16 GKI 开启）

    配置：CONFIG_READ_ONLY_THP_FOR_FS=y
    依赖：CONFIG_TRANSPARENT_HUGEPAGE=y && CONFIG_SHMEM=y（原厂均满足）
    收益：只读文件页（可执行代码、shmem）可被折叠成 THP，减少 iTLB miss；对大型 so（容器里的工具链）有边际收益
    风险：6.1 的实现标 EXPERIMENTAL，只覆盖只读文件页；可能增加内存占用
    建议：可开，但**收益有限**，建议与 §6.2 一起做一轮对比测试再决定

### 6.5 RCU_NOCB_CPU_DEFAULT_ALL

    配置：CONFIG_RCU_NOCB_CPU_DEFAULT_ALL=y
    现状：原厂 CONFIG_RCU_NOCB_CPU=y，仅 DEFAULT_ALL 未开
    收益：所有 CPU 的 RCU 回调交给 rcuo 线程，降低软中断抖动/尾延迟（A16 GKI 默认开）
    风险：多几个内核线程，空载功耗可能略升；调度类不敏感场景收益小
    建议：可开，性能测试通过即可保留

### 6.6 ZRAM_WRITEBACK（与现有 enhance 片段重叠）

    配置：CONFIG_ZRAM_WRITEBACK=y
    现状：符号存在，原厂未开；config-enhance.fragment 已列
    收益：zram 回写（配合 zram 的 writeback 设备，如 zram 分区/文件），内存紧张时把冷页换出到磁盘而不是 OOM
    风险：需要额外的 swap backing 设备才能用；不用则零影响；依赖 CONFIG_ZRAM=m（原厂=m）
    建议：保留

### 6.7 可选：nftables 与网络配置（对容器有价值，对系统无必要）

    配置：CONFIG_NF_TABLES=y
          CONFIG_NF_TABLES_INET=y / CONFIG_NF_TABLES_NETDEV=y / CONFIG_NFT_NAT=y / CONFIG_NFT_MASQ=y
    事实：**GKI 6.12/6.18 都没有开 NF_TABLES**，Android 用户态仍是 iptables/xtables + eBPF；所以这不是「A16 要求」
    收益：容器里可以用 nft（Kali/Debian 的 nftables 前端），配合 netns 做 NAT/防火墙
    风险：依赖链深（NF_TABLES 关闭时 NF_TABLES_INET/NFT_* 是**不可见符号**，一次性 append 会被 kconfig 丢弃，见 §12）
    建议：如果容器需要 nft 再开，且**单独一轮构建验证**

---

## 7. ⚠️ 需要小补丁

### 7.1 Landlock 新版 ABI（6.7 网络 / 6.10 ioctl / 6.12 作用域）

- **补丁面**：security/landlock 目录 + include/uapi/linux/landlock.h + LSM 钩子注册；6.1→6.12 的 landlock 改动是**独立子系统**，不碰导出结构体。
- **风险**：低-中。真正难点是 6.1 的 LSM 基础设施与 6.12 有差异（hook 签名、tsync 支持），需要逐补丁适配；另需确认不破坏 SELinux 栈顺序。
- **收益**：ABI v6 的「作用域」对容器隔离有用；「网络限制」对沙箱有用。
- **建议**：优先级低于 ✅ 项；若只想要「能沙箱」则 §6.1 的 v2 已够。

### 7.2 EROFS zstd / deflate 压缩（6.12）

- **补丁面**：fs/erofs 的压缩路径 + lib/zstd 依赖；6.12 的 erofs 还改了 folio 化 IO。
- **风险**：低-中（fs 独立，导出符号少）。但 **Android 14 的 vendor 镜像不是 zstd 压缩的**，系统镜像用不到；只有自己做的容器镜像/squashfs 替代方案能用。
- **建议**：除非要在手机上做 zstd 压缩的自定义镜像，否则不做。

### 7.3 DAMON_STAT（6.17）

- **补丁面**：mm/damon/stat.c + sysfs 接口，纯新增文件，依赖 DAMON 核心。
- **风险**：低。**收益**：容器内存观测（哪些进程/区域在访问）比 6.1 的 DAMON_SYSFS 手工配 schemes 好用得多。
- **建议**：如果做内存调优工具，值得回移；否则可选。

### 7.4 nftables 深度整合（若要做成系统级能力）

- 单纯开 NF_TABLES 属 ✅；但要让 Android 的 netd/防火墙走 nft，需要用户态改造（netd 是 vendor/system 预编译），**不可行**。
- 因此 nftables 只定位为「容器内可用」，不要期待系统级替换 iptables。

### 7.5 hardlockup detector 通用实现（6.12）

- 6.1 arm64 没有 arch 无关的 HARDLOCKUP_DETECTOR（原厂 config 无此符号）；6.12 的实现在 kernel/watchdog.c + perf/NMI 抽象层。
- **风险**：中。QCOM 的 GIC/中断路由对 NMI-like 机制敏感，需要实测（与 §7.6 同源问题）。

### 7.6 ARM64_PSEUDO_NMI（配置项，但归 ⚠️）

- 6.1 有符号、纯配置，但 PSEUDO_NMI 依赖 GICv3 的优先级掩码行为，在高通平台上**历史上出现过中断丢失/看门狗误报**。
- **建议**：只在确实需要 hardlockup 检测时开，且必须做压力测试。

---

## 8. ❌ 无法回移（按根因分组）

### A. 编译期常量 / 全局二进制契约

**16KB 页（PAGE_SHIFT=14）**

- 页大小是编译期常量：内核镜像、每个模块的段对齐、ELF 的 p_align、用户态 so 的段对齐全部绑定。
- 434 个厂商模块是 **4K 页** 编出来的（原厂 config：ARM64_PAGE_SHIFT=12、ARM64_4K_PAGES=y）；16K 内核加载 4K 模块会在模块加载/重定位阶段失败。
- AOSP 的 16KB GKI 只覆盖 android15-6.6 / android16-6.12 / android17-6.18，**android14-6.1 没有 16KB GKI 构建**（官方 16 KB GKI releases 页面）。
- 即使内核侧强行 16K，整机用户态（system/vendor/product 的预编译 ELF）也全部要 16K 对齐重编——本机不可能。

### B. 新子系统 / 新调度类 / 抢占模型

**sched_ext、EEVDF、PREEMPT_RT、lazy preemption、proxy execution**

- sched_ext 是 6.12 才有的**新调度类**（kernel/sched/ext.c + BPF struct_ops + 新 kfunc），无法以配置形式出现在 6.1；回移等于把 6.12 调度核心搬过来。
- EEVDF 在 6.6 替换了 CFS 的选取算法，改的是 struct sched_entity/sched_avg 的语义与字段——属「导出原型可达」的高风险结构，直接破坏 434 模块。
- PREEMPT_RT（6.12 进主线）把 spinlock 全面改为 rtmutex，是抢占模型的整体置换；lazy preemption（6.13）是 PREEMPT 模型的第四种取值；proxy execution（6.12）新增调度器间代理执行机制。
- 结论：这五项都属于「换内核代际」，不是补丁级别。

### C. GKI 新基线 / ABI 预留机制

**CFS_BANDWIDTH、CGROUP_PIDS、task_struct vendor 预留区**

- 6.12 GKI 直接开 CFS_BANDWIDTH/CGROUP_PIDS → 6.12 的 KMI 是带它们定义的；6.1 的 KMI 不带。
- 本机已三重实测（单开、双开、CRC 容忍补丁）全部 bootloop（§2.4）。**这不是 CRC 问题，是布局问题**：模块按旧 task_group/cfs_rq 偏移读写。
- CONFIG_GKI_TASK_STRUCT_VENDOR_SIZE_MAX=1280（6.12）是 GKI 给 task_struct 预留 vendor 区的编译期手段；改它就是改 task_struct 大小 → 高风险。6.1 只有 ANDROID_VENDOR_HOOKS/OEM_DATA 机制，且原厂模块依赖当前大小。

### D. 新 syscall / ABI 单元

**mseal、futex2、io_uring 新语义**

- mseal（6.10）新增 syscall 并给 vm_area_struct/VM_ 标志加语义；MSEAL_SYSTEM_MAPPINGS（6.15）把 mseal 用于系统映射。
- futex2（6.7 开始分片）与 io_uring 6.7–6.18 的新 opcode 都属于「子系统语义单元」，回移要连带改完成机制、task_work、文件引用计数等核心路径。
- 这些能力在 Android 14 用户态里**没有消费者**（A14 的 bionic/ART 不调用），回移收益接近 0。

### E. 代码演进 / 构建设施 / 语言运行时

**MGLRU 6.12+ 调优、mTHP、内存分配剖析、Rust Binder、binder netlink 报告、F2FS 演进、gendwarfksyms、AutoFDO**

- 这些是「同一机制的持续演进」，没有配置开关；回移是成百上千行的 mm/fs 补丁，且往往牵连 folio/page 类型。
- Rust Binder（6.12 ACK 的 ANDROID_BINDER_IPC_RUST=m、6.18 主线 rust_binder）需要 Rust for Linux 基础设施（6.12 才在 ACK 可用；6.1 ACK 无 CONFIG_RUST 支持）。
- gendwarfksyms（6.12 GKI 的 CONFIG_GENDWARFKSYMS=y）是**版本号生成工具**，作用是让 CRC 对「非 ABI 变更」更稳定（--stable 规则：declonly、enumerator_ignore、结构体尾部追加等）。它**不会**让你能改 ABI，把它理解成「GKI 维护者做 LTS 回移时的工具」即可；6.1 树里没有这套工具链。
- AutoFDO（6.12/6.18 GKI 的 CONFIG_AUTOFDO_CLANG=y）是构建期 PGO，需要 clang 18+ 与配套 profile；原厂 clang 是 r487747c（17.0.2），不满足。

### F. 新硬件能力依赖

**GCS（Guarded Control Stack，ARM64 用户态影子栈）**

- 6.13 起 arm64 才支持 GCS，需要 CPU 支持 FEAT_GCS（ARMv9.4）；sm8650（Cortex-X4/A720 代）不保证具备。
- A17 6.18 的 CONFIG_CFI 与 GCS 搭配是「新一代安全基线」，与本机无关。

---

## 9. 兼容性边界：回移 ≠ 升级

| 期待 | 现实 |
|---|---|
| 「把 A16/A17 特性搬过来，系统就更 A16 了」 | 不会。系统行为由 **system/vendor 分区 + GKI 用户态**决定，内核只是被调用方；A14 的 netd、ART、lmkd 不会因为内核多一个 Landlock 就变 A16 |
| 「刷 A16 GSI 试试」 | 不可能。GSI 要求对应代际的 GKI KMI（6.12），android14-6.1 内核不满足 VINTF/KMI 要求 |
| 「回移能提升性能」 | 只有 DAMON、RCU_NOCB、READ_ONLY_THP 这类边际项；A16 的性能提升（EEVDF 调优、mTHP、MGLRU 调优）主体在代码里，不在开关里 |
| 「回移能提升安全」 | Landlock 可给容器用；CFI/SCS/MTE 原厂已开；A16 的新安全能力基本都要新内核 |

**所以回移的唯一正当目标**：为 Droidspaces/NetHunter/Kali 容器和自用调试增加**内核能力面**，而不是改变系统版本。

---

## 10. 验证闸门（构建与启动验证方法，本次未执行）

### 10.1 从厂商模块反查「期望 CRC」

厂商模块的 __versions 段记录了它期望的每个符号 CRC，可用 kmod 直接导出：

    # 在设备上（或解包 vendor_boot/vendor_dlkm 后）
    for ko in /vendor/lib/modules/*.ko; do
        modprobe --dump-modversions "$ko"
    done | awk '{print $2, $1}' | sort -u > /tmp/vendor_expected_crc.txt

### 10.2 与自编内核的 __crc_ 比对

    # 构建产物 out/vmlinux 内每个导出符号都有 __crc_<sym>
    nm out/vmlinux | awk '/__crc_/ {print $3" "$1}' | sed 's/__crc_//' | sort > /tmp/kernel_crc.txt

    # 逐条比对：只要出现「期望值 != 内核值」的符号，这个配置就不许上机
    join -j1 /tmp/vendor_expected_crc.txt /tmp/kernel_crc.txt | awk '$2 != $3 {print "MISMATCH", $1}'

更稳的做法是**双构建差分**：同一棵树，A 组用原厂 config，B 组用原厂 config + 新片段，比较两次的 Module.symvers（或 __crc_ 列表）。**任何已有符号的 CRC 变化都视为回归**（新符号增加是允许的）。

### 10.3 启动验证顺序（必须遵守）

    1) 先备份 boot_a（EDL 读回并校验 sha256）
    2) 只刷 boot_a（不动 init_boot，保留 root）
    3) 开机后立刻确认：getprop sys.boot_completed=1 / dmesg 无 "disagrees about version" / lsmod 数量
    4) 抽查关键模块：msm_kgsl（GPU）、msm_drm、camera、qca_cld3_kiwi_v2、zte_tpd
    5) 失败即 EDL 回滚 boot_a

### 10.4 失败判据

| 现象 | 含义 | 处理 |
|---|---|---|
| 开机动画卡死 + dmesg 有 "disagrees about version of symbol" | CRC 变化 | 回滚，放弃该配置或补 kABI 填充 |
| 无限重启、pstore 无记录 | 布局破坏或早期 init 失败 | 回滚，按 §2.2 重新定级 |
| 能开机但某硬件失效 | 该子系统结构体被改 | 定位符号，回滚 |

---

## 11. 建议路线图

| 阶段 | 内容 | 风险 | 验收 |
|---|---|---|---|
| P1（低风险，建议做） | Landlock、DAMON_PADDR/RECLAIM/LRU_SORT、RCU_NOCB_CPU_DEFAULT_ALL、READ_ONLY_THP_FOR_FS、ZRAM_WRITEBACK（后者已规划） | 低 | CRC 全等 + 开机 + 434 模块 |
| P2（中风险，可选） | BPF_LSM、NF_TABLES 系（容器需要时） | 低-中 | 单独构建验证 + 容器内 nft 实测 |
| P3（补丁级，按需） | Landlock ABI v6、DAMON_STAT、EROFS zstd | 中 | 独立分支 + 回归测试 |
| 不做 | 16KB、sched_ext、EEVDF、RT/lazy preempt、CFS_BANDWIDTH/CGROUP_PIDS、Rust Binder、mTHP、mseal、io_uring 新版、GCS | — | — |

---

## 12. 对现有 config-enhance.fragment 的交叉核对（只读建议，未改文件）

按 ACK android14-6.1 源码逐条核对，发现几处「写了但不生效 / 需要父开关」的情况：

| 项 | 核对结果 | 建议 |
|---|---|---|
| CONFIG_MEMCG_SWAP=y | **ACK 6.1 无此符号**（init/Kconfig 只有 MEMCG/MEMCG_KMEM，原厂 config 也无该行） | 删除；swap accounting 在 6.1 由 MEMCG 统一处理 |
| CONFIG_TCP_CONG_BBR=y | 符号存在但默认**不可见**（depends on TCP_CONG_ADVANCED，原厂该父项为 n，原厂 config 里连 TCP_CONG_BBR 行都没有） | 同时写 CONFIG_TCP_CONG_ADVANCED=y |
| CONFIG_NF_TABLES_INET / NFT_NAT / NFT_MASQ | 父项 NF_TABLES 为 n 时这些符号**不可见**，一次性 append 可能被 kconfig 丢弃 | 先确认 NF_TABLES=y 生效（两遍 olddefconfig 或 merge_config.sh）再开子项 |
| CONFIG_SECURITY_LANDLOCK / SECURITY_YAMA / BPF_UNPRIV_DEFAULT_OFF / INIT_ON_FREE_DEFAULT_ON / DEBUG_WX / NTFS3_FS / NET_SCH_CAKE / ZRAM_WRITEBACK | 符号均存在且当前未开，属纯配置 | 保留；但 INIT_ON_FREE_DEFAULT_ON 有明显性能代价，建议只在安全演示构建启用 |
| 片段整体 | 直接 cat 到 .config 再 olddefconfig，**链式依赖可能只解析一遍** | 建议用 scripts/kconfig/merge_config.sh，或 olddefconfig 跑两遍并 grep 最终 .config 确认 |

---

## 13. 参考资料

| 资料 | 链接 |
|---|---|
| AOSP Android 16 release notes | https://source.android.com/docs/whatsnew/android-16-release |
| AOSP Android 17 release notes | https://source.android.com/docs/whatsnew/android-17-release |
| AOSP KMI 维护（ABI 规则） | https://source.android.com/docs/core/architecture/kernel/stable-kmi |
| AOSP ABI monitoring | https://source.android.com/docs/core/architecture/kernel/abi-monitor |
| AOSP 16 KB page size | https://source.android.com/docs/core/architecture/16kb-page-size/16kb |
| AOSP GKI releases（含 16 KB GKI 支持分支） | https://source.android.com/docs/core/architecture/kernel/gki-releases |
| ACK 分支与 defconfig | https://android.googlesource.com/kernel/common/+/refs/heads/android16-6.12 |
| ACK android17-6.18 | https://android.googlesource.com/kernel/common/+/refs/heads/android17-6.18 |
| Linux 6.7–6.18 变更摘要 | https://kernelnewbies.org/Linux_6.12 等 |
| gendwarfksyms（DWARF 符号版本 + kABI 稳定规则） | https://docs.kernel.org/kbuild/gendwarfksyms.html |
| Landlock ABI 文档 | https://docs.kernel.org/userspace-api/landlock.html |
| kernel.org releases.json（LTS/EOL 事实） | https://www.kernel.org/releases.json |
| Droidspaces kABI 说明（本项目既有依据） | https://github.com/ravindu644/Droidspaces-OSS |

---

## 附录 A：android16-6.12 GKI defconfig 相对 android14-6.1 的 112 个新增符号

（机器比对 arch/arm64/configs/gki_defconfig；仅新增，未含被删除项）

    [调度/调度类] SCHED_CLASS_EXT SCHED_PROXY_EXEC CFS_BANDWIDTH CGROUP_PIDS CGROUP_FAVOR_DYNMODS
    [内存] DAMON_PADDR MEM_ALLOC_PROFILING READ_ONLY_THP_FOR_FS CMA_SYSFS GCMA GCMA_SYSFS GKI_TASK_STRUCT_VENDOR_SIZE_MAX=1280
    [安全] SECURITY_LANDLOCK BPF_LSM ARM64_PSEUDO_NMI
    [存储] ZRAM_WRITEBACK ZRAM_MULTI_COMP ZRAM_BACKEND_LZ4 ZRAM_BACKEND_LZO ZRAM_BACKEND_ZSTD ZRAM_ANDROID_IOCTL EROFS_FS_ZIP_ZSTD
    [IPC/构建] ANDROID_BINDER_IPC_RUST RUST RUST_INLINE_HELPERS GENDWARFKSYMS AUTOFDO_CLANG DEBUG_INFO_DWARF5 DEBUG_INFO_COMPRESSED_ZSTD EXPERT
    [时间/看门狗] DPM_WATCHDOG DPM_WATCHDOG_TIMEOUT DPM_WATCHDOG_WARNING_TIMEOUT HARDLOCKUP_DETECTOR HARDLOCKUP_DETECTOR_PREFER_BUDDY RCU_NOCB_CPU_DEFAULT_ALL
    [网络] TCP_CONG_ADVANCED TCP_CONG_BBR NETFILTER_XT_TARGET_LOG IP_NF_MATCH_RPFILTER NETFILTER_XTABLES_COMPAT GACT_PROB NET_CLS_CGROUP NETDEV_ADDR_LIST_TEST MACSEC
    [虚拟化/驱动] VFIO VFIO_PLATFORM ARM_PKVM_GUEST PKVM_PVIOMMU VFIO_PKVM_IOMMU GUNYAH_QCOM_TRUSTED_VM VIRTIO_BLK VIRTIO_PCI VIRTIO_CONSOLE VIRTIO_BALLOON VIRTIO_VSOCKETS
    [其它] ARM_SDE_INTERFACE ARM64_VA_BITS_39 BLK_WBT CPUSETS_V1 MEMCG_V1 SWIOTLB_DYNAMIC STACKTRACE_BUILD_ID TASK_DELAY_ACCT PTDUMP_STAGE2_DEBUGFS PSTORE_BLK PTP_1588_CLOCK GNSS USB_MON USB_XHCI_SIDEBAND
    [KUnit/m] KUNIT KUNIT_TEST KUNIT_EXAMPLE_TEST 及各子系统 *_KUNIT_TEST=m
    [Android] ANDROID_USB_CONFIGFS_F_ACC ANDROID_USB_CONFIGFS_UEVENT
    （完整 112 项可用 comm -13 于两分支 gki_defconfig 复现）

被删除的代表项（6.12 不再有）：MODULE_SIG_PROTECT、POSIX_MQUEUE、ZONE_DEVICE、EROFS_FS_ZIP_LZMA、IOSCHED_BFQ/BFQ_GROUP_IOSCHED、PER_VMA_LOCK_STATS、SOFTLOCKUP_DETECTOR（改为 HARDLOCKUP 体系）、INET/UNIX（被 select）、KFENCE_STATIC_KEYS、DMABUF_HEAPS_PAGE_POOL。

## 附录 B：android17-6.18 相对 android16-6.12 的符号增删

新增（节选）：

    CONFIG_CFI（取代 CFI_CLANG）  MSEAL_SYSTEM_MAPPINGS  NET_APF  PTSHARE
    IP_NF_IPTABLES_LEGACY  IP6_NF_IPTABLES_LEGACY  NETFILTER_XTABLES_LEGACY
    ZRAM_TRACK_ENTRY_ACTIME  RUST_FW_LOADER_ABSTRACTIONS  USB4  CORESIGHT  PCIE_PTM
    ANDROID_BINDER_ALLOC_KUNIT_TEST（Binder 分配测试）  CRYPTO_FIPS140_LIB_OVERRIDE_SUPPORT
    PROC_MEM_FORCE_PTRACE  SW_SYNC  DRM_ACCEL  IPV6_SUBTREES  PM_USERSPACE_AUTOSLEEP

移除（节选）：

    DAMON_VADDR / DAMON_PADDR / DAMON_SYSFS（6.18 重构，不再作为独立可见项）
    MEMCG_V1  CPUSETS_V1  RCU_NOCB_CPU_DEFAULT_ALL  SCHED_MC  JUMP_LABEL  PCIEPORTBUS
    CFI_CLANG（并入 CONFIG_CFI）  WATCHDOG_PRETIMEOUT_GOV  THERMAL_DEBUGFS

## 附录 C：本文引用的 6.1 Kconfig 依赖（源码核对）

    mm/damon/Kconfig:
      DAMON_PADDR  depends on DAMON && MMU
      DAMON_RECLAIM depends on DAMON_PADDR
      DAMON_LRU_SORT depends on DAMON_PADDR
      DAMON_DBGFS  depends on DAMON_VADDR && DAMON_PADDR && DEBUG_FS（6.14 起上游移除）
    mm/Kconfig:
      READ_ONLY_THP_FOR_FS depends on TRANSPARENT_HUGEPAGE && SHMEM（标 EXPERIMENTAL）
    init/Kconfig:
      CFS_BANDWIDTH depends on FAIR_GROUP_SCHED（原厂 FAIR_GROUP_SCHED=y，故历史上「可开」，但实测 bootloop）
      CGROUP_PIDS 无依赖（原厂未开，实测 bootloop）
      **无 MEMCG_SWAP 符号**（6.1 起由 MEMCG 统一处理）
    security/landlock:
      6.1 ABI = LANDLOCK_ABI_VERSION 2（LANDLOCK_LAST_ACCESS_FS = REFER，无 NET/无 IOCTL/SCOPE）
      6.12 = 含 NET（6.7）、IOCTL_DEV（6.10）、SCOPE_SIGNAL（6.12），即 ABI v6

---

*本文只做分析与可行性判定，未修改除本文件外的任何文件，未执行构建/刷机。*
