import Foundation
import IOKit
import IOKit.hid

let amInfinityPollInterval: TimeInterval = 60
let amInfinityInitialRetryInterval: TimeInterval = 5

struct AMBatteryReading: Equatable {
    let chargingStatus: Int
    let level: Int
    let health: Int?
    let exists: Bool

    var isCharging: Bool {
        chargingStatus == 1
    }

    var isCharged: Bool {
        chargingStatus == 2 || (chargingStatus != 0 && level >= 100)
    }

    var isExternallyPowered: Bool {
        chargingStatus != 0
    }
}

enum AMMouseConnection: Equatable {
    case wiredUSB
    case bluetooth
    case receiver

    var label: String {
        switch self {
        case .wiredUSB:
            return "Wired USB"
        case .bluetooth:
            return "Bluetooth"
        case .receiver:
            return "2.4 GHz"
        }
    }
}

enum AMBatteryDeviceModel: Int, Hashable {
    case infinity97
    case infinity8K

    var mouseName: String {
        switch self {
        case .infinity97:
            return "AM Infinity Mouse .97"
        case .infinity8K:
            return "AM Infinity Mouse"
        }
    }

    var receiverName: String {
        "\(mouseName) Receiver"
    }

    var compactMouseName: String {
        switch self {
        case .infinity97:
            return "AM Infinity .97"
        case .infinity8K:
            return "AM Infinity"
        }
    }

    var compactReceiverName: String {
        "\(compactMouseName) Receiver"
    }

    fileprivate var powerSourceMouseName: String {
        mouseName
    }

    fileprivate var powerSourceReceiverName: String {
        "\(powerSourceMouseName) Receiver"
    }

    fileprivate var vendorID: Int {
        switch self {
        case .infinity97:
            return AMInfinity97Protocol.vendorID
        case .infinity8K:
            return OriginalAMInfinityProtocol.vendorID
        }
    }

    fileprivate var mouseProductID: Int {
        switch self {
        case .infinity97:
            return AMInfinity97Protocol.wiredMouseProductID
        case .infinity8K:
            return OriginalAMInfinityProtocol.receiverProductID
        }
    }

    fileprivate var receiverProductID: Int {
        switch self {
        case .infinity97:
            return AMInfinity97Protocol.dongleProductID
        case .infinity8K:
            return OriginalAMInfinityProtocol.receiverProductID
        }
    }
}

struct AMBatteryDeviceGroup: Equatable, Identifiable {
    let id: String
    let model: AMBatteryDeviceModel
    let mouseExpected: Bool
    let receiverExpected: Bool
    let mouseConnection: AMMouseConnection?
    let mouse: AMBatteryReading?
    let receiver: AMBatteryReading?
}

struct AMBatterySnapshot {
    let groups: [AMBatteryDeviceGroup]
    let message: String?

    static let disconnected = AMBatterySnapshot(
        groups: [],
        message: nil
    )
}

final class InfinityHubService: @unchecked Sendable {
    private let readers: [any AMBatteryProfileReader]
    private var powerSources: [String: AccessoryPowerSource] = [:]

    init() {
        readers = [
            AMInfinity97BatteryReader(),
            OriginalAMInfinityBatteryReader(),
        ]
    }

    func poll() -> AMBatterySnapshot {
        let snapshots = readers.map { $0.read() }
        let groups = snapshots.flatMap(\.groups)
        var messages = snapshots.compactMap(\.message)

        do {
            try updatePowerSources(for: groups)
        } catch {
            messages.append(
                "Could not update macOS Batteries: \(error.localizedDescription)"
            )
        }

        return AMBatterySnapshot(
            groups: groups,
            message: messages.isEmpty ? nil : messages.joined(separator: "\n")
        )
    }

    func stop() {
        readers.forEach { $0.stop() }
        powerSources.values.forEach { $0.close() }
        powerSources.removeAll()
    }

    private func updatePowerSources(
        for groups: [AMBatteryDeviceGroup]
    ) throws {
        let groupsByModel = Dictionary(grouping: groups, by: \.model)
        var modelIndices: [AMBatteryDeviceModel: Int] = [:]
        var activeKeys: Set<String> = []

        for group in groups {
            let modelCount = groupsByModel[group.model]?.count ?? 1
            let modelIndex = (modelIndices[group.model] ?? 0) + 1
            modelIndices[group.model] = modelIndex
            let suffix = modelCount > 1 ? " \(modelIndex)" : ""

            if group.mouseConnection != .bluetooth,
               let reading = group.mouse
            {
                let key = "\(group.id).mouse"
                activeKeys.insert(key)
                let source = powerSource(
                    for: key,
                    name: "\(group.model.powerSourceMouseName)\(suffix)",
                    category: "Mouse",
                    vendorID: group.model.vendorID,
                    productID: group.model.mouseProductID
                )
                try source.publish(reading)
            }

            if let reading = group.receiver {
                let key = "\(group.id).receiver"
                activeKeys.insert(key)
                let source = powerSource(
                    for: key,
                    name:
                        "\(group.model.powerSourceReceiverName)\(suffix)",
                    category: "Unknown",
                    vendorID: group.model.vendorID,
                    productID: group.model.receiverProductID
                )
                try source.publish(reading)
            }
        }

        for key in Array(powerSources.keys)
        where !activeKeys.contains(key) {
            powerSources[key]?.close()
            powerSources.removeValue(forKey: key)
        }
    }

    private func powerSource(
        for key: String,
        name: String,
        category: String,
        vendorID: Int,
        productID: Int
    ) -> AccessoryPowerSource {
        if let existing = powerSources[key] {
            return existing
        }

        let identifierSuffix = key
            .lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let source = AccessoryPowerSource(
            name: name,
            category: category,
            identifier:
                "angrymiao.infinityhub.\(String(identifierSuffix))",
            vendorID: vendorID,
            productID: productID
        )
        powerSources[key] = source
        return source
    }
}

private protocol AMBatteryProfileReader {
    func read() -> AMBatterySnapshot
    func stop()
}

private extension AMBatteryProfileReader {
    func stop() {}
}

private enum AMInfinity97Protocol {
    static let vendorID = 0x0E8D
    static let wiredMouseProductID = 0x0880
    static let dongleProductID = 0x0703
    static let usagePage = 0xFF13
    static let usage = 0x01

    static let outputReportID: CFIndex = 0x06
    static let inputReportID: CFIndex = 0x07
    static let reportLength = 62

    static let mouseBatteryCommand: [UInt8] = [
        0x05, 0x5A, 0x02, 0x00, 0xCF, 0x30,
    ]
    static let baseBatteryCommand: [UInt8] = [
        0x05, 0x5A, 0x02, 0x00, 0x0F, 0x30,
    ]
}

private enum OriginalAMInfinityProtocol {
    static let vendorID = 0x3151
    static let receiverProductID = 0x5007
    static let usagePage = 0xFFFF
    static let usage = 0x0002
    static let reportID: CFIndex = 0
    static let reportLength = 64
    static let productName = "AM INFINITY 8K MOUSE"
    static let reportDescriptor = Data([
        0x06, 0xFF, 0xFF, 0x09, 0x02, 0xA1, 0x01,
        0x09, 0x02, 0x15, 0x80, 0x25, 0x7F, 0x95,
        0x40, 0x75, 0x08, 0xB1, 0x02, 0xC0,
    ])

    static let mailboxInitializeRequest =
        [UInt8(0xF6), 0x05]
        + [UInt8](repeating: 0, count: reportLength - 2)
    static let statusRequest =
        [UInt8(0xF7)]
        + [UInt8](repeating: 0, count: reportLength - 1)
    static let mailboxLengthRequest =
        [UInt8(0xFE), 0x40]
        + [UInt8](repeating: 0, count: reportLength - 2)
    static let mouseBatteryRequest =
        [UInt8(0xD6), 0, 0, 0, 0, 0, 0, 0x29]
        + [UInt8](repeating: 0, count: reportLength - 8)
    static let mailboxReadRequest =
        [UInt8(0xFC)]
        + [UInt8](repeating: 0, count: reportLength - 1)

    // The production reader may only send these exact, verified read-only
    // requests. No configuration payload is permitted through this interface.
    static let readOnlyRequestAllowlist = [
        mailboxInitializeRequest,
        statusRequest,
        mailboxLengthRequest,
        mouseBatteryRequest,
        mailboxReadRequest,
    ]

    static let featureExchangeDelay: TimeInterval = 0.01
    static let mailboxPollAttempts = 10
    static let sendReadyPollInterval: TimeInterval = 0.1
    static let readReadyPollInterval: TimeInterval = 0.11
}

private enum BatteryServiceError: LocalizedError {
    case managerOpen(IOReturn)
    case deviceNotFound(vendorID: Int, productID: Int)
    case unexpectedInterface(String)
    case deviceOpen(IOReturn)
    case setReport(IOReturn)
    case getReport(IOReturn)
    case invalidResponse
    case mailboxTimedOut(String)
    case responseTimedOut(raceID: [UInt8])
    case powerSourceCreate(IOReturn)
    case powerSourceUpdate(name: String, result: IOReturn)

    var errorDescription: String? {
        switch self {
        case .managerOpen(let result):
            return "Unable to open IOHIDManager (\(formatted(result)))"
        case .deviceNotFound(let vendorID, let productID):
            return String(
                format: "Protocol HID interface 0x%04X:0x%04X was not found",
                vendorID,
                productID
            )
        case .unexpectedInterface(let reason):
            return "Protocol HID interface failed its safety check (\(reason))"
        case .deviceOpen(let result):
            return "Unable to open the protocol HID interface (\(formatted(result)))"
        case .setReport(let result):
            return "Unable to send the battery query (\(formatted(result)))"
        case .getReport(let result):
            return "Unable to read the battery response (\(formatted(result)))"
        case .invalidResponse:
            return "The battery query returned an invalid response"
        case .mailboxTimedOut(let state):
            return "Timed out waiting for the receiver mailbox to become \(state)"
        case .responseTimedOut(let raceID):
            return "Timed out waiting for RACE response \(hex(raceID))"
        case .powerSourceCreate(let result):
            return "Unable to create a macOS accessory source (\(formatted(result)))"
        case .powerSourceUpdate(let name, let result):
            return "Unable to update \(name) (\(formatted(result)))"
        }
    }
}

private func formatted(_ value: IOReturn) -> String {
    String(format: "0x%08X", UInt32(bitPattern: value))
}

private func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
}

private func integerProperty(_ device: IOHIDDevice, _ key: CFString) -> Int? {
    (IOHIDDeviceGetProperty(device, key) as? NSNumber)?.intValue
}

private func stringProperty(_ device: IOHIDDevice, _ key: CFString) -> String? {
    IOHIDDeviceGetProperty(device, key) as? String
}

private func hidDeviceIdentifier(
    _ device: IOHIDDevice,
    prefix: String
) -> String {
    var components: [String] = []
    if let serial = stringProperty(
        device,
        kIOHIDSerialNumberKey as CFString
    ), !serial.isEmpty {
        components.append("serial-\(serial)")
    }

    if let locationID = integerProperty(
        device,
        kIOHIDLocationIDKey as CFString
    ) {
        components.append(
            "location-\(String(locationID, radix: 16))"
        )
    }

    if !components.isEmpty {
        return ([prefix] + components).joined(separator: "-")
    }

    var registryID: UInt64 = 0
    let service = IOHIDDeviceGetService(device)
    if IORegistryEntryGetRegistryEntryID(service, &registryID)
        == KERN_SUCCESS
    {
        return "\(prefix)-registry-\(String(registryID, radix: 16))"
    }

    return "\(prefix)-unknown"
}

private final class InputReportMonitor {
    private let device: IOHIDDevice
    private let buffer: UnsafeMutablePointer<UInt8>
    private let bufferLength = 64
    private let lock = NSLock()
    private var reports: [[UInt8]] = []

    init(device: IOHIDDevice) {
        self.device = device
        buffer = .allocate(capacity: bufferLength)
        buffer.initialize(repeating: 0, count: bufferLength)

        IOHIDDeviceRegisterInputReportCallback(
            device,
            buffer,
            bufferLength,
            { context, result, _, _, reportID, report, reportLength in
                guard result == kIOReturnSuccess,
                      let context,
                      reportLength > 0
                else { return }

                let monitor = Unmanaged<InputReportMonitor>
                    .fromOpaque(context)
                    .takeUnretainedValue()
                let payload = Array(
                    UnsafeBufferPointer(start: report, count: reportLength)
                )
                monitor.append([UInt8(reportID)] + payload)
            },
            Unmanaged.passUnretained(self).toOpaque()
        )
        IOHIDDeviceScheduleWithRunLoop(
            device,
            CFRunLoopGetCurrent(),
            CFRunLoopMode.defaultMode.rawValue
        )
    }

    private func append(_ report: [UInt8]) {
        lock.lock()
        reports.append(report)
        lock.unlock()
    }

    func drain() -> [[UInt8]] {
        lock.lock()
        defer { lock.unlock() }
        let drained = reports
        reports.removeAll(keepingCapacity: true)
        return drained
    }

    func clear() {
        _ = drain()
    }

    func stop() {
        IOHIDDeviceUnscheduleFromRunLoop(
            device,
            CFRunLoopGetCurrent(),
            CFRunLoopMode.defaultMode.rawValue
        )
        IOHIDDeviceRegisterInputReportCallback(
            device,
            buffer,
            bufferLength,
            nil,
            nil
        )
    }

    deinit {
        buffer.deinitialize(count: bufferLength)
        buffer.deallocate()
    }
}

private struct HIDConnection {
    let manager: IOHIDManager
    let device: IOHIDDevice

    func close() {
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }
}

private final class HIDDeviceCollection {
    let manager: IOHIDManager
    let devices: [IOHIDDevice]
    private var isClosed = false

    init(manager: IOHIDManager, devices: [IOHIDDevice]) {
        self.manager = manager
        self.devices = devices
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        devices.forEach {
            _ = IOHIDDeviceClose(
                $0,
                IOOptionBits(kIOHIDOptionsTypeNone)
            )
        }
        _ = IOHIDManagerClose(
            manager,
            IOOptionBits(kIOHIDOptionsTypeNone)
        )
    }

    deinit {
        close()
    }
}

private final class AMInfinity97BatteryReader: AMBatteryProfileReader {
    private let bluetoothReader = AMInfinity97BluetoothBatteryReader()

    func read() -> AMBatterySnapshot {
        var groups: [AMBatteryDeviceGroup] = []
        var errors: [String] = []
        let bluetoothMouse = bluetoothReader.read()

        do {
            let connections = try openDevices(
                productID: AMInfinity97Protocol.wiredMouseProductID
            )
            for device in connections.devices {
                groups.append(
                    AMBatteryDeviceGroup(
                        id: hidDeviceIdentifier(
                            device,
                            prefix: "infinity-97-wired"
                        ),
                        model: .infinity97,
                        mouseExpected: true,
                        receiverExpected: false,
                        mouseConnection: .wiredUSB,
                        mouse: readMouse(device, remote: false),
                        receiver: nil
                    )
                )
            }
            connections.close()
        } catch BatteryServiceError.deviceNotFound {
        } catch {
            errors.append("Wired mouse: \(error.localizedDescription)")
        }

        let hasWiredMouseReading = groups.contains {
            $0.mouseConnection == .wiredUSB && $0.mouse != nil
        }
        if !hasWiredMouseReading, let bluetoothMouse {
            groups.append(
                AMBatteryDeviceGroup(
                    id: "infinity-97-bluetooth",
                    model: .infinity97,
                    mouseExpected: true,
                    receiverExpected: false,
                    mouseConnection: .bluetooth,
                    mouse: bluetoothMouse,
                    receiver: nil
                )
            )
        }

        let includeReceiverMouse =
            !hasWiredMouseReading && bluetoothMouse == nil
        do {
            let connections = try openDevices(
                productID: AMInfinity97Protocol.dongleProductID
            )
            for device in connections.devices {
                let readings = readDongle(
                    device,
                    includeMouse: includeReceiverMouse
                )
                groups.append(
                    AMBatteryDeviceGroup(
                        id: hidDeviceIdentifier(
                            device,
                            prefix: "infinity-97-receiver"
                        ),
                        model: .infinity97,
                        mouseExpected: includeReceiverMouse,
                        receiverExpected: true,
                        mouseConnection:
                            includeReceiverMouse ? .receiver : nil,
                        mouse: readings.mouse,
                        receiver: readings.base
                    )
                )
            }
            connections.close()
        } catch BatteryServiceError.deviceNotFound {
        } catch {
            errors.append("Receiver: \(error.localizedDescription)")
        }

        return AMBatterySnapshot(
            groups: groups,
            message:
                errors.isEmpty ? nil : errors.joined(separator: "\n")
        )
    }

    func stop() {
        bluetoothReader.stop()
    }

    private func openDevices(productID: Int) throws -> HIDDeviceCollection {
        let manager = IOHIDManagerCreate(
            kCFAllocatorDefault,
            IOOptionBits(kIOHIDOptionsTypeNone)
        )
        IOHIDManagerSetDeviceMatching(
            manager,
            [
                kIOHIDVendorIDKey: AMInfinity97Protocol.vendorID,
                kIOHIDProductIDKey: productID,
                kIOHIDPrimaryUsagePageKey: AMInfinity97Protocol.usagePage,
                kIOHIDPrimaryUsageKey: AMInfinity97Protocol.usage,
            ] as CFDictionary
        )

        let managerResult = IOHIDManagerOpen(
            manager,
            IOOptionBits(kIOHIDOptionsTypeNone)
        )
        guard managerResult == kIOReturnSuccess else {
            throw BatteryServiceError.managerOpen(managerResult)
        }

        let matchedDevices = Array(
            (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
        )
        let devices = matchedDevices
            .filter {
                integerProperty($0, kIOHIDVendorIDKey as CFString)
                    == AMInfinity97Protocol.vendorID
                    && integerProperty($0, kIOHIDProductIDKey as CFString)
                        == productID
                    && integerProperty(
                        $0,
                        kIOHIDPrimaryUsagePageKey as CFString
                    ) == AMInfinity97Protocol.usagePage
                    && integerProperty(
                        $0,
                        kIOHIDPrimaryUsageKey as CFString
                    ) == AMInfinity97Protocol.usage
            }
            .sorted {
                hidDeviceIdentifier($0, prefix: "hid")
                    < hidDeviceIdentifier($1, prefix: "hid")
            }
        guard !devices.isEmpty else {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            throw BatteryServiceError.deviceNotFound(
                vendorID: AMInfinity97Protocol.vendorID,
                productID: productID
            )
        }

        var openedDevices: [IOHIDDevice] = []
        var firstOpenFailure: IOReturn?
        for device in devices {
            let result = IOHIDDeviceOpen(
                device,
                IOOptionBits(kIOHIDOptionsTypeNone)
            )
            if result == kIOReturnSuccess {
                openedDevices.append(device)
            } else if firstOpenFailure == nil {
                firstOpenFailure = result
            }
        }

        guard !openedDevices.isEmpty else {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            throw BatteryServiceError.deviceOpen(
                firstOpenFailure ?? kIOReturnError
            )
        }

        return HIDDeviceCollection(
            manager: manager,
            devices: openedDevices
        )
    }

    private func readDongle(
        _ device: IOHIDDevice,
        includeMouse: Bool
    ) -> (mouse: AMBatteryReading?, base: AMBatteryReading?) {
        let monitor = InputReportMonitor(device: device)
        defer { monitor.stop() }

        let mouse: AMBatteryReading?
        if includeMouse {
            mouse = attempt(
                device: device,
                monitor: monitor,
                command: AMInfinity97Protocol.mouseBatteryCommand,
                remote: true
            )
            Thread.sleep(forTimeInterval: 0.1)
        } else {
            mouse = nil
        }

        let base = attempt(
            device: device,
            monitor: monitor,
            command: AMInfinity97Protocol.baseBatteryCommand,
            remote: false
        )

        return (mouse, base)
    }

    private func readMouse(
        _ device: IOHIDDevice,
        remote: Bool
    ) -> AMBatteryReading? {
        let monitor = InputReportMonitor(device: device)
        defer { monitor.stop() }

        return attempt(
            device: device,
            monitor: monitor,
            command: AMInfinity97Protocol.mouseBatteryCommand,
            remote: remote
        )
    }

    private func attempt(
        device: IOHIDDevice,
        monitor: InputReportMonitor,
        command: [UInt8],
        remote: Bool
    ) -> AMBatteryReading? {
        try? query(
            device: device,
            monitor: monitor,
            command: command,
            remote: remote
        )
    }

    private func query(
        device: IOHIDDevice,
        monitor: InputReportMonitor,
        command: [UInt8],
        remote: Bool
    ) throws -> AMBatteryReading {
        monitor.clear()

        var packet = [
            UInt8(AMInfinity97Protocol.outputReportID),
            UInt8(command.count),
            remote ? 0x80 : 0x00,
        ]
        packet.append(contentsOf: command)
        if packet.count < AMInfinity97Protocol.reportLength {
            packet.append(
                contentsOf: repeatElement(
                    0,
                    count: AMInfinity97Protocol.reportLength - packet.count
                )
            )
        }

        var outputPayload = packet
        let sendResult = outputPayload.withUnsafeMutableBufferPointer { pointer in
            IOHIDDeviceSetReport(
                device,
                kIOHIDReportTypeOutput,
                AMInfinity97Protocol.outputReportID,
                pointer.baseAddress!,
                pointer.count
            )
        }
        guard sendResult == kIOReturnSuccess else {
            throw BatteryServiceError.setReport(sendResult)
        }

        let raceID = Array(command[4..<6])
        let deadline = Date().addingTimeInterval(1.5)

        while Date() < deadline {
            CFRunLoopRunInMode(.defaultMode, 0.02, true)

            for report in monitor.drain() {
                if let reading = batteryReading(in: report, raceID: raceID) {
                    return reading
                }
            }

            var inputPayload = [UInt8](
                repeating: 0,
                count: AMInfinity97Protocol.reportLength
            )
            inputPayload[0] = UInt8(AMInfinity97Protocol.inputReportID)
            var inputLength = inputPayload.count
            let result = inputPayload.withUnsafeMutableBufferPointer { pointer in
                IOHIDDeviceGetReport(
                    device,
                    kIOHIDReportTypeInput,
                    AMInfinity97Protocol.inputReportID,
                    pointer.baseAddress!,
                    &inputLength
                )
            }
            guard result == kIOReturnSuccess else { continue }

            let report = Array(inputPayload.prefix(inputLength))
            if let reading = batteryReading(in: report, raceID: raceID) {
                return reading
            }
        }

        throw BatteryServiceError.responseTimedOut(raceID: raceID)
    }

    private func batteryReading(
        in report: [UInt8],
        raceID: [UInt8]
    ) -> AMBatteryReading? {
        guard report.count >= 11, raceID.count == 2 else { return nil }

        // The receiver may append a 05 5B response behind an unsolicited 05 5D
        // event in one HID report. Scan for the matching RACE response body.
        for index in 0...(report.count - 11) {
            guard report[index] == 0x05,
                  report[index + 1] == 0x5B,
                  report[index + 4] == raceID[0],
                  report[index + 5] == raceID[1]
            else { continue }

            let chargingStatus = Int(report[index + 7])
            let level = min(max(Int(report[index + 8]), 0), 100)
            let rawHealth = Int(report[index + 9])

            return AMBatteryReading(
                chargingStatus: chargingStatus,
                level: level,
                health: rawHealth == 0xFF ? nil : rawHealth,
                exists: report[index + 10] != 0
            )
        }

        return nil
    }
}

private final class OriginalAMInfinityBatteryReader: AMBatteryProfileReader {
    private struct ReceiverStatus {
        let readReady: Int
        let mouseOnlineRaw: Int
        let sendReady: Int
        let receiverLevel: Int

        var mouseIsOnline: Bool {
            // The official driver maps zero to online and non-zero to offline.
            mouseOnlineRaw == 0
        }
    }

    private struct MouseBatteryStatus {
        let status: Int
        let enabled: Int
        let percent: Int
    }

    func read() -> AMBatterySnapshot {
        var groupID: String?

        do {
            let connection = try open()
            defer { connection.close() }
            let id = hidDeviceIdentifier(
                connection.device,
                prefix: "infinity-8k-receiver"
            )
            groupID = id

            let receiverStatus = try queryReceiverStatus(
                device: connection.device
            )
            let mouse: AMBatteryReading?
            if receiverStatus.mouseIsOnline {
                let battery = try queryMouseBattery(
                    device: connection.device
                )
                mouse = AMBatteryReading(
                    chargingStatus: 0,
                    level: battery.percent,
                    health: nil,
                    exists: battery.enabled != 0
                )
            } else {
                mouse = nil
            }
            let receiver = AMBatteryReading(
                chargingStatus: 0,
                level: receiverStatus.receiverLevel,
                health: nil,
                exists: true
            )

            return AMBatterySnapshot(
                groups: [
                    AMBatteryDeviceGroup(
                        id: id,
                        model: .infinity8K,
                        mouseExpected: true,
                        receiverExpected: true,
                        mouseConnection:
                            receiverStatus.mouseIsOnline ? .receiver : nil,
                        mouse: mouse,
                        receiver: receiver
                    ),
                ],
                message: nil
            )
        } catch BatteryServiceError.deviceNotFound {
            return .disconnected
        } catch {
            return AMBatterySnapshot(
                groups: groupID.map {
                    [
                        AMBatteryDeviceGroup(
                            id: $0,
                            model: .infinity8K,
                            mouseExpected: true,
                            receiverExpected: true,
                            mouseConnection: nil,
                            mouse: nil,
                            receiver: nil
                        ),
                    ]
                } ?? [],
                message: "Original Infinity: \(error.localizedDescription)"
            )
        }
    }

    private func open() throws -> HIDConnection {
        let manager = IOHIDManagerCreate(
            kCFAllocatorDefault,
            IOOptionBits(kIOHIDOptionsTypeNone)
        )
        IOHIDManagerSetDeviceMatching(
            manager,
            [
                kIOHIDVendorIDKey: OriginalAMInfinityProtocol.vendorID,
                kIOHIDProductIDKey:
                    OriginalAMInfinityProtocol.receiverProductID,
                kIOHIDPrimaryUsagePageKey:
                    OriginalAMInfinityProtocol.usagePage,
                kIOHIDPrimaryUsageKey: OriginalAMInfinityProtocol.usage,
            ] as CFDictionary
        )

        let managerResult = IOHIDManagerOpen(
            manager,
            IOOptionBits(kIOHIDOptionsTypeNone)
        )
        guard managerResult == kIOReturnSuccess else {
            throw BatteryServiceError.managerOpen(managerResult)
        }

        let devices = Array(
            (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
        )
        guard let device = devices.first(where: {
            integerProperty($0, kIOHIDPrimaryUsagePageKey as CFString)
                == OriginalAMInfinityProtocol.usagePage
                && integerProperty($0, kIOHIDPrimaryUsageKey as CFString)
                    == OriginalAMInfinityProtocol.usage
        }) else {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            throw BatteryServiceError.deviceNotFound(
                vendorID: OriginalAMInfinityProtocol.vendorID,
                productID: OriginalAMInfinityProtocol.receiverProductID
            )
        }

        let descriptor = IOHIDDeviceGetProperty(
            device,
            kIOHIDReportDescriptorKey as CFString
        ) as? Data
        let safetyChecks: [(Bool, String)] = [
            (
                integerProperty(device, kIOHIDVendorIDKey as CFString)
                    == OriginalAMInfinityProtocol.vendorID,
                "unexpected vendor ID"
            ),
            (
                integerProperty(device, kIOHIDProductIDKey as CFString)
                    == OriginalAMInfinityProtocol.receiverProductID,
                "unexpected product ID"
            ),
            (
                integerProperty(
                    device,
                    kIOHIDMaxInputReportSizeKey as CFString
                ) == 0,
                "interface exposes input reports"
            ),
            (
                integerProperty(
                    device,
                    kIOHIDMaxOutputReportSizeKey as CFString
                ) == 0,
                "interface exposes output reports"
            ),
            (
                integerProperty(
                    device,
                    kIOHIDMaxFeatureReportSizeKey as CFString
                ) == OriginalAMInfinityProtocol.reportLength,
                "unexpected feature report length"
            ),
            (
                stringProperty(device, kIOHIDProductKey as CFString)
                    == OriginalAMInfinityProtocol.productName,
                "unexpected product name"
            ),
            (
                descriptor == OriginalAMInfinityProtocol.reportDescriptor,
                "unexpected report descriptor"
            ),
        ]
        if let failed = safetyChecks.first(where: { !$0.0 }) {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            throw BatteryServiceError.unexpectedInterface(failed.1)
        }

        let deviceResult = IOHIDDeviceOpen(
            device,
            IOOptionBits(kIOHIDOptionsTypeNone)
        )
        guard deviceResult == kIOReturnSuccess else {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            throw BatteryServiceError.deviceOpen(deviceResult)
        }

        return HIDConnection(manager: manager, device: device)
    }

    private func setFeature(
        device: IOHIDDevice,
        exactAllowedRequest request: [UInt8]
    ) throws {
        guard request.count == OriginalAMInfinityProtocol.reportLength,
              OriginalAMInfinityProtocol.readOnlyRequestAllowlist
                .contains(request)
        else {
            throw BatteryServiceError.invalidResponse
        }

        var payload = request
        let result = payload.withUnsafeMutableBufferPointer { pointer in
            IOHIDDeviceSetReport(
                device,
                kIOHIDReportTypeFeature,
                OriginalAMInfinityProtocol.reportID,
                pointer.baseAddress!,
                pointer.count
            )
        }
        guard result == kIOReturnSuccess else {
            throw BatteryServiceError.setReport(result)
        }
    }

    private func getFeature(device: IOHIDDevice) throws -> [UInt8] {
        var response = [UInt8](
            repeating: 0,
            count: OriginalAMInfinityProtocol.reportLength
        )
        var responseLength = response.count
        let getResult = response.withUnsafeMutableBufferPointer { pointer in
            IOHIDDeviceGetReport(
                device,
                kIOHIDReportTypeFeature,
                OriginalAMInfinityProtocol.reportID,
                pointer.baseAddress!,
                &responseLength
            )
        }
        guard getResult == kIOReturnSuccess else {
            throw BatteryServiceError.getReport(getResult)
        }

        let packet = Array(response.prefix(responseLength))
        guard packet.count == OriginalAMInfinityProtocol.reportLength else {
            throw BatteryServiceError.invalidResponse
        }
        return packet
    }

    private func exchangeFeature(
        device: IOHIDDevice,
        exactAllowedRequest request: [UInt8]
    ) throws -> [UInt8] {
        try setFeature(
            device: device,
            exactAllowedRequest: request
        )
        Thread.sleep(
            forTimeInterval: OriginalAMInfinityProtocol.featureExchangeDelay
        )
        return try getFeature(device: device)
    }

    private func queryReceiverStatus(
        device: IOHIDDevice
    ) throws -> ReceiverStatus {
        let packet = try exchangeFeature(
            device: device,
            exactAllowedRequest: OriginalAMInfinityProtocol.statusRequest
        )

        let readReady = Int(packet[0])
        let mouseOnlineRaw = Int(packet[4])
        let sendReady = Int(packet[5])
        let receiverLevel = Int(packet[10])
        guard packet.contains(where: { $0 != 0 }),
              (0...1).contains(readReady),
              (0...1).contains(mouseOnlineRaw),
              (0...1).contains(sendReady),
              (0...100).contains(receiverLevel)
        else {
            throw BatteryServiceError.invalidResponse
        }

        return ReceiverStatus(
            readReady: readReady,
            mouseOnlineRaw: mouseOnlineRaw,
            sendReady: sendReady,
            receiverLevel: receiverLevel
        )
    }

    private func queryMouseBattery(
        device: IOHIDDevice
    ) throws -> MouseBatteryStatus {
        try setFeature(
            device: device,
            exactAllowedRequest:
                OriginalAMInfinityProtocol.mailboxInitializeRequest
        )

        var sendReady = false
        for _ in 0..<OriginalAMInfinityProtocol.mailboxPollAttempts {
            let status = try queryReceiverStatus(device: device)
            if status.sendReady == 1 {
                sendReady = true
                break
            }
            Thread.sleep(
                forTimeInterval:
                    OriginalAMInfinityProtocol.sendReadyPollInterval
            )
        }
        guard sendReady else {
            throw BatteryServiceError.mailboxTimedOut("send-ready")
        }

        _ = try exchangeFeature(
            device: device,
            exactAllowedRequest:
                OriginalAMInfinityProtocol.mailboxLengthRequest
        )
        _ = try exchangeFeature(
            device: device,
            exactAllowedRequest:
                OriginalAMInfinityProtocol.mouseBatteryRequest
        )

        for _ in 0..<OriginalAMInfinityProtocol.mailboxPollAttempts {
            let status = try queryReceiverStatus(device: device)
            if status.readReady == 1 {
                let response = try exchangeFeature(
                    device: device,
                    exactAllowedRequest:
                        OriginalAMInfinityProtocol.mailboxReadRequest
                )
                return try parseMouseBattery(response)
            }
            Thread.sleep(
                forTimeInterval:
                    OriginalAMInfinityProtocol.readReadyPollInterval
            )
        }

        throw BatteryServiceError.mailboxTimedOut("read-ready")
    }

    private func parseMouseBattery(
        _ response: [UInt8]
    ) throws -> MouseBatteryStatus {
        guard response.count == OriginalAMInfinityProtocol.reportLength,
              response[0] == 0xD6
        else {
            throw BatteryServiceError.invalidResponse
        }

        let status = Int(response[1])
        let enabled = Int(response[2])
        let percent = Int(response[3])
        guard (0...1).contains(enabled),
              (0...100).contains(percent)
        else {
            throw BatteryServiceError.invalidResponse
        }

        return MouseBatteryStatus(
            status: status,
            enabled: enabled,
            percent: percent
        )
    }
}

private typealias IOPSPowerSourceID = OpaquePointer

@_silgen_name("IOPSCreatePowerSource")
private func IOPSCreatePowerSource(
    _ source: UnsafeMutablePointer<IOPSPowerSourceID?>
) -> IOReturn

@_silgen_name("IOPSSetPowerSourceDetails")
private func IOPSSetPowerSourceDetails(
    _ source: IOPSPowerSourceID,
    _ details: CFDictionary
) -> IOReturn

@_silgen_name("IOPSReleasePowerSource")
private func IOPSReleasePowerSource(
    _ source: IOPSPowerSourceID
) -> IOReturn

private final class AccessoryPowerSource {
    private let name: String
    private let category: String
    private let identifier: String
    private let vendorID: Int
    private let productID: Int
    private var source: IOPSPowerSourceID?
    private var lastReading: AMBatteryReading?
    private var isPublishedPresent = false

    init(
        name: String,
        category: String,
        identifier: String,
        vendorID: Int,
        productID: Int
    ) {
        self.name = name
        self.category = category
        self.identifier = identifier
        self.vendorID = vendorID
        self.productID = productID
    }

    func publish(_ reading: AMBatteryReading) throws {
        guard reading.exists else {
            try markAbsent()
            return
        }

        guard reading != lastReading || !isPublishedPresent else { return }
        try createIfNeeded()
        try setDetails(reading: reading, present: true)
        lastReading = reading
        isPublishedPresent = true
    }

    func markAbsent() throws {
        guard source != nil, isPublishedPresent else { return }
        try setDetails(reading: lastReading, present: false)
        isPublishedPresent = false
    }

    func close() {
        guard let source else { return }
        _ = IOPSReleasePowerSource(source)
        self.source = nil
        lastReading = nil
        isPublishedPresent = false
    }

    deinit {
        close()
    }

    private func createIfNeeded() throws {
        guard source == nil else { return }

        let result = IOPSCreatePowerSource(&source)
        guard result == kIOReturnSuccess, source != nil else {
            throw BatteryServiceError.powerSourceCreate(result)
        }
    }

    private func setDetails(
        reading: AMBatteryReading?,
        present: Bool
    ) throws {
        guard let source else { return }

        let level = reading?.level ?? 0
        let isCharging = present && (reading?.isCharging ?? false)
        let isCharged = present && (reading?.isCharged ?? false)
        let externalPower = present && (reading?.isExternallyPowered ?? false)

        let details: [String: Any] = [
            "Name": name,
            "Type": "Accessory Source",
            "Transport Type": "USB",
            "Power Source State": externalPower ? "AC Power" : "Battery Power",
            "Current Capacity": level,
            "Max Capacity": 100,
            "Is Present": present,
            "Is Charging": isCharging,
            "Is Charged": isCharged,
            "Vendor ID": vendorID,
            "Product ID": productID,
            "Accessory Category": category,
            "Accessory Identifier": identifier,
        ]

        let result = IOPSSetPowerSourceDetails(
            source,
            details as CFDictionary
        )
        guard result == kIOReturnSuccess else {
            throw BatteryServiceError.powerSourceUpdate(
                name: name,
                result: result
            )
        }
    }
}
