//
import SwiftUI

@main
struct YunmeiUnlockApp: App {
    @StateObject private var configurationStore = DoorConfigurationStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(configurationStore)
        }
    }
}
