# NX721J Droidspaces Kernel

为 **nubia NX721J（Z60 Ultra，sm8650）** 构建支持 Droidspaces 的 GKI 内核。

## 构建配方

| 项目 | 值 |
|---|---|
| 源码 | Android Common Kernel android14-6.1 @ `716498f88d0f`（与设备原厂内核同源） |
| 编译器 | AOSP clang `r487747c`（17.0.2，与原厂完全一致） |
| 基础配置 | 设备自身 `/proc/config.gz`（MyOS 14.5.6MR2） |
| kABI 补丁 | Droidspaces 官方 SYSVIPC 补丁（`3_4_5` 变体） |
| 版本字符串 | `6.1.68-android14-11-g716498f88d0f-ab11695701`（保持与原厂一致） |
| 模块签名 | 嵌入原厂公钥证书，关闭 `MODULE_SIG_PROTECT` |

## 产物

`out/Image` — 替换 `boot.img` 中的 kernel 即可（boot.img 头部 kernel_size 需同步更新）。

## ⚠️ 绝对不能启用的选项

`CONFIG_CFS_BANDWIDTH` 和 `CONFIG_CGROUP_PIDS` **会改变调度器/cgroup 结构体，
导致厂商预编译模块（434 个）CRC 不匹配而拒绝加载 → 无限重启**。

不重建全部厂商模块就无法启用它们（Droidspaces 的 `--cpus` / `--pids-limit` 因此不可用）。

## 已验证的工作配置

```
CONFIG_SYSVIPC=y          CONFIG_POSIX_MQUEUE=y
CONFIG_IPC_NS=y           CONFIG_PID_NS=y
CONFIG_USER_NS=y          CONFIG_DEVTMPFS=y
CONFIG_TMPFS_POSIX_ACL=y  CONFIG_TMPFS_XATTR=y
CONFIG_MACVLAN=y          CONFIG_IP6_NF_NAT=y
CONFIG_IP_SET=y           CONFIG_NETFILTER_XT_MATCH_ADDRTYPE=y
CONFIG_USB_CONFIGFS_F_HID=y（HID 攻击内置支持）
# CONFIG_CFS_BANDWIDTH is not set
# CONFIG_CGROUP_PIDS is not set
# CONFIG_MODULE_SIG_PROTECT is not set
```

## 刷入方式

用 9008（EDL）写入 `boot_a`，或 root 后用任意内核刷写工具。刷入前务必备份原厂 boot 分区。
