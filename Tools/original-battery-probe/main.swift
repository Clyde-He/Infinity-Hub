import Foundation
import IOKit.hid

private enum OriginalInfinityProtocol {
    static let vendorID = 0x3151
    static let receiverProductID = 0x5007
    static let usagePage = 0xFFFF
    static let usage = 0x0002
    static let reportID: CFIndex = 0
    static let reportLength = 64
    static let productName = "AM INFINITY 8K MOUSE"

    // This is the complete, read-only F7 status request used by the official
    // driver. No other command byte is accepted by this probe.
    static let batteryRequest =
        [UInt8(0xF7)]
        + [UInt8](repeating: 0, count: reportLength - 1)
}

private enum ProbeError: Error, CustomStringConvertible {
    case managerOpen(IOReturn)
    case deviceNotFound
    case unexpectedInterface(String)
    case deviceOpen(IOReturn)
    case setFeature(IOReturn)
    case getFeature(IOReturn)
    case invalidResponse([UInt8])

    var description: String {
        switch self {
        case .managerOpen(let result):
            return "Unable to open IOHIDManager: \(formatted(result))"
        case .deviceNotFound:
            return "Original AM Infinity receiver feature interface was not found"
        case .unexpectedInterface(let reason):
            return "Matched interface failed the safety check: \(reason)"
        case .deviceOpen(let result):
            return "Unable to open the feature interface: \(formatted(result))"
        case .setFeature(let result):
            return "Unable to send the F7 status request: \(formatted(result))"
        case .getFeature(let result):
            return "Unable to read the F7 status response: \(formatted(result))"
        case .invalidResponse(let response):
            return "F7 returned an invalid status response: \(hex(response))"
        }
    }
}

private struct BatteryStatus {
    let readReady: Int
    let mouseLevel: Int
    let mouseOnlineRaw: Int
    let sendReady: Int
    let receiverLevel: Int

    var mouseIsOnline: Bool {
        // The official driver maps zero to online and non-zero to offline.
        mouseOnlineRaw == 0
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

private func openFeatureInterface() throws -> (IOHIDManager, IOHIDDevice) {
    let manager = IOHIDManagerCreate(
        kCFAllocatorDefault,
        IOOptionBits(kIOHIDOptionsTypeNone)
    )
    IOHIDManagerSetDeviceMatching(
        manager,
        [
            kIOHIDVendorIDKey: OriginalInfinityProtocol.vendorID,
            kIOHIDProductIDKey: OriginalInfinityProtocol.receiverProductID,
            kIOHIDPrimaryUsagePageKey: OriginalInfinityProtocol.usagePage,
            kIOHIDPrimaryUsageKey: OriginalInfinityProtocol.usage,
        ] as CFDictionary
    )

    let managerResult = IOHIDManagerOpen(
        manager,
        IOOptionBits(kIOHIDOptionsTypeNone)
    )
    guard managerResult == kIOReturnSuccess else {
        throw ProbeError.managerOpen(managerResult)
    }

    let devices = Array(
        (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
    )
    guard let device = devices.first else {
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        throw ProbeError.deviceNotFound
    }

    let safetyProperties: [(Bool, String)] = [
        (
            integerProperty(device, kIOHIDVendorIDKey as CFString)
                == OriginalInfinityProtocol.vendorID,
            "unexpected vendor ID"
        ),
        (
            integerProperty(device, kIOHIDProductIDKey as CFString)
                == OriginalInfinityProtocol.receiverProductID,
            "unexpected product ID"
        ),
        (
            integerProperty(device, kIOHIDPrimaryUsagePageKey as CFString)
                == OriginalInfinityProtocol.usagePage,
            "unexpected usage page"
        ),
        (
            integerProperty(device, kIOHIDPrimaryUsageKey as CFString)
                == OriginalInfinityProtocol.usage,
            "unexpected usage"
        ),
        (
            integerProperty(device, kIOHIDMaxInputReportSizeKey as CFString)
                == 0,
            "interface exposes input reports"
        ),
        (
            integerProperty(device, kIOHIDMaxOutputReportSizeKey as CFString)
                == 0,
            "interface exposes output reports"
        ),
        (
            integerProperty(device, kIOHIDMaxFeatureReportSizeKey as CFString)
                == OriginalInfinityProtocol.reportLength,
            "unexpected feature report length"
        ),
        (
            stringProperty(device, kIOHIDProductKey as CFString)
                == OriginalInfinityProtocol.productName,
            "unexpected USB product name"
        ),
    ]
    if let failed = safetyProperties.first(where: { !$0.0 }) {
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        throw ProbeError.unexpectedInterface(failed.1)
    }

    let deviceResult = IOHIDDeviceOpen(
        device,
        IOOptionBits(kIOHIDOptionsTypeNone)
    )
    guard deviceResult == kIOReturnSuccess else {
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        throw ProbeError.deviceOpen(deviceResult)
    }

    return (manager, device)
}

private func getFeatureReport(_ device: IOHIDDevice) throws -> [UInt8] {
    var response = [UInt8](
        repeating: 0,
        count: OriginalInfinityProtocol.reportLength
    )
    var responseLength = response.count
    let result = response.withUnsafeMutableBufferPointer { pointer in
        IOHIDDeviceGetReport(
            device,
            kIOHIDReportTypeFeature,
            OriginalInfinityProtocol.reportID,
            pointer.baseAddress!,
            &responseLength
        )
    }
    guard result == kIOReturnSuccess else {
        throw ProbeError.getFeature(result)
    }
    return Array(response.prefix(responseLength))
}

private func queryBattery(_ device: IOHIDDevice) throws -> [UInt8] {
    precondition(
        OriginalInfinityProtocol.batteryRequest.count
            == OriginalInfinityProtocol.reportLength
    )
    precondition(
        OriginalInfinityProtocol.batteryRequest[0] == 0xF7
            && OriginalInfinityProtocol.batteryRequest.dropFirst().allSatisfy {
                $0 == 0
            }
    )

    var request = OriginalInfinityProtocol.batteryRequest
    let sendResult = request.withUnsafeMutableBufferPointer { pointer in
        IOHIDDeviceSetReport(
            device,
            kIOHIDReportTypeFeature,
            OriginalInfinityProtocol.reportID,
            pointer.baseAddress!,
            pointer.count
        )
    }
    guard sendResult == kIOReturnSuccess else {
        throw ProbeError.setFeature(sendResult)
    }

    Thread.sleep(forTimeInterval: 0.01)
    return try getFeatureReport(device)
}

private func parseBattery(_ response: [UInt8]) throws -> BatteryStatus {
    guard response.count >= 11 else {
        throw ProbeError.invalidResponse(response)
    }

    let status = BatteryStatus(
        readReady: Int(response[0]),
        mouseLevel: Int(response[2]),
        mouseOnlineRaw: Int(response[4]),
        sendReady: Int(response[5]),
        receiverLevel: Int(response[10])
    )
    guard (0...100).contains(status.mouseLevel),
          (0...100).contains(status.receiverLevel),
          (0...1).contains(status.mouseOnlineRaw),
          (0...1).contains(status.readReady),
          (0...1).contains(status.sendReady)
    else {
        throw ProbeError.invalidResponse(response)
    }
    return status
}

do {
    let (manager, device) = try openFeatureInterface()
    defer {
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    let baseline = try getFeatureReport(device)
    print("Before F7: \(hex(baseline))")

    let response = try queryBattery(device)
    print("F7 response: \(hex(response))")

    let status = try parseBattery(response)
    print("Mouse battery: \(status.mouseLevel)%")
    print("Mouse online: \(status.mouseIsOnline)")
    print("Receiver battery: \(status.receiverLevel)%")
    print("Mailbox flags: read=\(status.readReady), send=\(status.sendReady)")
} catch {
    fputs("Original Infinity battery probe failed: \(error)\n", stderr)
    exit(1)
}
