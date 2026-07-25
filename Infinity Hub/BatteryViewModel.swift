import AppKit
import Foundation
import ServiceManagement

enum AccessoryDisplayKind: Equatable {
    case mouse
    case receiver

    var symbol: String {
        switch self {
        case .mouse:
            return "computermouse.fill"
        case .receiver:
            return "cable.connector"
        }
    }
}

struct AccessoryDisplayState: Identifiable {
    let id: String
    let kind: AccessoryDisplayKind
    let name: String
    let level: Int?
    let isPresent: Bool
    let isCharging: Bool
    let isCharged: Bool
    let detail: String?

    static let disconnectedMouse = AccessoryDisplayState(
        id: "disconnected.mouse",
        kind: .mouse,
        name: "Mouse",
        level: nil,
        isPresent: false,
        isCharging: false,
        isCharged: false,
        detail: "Disconnected"
    )

    static let disconnectedBase = AccessoryDisplayState(
        id: "disconnected.receiver",
        kind: .receiver,
        name: "Receiver",
        level: nil,
        isPresent: false,
        isCharging: false,
        isCharged: false,
        detail: "Disconnected"
    )
}

@MainActor
final class BatteryViewModel: ObservableObject {
    @Published private(set) var accessories = [
        AccessoryDisplayState.disconnectedMouse,
        AccessoryDisplayState.disconnectedBase,
    ]
    @Published private(set) var message: String?
    @Published private(set) var isRefreshing = false

    private let service = InfinityHubService()
    private let worker = DispatchQueue(
        label: "design.specos.infinityhub.poller",
        qos: .utility
    )
    private var scheduledRefresh: DispatchWorkItem?
    private var isPolling = false
    private var isStopped = false

    var menuBarSymbol: String {
        if let mouse = accessories.first(where: {
            $0.kind == .mouse && $0.isPresent
        }), let level = mouse.level {
            return batterySymbol(for: level)
        }
        if let receiver = accessories.first(where: {
            $0.kind == .receiver && $0.isPresent
        }), let level = receiver.level {
            return batterySymbol(for: level)
        }
        return "computermouse"
    }

    var menuBarAccessibilityLabel: String {
        if let mouse = accessories.first(where: {
            $0.kind == .mouse && $0.isPresent
        }), let level = mouse.level {
            return "Infinity Hub, \(mouse.name) \(level) percent"
        }
        if let receiver = accessories.first(where: {
            $0.kind == .receiver && $0.isPresent
        }), let level = receiver.level {
            return "Infinity Hub, \(receiver.name) \(level) percent"
        }
        return "Infinity Hub, not connected"
    }

    private func batterySymbol(for level: Int) -> String {
        switch level {
        case 88...:
            return "battery.100percent"
        case 63...:
            return "battery.75percent"
        case 38...:
            return "battery.50percent"
        case 13...:
            return "battery.25percent"
        default:
            return "battery.0percent"
        }
    }

    init() {
        refresh(showActivity: false)
    }

    func refresh(showActivity: Bool = true) {
        guard !isStopped, !isPolling else { return }
        scheduledRefresh?.cancel()
        scheduledRefresh = nil
        isPolling = true
        if showActivity {
            isRefreshing = true
        }

        let service = service
        worker.async { [weak self] in
            guard let self else { return }
            let snapshot = service.poll()
            DispatchQueue.main.async { [weak self] in
                self?.apply(snapshot)
            }
        }
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        scheduledRefresh?.cancel()
        scheduledRefresh = nil
        worker.sync {
            service.stop()
        }
    }

    private func apply(_ snapshot: AMBatterySnapshot) {
        guard !isStopped else { return }
        isPolling = false
        isRefreshing = false
        message = snapshot.message

        let groups = snapshot.groups.sorted {
            if $0.model.rawValue != $1.model.rawValue {
                return $0.model.rawValue < $1.model.rawValue
            }
            return $0.id < $1.id
        }
        if groups.isEmpty {
            accessories = [
                .disconnectedMouse,
                .disconnectedBase,
            ]
        } else {
            accessories = displayStates(for: groups)
        }

        let missingMouseReading = groups.isEmpty || groups.contains {
            $0.mouseExpected && $0.mouse?.exists != true
        }
        scheduleNext(
            after: missingMouseReading
                ? amInfinityInitialRetryInterval
                : amInfinityPollInterval
        )
    }

    private func displayStates(
        for groups: [AMBatteryDeviceGroup]
    ) -> [AccessoryDisplayState] {
        let isSingleGroup = groups.count == 1
        let mouseCounts = Dictionary(
            grouping: groups.filter(\.mouseExpected),
            by: \.model
        ).mapValues(\.count)
        let receiverCounts = Dictionary(
            grouping: groups.filter(\.receiverExpected),
            by: \.model
        ).mapValues(\.count)
        var mouseIndices: [AMBatteryDeviceModel: Int] = [:]
        var receiverIndices: [AMBatteryDeviceModel: Int] = [:]
        var states: [AccessoryDisplayState] = []

        for group in groups {
            if group.mouseExpected {
                let index = (mouseIndices[group.model] ?? 0) + 1
                mouseIndices[group.model] = index
                let name = isSingleGroup
                    ? "Mouse"
                    : displayName(
                        group.model.mouseName,
                        count: mouseCounts[group.model] ?? 1,
                        index: index
                    )
                states.append(
                    displayState(
                        id: "\(group.id).mouse",
                        kind: .mouse,
                        name: name,
                        reading: group.mouse,
                        connection: group.mouseConnection
                    )
                )
            }

            if group.receiverExpected {
                let index = (receiverIndices[group.model] ?? 0) + 1
                receiverIndices[group.model] = index
                let name = isSingleGroup
                    ? "Receiver"
                    : displayName(
                        group.model.receiverName,
                        count: receiverCounts[group.model] ?? 1,
                        index: index
                    )
                states.append(
                    displayState(
                        id: "\(group.id).receiver",
                        kind: .receiver,
                        name: name,
                        reading: group.receiver
                    )
                )
            }
        }

        return states
    }

    private func displayName(
        _ name: String,
        count: Int,
        index: Int
    ) -> String {
        count > 1 ? "\(name) \(index)" : name
    }

    private func scheduleNext(after delay: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in
            self?.refresh(showActivity: false)
        }
        scheduledRefresh = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + delay,
            execute: work
        )
    }

    private func displayState(
        id: String,
        kind: AccessoryDisplayKind,
        name: String,
        reading: AMBatteryReading?,
        connection: AMMouseConnection? = nil
    ) -> AccessoryDisplayState {
        guard let reading, reading.exists else {
            return AccessoryDisplayState(
                id: id,
                kind: kind,
                name: name,
                level: nil,
                isPresent: false,
                isCharging: false,
                isCharged: false,
                detail: "Disconnected"
            )
        }

        return AccessoryDisplayState(
            id: id,
            kind: kind,
            name: name,
            level: reading.level,
            isPresent: true,
            isCharging: reading.isCharging,
            isCharged: reading.isCharged,
            detail: connection?.label
        )
    }
}

@MainActor
final class LoginItemController: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var requiresApproval = false
    @Published private(set) var errorMessage: String?

    init() {
        refreshStatus()
    }

    func refreshStatus() {
        let status = SMAppService.mainApp.status
        isEnabled = status == .enabled
        requiresApproval = status == .requiresApproval
    }

    func setEnabled(_ enabled: Bool) {
        errorMessage = nil

        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        refreshStatus()
    }
}
