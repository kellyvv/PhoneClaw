# 第三部分（续）：无需权限的系统 API

---

## 21. ⚡ 触觉反馈 — Core Haptics

### 权限: 无需

| API | 能力 |
|-----|------|
| `UIImpactFeedbackGenerator` | 碰撞反馈 (轻/中/重) |
| `UISelectionFeedbackGenerator` | 选择反馈 |
| `UINotificationFeedbackGenerator` | 通知反馈 (成功/警告/错误) |
| `CHHapticEngine` + `CHHapticPattern` | 自定义震动模式编排 |

### Skill: `haptic_feedback` → Agent 回复/错误/导航时触觉确认

---

## 22. 📺 设备信息 — UIDevice / UIScreen / ProcessInfo

### 权限: 无需

| API | 能力 |
|-----|------|
| `UIScreen.main.brightness` | 获取/设置屏幕亮度 |
| `UIDevice.current.batteryLevel` | 电池电量 |
| `UIDevice.current.batteryState` | 充电状态 |
| `UIDevice.current.model` | 设备型号 |
| `UIDevice.current.systemVersion` | iOS 版本 |
| `ProcessInfo.processInfo.thermalState` | 设备温度状态 |
| `ProcessInfo.processInfo.isLowPowerModeEnabled` | 低电量模式 |
| `ProcessInfo.processInfo.physicalMemory` | 物理内存 |

### Skills
```
skill: device_info       → 返回设备型号/版本/电量/温度
skill: screen_brightness → 读取或调节屏幕亮度
skill: battery_status    → 电量 + 充电状态 + 低电量模式
```

---

## 23. 🔑 Keychain — Security Framework

### 权限: 无需 (沙箱内自动可用)

| API | 能力 |
|-----|------|
| `SecItemAdd()` | 加密存储密钥/密码 |
| `SecItemCopyMatching()` | 查询存储项 |
| `SecItemUpdate()` / `SecItemDelete()` | 更新/删除 |

### Skill: Agent 安全存储 API 密钥和用户凭证

---

## 24. 💾 UserDefaults — 轻量存储

### 权限: 无需 (需 Privacy Manifest 声明)

用途: Agent 记忆用户偏好（语言、目标、人格设置）

---

## 25. 🎙 语音合成 — AVSpeechSynthesizer

### 权限: 无需

| API | 能力 |
|-----|------|
| `AVSpeechSynthesizer.speak()` | 文字转语音 |
| `AVSpeechSynthesisVoice` | 选择语言/声音 |
| `.rate` / `.pitchMultiplier` / `.volume` | 语速/音调/音量 |

### Skill: `tts_speak` → Agent 语音回复用户
