# 第三部分：系统集成能力

---

## 14. 📋 剪贴板 — UIPasteboard

### 权限配置
```
无需 Info.plist 声明
iOS 14+: 读取时系统顶部显示通知条
iOS 16+: 跨 App 粘贴时需用户确认弹窗
```

### 可调用 API

| API | 框架 | 能力 |
|-----|------|------|
| `UIPasteboard.general.string` | UIKit | 读取/写入剪贴板文本 |
| `UIPasteboard.general.image` | UIKit | 读取/写入剪贴板图片 |
| `UIPasteboard.general.url` | UIKit | 读取剪贴板 URL |
| `UIPasteboard.general.hasStrings` | UIKit | 检查有无文本（不触发通知）|

### Agent Skills

```
skill: clipboard_read   → 读取并分析剪贴板内容
skill: clipboard_write  → 写入翻译/格式化结果到剪贴板
skill: clipboard_analyze → 读取 → Gemma 4 自动判断类型(文本/URL/图片) → 总结/翻译
```

---

## 15. 🔔 通知 — UserNotifications

### 权限配置
```
需 UNUserNotificationCenter.requestAuthorization() 授权
```

### 可调用 API

| API | 框架 | 能力 |
|-----|------|------|
| `UNMutableNotificationContent` | UserNotifications | 通知内容（标题/正文/声音/附件）|
| `UNTimeIntervalNotificationTrigger` | UserNotifications | 延时触发 |
| `UNCalendarNotificationTrigger` | UserNotifications | 日历时间触发 |
| `UNLocationNotificationTrigger` | UserNotifications | 地点触发 |
| `UNNotificationAction` / `UNNotificationCategory` | UserNotifications | 交互按钮 |
| `UNNotificationAttachment` | UserNotifications | 富媒体附件 |

### Agent Skills

```
skill: notification_send     → 定时/延时推送本地通知
skill: notification_schedule → 重复通知（每天吃药提醒）
skill: notification_location → 到达/离开某地触发通知
skill: notification_interactive → 带操作按钮的通知
```

---

## 16. 🏠 智能家居 — HomeKit

### 权限配置
```
Info.plist: NSHomeKitUsageDescription
Entitlement: com.apple.developer.homekit
```

### 可调用 API

| API | 框架 | 能力 |
|-----|------|------|
| `HMHomeManager` | HomeKit | 获取所有家庭 |
| `HMAccessory` | HomeKit | 配件设备（灯/空调/锁等）|
| `HMCharacteristic.writeValue()` | HomeKit | 控制设备 |
| `HMCharacteristic.readValue()` | HomeKit | 读取设备状态 |
| `HMActionSet` | HomeKit | 场景执行 |
| `HMEventTrigger` / `HMTimerTrigger` | HomeKit | 自动化 |

### Agent Skills

```
skill: home_list_devices  → 列出所有房间和设备
skill: home_control       → 控制设备 (开灯/调温/关窗帘)
skill: home_read_status   → 读取设备状态
skill: home_scene         → 执行场景 ("回家模式")
skill: home_automation    → 创建自动化 (日落开灯)
skill: home_sensor_read   → 读取温湿度传感器
```

---

## 17. ⌨️ Shortcuts — App Intents

### 权限: 无需特殊权限

| API | 框架 | 能力 |
|-----|------|------|
| `AppIntent` protocol | App Intents | 定义可被 Siri/Shortcuts 调用的操作 |
| `AppShortcutsProvider` | App Intents | 自动注册快捷指令 |

Agent 的每个 Skill 都可注册为 App Intent → Siri 可直接调用。

---

## 18. 🌐 网络请求 — URLSession + Network

### 权限: 无需特殊权限（局域网需 NSLocalNetworkUsageDescription）

| API | 框架 | 能力 |
|-----|------|------|
| `URLSession.shared.data(from:)` | Foundation | HTTP 请求 |
| `URLSession.shared.download(from:)` | Foundation | 下载文件 |
| `URLSession.shared.webSocketTask()` | Foundation | WebSocket |
| `NWPathMonitor` | Network | 网络状态监听 |
| `NWBrowser` | Network | 局域网服务发现 |
| `NEHotspotConfiguration` | NetworkExtension | 程序化连接 WiFi |

### Agent Skills
```
skill: web_fetch      → HTTP 请求
skill: web_search     → 搜索 + Gemma 4 总结
skill: api_call       → 调用 REST API
skill: network_status → 网络状态查询
skill: download_file  → 下载文件到沙箱
```

---

## 19. 🔐 Face ID — LocalAuthentication

### 权限: NSFaceIDUsageDescription

| API | 能力 |
|-----|------|
| `LAContext.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics)` | 生物识别 |
| `LAContext.biometryType` | Face ID / Touch ID 检测 |

### Agent Skill
```
skill: auth_biometric → 敏感操作前要求人脸/指纹确认
```

---

## 20. 💬 邮件/短信 — MessageUI

### 权限: 无需 — 系统弹出编辑界面，用户手动确认发送

| API | 能力 |
|-----|------|
| `MFMailComposeViewController` | 编辑发送邮件（支持附件）|
| `MFMessageComposeViewController` | 编辑发送短信/iMessage |

### Agent Skills
```
skill: email_compose → 预填邮件内容，用户确认发送
skill: sms_compose   → 预填短信内容，用户确认发送
```
