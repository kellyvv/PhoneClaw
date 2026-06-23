# 第五部分：App Extension 能力 + 最终汇总

---

## 36-40. App Extensions — 超出 App 边界的系统级集成

### 36. 🔤 自定义键盘 Extension

```
Keyboard Extension Target
→ Agent 作为系统键盘运行在任何 App 中
→ 能力: 在任何输入框中提供 AI 辅助
   - 智能补全
   - 实时翻译
   - 语法纠错
   - 语气转换（正式/口语/幽默）
```

### 37. 🔗 Share Extension

```
Share Extension Target
→ 用户在任何 App 的分享菜单中调用 Agent
→ 场景:
   - Safari 分享网页 → Agent 总结
   - 相册分享照片 → Agent 识别/分类
   - 备忘录分享文本 → Agent 分析/翻译
```

### 38. 🖼 Photo Editing Extension

```
Photo Editing Extension Target
→ 在系统相册 App 中直接调用 Agent 编辑照片
→ 能力: AI 描述照片、智能裁切建议、OCR 提取文字
```

### 39. 🌐 Safari Content Blocker

```
Content Blocker Extension Target
→ Agent 管理 Safari 广告和追踪器屏蔽规则
→ 用户: "帮我屏蔽这个网站的弹窗广告"
→ Agent 动态更新屏蔽规则 JSON
```

### 40. 🎯 Action Extension

```
Action Extension Target  
→ 用户选中文字/图片 → 长按 → 调用 Agent
→ 场景: 选中英文 → "翻译成中文" → 直接替换
```

---

# 最终汇总

## 完整 Skill 清单（按权限分类）

### 🔴 需用户授权（Info.plist + 弹窗）

| # | 权限 | Info.plist Key | Skills | 数量 |
|---|------|---------------|--------|------|
| 1 | 相机 | NSCameraUsageDescription | camera_capture, document_scan, barcode_scan, ocr_extract, object_detect, face_analyze, body_pose, live_scene_describe | 8 |
| 2 | 麦克风 | NSMicrophoneUsageDescription | voice_listen, audio_record, meeting_transcribe, sound_detect, audio_to_model | 5 |
| 3 | 语音识别 | NSSpeechRecognitionUsageDescription | (包含在麦克风 skills 中) | - |
| 4 | 定位(前台) | NSLocationWhenInUseUsageDescription | location_get, nearby_search, route_plan, compass_heading | 4 |
| 5 | 定位(后台) | NSLocationAlwaysAndWhenInUseUsageDescription | location_track, geofence_set | 2 |
| 6 | 运动传感器 | NSMotionUsageDescription | step_count, activity_detect, motion_raw, fall_detect, altitude_track | 5 |
| 7 | NFC | NFCReaderUsageDescription | nfc_read, nfc_write, nfc_tag_info | 3 |
| 8 | 蓝牙 | NSBluetoothAlwaysUsageDescription | ble_scan, ble_connect, ble_read, ble_write, ble_subscribe | 5 |
| 9 | 相册(读) | NSPhotoLibraryUsageDescription | photos_search, photos_recent, photos_by_location, photos_organize, photo_edit_metadata | 5 |
| 10 | 相册(写) | NSPhotoLibraryAddUsageDescription | photos_save | 1 |
| 11 | 通讯录 | NSContactsUsageDescription | contacts_search, contacts_create, contacts_update, contacts_list_all, contacts_birthday_upcoming | 5 |
| 12 | 日历 | NSCalendarsFullAccessUsageDescription | calendar_query, calendar_create, calendar_check_free, calendar_recurring, calendar_delete | 5 |
| 13 | 提醒事项 | NSRemindersFullAccessUsageDescription | reminders_query, reminders_create, reminders_location_based, reminders_complete, reminders_batch_create | 5 |
| 14 | 健康(读) | NSHealthShareUsageDescription | health_steps, health_heart_rate, health_sleep, health_weight_trend, health_blood_oxygen, health_comprehensive_report | 6 |
| 15 | 健康(写) | NSHealthUpdateUsageDescription | health_workout_log, health_water_log | 2 |
| 16 | 音乐库 | NSAppleMusicUsageDescription | music_play, music_control, music_now_playing, music_search_library | 4 |
| 17 | Face ID | NSFaceIDUsageDescription | auth_biometric | 1 |
| 18 | HomeKit | NSHomeKitUsageDescription | home_list_devices, home_control, home_read_status, home_scene, home_automation, home_sensor_read | 6 |
| 19 | Siri | NSSiriUsageDescription | siri_integration (所有 skill 暴露给 Siri) | 1 |
| 20 | Focus 状态 | NSFocusStatusUsageDescription | focus_status | 1 |
| 21 | 通知 | UNUserNotificationCenter (代码请求) | notification_send, notification_schedule, notification_location, notification_interactive | 4 |

### 🟢 无需用户授权

| # | 能力 | Skills | 数量 |
|---|------|--------|------|
| 22 | 剪贴板 | clipboard_read, clipboard_write, clipboard_analyze | 3 |
| 23 | 文件(沙箱) | file_pick, file_read, file_write, file_list, file_analyze_pdf | 5 |
| 24 | 网络请求 | web_fetch, web_search, api_call, network_status, download_file | 5 |
| 25 | 邮件/短信 | email_compose, sms_compose | 2 |
| 26 | 触觉反馈 | haptic_feedback, haptic_pattern | 2 |
| 27 | 设备信息 | device_info, screen_brightness, battery_status | 3 |
| 28 | Keychain | keychain_store, keychain_retrieve | 2 |
| 29 | UserDefaults | preference_set, preference_get | 2 |
| 30 | 语音合成 | tts_speak, tts_stop | 2 |
| 31 | Spotlight | spotlight_index | 1 |
| 32 | Widget | widget_update | 1 |
| 33 | Live Activity | live_activity_start, live_activity_update | 2 |
| 34 | 后台任务 | bg_refresh, bg_process | 2 |
| 35 | AR | ar_measure, ar_scene_understand, ar_place_info, ar_face_mesh, ar_room_scan | 5 |
| 36 | 录屏 | screen_record_start, screen_record_stop, screen_capture_frame | 3 |
| 37 | 辅助功能 | accessibility_check | 1 |
| 38 | CallKit | call_display | 1 |

### 🔵 App Extension

| # | 类型 | 能力 |
|---|------|------|
| 39 | Keyboard Extension | 任意输入框中 AI 辅助 |
| 40 | Share Extension | 系统分享菜单集成 |
| 41 | Photo Editing Extension | 相册中 AI 编辑 |
| 42 | Content Blocker | Safari 广告屏蔽 |
| 43 | Action Extension | 选中内容快速处理 |

---

## 统计

| 维度 | 数量 |
|------|------|
| **总权限类型** | 21 类需授权 + 17 类无需授权 + 5 类 Extension |
| **总 Skill 数** | ~105 个可实现的 Agent Skill |
| **总 API 数** | ~200+ 个可调用的 iOS API |
| **Info.plist Keys** | 21 个 NSUsageDescription |
| **Entitlements** | 3-5 个 (HealthKit, HomeKit, NFC, Siri, BLE Background) |
| **Background Modes** | 4 个 (Location, Audio, Background fetch, Background processing) |

---

## Info.plist 完整清单

```xml
<!-- 硬件 -->
<key>NSCameraUsageDescription</key>
<string>PhoneClaw 需要相机来拍照识别和扫码</string>
<key>NSMicrophoneUsageDescription</key>
<string>PhoneClaw 需要麦克风来语音对话和录音</string>
<key>NSSpeechRecognitionUsageDescription</key>
<string>PhoneClaw 需要语音识别来理解你的语音指令</string>
<key>NSLocationWhenInUseUsageDescription</key>
<string>PhoneClaw 需要位置来搜索附近和导航</string>
<key>NSLocationAlwaysAndWhenInUseUsageDescription</key>
<string>PhoneClaw 需要后台定位来实现地理围栏提醒</string>
<key>NSMotionUsageDescription</key>
<string>PhoneClaw 需要运动数据来记录步数和检测活动</string>
<key>NFCReaderUsageDescription</key>
<string>PhoneClaw 需要 NFC 来读写标签</string>
<key>NSBluetoothAlwaysUsageDescription</key>
<string>PhoneClaw 需要蓝牙来连接周边设备</string>

<!-- 用户数据 -->
<key>NSPhotoLibraryUsageDescription</key>
<string>PhoneClaw 需要相册来搜索和分析照片</string>
<key>NSPhotoLibraryAddUsageDescription</key>
<string>PhoneClaw 需要保存照片到相册</string>
<key>NSContactsUsageDescription</key>
<string>PhoneClaw 需要通讯录来查找和管理联系人</string>
<key>NSCalendarsFullAccessUsageDescription</key>
<string>PhoneClaw 需要日历来管理你的日程</string>
<key>NSRemindersFullAccessUsageDescription</key>
<string>PhoneClaw 需要提醒事项来管理待办</string>
<key>NSHealthShareUsageDescription</key>
<string>PhoneClaw 需要读取健康数据来提供健康建议</string>
<key>NSHealthUpdateUsageDescription</key>
<string>PhoneClaw 需要写入健康数据来记录运动</string>
<key>NSAppleMusicUsageDescription</key>
<string>PhoneClaw 需要音乐库来播放和搜索音乐</string>

<!-- 系统集成 -->
<key>NSFaceIDUsageDescription</key>
<string>PhoneClaw 使用 Face ID 保护敏感操作</string>
<key>NSHomeKitUsageDescription</key>
<string>PhoneClaw 需要 HomeKit 来控制智能家居</string>
<key>NSSiriUsageDescription</key>
<string>PhoneClaw 通过 Siri 提供语音助手能力</string>
<key>NSFocusStatusUsageDescription</key>
<string>PhoneClaw 需要专注状态来避免在专注模式下打扰你</string>
<key>NSLocalNetworkUsageDescription</key>
<string>PhoneClaw 需要局域网来发现本地设备</string>
```
