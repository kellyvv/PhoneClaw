import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        BackgroundDownloadSession.shared.setBackgroundCompletionHandler(
            identifier: identifier,
            completionHandler: completionHandler
        )
    }
}

@main
struct PhoneClawApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // ⚠️ CRITICAL: LiteRTBootstrap MUST be the first call.
        // LiteRT's accelerator registry is a process-level singleton that seals
        // on the first litert_lm_engine_create(). GPU Metal accelerator must be
        // registered before that happens, otherwise GPU engines can never be
        // created in this process. See docs/RUNTIME_ARCHITECTURE_PLAN.md §VI.
        LiteRTBootstrap.bootstrap()

        #if DEBUG
        AudioBypassTest.runIfRequested()
        #endif
    }
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
