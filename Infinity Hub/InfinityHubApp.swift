import AppKit
import SwiftUI

@main
struct InfinityHubApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self)
    private var appDelegate

    @StateObject private var battery: BatteryViewModel
    @StateObject private var loginItem: LoginItemController

    init() {
        let battery = BatteryViewModel()
        _battery = StateObject(wrappedValue: battery)
        _loginItem = StateObject(wrappedValue: LoginItemController())
        AppDelegate.battery = battery
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView(
                battery: battery,
                loginItem: loginItem
            )
        } label: {
            Image(systemName: battery.menuBarSymbol)
                .accessibilityLabel(battery.menuBarAccessibilityLabel)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var battery: BatteryViewModel?

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            Self.battery?.stop()
        }
    }
}
