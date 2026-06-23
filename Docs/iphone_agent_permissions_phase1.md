# PhoneClaw: iPhone Agent 权限全景图

> 基于 Apple 官方文档的真实 iOS API 清单，非想象。每一条都是可调用的系统能力。

## 架构核心

```
用户输入（语音/文本/拍照）
        │
        ▼
┌───────────────┐
│   Gemma 4 Gemma 4 │  ← 端侧推理，CoreML/MLX
│   (LLM Brain) │
└───────┬───────┘
        │ Function Calling (意图 → Skill 名)
        ▼
┌───────────────┐
│  Skill Router │  ← 路由到具体 iOS API 封装
└───────┬───────┘
        │
        ▼
┌───────────────────────────────────────────┐
│            iOS Skill Layer                │
│                                           │
│  每个 Skill = 一个 Swift 函数封装          │
│  接收 JSON 参数，返回 JSON 结果            │
│  所有数据不出设备                          │
└───────────────────────────────────────────┘
```

### Skill 协议定义（Swift）

```swift
protocol AgentSkill {
    var name: String { get }
    var description: String { get }
    var parameters: [SkillParameter] { get }
    
    func execute(args: [String: Any]) async throws -> SkillResult
}
```

### 权限获取方式

| 方式 | 说明 |
|------|------|
| `Info.plist` NSUsageDescription | 首次调用时弹窗请求 |
| Entitlements | Xcode Signing & Capabilities 配置 |
| 无需权限 | 沙箱内 API，直接可用 |
| Background Mode | Info.plist + BGTaskScheduler |

---

# 第一部分：硬件传感器权限（需用户授权）

---

## 1. 📷 相机 — AVFoundation + VisionKit

### 权限配置
```
Info.plist: NSCameraUsageDescription
```

### 可调用 API

| API | 框架 | 能力 |
|-----|------|------|
| `AVCaptureSession` | AVFoundation | 启动相机、获取实时帧 |
| `AVCapturePhotoOutput` | AVFoundation | 拍摄静态照片 |
| `AVCaptureMovieFileOutput` | AVFoundation | 录制视频 |
| `AVCaptureVideoDataOutput` | AVFoundation | 逐帧获取视频流（喂给 Vision/CoreML）|
| `VNDocumentCameraViewController` | VisionKit | 系统文档扫描 UI（自动裁切矫正）|
| `DataScannerViewController` | VisionKit | 实时扫码 + OCR UI |
| `VNDetectBarcodesRequest` | Vision | 条码/二维码检测 |
| `VNRecognizeTextRequest` | Vision | OCR 文字识别 |
| `VNCoreMLRequest` | Vision | 自定义 CoreML 模型推理 |
| `VNDetectFaceLandmarksRequest` | Vision | 人脸特征点检测 |
| `VNDetectHumanBodyPoseRequest` | Vision | 人体姿态检测 |
| `VNDetectHumanHandPoseRequest` | Vision | 手势检测 |
| `VNClassifyImageRequest` | Vision | 内置图像分类 |
| `VNGenerateObjectnessBasedSaliencyImageRequest` | Vision | 图像显著区域检测 |

### Agent Skills

```
skill: camera_capture
  → 拍照并返回 UIImage
  → Gemma 4 直接分析图片内容

skill: document_scan  
  → 调用 VNDocumentCameraViewController
  → 返回矫正后的文档图片
  → Gemma 4 分析文档内容并总结

skill: barcode_scan
  → VNDetectBarcodesRequest 实时扫码
  → 返回: { type: "QR", payload: "https://..." }

skill: ocr_extract
  → VNRecognizeTextRequest
  → 返回: { text: "识别到的全部文字", confidence: 0.95 }

skill: object_detect
  → VNCoreMLRequest + 自定义模型
  → 返回: { objects: [{ label: "cat", confidence: 0.92, bbox: {...} }] }

skill: face_analyze
  → VNDetectFaceLandmarksRequest
  → 返回: { faces: [{ landmarks: {...}, bbox: {...} }] }

skill: body_pose
  → VNDetectHumanBodyPoseRequest
  → 返回: { joints: { leftShoulder: {x,y}, rightKnee: {x,y}, ... } }

skill: live_scene_describe
  → AVCaptureVideoDataOutput → 逐帧送入 Gemma 4
  → 实时描述当前画面（辅助功能场景）
```

### 杀手级场景

```
用户: "帮我看看这个药盒上写了什么"
  → camera_capture → Gemma 4 图片理解
  → 返回: "这是布洛芬缓释胶囊，规格0.3g×24粒，
           有效期至2026年8月，每次1-2粒，每日2次"

用户: "扫一下这个二维码"
  → barcode_scan
  → 返回: "这是一个微信支付码，金额35元，商户: 星巴克西湖店"
 
用户: "这个东西叫什么？"
  → camera_capture → object_detect + Gemma 4
  → 返回: "这是一株龟背竹 (Monstera deliciosa)，
           喜半阴湿润环境，每周浇水1-2次"
```

---

## 2. 🎤 麦克风 — AVFoundation + Speech + SoundAnalysis

### 权限配置
```
Info.plist: NSMicrophoneUsageDescription
Info.plist: NSSpeechRecognitionUsageDescription  (如用语音识别)
```

### 可调用 API

| API | 框架 | 能力 |
|-----|------|------|
| `AVAudioRecorder` | AVFoundation | 录制音频文件 |
| `AVAudioEngine` | AVFoundation | 实时音频流处理（低延迟）|
| `AVAudioEngine.inputNode` | AVFoundation | 获取麦克风实时 PCM 数据 |
| `SFSpeechRecognizer` | Speech | Apple 语音转文字（支持中文）|
| `SFSpeechAudioBufferRecognitionRequest` | Speech | 实时流式语音识别 |
| `SNAudioStreamAnalyzer` | SoundAnalysis | 实时环境声音分类 |
| `SNClassifySoundRequest` | SoundAnalysis | 内置声音分类（300+类）|

### Agent Skills

```
skill: voice_listen
  → AVAudioEngine + SFSpeechRecognizer
  → 实时语音转文字，作为 Agent 输入
  → Gemma 4 原生支持音频输入时可直接喂原始音频

skill: audio_record
  → AVAudioRecorder → 录制音频文件
  → 返回: { filePath: "/tmp/recording.m4a", duration: 45.2 }

skill: meeting_transcribe
  → SFSpeechAudioBufferRecognitionRequest (流式)
  → 持续转写 → 结束后 Gemma 4 总结
  → 返回: { transcript: "...", summary: "..." }

skill: sound_detect
  → SNClassifySoundRequest (内置 300+ 类声音)
  → 返回: { sound: "dog_bark", confidence: 0.88 }
  → 可识别: 门铃、婴儿哭声、警报、咳嗽、鼓掌等

skill: audio_to_model
  → AVAudioEngine → 原始音频 buffer
  → 直接送入 Gemma 4 多模态输入
  → Gemma 4 理解音频内容（如果模型支持）
```

### 杀手级场景

```
用户: "帮我录一下这个会议，结束后给我做个总结"
  → audio_record + meeting_transcribe (并行)
  → 会议结束后 Gemma 4 总结
  → 返回: "会议要点: 1. Q2目标调整为... 2. 张三负责... 
           3. 下周五前提交方案 | 待办: 3项 | 时长: 47分钟"

用户: [后台运行] sound_detect 持续监听
  → 检测到婴儿哭声 → notification_send
  → "检测到婴儿哭声，已持续30秒"
```

---

## 3. 📍 定位 — CoreLocation

### 权限配置
```
Info.plist: NSLocationWhenInUseUsageDescription     (前台)
Info.plist: NSLocationAlwaysAndWhenInUseUsageDescription (后台)
Background Mode: Location updates (如需后台持续定位)
```

### 可调用 API

| API | 框架 | 能力 |
|-----|------|------|
| `CLLocationManager.requestLocation()` | CoreLocation | 单次定位 |
| `CLLocationManager.startUpdatingLocation()` | CoreLocation | 持续定位 |
| `CLLocationManager.startMonitoringSignificantLocationChanges()` | CoreLocation | 显著位置变化（省电）|
| `CLLocationManager.startMonitoring(for: CLCircularRegion)` | CoreLocation | 地理围栏监控（进入/离开）|
| `CLLocationManager.startMonitoringVisits()` | CoreLocation | 用户"到访"某地检测 |
| `CLGeocoder.reverseGeocodeLocation()` | CoreLocation | 经纬度 → 地址名称 |
| `CLGeocoder.geocodeAddressString()` | CoreLocation | 地址名称 → 经纬度 |
| `CLLocationManager.heading` | CoreLocation | 电子罗盘方向 |
| `CLLocationManager.startRangingBeacons()` | CoreLocation | iBeacon 测距 |
| `MKLocalSearch` | MapKit | 搜索附近 POI（餐厅、加油站等）|
| `MKDirections` | MapKit | 路线规划（驾车/步行/公交）|
| `MKMapSnapshotter` | MapKit | 生成静态地图截图 |

### Agent Skills

```
skill: location_get
  → CLLocationManager.requestLocation()
  → CLGeocoder.reverseGeocodeLocation()
  → 返回: { lat: 30.27, lng: 120.15, 
            address: "杭州市西湖区文三路XX号", altitude: 15.2 }

skill: location_track
  → startUpdatingLocation() 持续追踪
  → 返回实时位置流

skill: geofence_set
  → startMonitoring(for: CLCircularRegion)
  → 设置地理围栏，进入/离开时触发
  → 返回: { fenceId: "office", radius: 200, center: {...} }

skill: nearby_search
  → MKLocalSearch(query: "咖啡店")
  → 返回: { results: [{ name: "星巴克", distance: "350m", rating: 4.5 }] }

skill: route_plan
  → MKDirections
  → 返回: { distance: "12.3km", eta: "25分钟", steps: [...] }

skill: compass_heading
  → CLLocationManager.heading
  → 返回: { heading: 127.5, direction: "东南" }
```

### 杀手级场景

```
用户: "我到公司了提醒我查看邮件"
  → geofence_set(address: "公司", event: "enter")
  → [用户进入围栏] → notification_send("你到公司了，记得查看邮件")

用户: "附近有什么吃的？"
  → location_get → nearby_search(query: "餐厅")
  → 返回: "你在文三路附近，500米内有: 
           1. 外婆家 (4.3星, 人均68)
           2. 绿茶 (4.5星, 人均72)
           走路最近的是外婆家，约6分钟"
```

---

## 4. 🏃 运动传感器 — CoreMotion

### 权限配置
```
Info.plist: NSMotionUsageDescription
```

### 可调用 API

| API | 框架 | 能力 |
|-----|------|------|
| `CMMotionManager.accelerometerData` | CoreMotion | 加速度计 (x, y, z) |
| `CMMotionManager.gyroData` | CoreMotion | 陀螺仪 (旋转速率) |
| `CMMotionManager.magnetometerData` | CoreMotion | 磁力计 |
| `CMMotionManager.deviceMotion` | CoreMotion | 融合数据（姿态、重力、用户加速度）|
| `CMPedometer.startUpdates()` | CoreMotion | 实时步数计数 |
| `CMPedometer.queryPedometerData()` | CoreMotion | 查询历史步数 |
| `CMAltimeter.startRelativeAltitudeUpdates()` | CoreMotion | 气压高度变化 |
| `CMMotionActivityManager.startActivityUpdates()` | CoreMotion | 活动类型识别(步行/跑步/驾车/静止) |
| `CMHeadphoneMotionManager` | CoreMotion | AirPods 头部运动追踪 |

### Agent Skills

```
skill: step_count
  → CMPedometer.queryPedometerData(from: today)
  → 返回: { steps: 8432, distance: 6.1km, floorsAscended: 12 }

skill: activity_detect 
  → CMMotionActivityManager.startActivityUpdates()
  → 返回: { activity: "walking", confidence: "high" }
  → 可识别: stationary / walking / running / cycling / driving

skill: motion_raw
  → CMMotionManager.deviceMotion
  → 返回: { attitude: { pitch, roll, yaw }, 
            gravity: { x, y, z },
            userAcceleration: { x, y, z },
            rotationRate: { x, y, z } }

skill: fall_detect
  → 持续监听 deviceMotion
  → 检测突然加速度变化 → 判定跌倒
  → 触发通知或紧急联系

skill: altitude_track
  → CMAltimeter
  → 返回: { relativeAltitude: 15.3, pressure: 1013.25 } // kPa
```

---

## 5. 📱 NFC — CoreNFC

### 权限配置
```
Info.plist: NFCReaderUsageDescription
Entitlement: com.apple.developer.nfc.readersession.formats
设备要求: iPhone 7+ (读取), iPhone XS+ (后台读取)
```

### 可调用 API

| API | 框架 | 能力 |
|-----|------|------|
| `NFCNDEFReaderSession` | CoreNFC | 读取 NDEF 标签 |
| `NFCNDEFReaderSession.write()` | CoreNFC | 写入 NDEF 数据 |
| `NFCTagReaderSession` | CoreNFC | 读取 ISO 7816 / ISO 15693 / FeliCa / MIFARE 标签 |
| Background Tag Reading | CoreNFC | iPhone XS+ 后台自动检测 NFC 标签 |

### Agent Skills

```
skill: nfc_read
  → NFCNDEFReaderSession
  → 返回: { type: "URI", payload: "https://example.com" }
  → 或: { type: "TEXT", payload: "Hello World", locale: "en" }

skill: nfc_write
  → NFCNDEFReaderSession + write
  → 写入 URL / 文本 / vCard 到空白标签
  → 返回: { success: true, bytesWritten: 128 }

skill: nfc_tag_info
  → NFCTagReaderSession
  → 返回: { standard: "ISO14443", uid: "04:A2:...", type: "MIFARE Ultralight" }
```

### 杀手级场景

```
用户: "扫一下这个 NFC 标签"
  → nfc_read → Gemma 4 分析内容
  → "这个标签包含一个 Wi-Fi 配置:
     SSID: HomeNetwork, 加密: WPA2
     要我帮你连接吗？"

用户: "帮我把这个网址写到 NFC 贴纸上"
  → nfc_write(type: "URI", payload: "https://my-portfolio.com")
  → "已写入，任何手机靠近都会打开你的作品集网站"
```

---

## 6. 📶 蓝牙 — CoreBluetooth

### 权限配置
```
Info.plist: NSBluetoothAlwaysUsageDescription
Background Mode: Uses Bluetooth LE accessories (如需后台)
```

### 可调用 API

| API | 框架 | 能力 |
|-----|------|------|
| `CBCentralManager.scanForPeripherals()` | CoreBluetooth | 扫描 BLE 设备 |
| `CBCentralManager.connect()` | CoreBluetooth | 连接外设 |
| `CBPeripheral.discoverServices()` | CoreBluetooth | 发现服务 |
| `CBPeripheral.discoverCharacteristics()` | CoreBluetooth | 发现特征值 |
| `CBPeripheral.readValue()` | CoreBluetooth | 读取数据 |
| `CBPeripheral.writeValue()` | CoreBluetooth | 写入数据 |
| `CBPeripheral.setNotifyValue()` | CoreBluetooth | 订阅数据变化 |
| `CBPeripheralManager` | CoreBluetooth | 作为外设广播 |

### Agent Skills

```
skill: ble_scan
  → CBCentralManager.scanForPeripherals()
  → 返回: { devices: [
      { name: "Mi Band 7", rssi: -45, uuid: "..." },
      { name: "AirPods Pro", rssi: -32, uuid: "..." }
    ]}

skill: ble_connect
  → 连接指定设备 → 发现服务和特征值
  → 返回: { connected: true, services: ["heart_rate", "battery"] }

skill: ble_read
  → 读取指定特征值
  → 返回: { characteristic: "heart_rate", value: 72 }

skill: ble_write
  → 写入数据到外设
  → 返回: { success: true }

skill: ble_subscribe
  → setNotifyValue → 持续接收数据更新
  → 实时流: { heart_rate: 75 }, { heart_rate: 78 }, ...
```

---

> **第一阶段完成** — 6 类硬件传感器权限，共 **50+ 可调用 API**
> 
> 下一阶段将覆盖：用户数据权限（相册、通讯录、日历、提醒、健康、音乐库）
