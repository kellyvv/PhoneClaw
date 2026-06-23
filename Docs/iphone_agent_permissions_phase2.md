# 第二部分：用户数据权限（需用户授权）

---

## 7. 📸 相册 — PhotoKit (Photos Framework)

### 权限配置
```
Info.plist: NSPhotoLibraryUsageDescription          (读取)
Info.plist: NSPhotoLibraryAddUsageDescription        (仅写入)
```

> iOS 14+ 支持"选择部分照片"的有限访问模式 (PHAccessLevel.limited)

### 可调用 API

| API | 框架 | 能力 |
|-----|------|------|
| `PHAsset.fetchAssets()` | Photos | 查询所有照片/视频资产 |
| `PHAsset` 属性 | Photos | 获取: 创建日期、位置、尺寸、媒体类型、收藏状态 |
| `PHImageManager.requestImage()` | Photos | 获取指定尺寸的图片数据 |
| `PHImageManager.requestAVAsset()` | Photos | 获取视频的 AVAsset |
| `PHAssetCollection.fetchAssetCollections()` | Photos | 查询相册列表 |
| `PHAssetCreationRequest` | Photos | 保存新照片到相册 |
| `PHAssetChangeRequest` | Photos | 修改照片元数据（收藏、隐藏等）|
| `PHFetchOptions` (predicate/sortDescriptors) | Photos | 按日期、位置、媒体类型筛选 |
| `PHPhotoLibrary.shared().performChanges()` | Photos | 批量修改操作 |

### Agent Skills

```
skill: photos_search
  参数: { query: "上周的收据", type: "image", dateRange: "last_week" }
  → PHFetchOptions 按日期筛选 
  → PHImageManager 获取缩略图 → Gemma 4 批量图片理解
  → 返回: { matches: [{ id: "...", date: "2026-03-28", 
            description: "星巴克收据 ¥35" }] }

skill: photos_recent
  参数: { count: 10 }
  → 获取最近 N 张照片
  → 返回: [{ id, date, location, thumbnail }]

skill: photos_save
  参数: { image: UIImage }
  → PHAssetCreationRequest 保存到相册
  → 返回: { saved: true, assetId: "..." }

skill: photos_by_location
  参数: { location: "杭州", radius: 5000 }
  → PHFetchOptions + CLLocation predicate
  → 返回按地点筛选的照片列表

skill: photos_organize
  → 批量获取照片 → Gemma 4 分类（风景/人物/文档/食物/截图）
  → 返回分类建议: { categories: { food: [ids], docs: [ids], ... } }

skill: photo_edit_metadata
  参数: { assetId: "...", favorite: true }
  → PHAssetChangeRequest 修改元数据
  → 返回: { updated: true }
```

### 杀手级场景

```
用户: "帮我找上周拍的那张发票"
  → photos_search(query: "发票", dateRange: "last_week")
  → Gemma 4 逐张分析缩略图，识别发票
  → "找到了，是3月28日拍的，金额¥1,280，
     开票方: XX科技有限公司，要我帮你提取详细信息吗？"

用户: "整理我这个月的照片"
  → photos_organize → Gemma 4 批量分类
  → "这个月共 247 张照片:
     - 自拍/人物: 45张
     - 食物: 32张  
     - 风景: 28张
     - 截图: 89张 (建议清理)
     - 文档/收据: 18张
     - 其他: 35张
     要我帮你把截图移到单独相册吗？"
```

---

## 8. 👤 通讯录 — Contacts Framework

### 权限配置
```
Info.plist: NSContactsUsageDescription
```

### 可调用 API

| API | 框架 | 能力 |
|-----|------|------|
| `CNContactStore.requestAccess()` | Contacts | 请求通讯录权限 |
| `CNContactStore.unifiedContacts(matching:)` | Contacts | 按条件查询联系人 |
| `CNContactStore.enumerateContacts()` | Contacts | 遍历所有联系人 |
| `CNContact` 属性 | Contacts | 姓名、电话、邮箱、地址、生日、公司、职位、头像、社交账号 |
| `CNContactFormatter` | Contacts | 本地化格式化联系人名字 |
| `CNSaveRequest.add()` | Contacts | 创建新联系人 |
| `CNSaveRequest.update()` | Contacts | 更新联系人信息 |
| `CNSaveRequest.delete()` | Contacts | 删除联系人 |
| `CNContactFetchRequest` | Contacts | 指定获取哪些字段（性能优化）|
| `CNGroup` / `CNContainer` | Contacts | 联系人分组管理 |

### Agent Skills

```
skill: contacts_search
  参数: { name: "张三" } 或 { company: "阿里巴巴" }
  → CNContactStore.unifiedContacts(matching: predicate)
  → 返回: { name: "张三", phone: "138xxxx5678", 
            email: "zhangsan@xxx.com", company: "阿里巴巴" }

skill: contacts_create
  参数: { name: "李四", phone: "139xxxx1234", company: "腾讯" }
  → CNSaveRequest.add(contact)
  → 返回: { created: true, contactId: "..." }

skill: contacts_update
  参数: { contactId: "...", phone: "新号码" }
  → CNSaveRequest.update()
  → 返回: { updated: true }

skill: contacts_list_all
  → CNContactStore.enumerateContacts()
  → 返回: { total: 352, contacts: [...] }

skill: contacts_birthday_upcoming
  → 遍历所有联系人 → 筛选未来 7 天生日
  → 返回: [{ name: "妈妈", birthday: "4月5日", daysUntil: 2 }]
```

### 杀手级场景

```
用户: [拍一张名片]
  → camera_capture → ocr_extract → Gemma 4 解析名片
  → contacts_create(name: "王五", phone: "186...", 
                     company: "字节跳动", title: "产品总监")
  → "已把王五的信息存入通讯录:
     王五 | 字节跳动 产品总监
     电话: 186xxxx7890 | 邮箱: wangwu@bytedance.com"

用户: "这周谁过生日？"
  → contacts_birthday_upcoming
  → "后天 (4月5日) 是妈妈的生日！要我帮你设置提醒吗？"
```

---

## 9. 📅 日历 — EventKit

### 权限配置
```
Info.plist: NSCalendarsFullAccessUsageDescription      (读写)
Info.plist: NSCalendarsWriteOnlyAccessUsageDescription  (仅写)
```

### 可调用 API

| API | 框架 | 能力 |
|-----|------|------|
| `EKEventStore.requestFullAccessToEvents()` | EventKit | 请求日历完整权限 |
| `EKEventStore.events(matching:)` | EventKit | 查询日期范围内的事件 |
| `EKEvent(eventStore:)` | EventKit | 创建新日历事件 |
| `EKEvent` 属性 | EventKit | 标题、开始/结束时间、地点、备注、URL、重复规则、提醒 |
| `EKAlarm` | EventKit | 事件提醒（时间偏移或绝对时间）|
| `EKRecurrenceRule` | EventKit | 重复规则（每天/每周/每月/自定义）|
| `EKEventStore.save()` | EventKit | 保存事件 |
| `EKEventStore.remove()` | EventKit | 删除事件 |
| `EKCalendar` | EventKit | 管理不同日历（工作/个人/节日等）|
| `EKEventStore.calendars(for: .event)` | EventKit | 获取所有日历列表 |

### Agent Skills

```
skill: calendar_query
  参数: { from: "today", to: "next_week" }
  → EKEventStore.events(matching: predicate)
  → 返回: [{ title: "产品评审", start: "2026-04-04 14:00",
             end: "15:00", location: "3楼会议室", calendar: "工作" }]

skill: calendar_create
  参数: { title: "和张三吃饭", date: "明天", time: "18:30",
           location: "外婆家西湖店", alert: "30min_before" }
  → 创建 EKEvent + EKAlarm
  → 返回: { created: true, eventId: "..." }

skill: calendar_check_free
  参数: { date: "2026-04-05" }
  → 查询当天事件 → 计算空闲时段
  → 返回: { busy: ["9:00-10:00", "14:00-16:00"],
            free: ["10:00-14:00", "16:00-18:00"] }

skill: calendar_recurring
  参数: { title: "周会", every: "weekly", day: "monday", time: "10:00" }
  → EKRecurrenceRule + EKEvent
  → 返回: { created: true, recurrence: "每周一 10:00" }

skill: calendar_delete
  参数: { eventId: "..." }
  → EKEventStore.remove()
  → 返回: { deleted: true }
```

---

## 10. ⏰ 提醒事项 — EventKit (Reminders)

### 权限配置
```
Info.plist: NSRemindersFullAccessUsageDescription
```

### 可调用 API

| API | 框架 | 能力 |
|-----|------|------|
| `EKEventStore.requestFullAccessToReminders()` | EventKit | 请求提醒权限 |
| `EKEventStore.fetchReminders(matching:)` | EventKit | 查询提醒 |
| `EKReminder(eventStore:)` | EventKit | 创建提醒 |
| `EKReminder` 属性 | EventKit | 标题、备注、优先级、完成状态、截止日期 |
| `EKAlarm` | EventKit | 时间提醒或位置提醒 |
| `EKAlarm(relativeOffset:)` | EventKit | 相对时间提醒 |
| `EKAlarm(structuredLocation:proximity:)` | EventKit | 到达/离开某地时提醒 |
| `EKEventStore.save()` / `.remove()` | EventKit | 保存/删除提醒 |

### Agent Skills

```
skill: reminders_query
  参数: { list: "购物清单", completed: false }
  → fetchReminders → 返回未完成提醒列表

skill: reminders_create
  参数: { title: "买牛奶", list: "购物清单", 
           dueDate: "明天", priority: 1 }
  → 创建 EKReminder + 设置到期日
  → 返回: { created: true, id: "..." }

skill: reminders_location_based
  参数: { title: "取快递", location: "小区门口",
           trigger: "arriving" }
  → EKAlarm(structuredLocation:, proximity: .enter)
  → 到达指定位置时触发提醒

skill: reminders_complete
  参数: { id: "..." }
  → reminder.isCompleted = true → save
  → 返回: { completed: true }

skill: reminders_batch_create
  参数: { list: "出差清单", items: ["充电宝","身份证","笔记本"] }
  → 批量创建提醒
  → 返回: { created: 3, list: "出差清单" }
```

---

## 11. ❤️ 健康数据 — HealthKit

### 权限配置
```
Info.plist: NSHealthShareUsageDescription    (读取)
Info.plist: NSHealthUpdateUsageDescription   (写入)
Entitlement: com.apple.developer.healthkit
Background Mode: Background fetch (用于后台健康数据更新)
```

> HealthKit 权限粒度极细——每个数据类型(步数/心率/睡眠...)需单独授权

### 可调用 API

| API / 数据类型 | 框架 | 能力 |
|-----|------|------|
| `HKHealthStore.requestAuthorization()` | HealthKit | 按类型请求权限 |
| `HKQuantityType(.stepCount)` | HealthKit | 步数 |
| `HKQuantityType(.heartRate)` | HealthKit | 心率 (bpm) |
| `HKQuantityType(.activeEnergyBurned)` | HealthKit | 活动消耗卡路里 |
| `HKQuantityType(.distanceWalkingRunning)` | HealthKit | 步行跑步距离 |
| `HKQuantityType(.bloodOxygenSaturation)` | HealthKit | 血氧 (SpO2) |
| `HKQuantityType(.bodyMass)` | HealthKit | 体重 |
| `HKQuantityType(.height)` | HealthKit | 身高 |
| `HKQuantityType(.bodyMassIndex)` | HealthKit | BMI |
| `HKQuantityType(.bloodPressureSystolic/Diastolic)` | HealthKit | 血压 |
| `HKQuantityType(.bloodGlucose)` | HealthKit | 血糖 |
| `HKQuantityType(.bodyTemperature)` | HealthKit | 体温 |
| `HKQuantityType(.dietaryEnergyConsumed)` | HealthKit | 饮食卡路里摄入 |
| `HKQuantityType(.dietaryWater)` | HealthKit | 饮水量 |
| `HKCategoryType(.sleepAnalysis)` | HealthKit | 睡眠分析（入睡/浅睡/深睡/REM）|
| `HKCategoryType(.mindfulSession)` | HealthKit | 正念冥想记录 |
| `HKWorkout` | HealthKit | 运动记录（类型/时长/消耗）|
| `HKStatisticsQuery` | HealthKit | 统计查询（求和/平均/最大/最小）|
| `HKStatisticsCollectionQuery` | HealthKit | 按时间段统计（每天/每周步数趋势）|
| `HKAnchoredObjectQuery` | HealthKit | 增量查询（新增数据）|
| `HKObserverQuery` | HealthKit | 数据变化监听 |
| `HKQuantitySample` | HealthKit | 写入健康数据样本 |

### Agent Skills

```
skill: health_steps
  参数: { period: "today" | "this_week" | "this_month" }
  → HKStatisticsQuery(stepCount, sum)
  → 返回: { steps: 8432, goal: 10000, progress: "84%" }

skill: health_heart_rate
  参数: { period: "today" }
  → HKStatisticsQuery(heartRate, min/max/avg)
  → 返回: { resting: 62, average: 75, max: 142, 
            readings: [{ time: "08:30", value: 68 }, ...] }

skill: health_sleep
  参数: { date: "last_night" }
  → HKSampleQuery(sleepAnalysis)
  → 返回: { total: "7h12m", inBed: "7h45m",
            deep: "1h30m", rem: "1h48m", light: "3h54m",
            awake: "33m", efficiency: "93%" }

skill: health_workout_log
  参数: { type: "running", duration: 30, distance: 5.2 }
  → 创建 HKWorkout 样本
  → 返回: { logged: true, calories: 320 }

skill: health_weight_trend
  参数: { period: "last_3_months" }
  → HKStatisticsCollectionQuery(bodyMass, weekly)
  → 返回: { trend: "下降", data: [{week: "W1", kg: 72.5}, ...],
            change: "-2.3kg" }

skill: health_water_log
  参数: { ml: 250 }
  → 写入 HKQuantitySample(dietaryWater)
  → 返回: { logged: true, todayTotal: "1,750ml", goal: "2,000ml" }

skill: health_blood_oxygen
  → HKSampleQuery(bloodOxygenSaturation, latest)
  → 返回: { spo2: 98, time: "10:30" }

skill: health_comprehensive_report
  → 并行查询: 步数 + 心率 + 睡眠 + 运动 + 体重
  → Gemma 4 综合分析
  → 返回自然语言健康报告
```

### 杀手级场景

```
用户: "我今天状态怎么样？"
  → health_comprehensive_report
  → Gemma 4 综合分析:
  → "整体状态不错:
     😴 昨晚睡了7小时12分，深睡1.5小时，质量评分88分
     🚶 今天已走 8,432 步 (目标84%)
     ❤️ 静息心率62，正常范围
     💧 已喝水1,250ml，还差750ml
     建议: 下午再喝3杯水，晚上散步20分钟达标"

用户: "帮我记一下，刚才跑了5公里"
  → health_workout_log(type: "running", distance: 5.0)
  → "已记录: 跑步5公里，估算消耗约310大卡，本周累计跑步15公里，不错！"
```

---

## 12. 🎵 音乐库 — MediaPlayer + MusicKit

### 权限配置
```
Info.plist: NSAppleMusicUsageDescription
```

### 可调用 API

| API | 框架 | 能力 |
|-----|------|------|
| `MPMediaQuery.songs()` | MediaPlayer | 查询所有本地歌曲 |
| `MPMediaQuery` (predicate) | MediaPlayer | 按艺人/专辑/流派筛选 |
| `MPMusicPlayerController.systemMusicPlayer` | MediaPlayer | 控制系统音乐播放器 |
| `.play()` / `.pause()` / `.skipToNextItem()` | MediaPlayer | 播放控制 |
| `.nowPlayingItem` | MediaPlayer | 当前播放歌曲信息 |
| `.setQueue(with:)` | MediaPlayer | 设置播放队列 |
| `MPMediaPickerController` | MediaPlayer | 系统歌曲选择 UI |
| `MusicCatalogSearchRequest` | MusicKit | 搜索 Apple Music 曲库 |
| `MusicSubscription` | MusicKit | 用户订阅状态 |

### Agent Skills

```
skill: music_play
  参数: { query: "周杰伦" | genre: "jazz" | album: "范特西" }
  → MPMediaQuery 筛选 → setQueue → play()
  → 返回: { playing: "晴天", artist: "周杰伦", album: "叶惠美" }

skill: music_control
  参数: { action: "pause" | "next" | "previous" | "volume_up" }
  → MPMusicPlayerController 控制
  → 返回: { action: "paused" }

skill: music_now_playing
  → nowPlayingItem
  → 返回: { title: "晴天", artist: "周杰伦", duration: "4:29", 
            progress: "2:15" }

skill: music_search_library
  参数: { artist: "陈奕迅" }
  → MPMediaQuery
  → 返回: { songs: [{ title: "十年", album: "黑白灰" }, ...], total: 23 }
```

---

## 13. 📁 文件访问 — FileManager + UIDocumentPickerViewController

### 权限配置
```
无特殊权限 — App 沙箱内文件自由读写
UIDocumentPickerViewController — 用户手动选择文件（无需权限声明）
```

### 可调用 API

| API | 框架 | 能力 |
|-----|------|------|
| `FileManager.default` | Foundation | 沙箱内文件 CRUD |
| `.contentsOfDirectory(atPath:)` | Foundation | 列出目录内容 |
| `.createFile()` / `.createDirectory()` | Foundation | 创建文件/目录 |
| `.removeItem(atPath:)` | Foundation | 删除文件 |
| `.copyItem()` / `.moveItem()` | Foundation | 复制/移动文件 |
| `.attributesOfItem()` | Foundation | 获取文件属性（大小/日期）|
| `UIDocumentPickerViewController` | UIKit | 用户选择 iCloud/本地文件 |
| `Data(contentsOf:)` | Foundation | 读取文件内容 |
| `data.write(to:)` | Foundation | 写入文件内容 |
| `JSONSerialization` / `JSONDecoder` | Foundation | JSON 读写 |
| `QLPreviewController` | QuickLook | 预览 PDF/Office/图片文件 |

### Agent Skills

```
skill: file_pick
  → UIDocumentPickerViewController
  → 用户选择文件 → 返回文件 URL
  → 读取内容 → Gemma 4 分析

skill: file_read
  参数: { path: "sandbox://Documents/notes.txt" }
  → Data(contentsOf:) → String
  → 返回: { content: "文件内容...", size: "2.3KB" }

skill: file_write
  参数: { path: "Documents/summary.md", content: "..." }
  → data.write(to:)
  → 返回: { written: true, path: "..." }

skill: file_list
  参数: { directory: "Documents" }
  → contentsOfDirectory
  → 返回: [{ name: "notes.txt", size: "2.3KB", modified: "..." }]

skill: file_analyze_pdf
  → file_pick (用户选PDF) → 提取文本 → Gemma 4 总结
  → 返回: { pages: 12, summary: "这份合同主要内容是..." }
```

---

> **第二阶段完成** — 7 类用户数据权限，共 **70+ 可调用 API**
>
> 下一阶段: 系统集成能力（剪贴板、通知、HomeKit、Shortcuts、辅助功能、网络请求等）
