# NX721J Droidspaces 内核构建

为 **nubia NX721J（Z60 Ultra，sm8650）** 构建带 Droidspaces 支持的 GKI 内核。

## 原理

| 项 | 值 |
|---|---|
| 源码 | Android Common Kernel (ACK) android14-6.1 @ `716498f88d0f`（与设备原厂内核同源） |
| 基础配置 | 设备自己的 `/proc/config.gz`（MyOS 14.5.6MR2） |
| 补丁 | Droidspaces 官方 SYSVIPC kABI 补丁（保持厂商模块可加载） |
| 版本字符串 | 保持 `6.1.68-android14-11-g716498f88d0f-ab11695701` 不变 |
| 产物 | `out/Image` + `nx721j-droidspaces-kernel.zip`（AnyKernel3） |

## 使用方法

1. 进入 Actions → `build-nx721j-droidspaces-kernel` → Run workflow
2. 等待构建完成（约 20-40 分钟）
3. 下载 artifacts：
   - `Image`：原始内核镜像
   - `nx721j-droidspaces-kernel.zip`：AnyKernel3 刷机包（用 KernelSU/Magisk 刷入）

## 说明

- 只替换 boot 分区里的内核，厂商模块（vendor_dlkm）保持原样，因为版本字符串和 kABI 都未改变
- 不含 CONFIG_CFS_BANDWIDTH / CONFIG_CGROUP_PIDS（会破坏 kABI，见 Droidspaces 官方文档）
