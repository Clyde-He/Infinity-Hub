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

struct AccessoryDisplayGroup: Identifiable {
    let id: String
    let title: String?
    let detail: String?
    let items: [AccessoryDisplayState]
}

@MainActor
final class BatteryViewModel: ObservableObject {
    @Published private(set) var deviceGroups = [
        AccessoryDisplayGroup(
            id: "disconnected.mouse.group",
            title: nil,
            detail: nil,
            items: [.disconnectedMouse]
        ),
        AccessoryDisplayGroup(
            id: "disconnected.receiver.group",
            title: nil,
            detail: nil,
            items: [.disconnectedBase]
        ),
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

    private var accessories: [AccessoryDisplayState] {
        deviceGroups.flatMap(\.items)
    }

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
            deviceGroups = [
                AccessoryDisplayGroup(
                    id: "disconnected.mouse.group",
                    title: nil,
                    detail: nil,
                    items: [.disconnectedMouse]
                ),
                AccessoryDisplayGroup(
                    id: "disconnected.receiver.group",
                    title: nil,
                    detail: nil,
                    items: [.disconnectedBase]
                ),
            ]
        } else {
            deviceGroups = displayGroups(for: groups)
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

    private func displayGroups(
        for groups: [AMBatteryDeviceGroup]
    ) -> [AccessoryDisplayGroup] {
        if let onlyGroup = groups.first, groups.count == 1 {
            return standaloneDisplayGroups(for: onlyGroup)
        }

        let combinedCounts = Dictionary(
            grouping: groups.filter {
                endpointCount(in: $0) > 1
            },
            by: \.model
        ).mapValues(\.count)
        var combinedIndices: [AMBatteryDeviceModel: Int] = [:]
        var displayGroups: [AccessoryDisplayGroup] = []

        for group in groups {
            let isCombined = endpointCount(in: group) > 1
            let combinedIndex: Int?
            if isCombined {
                let index = (combinedIndices[group.model] ?? 0) + 1
                combinedIndices[group.model] = index
                combinedIndex = index
            } else {
                combinedIndex = nil
            }
            var items: [AccessoryDisplayState] = []

            if group.mouseExpected {
                items.append(
                    displayState(
                        id: "\(group.id).mouse",
                        kind: .mouse,
                        name:
                            isCombined ? "Mouse" : group.model.compactMouseName,
                        reading: group.mouse,
                        connection: group.mouseConnection
                    )
                )
            }

            if group.receiverExpected {
                items.append(
                    displayState(
                        id: "\(group.id).receiver",
                        kind: .receiver,
                        name:
                            isCombined
                                ? "Receiver"
                                : group.model.compactReceiverName,
                        reading: group.receiver
                    )
                )
            }

            displayGroups.append(
                AccessoryDisplayGroup(
                    id: group.id,
                    title: isCombined ? group.model.mouseName : nil,
                    detail: isCombined
                        ? combinedDetail(
                            for: group,
                            count: combinedCounts[group.model] ?? 1,
                            index: combinedIndex ?? 1
                        )
                        : nil,
                    items: items
                )
            )
        }

        return displayGroups
    }

    private func standaloneDisplayGroups(
        for group: AMBatteryDeviceGroup
    ) -> [AccessoryDisplayGroup] {
        let hasMultipleEndpoints = endpointCount(in: group) > 1
        var groups: [AccessoryDisplayGroup] = []

        if group.mouseExpected {
            groups.append(
                AccessoryDisplayGroup(
                    id: "\(group.id).mouse.group",
                    title: nil,
                    detail: nil,
                    items: [
                        displayState(
                            id: "\(group.id).mouse",
                            kind: .mouse,
                            name:
                                hasMultipleEndpoints
                                    ? "Mouse"
                                    : group.model.compactMouseName,
                            reading: group.mouse,
                            connection: group.mouseConnection
                        ),
                    ]
                )
            )
        }

        if group.receiverExpected {
            groups.append(
                AccessoryDisplayGroup(
                    id: "\(group.id).receiver.group",
                    title: nil,
                    detail: nil,
                    items: [
                        displayState(
                            id: "\(group.id).receiver",
                            kind: .receiver,
                            name:
                                hasMultipleEndpoints
                                    ? "Receiver"
                                    : group.model.compactReceiverName,
                            reading: group.receiver
                        ),
                    ]
                )
            )
        }

        return groups
    }

    private func endpointCount(in group: AMBatteryDeviceGroup) -> Int {
        (group.mouseExpected ? 1 : 0)
            + (group.receiverExpected ? 1 : 0)
    }

    private func combinedDetail(
        for group: AMBatteryDeviceGroup,
        count: Int,
        index: Int
    ) -> String {
        let connection =
            group.mouseConnection?.label
            ?? AMMouseConnection.receiver.label
        return count > 1
            ? "\(connection) · \(index)"
            : connection
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
