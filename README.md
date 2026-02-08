# boox-telecom-fix

> 解除文石 P6 Pro 小彩马的电话和短信封锁
>
> Unlock calling and SMS on Boox P6 Pro

[![Firmware](https://img.shields.io/badge/Firmware-4.1.x-orange)](#)
[![Magisk Module](https://img.shields.io/badge/Magisk_Module-v30.6-brightgreen)](#)
[![SoC](https://img.shields.io/badge/SoC-SM7225-red)](#)

**[中文](#中文) | [English](#english)**

---

# 中文

## 问题

文石 P6 Pro 小彩马配备了完整的电话功能硬件和 SIM 卡槽，但在软件层面禁用了电话和短信功能。插入 SIM 卡后可以使用蜂窝数据，但无法拨打/接听电话或收发短信。

值得一提的是，文石在 2025 年 12 月 22 日发布的固件中曾短暂解禁了电话和短信功能，但很快在后续版本的固件更新中重新封堵。本模块的目的就是绕过这一限制，在新固件版本（2025-12-27）上恢复电话和短信功能。

具体表现：

- **拨出电话**：拨号界面正常，点击拨打后静默失败，无任何提示
- **来电接听**：来电时设备无任何响铃或通知，来电被静默丢弃
- **短信**：短信应用正常打开，点击发送按钮无反应；也无法接收短信

## 原因分析

通过逆向分析 Boox 固件中的 `Telecom.apk` 和 `telephony-common.jar` 的 DEX 字节码，发现了三处独立的拦截机制：

### 拨出电话拦截

位于 `/system/priv-app/Telecom/Telecom.apk` 中的 `TelecomServiceImpl`：

- 初始化时将 `mEnableCallingFeature`（AtomicBoolean）硬编码为 `false`
- 拨号时 `placeCall()` 调用 `isCallsEnabled()` 检查该标志，为 `false` 则静默丢弃呼叫
- 日志输出：`placeCall Disable , callsEnabled false`
- 但同时暴露了 binder 方法 `enableTelephonyCallingFeature(boolean)`（事务码 60），可以远程设置该标志

### 来电拦截

同样位于 `TelecomServiceImpl` 中，`addNewIncomingCall()` 方法包含**双重拦截**：

1. 首先检查 `isCallsEnabled()`（与拨出电话相同的标志）
2. 即使 `callsEnabled` 为 `true`，还会检查 `isDefaultDialerPackage()`——如果当前默认拨号器是 Boox 内置的 `org.codeaurora.dialer`，则**静默丢弃来电**

这意味着即使通过 `service call telecom 60 i32 1` 启用了电话功能，来电仍然会被第二道检查拦截。日志输出：

```
addNewIncomingCall Disable , callsEnabled true
```

注意 `callsEnabled true` 已经为真，但来电仍被拦截。逆向分析确认了拦截逻辑（DEX 偏移 `0x5ee04`）：

```
0007: if-eqz v0, +194      // callsEnabled == false → 拦截
000f: if-eqz v2, +4        // isDefaultDialerPackage == false → 放行
0011: goto/16 +184          // isDefaultDialerPackage == true → 拦截！
```

### 短信拦截

位于 `/system/framework/telephony-common.jar` 中的 `SmsController` 和 `SmsFeatureController`：

- `SmsFeatureController` 维护 `mEnableSmsFeature`（AtomicBoolean），默认为 `false`
- `SmsController.isSmsEnabled()` 委托给 `SmsFeatureController.getInstance().isSmsEnabled()`
- 发送短信时 `sendTextForSubscriberWithOptions()` 检查 `isSmsEnabled()`，为 `false` 则拦截
- 接收短信时 `onSmsReceived()` 同样检查该标志，导致**收发都被拦截**
- 日志输出：`sendTextForSubscriberWithOptions() Sms Disable, smsEnabled false`
- 与电话不同，`enableTelephonySmsFeature()` 方法**未暴露**在任何 binder 接口上，无法通过 `service call` 启用

## 修复方式

本模块采用三种策略分别解决拨出电话、来电接听和短信问题：

### 拨出电话修复（运行时）

通过 `service.sh` 在每次开机时执行：

```bash
service call telecom 60 i32 1
```

这会调用 `enableTelephonyCallingFeature(true)`，将 `mEnableCallingFeature` 设为 `true`，解除拨出电话拦截。

### 来电接听修复（运行时）

通过 `service.sh` 在每次开机时执行：

```bash
telecom set-default-dialer com.google.android.dialer
```

将默认拨号器从 Boox 内置的 `org.codeaurora.dialer` 切换为 `com.google.android.dialer`，绕过 `addNewIncomingCall` 中的第二道拦截。

> **注意**：`com.google.android.dialer` 不需要实际安装在设备上。该命令只是改变系统的默认拨号器设置值——`isDefaultDialerPackage()` 检查的是当前默认拨号器是否为 `org.codeaurora.dialer`，切换后该检查返回 `false`，来电即被放行。

### 短信修复（DEX 补丁）

由于启用方法未暴露在 binder 接口上，采用 DEX 字节码补丁方式修改 `telephony-common.jar`：

将 `SmsFeatureController.isSmsEnabled()` 方法修改为永远返回 `true`：

```
偏移:    0x115154
修补前:  54 00 ba 0f 6e 10 85 57 00 00 0a 00 0f 00
         (iget-object + invoke-virtual AtomicBoolean.get() + move-result + return)
修补后:  12 10 0f 00 00 00 00 00 00 00 00 00 00 00
         (const/4 v0, 1 + return v0 + nop 填充)
```

修补后重新计算了 DEX 的 SHA-1 签名和 Adler32 校验和。

| 场景 | 修补前 | 修补后 |
|------|--------|--------|
| 普通短信收发 | 被拦截 ❌ | 正常工作 ✅ |
| AtomicBoolean 状态 | 被绕过，不再检查 | 被绕过，不再检查 |

## 前置条件

- Boox P6 Pro 已 Root（Magisk）
- Root 教程参考 [boox-p6pro-root](https://github.com/dynamicfire/boox-p6pro-root)

## 安装

从 [Releases](https://github.com/dynamicfire/boox-telecom-fix/releases) 下载 `boox-telecom-fix-v1.3.zip`。

**方式一**：通过 Magisk App

1. 打开 Magisk → 模块 → 从本地安装
2. 选择 zip 文件
3. 重启

**方式二**：通过命令行

```bash
adb push boox-telecom-fix-v1.3.zip /sdcard/
adb shell su -c 'magisk --install-module /sdcard/boox-telecom-fix-v1.3.zip'
adb reboot
```

## 安装拨号器和短信应用

解锁后，你可能还需要自行安装第三方拨号器和短信应用才能正常使用电话和短信功能。推荐：

- **拨号器**：[Google Phone](https://play.google.com/store/apps/details?id=com.google.android.dialer)、[Fossify Phone](https://f-droid.org/packages/org.fossify.phone/)
- **短信**：[Google Messages](https://play.google.com/store/apps/details?id=com.google.android.apps.messaging)、[Fossify SMS Messenger](https://f-droid.org/packages/org.fossify.messages/)

安装后需要在系统设置中将其设为默认应用。

## 验证

重启后检查日志：

```bash
adb shell su -c 'cat /data/local/tmp/telecom-fix.log'
```

测试电话：

```bash
adb shell am start -a android.intent.action.CALL -d tel:10010
```

测试短信：打开短信应用，向 10010 发送任意内容，确认发送成功并能收到回复。

## 手动使用（不安装模块）

电话功能可以临时启用（重启后失效）：

```bash
# 启用拨出电话
adb shell su -c 'service call telecom 60 i32 1'
# 启用来电接听
adb shell su -c 'telecom set-default-dialer com.google.android.dialer'
```

短信功能无法通过命令行临时启用，必须使用本模块的 JAR 补丁。

## 卸载

通过 Magisk App 删除模块，或命令行：

```bash
adb shell su -c 'rm -rf /data/adb/modules/boox-telecom-fix'
adb reboot
```

## 兼容性

| 设备 | 固件 | 拨出电话 | 来电接听 | 短信 |
|------|------|----------|----------|------|
| Boox P6 Pro 小彩马 | 4.1 (SM7225) | ✅ | ✅ | ✅ |

电话的事务码（60）和短信的 DEX 补丁偏移可能因设备/固件版本而异。如需适配其他设备，参考[故障排除](#故障排除)部分。

## 故障排除

### 电话仍然无法拨打

检查日志。如果显示 `telecom service not found`，可能需要更多启动时间。编辑模块目录下的 `service.sh`（`/data/adb/modules/boox-telecom-fix/service.sh`），增加等待时间。

### 在其他设备上查找正确的事务码

如果事务码 60 在你的设备上无效：

```bash
adb shell su

logcat -s TelecomFramework 2>/dev/null | grep -i "enableTelephony\|callsEnabled" &

for i in $(seq 55 80); do
    echo "--- code $i ---"
    service call telecom $i i32 1
done

# 测试拨号
am start -a android.intent.action.CALL -d tel:10010
```

### 短信仍然无法收发

确认模块已正确安装并且 `telephony-common.jar` 被替换：

```bash
adb shell su -c 'ls -la /data/adb/modules/boox-telecom-fix/system/framework/'
```

如果文件存在但仍不工作，可能存在 oat 预编译缓存：

```bash
adb shell su -c 'ls /system/framework/oat/*/telephony-common.*'
```

若存在 oat 文件，需要在模块中添加对应的空文件覆盖。

## 与其他模块的兼容性

本模块与 [boox-ams-fix](https://github.com/dynamicfire/boox-ams-fix) 完全兼容，可以同时安装：

- **boox-ams-fix**：替换 `services.jar`（修复 Magisk App 崩溃）
- **boox-telecom-fix**：替换 `telephony-common.jar`（解除短信拦截）+ `service.sh`（解除电话拦截 + 来电拦截）

## 注意事项

- 本模块的 JAR 补丁专门针对固件 4.1 的 `telephony-common.jar`，其他固件版本不适用
- 如果文石后续更新固件修复了此问题，应卸载本模块
- OTA 更新后可能需要重新安装

## 相关项目

- [boox-p6pro-root](https://github.com/dynamicfire/boox-p6pro-root) — P6 Pro 小彩马完整 Root 指南（包含 EDL 解锁 Bootloader）
- [boox-ams-fix](https://github.com/dynamicfire/boox-ams-fix) — 修复 Boox 4.1.x 上 Magisk App 崩溃

---

# English

## Problem

The Boox P6 Pro has full telephony hardware and a SIM card slot, but calling and SMS are disabled at the software level. The SIM card works for cellular data, but you cannot make/receive calls or send/receive text messages.

Notably, Boox briefly enabled calling and SMS in the firmware released on December 22, 2025, but quickly re-disabled these features in subsequent firmware updates. This module bypasses that restriction and restores calling and SMS on newer firmware version.

Symptoms:

- **Outgoing calls**: Dialer UI works, but pressing call silently fails with no feedback
- **Incoming calls**: Device shows no ringing or notification when called; incoming calls are silently dropped
- **SMS**: Messaging app opens normally, but the send button does nothing; incoming SMS is also blocked

## Root Cause

Reverse engineering of the DEX bytecode in `Telecom.apk` and `telephony-common.jar` revealed three independent blocking mechanisms:

### Outgoing Call Blocking

In `TelecomServiceImpl` inside `/system/priv-app/Telecom/Telecom.apk`:

- `mEnableCallingFeature` (AtomicBoolean) is hardcoded to `false` on initialization
- `placeCall()` checks `isCallsEnabled()` and silently drops the call if the flag is false
- Log: `placeCall Disable , callsEnabled false`
- A binder method `enableTelephonyCallingFeature(boolean)` (transaction code 60) is exposed but never called with `true`

### Incoming Call Blocking

Also in `TelecomServiceImpl`, the `addNewIncomingCall()` method has a **dual gate**:

1. First checks `isCallsEnabled()` (same flag as outgoing calls)
2. Even if `callsEnabled` is `true`, it also checks `isDefaultDialerPackage()` — if the current default dialer is Boox's built-in `org.codeaurora.dialer`, incoming calls are **silently dropped**

This means even after enabling calling via `service call telecom 60 i32 1`, incoming calls are still blocked by the second check. Log output:

```
addNewIncomingCall Disable , callsEnabled true
```

Note that `callsEnabled true` is already set, but incoming calls are still blocked. Reverse engineering confirmed the blocking logic (DEX offset `0x5ee04`):

```
0007: if-eqz v0, +194      // callsEnabled == false → block
000f: if-eqz v2, +4        // isDefaultDialerPackage == false → allow
0011: goto/16 +184          // isDefaultDialerPackage == true → block!
```

### SMS Blocking

In `SmsController` and `SmsFeatureController` inside `/system/framework/telephony-common.jar`:

- `SmsFeatureController` maintains `mEnableSmsFeature` (AtomicBoolean), defaults to `false`
- `SmsController.isSmsEnabled()` delegates to `SmsFeatureController.getInstance().isSmsEnabled()`
- `sendTextForSubscriberWithOptions()` checks `isSmsEnabled()` — blocked if false
- `onSmsReceived()` also checks the same flag — **both sending and receiving are blocked**
- Log: `sendTextForSubscriberWithOptions() Sms Disable, smsEnabled false`
- Unlike calling, `enableTelephonySmsFeature()` is **not exposed** on any binder interface, so `service call` cannot enable it

## The Fix

This module uses three different strategies:

### Outgoing Call Fix (Runtime)

`service.sh` runs on every boot:

```bash
service call telecom 60 i32 1
```

This invokes `enableTelephonyCallingFeature(true)`, setting `mEnableCallingFeature` to `true`.

### Incoming Call Fix (Runtime)

`service.sh` also runs on every boot:

```bash
telecom set-default-dialer com.google.android.dialer
```

This switches the default dialer from Boox's built-in `org.codeaurora.dialer` to `com.google.android.dialer`, bypassing the second gate in `addNewIncomingCall`.

> **Note**: `com.google.android.dialer` does not need to be actually installed on the device. The command only changes the system's default dialer setting — `isDefaultDialerPackage()` checks whether the current default dialer is `org.codeaurora.dialer`, and after the switch it returns `false`, allowing incoming calls through.

### SMS Fix (DEX Patch)

Since the enable method is not exposed via binder, the module patches `telephony-common.jar` directly:

`SmsFeatureController.isSmsEnabled()` is modified to always return `true`:

```
Offset:  0x115154
Before:  54 00 ba 0f 6e 10 85 57 00 00 0a 00 0f 00
         (iget-object + invoke-virtual AtomicBoolean.get() + move-result + return)
After:   12 10 0f 00 00 00 00 00 00 00 00 00 00 00
         (const/4 v0, 1 + return v0 + nop padding)
```

DEX SHA-1 signature and Adler32 checksum were recalculated after patching.

| Scenario | Before Patch | After Patch |
|----------|-------------|-------------|
| SMS send/receive | Blocked ❌ | Works ✅ |
| AtomicBoolean state | Bypassed, no longer checked | Bypassed, no longer checked |

## Prerequisites

- Boox P6 Pro with root access (Magisk)
- For rooting instructions, see [boox-p6pro-root](https://github.com/dynamicfire/boox-p6pro-root)

## Installation

Download `boox-telecom-fix-v1.3.zip` from the [Releases](https://github.com/dynamicfire/boox-telecom-fix/releases) page.

**Option 1**: Via Magisk App

1. Open Magisk → Modules → Install from storage
2. Select the zip file
3. Reboot

**Option 2**: Via command line

```bash
adb push boox-telecom-fix-v1.3.zip /sdcard/
adb shell su -c 'magisk --install-module /sdcard/boox-telecom-fix-v1.3.zip'
adb reboot
```

## Install Dialer and SMS Apps

After unlocking, you may need to install third-party dialer and SMS apps to actually use calling and messaging. Recommended:

- **Dialer**: [Google Phone](https://play.google.com/store/apps/details?id=com.google.android.dialer), [Fossify Phone](https://f-droid.org/packages/org.fossify.phone/)
- **SMS**: [Google Messages](https://play.google.com/store/apps/details?id=com.google.android.apps.messaging), [Fossify SMS Messenger](https://f-droid.org/packages/org.fossify.messages/)

After installation, set them as default apps in system settings.

## Verification

After reboot, check the log:

```bash
adb shell su -c 'cat /data/local/tmp/telecom-fix.log'
```

Test calling:

```bash
adb shell am start -a android.intent.action.CALL -d tel:10010
```

Test SMS: Open the messaging app, send any text to 10010, and confirm you can both send and receive.

## Manual Usage (Without Module)

Calling can be temporarily enabled (resets on reboot):

```bash
# Enable outgoing calls
adb shell su -c 'service call telecom 60 i32 1'
# Enable incoming calls
adb shell su -c 'telecom set-default-dialer com.google.android.dialer'
```

SMS cannot be temporarily enabled via command line — the JAR patch in this module is required.

## Uninstall

Remove through Magisk App, or via command line:

```bash
adb shell su -c 'rm -rf /data/adb/modules/boox-telecom-fix'
adb reboot
```

## Compatibility

| Device | Firmware | Outgoing Calls | Incoming Calls | SMS |
|--------|----------|----------------|----------------|-----|
| Boox P6 Pro | 4.1 (SM7225) | ✅ | ✅ | ✅ |

The transaction code (60) and DEX patch offset may differ on other devices or firmware versions. See [Troubleshooting](#troubleshooting) for guidance on adapting to other devices.

## Troubleshooting

### Calling still doesn't work

Check the log. If it shows `telecom service not found`, the service may need more startup time. Edit `service.sh` in the module directory (`/data/adb/modules/boox-telecom-fix/service.sh`) and increase the wait delay.

### Finding the correct transaction code on other devices

If code 60 doesn't work on your device:

```bash
adb shell su

logcat -s TelecomFramework 2>/dev/null | grep -i "enableTelephony\|callsEnabled" &

for i in $(seq 55 80); do
    echo "--- code $i ---"
    service call telecom $i i32 1
done

# Test calling
am start -a android.intent.action.CALL -d tel:10010
```

### SMS still doesn't work

Verify the module is installed and `telephony-common.jar` is replaced:

```bash
adb shell su -c 'ls -la /data/adb/modules/boox-telecom-fix/system/framework/'
```

If the file exists but SMS still fails, check for precompiled oat cache:

```bash
adb shell su -c 'ls /system/framework/oat/*/telephony-common.*'
```

If oat files exist, empty override files need to be added to the module.

## Compatibility with Other Modules

This module is fully compatible with [boox-ams-fix](https://github.com/dynamicfire/boox-ams-fix):

- **boox-ams-fix**: Replaces `services.jar` (fixes Magisk App crash)
- **boox-telecom-fix**: Replaces `telephony-common.jar` (unlocks SMS) + `service.sh` (unlocks outgoing and incoming calls)

They replace different system files and do not interfere with each other.

## Notes

- The JAR patch targets `telephony-common.jar` from firmware 4.1 specifically; other firmware versions are not supported
- If Boox fixes this in a future firmware update, uninstall this module
- May need to be reinstalled after OTA updates

## Related Projects

- [boox-p6pro-root](https://github.com/dynamicfire/boox-p6pro-root) — Full root guide for P6 Pro (includes EDL bootloader unlock)
- [boox-ams-fix](https://github.com/dynamicfire/boox-ams-fix) — Fix Magisk App crash on Boox firmware 4.1.x

## Module Info

```
id=boox-telecom-fix
name=Boox P6 Pro Telecom Fix (Call + SMS)
version=v1.3
author=玄昼
```

The module uses Magisk's systemless overlay to replace `/system/framework/telephony-common.jar` without modifying the actual system partition. Safe to uninstall at any time.

## License

MIT
