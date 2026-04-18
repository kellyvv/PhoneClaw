import SwiftUI

@main
struct PhoneClawApp: App {
    init() {
        PCLog.suppressRuntimeNoise()
    }
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
