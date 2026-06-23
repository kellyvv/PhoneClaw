# 第四部分：高级能力 + App Extension

---

## 26. 🔮 AR 增强现实 — ARKit + RealityKit

### 权限配置
```
Info.plist: NSCameraUsageDescription (共用相机权限)
设备要求: A12+ 芯片 (iPhone XS+), LiDAR (iPhone 12 Pro+)
```

### 可调用 API

| API | 框架 | 能力 |
|-----|------|------|
| `ARSession` | ARKit | AR 会话管理 |
| `ARWorldTrackingConfiguration` | ARKit | 6DOF 世界追踪 |
| `ARPlaneDetection` | ARKit | 平面检测（水平/垂直）|
| `ARMeshAnchor` | ARKit | LiDAR 网格扫描 |
| `ARFaceTrackingConfiguration` | ARKit | 前置摄像头面部追踪 |
| `ARBodyTrackingConfiguration` | ARKit | 全身骨骼追踪 |
| `ARGeoTrackingConfiguration` | ARKit | 地理位置 AR 锚点 |
| `ARAnchor` | ARKit | 在 3D 空间中放置锚点 |
| `ARRaycastQuery` | ARKit | 射线检测（点击空间位置）|
| `RealityView` | RealityKit | 3D 渲染视图 |
| `ModelEntity` | RealityKit | 3D 模型实体 |
| `Entity.generateText()` | RealityKit | 3D 文字 |

### Agent Skills

```
skill: ar_measure
  → ARKit 平面检测 + 用户标记两点
  → 返回: { distance: "1.82m" }
  → "这面墙宽1米82"

skill: ar_scene_understand
  → ARKit 世界追踪 + 平面检测
  → 返回: { planes: [{type:"floor", size:{w:4,h:3}},
                      {type:"wall", count:3}],
            meshVertices: 12400 }

skill: ar_place_info
  → 拍照识别物体 → 在 AR 空间中放置信息标签
  → 用户看到的: 物体旁漂浮着说明文字

skill: ar_face_mesh
  → ARFaceTrackingConfiguration → 52个表情系数
  → 返回: { blendShapes: { jawOpen: 0.3, eyeBlinkLeft: 0.0, ... } }

skill: ar_room_scan
  → LiDAR 扫描房间 3D 结构
  → 返回房间尺寸、家具位置估计
```

---

## 27. 📹 屏幕录制 — ReplayKit

### 权限配置
```
系统自动弹窗请求用户确认，无需 Info.plist
```

### 可调用 API

| API | 框架 | 能力 |
|-----|------|------|
| `RPScreenRecorder.shared().startRecording()` | ReplayKit | 开始录屏 |
| `RPScreenRecorder.shared().stopRecording()` | ReplayKit | 停止录屏 |
| `RPScreenRecorder.shared().startCapture()` | ReplayKit | 逐帧捕获屏幕内容 |
| `RPPreviewViewController` | ReplayKit | 预览和保存录制 |
| `RPBroadcastActivityViewController` | ReplayKit | 直播推流 |

### Agent Skills

```
skill: screen_record_start → 开始录屏
skill: screen_record_stop  → 停止录屏并保存
skill: screen_capture_frame → 捕获当前屏幕帧 → Gemma 4 分析屏幕内容
```

> **重要**: `startCapture` 可以逐帧获取屏幕图像，
> 这意味着 Agent 可以"看到"屏幕上的内容并理解！

---

## 28. 👁 Focus 状态 — 专注模式

### 权限配置
```
Info.plist: NSFocusStatusUsageDescription
```

### 可调用 API

| API | 框架 | 能力 |
|-----|------|------|
| `INFocusStatusCenter.default.focusStatus` | Intents | 读取当前 Focus 状态 |
| `.isFocused` | Intents | 是否处于专注模式 |

### Agent Skill

```
skill: focus_status
  → INFocusStatusCenter.default.focusStatus
  → 返回: { focused: true }
  → Agent 据此调整行为（专注模式下减少打扰）
```

---

## 29. 🔍 Spotlight 搜索 — CoreSpotlight

### 权限: 无需

| API | 框架 | 能力 |
|-----|------|------|
| `CSSearchableItem` | CoreSpotlight | 创建可搜索条目 |
| `CSSearchableIndex.default().indexSearchableItems()` | CoreSpotlight | 索引到系统搜索 |
| `CSSearchableItemAttributeSet` | CoreSpotlight | 设置标题/描述/缩略图 |

### Agent Skill

```
skill: spotlight_index
  → 将 Agent 的对话、笔记、分析结果索引到 Spotlight
  → 用户在系统搜索中能找到 Agent 产生的内容
```

---

## 30. 📊 WidgetKit — 桌面小组件

### 权限: 无需 (通过 App Extension)

| API | 框架 | 能力 |
|-----|------|------|
| `TimelineProvider` | WidgetKit | 提供小组件数据 |
| `Widget` | WidgetKit | 定义小组件 UI |
| `TimelineEntry` | WidgetKit | 时间线条目 |
| App Intents 交互 | WidgetKit + App Intents | 小组件按钮交互 |

### Agent Skill

```
Agent 在桌面小组件上显示:
  - 今日健康摘要（步数/心率/睡眠）
  - 下一个日程
  - 待办提醒数量
  - 天气 + AI 建议
  - 快捷操作按钮（拍照识别、语音输入、快速记录）
```

---

## 31. 🏃 Live Activity — 锁屏实时信息

### 权限: 无需

| API | 框架 | 能力 |
|-----|------|------|
| `ActivityKit.Activity.request()` | ActivityKit | 启动 Live Activity |
| `Activity.update()` | ActivityKit | 更新实时数据 |
| `Activity.end()` | ActivityKit | 结束 Live Activity |
| Dynamic Island UI | ActivityKit | 灵动岛显示 |

### Agent Skill

```
skill: live_activity_start
  → Agent 在锁屏/灵动岛显示实时信息:
    - 会议倒计时
    - 运动实时数据
    - 导航进度
    - "正在分析你的照片 (3/10)..."
```

---

## 32. 📞 VoIP — CallKit

### 权限: 需 VoIP 相关 entitlement

| API | 框架 | 能力 |
|-----|------|------|
| `CXProvider` | CallKit | 管理来电/去电 UI |
| `CXCallController` | CallKit | 发起/结束通话 |
| `CXCallAction` | CallKit | 通话操作（接听/挂断/静音/保持）|

### Agent Skill

```
skill: call_display
  → Agent 发起的语音对话显示为原生通话界面
  → 锁屏显示来电界面，接听后进入 Agent 语音对话
```

---

## 33. ♿ 辅助功能 — Accessibility

### 权限: 无需（App 内读取自身 UI 层级）

| API | 框架 | 能力 |
|-----|------|------|
| `UIAccessibility.post(notification:)` | UIKit | 发送无障碍通知 |
| `UIAccessibility.isVoiceOverRunning` | UIKit | VoiceOver 是否开启 |
| `UIAccessibility.isReduceMotionEnabled` | UIKit | 减少动画是否开启 |
| `UIAccessibility.isBoldTextEnabled` | UIKit | 粗体文字是否开启 |
| `UIAccessibility.preferredContentSizeCategory` | UIKit | 用户字体大小偏好 |

### Agent Skill

```
skill: accessibility_check
  → 检测用户的辅助功能设置
  → Agent 自适应: VoiceOver 模式下自动语音回复
  → 大字体模式下调整 UI
```

---

## 34. ⏰ 后台任务 — BackgroundTasks

### 权限配置
```
Background Mode: Background fetch + Background processing
Info.plist: BGTaskSchedulerPermittedIdentifiers
```

| API | 框架 | 能力 |
|-----|------|------|
| `BGAppRefreshTask` | BackgroundTasks | 短任务 (~30秒)，定期刷新 |
| `BGProcessingTask` | BackgroundTasks | 长任务，设备充电或空闲时执行 |
| `BGTaskScheduler.shared.register()` | BackgroundTasks | 注册后台任务 |
| `BGTaskScheduler.shared.submit()` | BackgroundTasks | 提交任务请求 |

### Agent Skills

```
skill: bg_refresh
  → BGAppRefreshTask: 定期获取天气/日历变化/健康数据
  → 有重要变化时推送通知

skill: bg_process
  → BGProcessingTask: 夜间充电时:
    - 整理照片分类
    - 生成健康周报
    - 更新 ML 模型
    - 索引新联系人/日历事件
```

---

## 35. 🗣 Siri 集成 — SiriKit + App Intents

### 权限配置
```
Info.plist: NSSiriUsageDescription
```

| API | 框架 | 能力 |
|-----|------|------|
| `INInteraction.donate()` | Intents | 向 Siri 贡献用户行为 |
| `INShortcut` | Intents | 创建 Siri 快捷方式 |
| `AppIntent` + `AppShortcutsProvider` | App Intents | 自动注册到 Siri |

### Agent Skill

```
所有 Agent Skill 通过 App Intents 暴露给 Siri:
  "Hey Siri, 用 PhoneClaw 查一下我今天走了多少步"
  "Hey Siri, PhoneClaw 帮我安排明天下午的会议"
  "Hey Siri, PhoneClaw 分析我复制的内容"
```
