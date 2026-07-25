import CoreBluetooth
import Foundation

final class AMInfinity97BluetoothBatteryReader:
    NSObject,
    CBCentralManagerDelegate,
    CBPeripheralDelegate,
    @unchecked Sendable
{
    private enum ProtocolConstants {
        static let batteryService = CBUUID(string: "180F")
        static let batteryLevel = CBUUID(string: "2A19")
        static let deviceInformationService = CBUUID(string: "180A")
        static let modelNumber = CBUUID(string: "2A24")
        static let pnpID = CBUUID(string: "2A50")

        static let expectedModel = "ab162x"
        static let expectedVendorIDSource: UInt8 = 0x01
        static let expectedVendorID: UInt16 = 0x0148
        static let expectedProductID: UInt16 = 0x0000

        static let verifiedIdentifierKey =
            "AMInfinity97BluetoothVerifiedIdentifier"
        static let connectionTimeout: TimeInterval = 5
        static let identityTimeout: TimeInterval = 3
        static let retryInterval: TimeInterval = 1
        static let cachedReadingLifetime: TimeInterval = 90
    }

    private let queue = DispatchQueue(
        label: "design.specos.infinityhub.bluetooth",
        qos: .utility
    )
    private let readingLock = NSLock()

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var batteryService: CBService?
    private var batteryCharacteristic: CBCharacteristic?
    private var connectionTimeout: DispatchWorkItem?
    private var identityTimeout: DispatchWorkItem?
    private var candidateModel: String?
    private var candidatePnPID: Data?
    private var identityIsVerified = false
    private var rejectedIdentifiers: Set<UUID> = []
    private var cachedLevel: Int?
    private var cachedAt: Date?
    private var isStopped = false

    override init() {
        super.init()
        central = CBCentralManager(
            delegate: self,
            queue: queue,
            options: [CBCentralManagerOptionShowPowerAlertKey: false]
        )
    }

    func read() -> AMBatteryReading? {
        queue.async { [weak self] in
            self?.refresh()
        }

        readingLock.lock()
        defer { readingLock.unlock() }

        guard let cachedLevel,
              let cachedAt,
              Date().timeIntervalSince(cachedAt)
                <= ProtocolConstants.cachedReadingLifetime
        else {
            return nil
        }

        return AMBatteryReading(
            chargingStatus: 0,
            level: cachedLevel,
            health: nil,
            exists: true
        )
    }

    func stop() {
        queue.sync {
            guard !isStopped else { return }
            isStopped = true
            connectionTimeout?.cancel()
            identityTimeout?.cancel()
            connectionTimeout = nil
            identityTimeout = nil
            central.stopScan()

            if let peripheral {
                peripheral.delegate = nil
                central.cancelPeripheralConnection(peripheral)
            }

            self.peripheral = nil
            batteryService = nil
            batteryCharacteristic = nil
            store(level: nil)
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard !isStopped else { return }

        if central.state == .poweredOn {
            discoverDevice()
        } else {
            clearPeripheral()
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard !isStopped,
              self.peripheral == nil,
              !rejectedIdentifiers.contains(peripheral.identifier)
        else {
            return
        }

        central.stopScan()
        connect(peripheral)
    }

    func centralManager(
        _ central: CBCentralManager,
        didConnect peripheral: CBPeripheral
    ) {
        guard !isStopped, self.peripheral === peripheral else { return }
        connectionTimeout?.cancel()
        connectionTimeout = nil
        beginIdentityVerification(peripheral)
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        guard self.peripheral === peripheral else { return }
        forgetStoredIdentifier(ifMatches: peripheral.identifier)
        clearPeripheral()
        scheduleDiscovery()
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        guard self.peripheral === peripheral else { return }
        clearPeripheral()
        scheduleDiscovery()
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverServices error: Error?
    ) {
        guard !isStopped,
              self.peripheral === peripheral,
              error == nil,
              let services = peripheral.services
        else {
            disconnectAndRetry()
            return
        }

        guard let batteryService = services.first(where: {
                  $0.uuid == ProtocolConstants.batteryService
              }),
              let deviceInformation = services.first(where: {
                  $0.uuid == ProtocolConstants.deviceInformationService
              })
        else {
            rejectCurrentPeripheral()
            return
        }

        self.batteryService = batteryService
        peripheral.discoverCharacteristics(
            [
                ProtocolConstants.modelNumber,
                ProtocolConstants.pnpID,
            ],
            for: deviceInformation
        )
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard !isStopped,
              self.peripheral === peripheral,
              error == nil
        else {
            disconnectAndRetry()
            return
        }

        if service.uuid == ProtocolConstants.deviceInformationService {
            guard let characteristics = service.characteristics,
                  let model = characteristics.first(where: {
                      $0.uuid == ProtocolConstants.modelNumber
                          && $0.properties.contains(.read)
                  }),
                  let pnpID = characteristics.first(where: {
                      $0.uuid == ProtocolConstants.pnpID
                          && $0.properties.contains(.read)
                  })
            else {
                rejectCurrentPeripheral()
                return
            }

            peripheral.readValue(for: model)
            peripheral.readValue(for: pnpID)
            return
        }

        guard service.uuid == ProtocolConstants.batteryService,
              identityIsVerified,
              let characteristic = service.characteristics?.first(where: {
                  $0.uuid == ProtocolConstants.batteryLevel
              }),
              characteristic.properties.contains(.read)
        else {
            disconnectAndRetry()
            return
        }

        batteryCharacteristic = characteristic
        peripheral.readValue(for: characteristic)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard !isStopped, self.peripheral === peripheral else { return }

        if characteristic.service?.uuid
            == ProtocolConstants.deviceInformationService
        {
            guard error == nil, let value = characteristic.value else {
                rejectCurrentPeripheral()
                return
            }

            switch characteristic.uuid {
            case ProtocolConstants.modelNumber:
                guard let model = String(data: value, encoding: .utf8)?
                    .trimmingCharacters(
                        in: .whitespacesAndNewlines.union(.controlCharacters)
                    ),
                    !model.isEmpty
                else {
                    rejectCurrentPeripheral()
                    return
                }
                candidateModel = model
            case ProtocolConstants.pnpID:
                candidatePnPID = value
            default:
                return
            }

            verifyIdentityIfComplete()
            return
        }

        guard identityIsVerified,
              characteristic === batteryCharacteristic,
              characteristic.uuid == ProtocolConstants.batteryLevel,
              error == nil,
              let value = characteristic.value,
              value.count == 1,
              let rawLevel = value.first,
              rawLevel <= 100
        else {
            store(level: nil)
            return
        }

        store(level: Int(rawLevel))
    }

    private func refresh() {
        guard !isStopped, central.state == .poweredOn else { return }

        if let peripheral,
           peripheral.state == .connected,
           identityIsVerified,
           let batteryCharacteristic
        {
            peripheral.readValue(for: batteryCharacteristic)
        } else if peripheral == nil {
            discoverDevice()
        }
    }

    private func discoverDevice() {
        guard !isStopped,
              central.state == .poweredOn,
              peripheral == nil
        else {
            return
        }

        if let identifier = storedIdentifier,
           !rejectedIdentifiers.contains(identifier),
           let storedPeripheral = central.retrievePeripherals(
               withIdentifiers: [identifier]
           ).first
        {
            connect(storedPeripheral)
            return
        }

        if let connected = central.retrieveConnectedPeripherals(
            withServices: [ProtocolConstants.batteryService]
        ).first(where: {
            !rejectedIdentifiers.contains($0.identifier)
        }) {
            connect(connected)
            return
        }

        central.scanForPeripherals(
            withServices: [ProtocolConstants.batteryService],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    private func connect(_ peripheral: CBPeripheral) {
        guard !isStopped,
              self.peripheral == nil,
              !rejectedIdentifiers.contains(peripheral.identifier)
        else {
            return
        }

        self.peripheral = peripheral
        peripheral.delegate = self

        if peripheral.state == .connected {
            beginIdentityVerification(peripheral)
            return
        }

        central.connect(peripheral)

        let timeout = DispatchWorkItem { [weak self, weak peripheral] in
            guard let self,
                  let peripheral,
                  self.peripheral === peripheral,
                  peripheral.state != .connected
            else {
                return
            }

            self.forgetStoredIdentifier(ifMatches: peripheral.identifier)
            self.central.cancelPeripheralConnection(peripheral)
            self.clearPeripheral()
            self.scheduleDiscovery()
        }
        connectionTimeout = timeout
        queue.asyncAfter(
            deadline: .now() + ProtocolConstants.connectionTimeout,
            execute: timeout
        )
    }

    private func beginIdentityVerification(_ peripheral: CBPeripheral) {
        identityTimeout?.cancel()
        candidateModel = nil
        candidatePnPID = nil
        identityIsVerified = false
        batteryService = nil
        batteryCharacteristic = nil
        store(level: nil)

        peripheral.delegate = self
        peripheral.discoverServices([
            ProtocolConstants.batteryService,
            ProtocolConstants.deviceInformationService,
        ])

        let timeout = DispatchWorkItem { [weak self, weak peripheral] in
            guard let self,
                  let peripheral,
                  self.peripheral === peripheral,
                  !self.identityIsVerified
            else {
                return
            }
            self.rejectCurrentPeripheral()
        }
        identityTimeout = timeout
        queue.asyncAfter(
            deadline: .now() + ProtocolConstants.identityTimeout,
            execute: timeout
        )
    }

    private func verifyIdentityIfComplete() {
        guard !identityIsVerified,
              let candidateModel,
              let candidatePnPID
        else {
            return
        }

        guard candidateModel == ProtocolConstants.expectedModel,
              matchesExpectedPnPID(candidatePnPID),
              let peripheral,
              let batteryService
        else {
            rejectCurrentPeripheral()
            return
        }

        identityTimeout?.cancel()
        identityTimeout = nil
        identityIsVerified = true
        rejectedIdentifiers.remove(peripheral.identifier)
        UserDefaults.standard.set(
            peripheral.identifier.uuidString,
            forKey: ProtocolConstants.verifiedIdentifierKey
        )

        peripheral.discoverCharacteristics(
            [ProtocolConstants.batteryLevel],
            for: batteryService
        )
    }

    private func matchesExpectedPnPID(_ value: Data) -> Bool {
        guard value.count == 7 else { return false }

        let vendorID =
            UInt16(value[value.startIndex + 1])
            | (UInt16(value[value.startIndex + 2]) << 8)
        let productID =
            UInt16(value[value.startIndex + 3])
            | (UInt16(value[value.startIndex + 4]) << 8)

        return value[value.startIndex]
                == ProtocolConstants.expectedVendorIDSource
            && vendorID == ProtocolConstants.expectedVendorID
            && productID == ProtocolConstants.expectedProductID
    }

    private var storedIdentifier: UUID? {
        guard let value = UserDefaults.standard.string(
            forKey: ProtocolConstants.verifiedIdentifierKey
        ) else {
            return nil
        }
        return UUID(uuidString: value)
    }

    private func forgetStoredIdentifier(ifMatches identifier: UUID) {
        guard storedIdentifier == identifier else { return }
        UserDefaults.standard.removeObject(
            forKey: ProtocolConstants.verifiedIdentifierKey
        )
    }

    private func rejectCurrentPeripheral() {
        guard let peripheral else { return }
        rejectedIdentifiers.insert(peripheral.identifier)
        forgetStoredIdentifier(ifMatches: peripheral.identifier)
        central.cancelPeripheralConnection(peripheral)
        clearPeripheral()
        scheduleDiscovery()
    }

    private func disconnectAndRetry() {
        guard let peripheral else { return }
        central.cancelPeripheralConnection(peripheral)
        clearPeripheral()
        scheduleDiscovery()
    }

    private func clearPeripheral() {
        connectionTimeout?.cancel()
        identityTimeout?.cancel()
        connectionTimeout = nil
        identityTimeout = nil
        peripheral?.delegate = nil
        peripheral = nil
        batteryService = nil
        batteryCharacteristic = nil
        candidateModel = nil
        candidatePnPID = nil
        identityIsVerified = false
        store(level: nil)
    }

    private func scheduleDiscovery() {
        queue.asyncAfter(
            deadline: .now() + ProtocolConstants.retryInterval
        ) { [weak self] in
            self?.discoverDevice()
        }
    }

    private func store(level: Int?) {
        readingLock.lock()
        cachedLevel = level
        cachedAt = level == nil ? nil : Date()
        readingLock.unlock()
    }
}
