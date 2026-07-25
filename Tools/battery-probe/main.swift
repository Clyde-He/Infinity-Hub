import Foundation
import IOKit.hid

private let vendorID = 0x0E8D
private let wiredMouseProductID = 0x0880
private let dongleProductID = 0x0703
private let protocolUsagePage = 0xFF13
private let protocolUsage = 0x01

private let outputReportID: CFIndex = 0x06
private let inputReportID: CFIndex = 0x07
private let hidapiReportLength = 62
private let deviceOpenOptions = IOOptionBits(kIOHIDOptionsTypeNone)

private enum ProbeError: Error, CustomStringConvertible {
    case managerOpen(IOReturn)
    case deviceNotFound
    case deviceOpen(IOReturn)
    case setReport(IOReturn)
    case responseTimedOut(raceID: [UInt8], lastResult: IOReturn?)

    var description: String {
        switch self {
        case .managerOpen(let value):
            return String(format: "Unable to open IOHIDManager: 0x%08X", UInt32(bitPattern: value))
        case .deviceNotFound:
            return "AM Infinity .97 mouse HID interface was not found"
        case .deviceOpen(let value):
            return String(format: "Unable to open mouse HID interface: 0x%08X", UInt32(bitPattern: value))
        case .setReport(let value):
            return String(format: "Unable to send battery query: 0x%08X", UInt32(bitPattern: value))
        case .responseTimedOut(let raceID, let lastResult):
            let id = raceID.map { String(format: "%02X", $0) }.joined(separator: " ")
            let result = lastResult.map {
                String(format: "0x%08X", UInt32(bitPattern: $0))
            } ?? "none"
            return "Timed out waiting for raceID \(id); last IO result \(result)"
        }
    }
}

private func integerProperty(_ device: IOHIDDevice, _ key: CFString) -> Int? {
    (IOHIDDeviceGetProperty(device, key) as? NSNumber)?.intValue
}

private func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
}

private final class InputReportMonitor {
    private let device: IOHIDDevice
    private let buffer: UnsafeMutablePointer<UInt8>
    private let bufferLength = 64
    private let lock = NSLock()
    private var reports: [(id: UInt32, bytes: [UInt8])] = []

    init(device: IOHIDDevice) {
        self.device = device
        buffer = .allocate(capacity: bufferLength)
        buffer.initialize(repeating: 0, count: bufferLength)

        IOHIDDeviceRegisterInputReportCallback(
            device,
            buffer,
            bufferLength,
            { context, result, _, _, reportID, report, reportLength in
                guard
                    result == kIOReturnSuccess,
                    let context,
                    reportLength > 0
                else { return }

                let monitor = Unmanaged<InputReportMonitor>
                    .fromOpaque(context)
                    .takeUnretainedValue()
                let bytes = Array(
                    UnsafeBufferPointer(start: report, count: reportLength)
                )
                monitor.lock.lock()
                monitor.reports.append((reportID, bytes))
                monitor.lock.unlock()
            },
            Unmanaged.passUnretained(self).toOpaque()
        )
        IOHIDDeviceScheduleWithRunLoop(
            device,
            CFRunLoopGetCurrent(),
            CFRunLoopMode.defaultMode.rawValue
        )
    }

    func drain() -> [(id: UInt32, bytes: [UInt8])] {
        lock.lock()
        defer { lock.unlock() }
        let result = reports
        reports.removeAll(keepingCapacity: true)
        return result
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

private func matchingProtocolInterface(productID: Int) throws -> (IOHIDManager, IOHIDDevice) {
    let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    IOHIDManagerSetDeviceMatching(
        manager,
        [
            kIOHIDVendorIDKey: vendorID,
            kIOHIDProductIDKey: productID,
            kIOHIDPrimaryUsagePageKey: protocolUsagePage,
            kIOHIDPrimaryUsageKey: protocolUsage,
        ] as CFDictionary
    )

    let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    guard openResult == kIOReturnSuccess else {
        throw ProbeError.managerOpen(openResult)
    }

    let devices = Array((IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? [])
    guard let device = devices.first(where: {
        integerProperty($0, kIOHIDPrimaryUsagePageKey as CFString) == protocolUsagePage
            && integerProperty($0, kIOHIDPrimaryUsageKey as CFString) == protocolUsage
    }) else {
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        throw ProbeError.deviceNotFound
    }

    return (manager, device)
}

private func responseIncludingReportID(_ raw: [UInt8], raceID: [UInt8]) -> [UInt8]? {
    let candidates = [[UInt8(inputReportID)] + raw, raw]
    return candidates.first(where: {
        $0.count >= 14
            && Array($0[7..<9]) == raceID
    })
}

private func query(
    device: IOHIDDevice,
    monitor: InputReportMonitor,
    command: [UInt8],
    remote: Bool
) throws -> [UInt8] {
    guard command.count >= 6 else { preconditionFailure("Command is too short") }

    var hidapiPacket = [UInt8(outputReportID), UInt8(command.count), remote ? 0x80 : 0x00]
    hidapiPacket.append(contentsOf: command)
    if hidapiPacket.count < hidapiReportLength {
        hidapiPacket.append(
            contentsOf: repeatElement(0, count: hidapiReportLength - hidapiPacket.count)
        )
    }
    print("  output report: \(hex(hidapiPacket))")

    // hidapi's macOS backend passes the complete buffer, including a non-zero
    // report ID at byte 0, to IOHIDDeviceSetReport.
    var outputPayload = hidapiPacket
    let sendResult = outputPayload.withUnsafeMutableBufferPointer { pointer in
        IOHIDDeviceSetReport(
            device,
            kIOHIDReportTypeOutput,
            outputReportID,
            pointer.baseAddress!,
            pointer.count
        )
    }
    guard sendResult == kIOReturnSuccess else {
        throw ProbeError.setReport(sendResult)
    }

    let raceID = Array(command[4..<6])
    let deadline = Date().addingTimeInterval(1.0)
    var lastResult: IOReturn?
    var seenRawReports = Set<String>()

    while Date() < deadline {
        CFRunLoopRunInMode(.defaultMode, 0.01, true)
        for asyncReport in monitor.drain() {
            let candidates = [
                [UInt8(asyncReport.id)] + asyncReport.bytes,
                asyncReport.bytes,
            ]
            for raw in candidates {
                let rawDescription = hex(raw)
                if seenRawReports.insert("async " + rawDescription).inserted
                    && seenRawReports.count <= 5
                {
                    print("  async input report: \(rawDescription)")
                }
                if let response = responseIncludingReportID(raw, raceID: raceID) {
                    return response
                }
            }
        }

        var inputPayload = [UInt8](repeating: 0, count: hidapiReportLength)
        inputPayload[0] = UInt8(inputReportID)
        var inputLength = inputPayload.count
        let result = inputPayload.withUnsafeMutableBufferPointer { pointer in
            IOHIDDeviceGetReport(
                device,
                kIOHIDReportTypeInput,
                inputReportID,
                pointer.baseAddress!,
                &inputLength
            )
        }
        lastResult = result
        guard result == kIOReturnSuccess else { continue }

        let raw = Array(inputPayload.prefix(inputLength))
        let rawDescription = hex(raw)
        if seenRawReports.insert(rawDescription).inserted && seenRawReports.count <= 5 {
            print("  unmatched input report: \(rawDescription)")
        }
        if let response = responseIncludingReportID(raw, raceID: raceID) {
            return response
        }
    }

    throw ProbeError.responseTimedOut(raceID: raceID, lastResult: lastResult)
}

private func printBattery(label: String, response: [UInt8]) {
    print("\(label) raw: \(hex(response))")
    print("  charging_status = \(response[10])")
    print("  battery_level   = \(response[11])%")
    print("  health          = \(response[12])%")
    print("  exists          = \(response[13])")
}

private func attemptQuery(
    label: String,
    device: IOHIDDevice,
    monitor: InputReportMonitor,
    command: [UInt8],
    remote: Bool
) -> [UInt8]? {
    do {
        return try query(
            device: device,
            monitor: monitor,
            command: command,
            remote: remote
        )
    } catch {
        print("\(label) failed: \(error)")
        return nil
    }
}

private func probeDongle() -> Bool {
    do {
        let (manager, device) = try matchingProtocolInterface(productID: dongleProductID)
        defer { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }

        let openResult = IOHIDDeviceOpen(device, deviceOpenOptions)
        guard openResult == kIOReturnSuccess else { throw ProbeError.deviceOpen(openResult) }
        defer { IOHIDDeviceClose(device, deviceOpenOptions) }
        let monitor = InputReportMonitor(device: device)
        defer { monitor.stop() }

        print(String(format: "AM Infinity .97 via dongle (0x%04X:0x%04X)", vendorID, dongleProductID))
        let dock = attemptQuery(
            label: "Dock battery query",
            device: device,
            monitor: monitor,
            command: [0x05, 0x5A, 0x02, 0x00, 0x0F, 0x30],
            remote: false
        )
        if let dock {
            printBattery(label: "Dock battery", response: dock)
        }

        Thread.sleep(forTimeInterval: 0.1)
        let version = attemptQuery(
            label: "Remote firmware query",
            device: device,
            monitor: monitor,
            command: [0x05, 0x5A, 0x03, 0x00, 0x07, 0x1C, 0x00],
            remote: true
        )
        if let version {
            print("Remote firmware raw: \(hex(version))")
        }

        Thread.sleep(forTimeInterval: 0.1)
        let mouse = attemptQuery(
            label: "Mouse battery query",
            device: device,
            monitor: monitor,
            command: [0x05, 0x5A, 0x02, 0x00, 0xCF, 0x30],
            remote: true
        )
        if let mouse {
            printBattery(label: "Mouse battery", response: mouse)
        }
        guard dock != nil || version != nil || mouse != nil else {
            throw ProbeError.responseTimedOut(raceID: [], lastResult: nil)
        }
        return true
    } catch ProbeError.deviceNotFound {
        return false
    } catch {
        fputs("Dongle probe failed: \(error)\n", stderr)
        return true
    }
}

private func probeWiredMouse() -> Bool {
    do {
        let (manager, device) = try matchingProtocolInterface(productID: wiredMouseProductID)
        defer { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }

        let openResult = IOHIDDeviceOpen(device, deviceOpenOptions)
        guard openResult == kIOReturnSuccess else { throw ProbeError.deviceOpen(openResult) }
        defer { IOHIDDeviceClose(device, deviceOpenOptions) }
        let monitor = InputReportMonitor(device: device)
        defer { monitor.stop() }

        print(String(format: "AM Infinity .97 wired (0x%04X:0x%04X)", vendorID, wiredMouseProductID))
        let mouse = try query(
            device: device,
            monitor: monitor,
            command: [0x05, 0x5A, 0x02, 0x00, 0xCF, 0x30],
            remote: false
        )
        printBattery(label: "Mouse battery", response: mouse)
        return true
    } catch ProbeError.deviceNotFound {
        return false
    } catch {
        fputs("Wired mouse probe failed: \(error)\n", stderr)
        return true
    }
}

let foundDongle = probeDongle()
let foundWiredMouse = probeWiredMouse()
if !foundDongle && !foundWiredMouse {
    fputs("Battery probe failed: AM Infinity .97 was not found\n", stderr)
    exit(1)
}
