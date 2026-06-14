import Foundation

#if canImport(BackgroundTasks)
import BackgroundTasks
#endif

final class LiveBackgroundContinuation {
    static let shared = LiveBackgroundContinuation()

    static let taskIdentifier = "com.kellyvv.phoneclaw.live-continuation"

    private let lock = NSLock()
    private var registered = false
    private var registrationAccepted = false
    private var sessionActive = false
    private var activeTask: AnyObject?
    private var activeRequestIdentifier: String?

    private init() {}

    var supportsBackgroundGPU: Bool {
        #if canImport(BackgroundTasks)
        if #available(iOS 26.0, *) {
            return BGTaskScheduler.supportedResources.contains(.gpu)
        }
        #endif
        return false
    }

    func register() {
        #if canImport(BackgroundTasks)
        if #available(iOS 26.0, *) {
            lock.lock()
            if registered {
                lock.unlock()
                return
            }
            registered = true
            lock.unlock()

            let ok = BGTaskScheduler.shared.register(
                forTaskWithIdentifier: Self.taskIdentifier,
                using: nil
            ) { [weak self] task in
                self?.handle(task: task)
            }
            lock.lock()
            registrationAccepted = ok
            lock.unlock()
            print("[LiveBackground] register id=\(Self.taskIdentifier) ok=\(ok)")
        }
        #endif
    }

    func begin() {
        #if canImport(BackgroundTasks)
        guard #available(iOS 26.0, *) else {
            print("[LiveBackground] continuous task unavailable before iOS 26")
            return
        }

        register()

        lock.lock()
        let canSubmit = registrationAccepted
        sessionActive = true
        let existing = activeTask
        let existingIdentifier = activeRequestIdentifier
        lock.unlock()

        guard canSubmit else {
            print("[LiveBackground] submit skipped: no registered launch handler")
            return
        }

        if let existing = existing as? BGContinuedProcessingTask {
            update(task: existing, phase: "starting", detail: "PhoneClaw LIVE is starting")
            print("[LiveBackground] begin reuse id=\(existingIdentifier ?? "unknown")")
            return
        }

        let requestIdentifier = Self.taskIdentifier
        let request = BGContinuedProcessingTaskRequest(
            identifier: requestIdentifier,
            title: "PhoneClaw LIVE",
            subtitle: "Listening"
        )
        request.strategy = .fail

        if BGTaskScheduler.supportedResources.contains(.gpu) {
            request.requiredResources = .gpu
            print("[LiveBackground] requesting background GPU")
        } else {
            print("[LiveBackground] background GPU unsupported on this device/build")
        }

        do {
            lock.lock()
            activeRequestIdentifier = requestIdentifier
            lock.unlock()
            try BGTaskScheduler.shared.submit(request)
            print("[LiveBackground] submitted id=\(requestIdentifier)")
        } catch {
            lock.lock()
            if activeRequestIdentifier == requestIdentifier {
                activeRequestIdentifier = nil
            }
            lock.unlock()
            print("[LiveBackground] submit failed: \(error)")
        }
        #endif
    }

    func update(phase: String, detail: String) {
        #if canImport(BackgroundTasks)
        guard #available(iOS 26.0, *) else { return }
        lock.lock()
        let task = activeTask
        lock.unlock()
        guard let task = task as? BGContinuedProcessingTask else { return }
        update(task: task, phase: phase, detail: detail)
        #endif
    }

    func end(success: Bool) {
        #if canImport(BackgroundTasks)
        guard #available(iOS 26.0, *) else { return }
        lock.lock()
        sessionActive = false
        let task = activeTask
        activeTask = nil
        activeRequestIdentifier = nil
        lock.unlock()

        guard let task = task as? BGContinuedProcessingTask else { return }
        task.progress.totalUnitCount = 100
        task.progress.completedUnitCount = success ? 100 : max(task.progress.completedUnitCount, 1)
        task.updateTitle("PhoneClaw LIVE", subtitle: success ? "Ended" : "Stopped")
        task.setTaskCompleted(success: success)
        print("[LiveBackground] completed success=\(success)")
        #endif
    }

    #if canImport(BackgroundTasks)
    @available(iOS 26.0, *)
    private func handle(task: BGTask) {
        guard let continuedTask = task as? BGContinuedProcessingTask else {
            task.setTaskCompleted(success: false)
            return
        }

        lock.lock()
        activeTask = continuedTask
        let keepRunning = sessionActive
        let requestIdentifier = activeRequestIdentifier ?? task.identifier
        lock.unlock()

        continuedTask.expirationHandler = { [weak self, weak continuedTask] in
            guard let continuedTask else { return }
            self?.expire(task: continuedTask)
        }
        continuedTask.progress.totalUnitCount = 100
        update(task: continuedTask, phase: "starting", detail: "PhoneClaw LIVE")
        print("[LiveBackground] handler id=\(requestIdentifier) active=\(keepRunning)")

        if !keepRunning {
            complete(task: continuedTask, success: false, reason: "handler_inactive")
        }
    }

    @available(iOS 26.0, *)
    private func expire(task: BGContinuedProcessingTask) {
        complete(task: task, success: false, reason: "expired_by_system")
    }

    @available(iOS 26.0, *)
    private func complete(task: BGContinuedProcessingTask, success: Bool, reason: String) {
        lock.lock()
        sessionActive = false
        let isActiveTask = activeTask === task
        if isActiveTask {
            activeTask = nil
            activeRequestIdentifier = nil
        }
        lock.unlock()

        guard isActiveTask else {
            print("[LiveBackground] complete ignored stale reason=\(reason)")
            return
        }

        task.progress.totalUnitCount = 100
        task.progress.completedUnitCount = success ? 100 : max(task.progress.completedUnitCount, 1)
        task.updateTitle("PhoneClaw LIVE", subtitle: success ? "Ended" : "Stopped")
        task.setTaskCompleted(success: success)
        print("[LiveBackground] completed success=\(success) reason=\(reason)")
    }

    @available(iOS 26.0, *)
    private func update(task: BGContinuedProcessingTask, phase: String, detail: String) {
        task.progress.totalUnitCount = 100
        task.progress.completedUnitCount = max(
            task.progress.completedUnitCount,
            progressUnit(for: phase)
        )
        task.updateTitle("PhoneClaw LIVE", subtitle: clipped(detail))
    }
    #endif

    private func progressUnit(for phase: String) -> Int64 {
        switch phase {
        case "starting": return 5
        case "listening": return 15
        case "recording": return 35
        case "understanding": return 55
        case "processing": return 65
        case "searching", "executing": return 72
        case "summarizing": return 84
        case "skill": return 90
        default: return 10
        }
    }

    private func clipped(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Active" }
        guard trimmed.count > 80 else { return trimmed }
        return String(trimmed.prefix(80))
    }
}
