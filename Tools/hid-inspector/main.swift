import Foundation
import IOKit
import IOKit.hid

private struct HIDProfile {
    let vendorID: Int
    let productIDs: [Int]
    let usagePage: Int
    let usage: Int
}

private let profiles = [
    HIDProfile(
        vendorID: 0x0E8D,
        productIDs: [0x0703, 0x0880],
        usagePage: 0xFF13,
        usage: 0x01
    ),
    HIDProfile(
        vendorID: 0x3151,
        productIDs: [0x5007],
        usagePage: 0xFFFF,
        usage: 0x0002
    ),
]

private func value(_ device: IOHIDDevice, _ key: CFString) -> Any? {
    IOHIDDeviceGetProperty(device, key)
}

private func integer(_ device: IOHIDDevice, _ key: CFString) -> Int? {
    (value(device, key) as? NSNumber)?.intValue
}

private func string(_ device: IOHIDDevice, _ key: CFString) -> String? {
    value(device, key) as? String
}

private func usageName(page: Int, usage: Int) -> String {
    switch (page, usage) {
    case (0x01, 0x01): return "Pointer"
    case (0x01, 0x02): return "Mouse"
    case (0x01, 0x06): return "Keyboard"
    case (0x0C, 0x01): return "Consumer Control"
    case (0x84, _): return "Power Device"
    case (0x85, _): return "Battery System"
    default:
        if page >= 0xFF00 { return "Vendor-defined" }
        return "Other"
    }
}

private func format(_ item: Any) -> String {
    if let data = item as? Data {
        return data.prefix(64).map { String(format: "%02X", $0) }.joined(separator: " ")
            + (data.count > 64 ? " … (\(data.count) bytes)" : "")
    }
    return String(describing: item)
}

private func interestingRegistryProperties(_ device: IOHIDDevice) -> [(String, String)] {
    let service = IOHIDDeviceGetService(device)
    guard service != 0 else { return [] }

    var unmanaged: Unmanaged<CFMutableDictionary>?
    guard IORegistryEntryCreateCFProperties(
        service,
        &unmanaged,
        kCFAllocatorDefault,
        IOOptionBits(0)
    ) == KERN_SUCCESS,
    let properties = unmanaged?.takeRetainedValue() as? [String: Any] else {
        return []
    }

    let terms = ["battery", "charge", "charging", "capacity", "percent", "power"]
    return properties.compactMap { key, value in
        let lowered = key.lowercased()
        guard terms.contains(where: lowered.contains) else { return nil }
        return (key, format(value))
    }.sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
}

private func interestingElements(_ device: IOHIDDevice) -> [(page: Int, usage: Int, type: IOHIDElementType, reportID: Int, logicalMin: Int, logicalMax: Int)] {
    guard let elements = IOHIDDeviceCopyMatchingElements(
        device,
        nil,
        IOOptionBits(kIOHIDOptionsTypeNone)
    ) as? [IOHIDElement] else {
        return []
    }

    return elements.compactMap { element in
        let page = Int(IOHIDElementGetUsagePage(element))
        let usage = Int(IOHIDElementGetUsage(element))
        let type = IOHIDElementGetType(element)
        let isBatteryOrPower = page == 0x84 || page == 0x85
        let isVendorFeature = page >= 0xFF00 && type == kIOHIDElementTypeFeature
        guard isBatteryOrPower || isVendorFeature else { return nil }
        return (
            page,
            usage,
            type,
            Int(IOHIDElementGetReportID(element)),
            IOHIDElementGetLogicalMin(element),
            IOHIDElementGetLogicalMax(element)
        )
    }
}

private func readFeatureReport(
    _ device: IOHIDDevice,
    reportID: Int,
    maximumLength: Int
) -> (result: IOReturn, bytes: [UInt8]) {
    let openResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
    guard openResult == kIOReturnSuccess else {
        return (openResult, [])
    }
    defer { IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)) }

    var bytes = [UInt8](repeating: 0, count: max(1, maximumLength))
    var length = bytes.count
    let result = bytes.withUnsafeMutableBufferPointer { pointer in
        IOHIDDeviceGetReport(
            device,
            kIOHIDReportTypeFeature,
            CFIndex(reportID),
            pointer.baseAddress!,
            &length
        )
    }
    return (result, Array(bytes.prefix(length)))
}

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
let matches = profiles.flatMap { profile in
    profile.productIDs.map { productID in
        [
            kIOHIDVendorIDKey: profile.vendorID,
            kIOHIDProductIDKey: productID,
            kIOHIDPrimaryUsagePageKey: profile.usagePage,
            kIOHIDPrimaryUsageKey: profile.usage,
        ] as CFDictionary
    }
}
IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)

let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
guard openResult == kIOReturnSuccess else {
    fputs(String(format: "Unable to open IOHIDManager: 0x%08X\n", UInt32(bitPattern: openResult)), stderr)
    exit(1)
}
defer { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }

let devices = Array((IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? [])
    .filter {
        let product = (string($0, kIOHIDProductKey as CFString) ?? "").lowercased()
        let manufacturer = (string($0, kIOHIDManufacturerKey as CFString) ?? "").lowercased()
        return manufacturer.contains("angrymiao")
            || manufacturer.contains("angry miao")
            || product.contains("am infinity")
    }
    .sorted {
        let leftPage = integer($0, kIOHIDPrimaryUsagePageKey as CFString) ?? 0
        let rightPage = integer($1, kIOHIDPrimaryUsagePageKey as CFString) ?? 0
        if leftPage != rightPage { return leftPage < rightPage }
        let leftUsage = integer($0, kIOHIDPrimaryUsageKey as CFString) ?? 0
        let rightUsage = integer($1, kIOHIDPrimaryUsageKey as CFString) ?? 0
        return leftUsage < rightUsage
    }

print("Angry Miao HID interfaces: \(devices.count)")

for (index, device) in devices.enumerated() {
    let product = string(device, kIOHIDProductKey as CFString) ?? "(unknown)"
    let manufacturer = string(device, kIOHIDManufacturerKey as CFString) ?? "(unknown)"
    let transport = string(device, kIOHIDTransportKey as CFString) ?? "(unknown)"
    let vendorID = integer(device, kIOHIDVendorIDKey as CFString) ?? 0
    let productID = integer(device, kIOHIDProductIDKey as CFString) ?? 0
    let page = integer(device, kIOHIDPrimaryUsagePageKey as CFString) ?? 0
    let usage = integer(device, kIOHIDPrimaryUsageKey as CFString) ?? 0
    let input = integer(device, kIOHIDMaxInputReportSizeKey as CFString) ?? 0
    let output = integer(device, kIOHIDMaxOutputReportSizeKey as CFString) ?? 0
    let feature = integer(device, kIOHIDMaxFeatureReportSizeKey as CFString) ?? 0

    print(String(
        format: "\n[%d] %@ — %@\n  VID:PID 0x%04X:0x%04X, transport %@\n  usage 0x%04X:0x%04X (%@)\n  reports input=%d output=%d feature=%d",
        index,
        product,
        manufacturer,
        vendorID,
        productID,
        transport,
        page,
        usage,
        usageName(page: page, usage: usage),
        input,
        output,
        feature
    ))
    if let descriptor = value(device, kIOHIDReportDescriptorKey as CFString) as? Data {
        print("  report descriptor: \(format(descriptor))")
    }

    let registryProperties = interestingRegistryProperties(device)
    if registryProperties.isEmpty {
        print("  standard battery/power properties: none")
    } else {
        print("  battery/power properties:")
        for (key, value) in registryProperties {
            print("    \(key) = \(value)")
        }
    }

    let elements = interestingElements(device)
    if elements.isEmpty {
        print("  battery/power or vendor feature elements: none")
    } else {
        print("  battery/power or vendor feature elements:")
        for element in elements {
            print(String(
                format: "    page=0x%04X usage=0x%04X type=%d reportID=%d range=%d...%d",
                element.page,
                element.usage,
                element.type.rawValue,
                element.reportID,
                element.logicalMin,
                element.logicalMax
            ))
        }

        let reportIDs = Set(elements.map(\.reportID)).sorted()
        for reportID in reportIDs {
            let report = readFeatureReport(
                device,
                reportID: reportID,
                maximumLength: max(1, feature)
            )
            if report.result == kIOReturnSuccess {
                print(String(
                    format: "    feature report 0x%02X = %@",
                    reportID,
                    format(Data(report.bytes))
                ))
            } else {
                print(String(
                    format: "    feature report 0x%02X read failed: 0x%08X",
                    reportID,
                    UInt32(bitPattern: report.result)
                ))
            }
        }
    }
}
