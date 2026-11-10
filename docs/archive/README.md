# 📦 历史实验归档

本目录保存内核增强实验的分析报告（2026-11-10）。

## 结论摘要

| 实验 | 配置 | 结果 |
|---|---|---|
| v1（当前使用） | SYSVIPC/命名空间/DEVTMPFS/证书 | ✅ 稳定 |
| v2 | +Landlock/BBR/NFTables 等 | ❌ bootloop（含 NF_TABLES ABI 破坏） |
| v3.1 | 23 项 ABI 安全增强 | ❌ bootloop |
| net 组 | 10 项网络增强 | ❌ bootloop |

**已确认的 ABI 破坏项：**
- `CONFIG_CFS_BANDWIDTH` / `CONFIG_CGROUP_PIDS`（实测 bootloop）
- `CONFIG_NF_TABLES` / `NFT_*`（struct net 偏移变化）

**尚未定位：** net 组中其余 10 项的失败原因（已拆分 n1/n2/n3 待验证）。

## 文档

- [ANALYSIS-A16.md](ANALYSIS-A16.md) — Android 16/17 内核特性回移分析
- [ANALYSIS-PERF.md](ANALYSIS-PERF.md) — ABI 安全性能增强清单
- [ANALYSIS-ENHANCE.md](ANALYSIS-ENHANCE.md) — 综合增强分析

> 这些分析对后续再尝试仍然有价值，但当前内核（v1）已回退到稳定配置。
