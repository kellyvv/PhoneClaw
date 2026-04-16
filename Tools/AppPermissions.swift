import AVFoundation
import Contacts
import EventKit
import Foundation

// MARK: - 权限模型

enum AppPermissionKind: String, CaseIterable, Identifiable {
    case microphone
    case camera
    case calendar
    case reminders
    case contacts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .microphone: return "麦克风"
        case .camera: return "摄像头"
        case .calendar: return "日历"
        case .reminders: return "提醒事项"
        case .contacts: return "通讯录"
        }
    }

    var description: String {
        switch self {
        case .microphone: return "允许录音并采集实时音频输入"
        case .camera: return "允许在 Live 模式中观察周围环境"
        case .calendar: return "允许创建和写入日历事项"
        case .reminders: return "允许创建提醒和待办"
        case .contacts: return "允许查询、保存和删除联系人"
        }
    }

    var icon: String {
        switch self {
        case .microphone: return "mic"
        case .camera: return "camera"
        case .calendar: return "calendar"
        case .reminders: return "bell"
        case .contacts: return "person.crop.circle"
        }
    }
}

enum AppPermissionStatus: Equatable {
    case notDetermined
    case denied
    case restricted
    case granted

    var label: String {
        switch self {
        case .notDetermined: return "未请求"
        case .denied: return "已拒绝"
        case .restricted: return "受限制"
        case .granted: return "已授权"
        }
    }

    var detail: String {
        switch self {
        case .notDetermined: return "首次使用时会弹出系统授权框"
        case .denied: return "请到系统设置里手动开启权限"
        case .restricted: return "当前设备限制了这项权限"
        case .granted: return "可以直接执行相关 Skill"
        }
    }

    var isGranted: Bool {
        self == .granted
    }
}

// MARK: - 权限查询与请求

extension ToolRegistry {

    func authorizationStatus(for kind: AppPermissionKind) -> AppPermissionStatus {
        switch kind {
        case .microphone:
            #if os(iOS)
            switch AVAudioSession.sharedInstance().recordPermission {
            case .granted:
                return .granted
            case .denied:
                return .denied
            case .undetermined:
                return .notDetermined
            @unknown default:
                return .restricted
            }
            #else
            // macOS CLI: 无 AVAudioSession, 权限系统不适用
            return .granted
            #endif

        case .camera:
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                return .granted
            case .notDetermined:
                return .notDetermined
            case .denied:
                return .denied
            case .restricted:
                return .restricted
            @unknown default:
                return .restricted
            }

        case .calendar:
            let status = EKEventStore.authorizationStatus(for: .event)
            switch status {
            case .fullAccess, .writeOnly, .authorized:
                return .granted
            case .notDetermined:
                return .notDetermined
            case .denied:
                return .denied
            case .restricted:
                return .restricted
            @unknown default:
                return .restricted
            }

        case .reminders:
            let status = EKEventStore.authorizationStatus(for: .reminder)
            switch status {
            case .fullAccess, .authorized:
                return .granted
            case .notDetermined:
                return .notDetermined
            case .denied:
                return .denied
            case .restricted, .writeOnly:
                return .restricted
            @unknown default:
                return .restricted
            }

        case .contacts:
            let status = CNContactStore.authorizationStatus(for: .contacts)
            switch status {
            case .authorized:
                return .granted
            case .limited:
                return .granted
            case .notDetermined:
                return .notDetermined
            case .denied:
                return .denied
            case .restricted:
                return .restricted
            @unknown default:
                return .restricted
            }
        }
    }

    func allPermissionStatuses() -> [AppPermissionKind: AppPermissionStatus] {
        Dictionary(uniqueKeysWithValues: AppPermissionKind.allCases.map {
            ($0, authorizationStatus(for: $0))
        })
    }

    func requestAccess(for kind: AppPermissionKind) async throws -> Bool {
        switch kind {
        case .microphone:
            #if os(iOS)
            return await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
            #else
            return true
            #endif
        case .camera:
            return await AVCaptureDevice.requestAccess(for: .video)
        case .calendar:
            return try await withCheckedThrowingContinuation { continuation in
                SystemStores.event.requestWriteOnlyAccessToEvents { granted, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: granted)
                    }
                }
            }
        case .reminders:
            return try await withCheckedThrowingContinuation { continuation in
                SystemStores.event.requestFullAccessToReminders { granted, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: granted)
                    }
                }
            }
        case .contacts:
            return try await withCheckedThrowingContinuation { continuation in
                SystemStores.contacts.requestAccess(for: .contacts) { granted, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: granted)
                    }
                }
            }
        }
    }
}
