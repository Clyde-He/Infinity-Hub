import AppKit
import Combine
import SwiftUI

@main
struct InfinityHubApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self)
    private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let battery = BatteryViewModel()
    private let loginItem = LoginItemController()
    private let statusItem = NSStatusBar.system.statusItem(
        withLength: NSStatusItem.variableLength
    )
    private let popover = NSPopover()
    private lazy var contextMenu = makeContextMenu()
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureStatusItem()
        configurePopover()

        battery.$accessories
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateStatusButton()
            }
            .store(in: &cancellables)
    }

    func applicationWillTerminate(_ notification: Notification) {
        battery.stop()
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        updateStatusButton()
    }

    private func configurePopover() {
        let content = MenuBarContentView(
            battery: battery,
            loginItem: loginItem
        )
        let hostingController = NSHostingController(rootView: content)
        hostingController.sizingOptions = [.preferredContentSize]

        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = hostingController
    }

    private func updateStatusButton() {
        guard let button = statusItem.button else { return }
        let image = NSImage(
            systemSymbolName: battery.menuBarSymbol,
            accessibilityDescription: battery.menuBarAccessibilityLabel
        )
        image?.isTemplate = true
        button.image = image
        button.imagePosition = .imageOnly
        button.toolTip = battery.menuBarAccessibilityLabel
        button.setAccessibilityLabel(battery.menuBarAccessibilityLabel)
    }

    @objc
    private func statusItemClicked(_ sender: Any?) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(
                relativeTo: button.bounds,
                of: button,
                preferredEdge: .minY
            )
        }
    }

    private func showContextMenu() {
        popover.performClose(nil)
        loginItem.refreshStatus()
        updateContextMenu()

        guard let button = statusItem.button else { return }
        contextMenu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: button.bounds.minY),
            in: button
        )
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(
            NSMenuItem(
                title: "Refresh",
                action: #selector(refresh),
                keyEquivalent: ""
            )
        )
        menu.addItem(
            NSMenuItem(
                title: "Start at Login",
                action: #selector(toggleStartAtLogin),
                keyEquivalent: ""
            )
        )
        menu.addItem(
            NSMenuItem(
                title: "Quit Infinity Hub",
                action: #selector(quit),
                keyEquivalent: "q"
            )
        )
        menu.items.forEach { $0.target = self }
        return menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        loginItem.refreshStatus()
        updateContextMenu()
    }

    private func updateContextMenu() {
        guard contextMenu.items.count == 3 else { return }
        contextMenu.items[0].isEnabled = !battery.isRefreshing
        contextMenu.items[1].state = loginItem.isEnabled ? .on : .off
    }

    @objc
    private func refresh() {
        battery.refresh()
    }

    @objc
    private func toggleStartAtLogin() {
        loginItem.setEnabled(!loginItem.isEnabled)
        updateContextMenu()
    }

    @objc
    private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
