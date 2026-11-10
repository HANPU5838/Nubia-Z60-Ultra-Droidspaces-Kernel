# 🛠️ 疑难解答与恢复指南

## 一、刷入内核后无限重启怎么办

### 症状
- 卡在开机动画 / 反复重启
- adb 无法连接

### 恢复步骤（9008 / EDL）

1. 手机关机，按住音量键进入 9008 模式（或用电脑 adb reboot edl）
2. 用 9008 工具刷回原厂 boot 分区：

```bash
python3 edl.py --memory=UFS --loader=prog_ufs_firehose_sm8650_ddr.elf \
    w boot_a 原厂boot备份.img
python3 edl.py --loader=prog_ufs_firehose_sm8650_ddr.elf reset --resetmode=ufs
```

> 建议刷机前先用 `edl.py r boot_a boot_a_current.img` 备份原厂 boot。

### 常见原因对照

| 现象 | 可能原因 | 处理 |
|---|---|---|
| 开机动画卡死 + adb 可连 + 日志有 `exports protected symbol` | MODULE_SIG_PROTECT 拦截厂商模块 | 关闭该选项 / 嵌入原厂公钥证书 |
| 无限重启 + adb 不可连 | 模块 CRC 不匹配（结构体布局改变） | 不要开启 CFS_BANDWIDTH / CGROUP_PIDS |
| 无限重启 + pstore 无记录 | 用户态 init 启动失败 | 检查 cgroup 配置；回滚 |
| 刷入后不启动、无任何反应 | boot.img 打包错误 | 重新打包并核对 kernel_size |

## 二、如何确认当前运行的内核

```bash
adb shell uname -r
# 6.1.68-android14-11-g716498f88d0f-ab11695701 = 原厂版本字符串（自制内核也保持一致）

# 区分原厂/自制：看 SYSVIPC
adb shell "zcat /proc/config.gz | grep CONFIG_SYSVIPC"
# CONFIG_SYSVIPC=y → 自制内核；无输出 → 原厂
```

## 三、刷入后 Magisk root 丢失怎么办

Magisk 位于 `init_boot` 分区，与内核（`boot` 分区）分离：
- 只刷内核 → root 保留
- 刷了 init_boot → 需要重新用 Magisk 补丁 init_boot

```bash
# 检查 root
adb shell su -c id
```

## 四、如何确认 WiFi monitor 模式支持

```bash
adb shell su -c "/system/bin/iw phy | grep -A8 'Supported interface modes'"
# 出现 * monitor 即支持

# 正确开启（QCACLD 驱动）
adb shell su -c "ip link set wlan0 down"
adb shell su -c "echo 4 > /sys/module/qca_cld3_kiwi_v2/parameters/con_mode"
adb shell su -c "ip link set wlan0 up"
adb shell su -c "/system/bin/iw dev wlan0 info"
```

## 五、EDL 相关已知问题

| 问题 | 原因 | 解决 |
|---|---|---|
| firehose 卡住无响应 | 会话被中途 kill | 手机物理断电重进 9008 |
| reset 命令报 usage | 传了 `--memory` | reset 不要带 `--memory` |
| 读回哈希不一致 | 写入中断 | 重新写入并回读校验 |

## 六、构建相关

| 问题 | 原因 | 解决 |
|---|---|---|
| `No rule to make target 'Image'` | 没设 ARCH | `make ARCH=arm64 LLVM=1` |
| 版本字符串多 `+` | setlocalversion 在 git 仓库内 | 空 `.scmversion` + `LOCALVERSION=` |
| 补丁 Hunk 失败 | 变体与内核版本不匹配 | 换 `1_2_3` / `3_4_5` / `6_7_8` 变体 |
| ACK 下载损坏 | 网络中断 | 下载后 `tar tzf` 校验并重试 |
