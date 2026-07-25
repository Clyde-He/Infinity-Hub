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
}

struct AccessoryDisplayGroup: Identifiable {
    let id: String
    let title: String?
    let items: [AccessoryDisplayState]
}

@MainActor
final class BatteryViewModel: ObservableObject {
    private struct CachedWirelessMouse {
        let model: AMBatteryDeviceModel
        let connection: AMMouseConnection
        let reading: AMBatteryReading
        let lastSeen: Date
    }

    private static let wirelessMouseRetentionInterval: TimeInterval = 5 * 60

    @Published private(set) var deviceGroups: [AccessoryDisplayGroup] = []
    @Published private(set) var message: String?
    @Published private(set) var isRefreshing = false

    private lazy var service = InfinityHubService()
    private let worker = DispatchQueue(
        label: "design.specos.infinityhub.poller",
        qos: .utility
    )
    private var scheduledRefresh: DispatchWorkItem?
    private var isPolling = false
    private var isStopped = false
    private var cachedWirelessMice: [String: CachedWirelessMouse] = [:]

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

    #if DEBUG
    init(
        previewDeviceGroups: [AccessoryDisplayGroup],
        message: String? = nil,
        isRefreshing: Bool = false
    ) {
        deviceGroups = previewDeviceGroups
        self.message = message
        self.isRefreshing = isRefreshing
        isStopped = true
    }
    #endif

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

        let groups = visibleGroups(
            from: groupsRetainingWirelessMice(
                snapshot.groups,
                now: Date()
            )
        ).sorted {
            if $0.model.rawValue != $1.model.rawValue {
                return $0.model.rawValue < $1.model.rawValue
            }
            if $0.mouseExpected != $1.mouseExpected {
                return $0.mouseExpected
            }
            return $0.id < $1.id
        }
        deviceGroups = displayGroups(for: groups)

        let missingMouseReading =
            snapshot.groups.isEmpty || snapshot.groups.contains {
                $0.mouseExpected && $0.mouse?.exists != true
            }
        scheduleNext(
            after: missingMouseReading
                ? amInfinityInitialRetryInterval
                : amInfinityPollInterval
        )
    }

    private func groupsRetainingWirelessMice(
        _ groups: [AMBatteryDeviceGroup],
        now: Date
    ) -> [AMBatteryDeviceGroup] {
        cachedWirelessMice = cachedWirelessMice.filter {
            now.timeIntervalSince($0.value.lastSeen)
                <= Self.wirelessMouseRetentionInterval
        }

        let activeGroupIDs = Set(groups.map(\.id))
        cachedWirelessMice = cachedWirelessMice.filter {
            $0.value.connection == .bluetooth
                || activeGroupIDs.contains($0.key)
        }

        let hasFreshNonBluetoothInfinity97Mouse = groups.contains {
            $0.model == .infinity97
                && $0.mouseConnection != .bluetooth
                && $0.mouse?.exists == true
        }
        if hasFreshNonBluetoothInfinity97Mouse {
            cachedWirelessMice = cachedWirelessMice.filter {
                !($0.value.model == .infinity97
                    && $0.value.connection == .bluetooth)
            }
        }

        for group in groups {
            if group.receiverExpected && !group.mouseExpected {
                cachedWirelessMice.removeValue(forKey: group.id)
            }

            guard group.mouseExpected else { continue }

            if group.mouseConnection == .wiredUSB {
                cachedWirelessMice.removeValue(forKey: group.id)
                continue
            }

            guard let connection = group.mouseConnection,
                  connection == .receiver || connection == .bluetooth,
                  let reading = group.mouse,
                  reading.exists
            else {
                continue
            }

            cachedWirelessMice[group.id] = CachedWirelessMouse(
                model: group.model,
                connection: connection,
                reading: reading,
                lastSeen: now
            )
        }

        var retainedGroups = groups.map { group in
            guard group.mouseExpected,
                  group.mouse?.exists != true,
                  let cachedMouse = cachedWirelessMice[group.id]
            else {
                return group
            }

            return AMBatteryDeviceGroup(
                id: group.id,
                model: group.model,
                mouseExpected: true,
                receiverExpected: group.receiverExpected,
                mouseConnection: cachedMouse.connection,
                mouse: cachedMouse.reading,
                receiver: group.receiver
            )
        }

        let retainedGroupIDs = Set(retainedGroups.map(\.id))
        for (id, cachedMouse) in cachedWirelessMice
        where cachedMouse.connection == .bluetooth
            && !retainedGroupIDs.contains(id)
        {
            retainedGroups.append(
                AMBatteryDeviceGroup(
                    id: id,
                    model: cachedMouse.model,
                    mouseExpected: true,
                    receiverExpected: false,
                    mouseConnection: .bluetooth,
                    mouse: cachedMouse.reading,
                    receiver: nil
                )
            )
        }

        return retainedGroups
    }

    private func visibleGroups(
        from groups: [AMBatteryDeviceGroup]
    ) -> [AMBatteryDeviceGroup] {
        groups.compactMap { group in
            let mouse = group.mouse?.exists == true ? group.mouse : nil
            let receiver =
                group.receiver?.exists == true ? group.receiver : nil

            guard mouse != nil || receiver != nil else { return nil }

            return AMBatteryDeviceGroup(
                id: group.id,
                model: group.model,
                mouseExpected: mouse != nil,
                receiverExpected: receiver != nil,
                mouseConnection: mouse == nil ? nil : group.mouseConnection,
                mouse: mouse,
                receiver: receiver
            )
        }
    }

    private func displayGroups(
        for groups: [AMBatteryDeviceGroup]
    ) -> [AccessoryDisplayGroup] {
        if let onlyGroup = groups.first, groups.count == 1 {
            return standaloneDisplayGroups(for: onlyGroup)
        }

        var displayGroups: [AccessoryDisplayGroup] = []

        for group in groups {
            let isCombined = endpointCount(in: group) > 1
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
                    title: isCombined ? group.model.compactMouseName : nil,
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
        var items: [AccessoryDisplayState] = []

        if group.mouseExpected {
            items.append(
                displayState(
                    id: "\(group.id).mouse",
                    kind: .mouse,
                    name:
                        hasMultipleEndpoints
                            ? "Mouse"
                            : group.model.compactMouseName,
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
                        hasMultipleEndpoints
                            ? "Receiver"
                            : group.model.compactReceiverName,
                    reading: group.receiver
                )
            )
        }

        return [
            AccessoryDisplayGroup(
                id: group.id,
                title: nil,
                items: items
            ),
        ]
    }

    private func endpointCount(in group: AMBatteryDeviceGroup) -> Int {
        (group.mouseExpected ? 1 : 0)
            + (group.receiverExpected ? 1 : 0)
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

    private let usesSystemStatus: Bool

    init() {
        usesSystemStatus = true
        refreshStatus()
    }

    #if DEBUG
    init(
        previewIsEnabled: Bool,
        previewRequiresApproval: Bool = false,
        previewErrorMessage: String? = nil
    ) {
        usesSystemStatus = false
        isEnabled = previewIsEnabled
        requiresApproval = previewRequiresApproval
        errorMessage = previewErrorMessage
    }
    #endif

    func refreshStatus() {
        guard usesSystemStatus else { return }
        let status = SMAppService.mainApp.status
        isEnabled = status == .enabled
        requiresApproval = status == .requiresApproval
    }

    func setEnabled(_ enabled: Bool) {
        guard usesSystemStatus else {
            isEnabled = enabled
            return
        }
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
