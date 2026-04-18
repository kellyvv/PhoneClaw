import SwiftUI

@main
struct PhoneClawApp: App {
    init() {
        PCLog.suppressRuntimeNoise()
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
