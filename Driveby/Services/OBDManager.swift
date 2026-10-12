//  OBDManager.swift — Driveby
//  Decision 4: an ELM327 Bluetooth LE dongle (~$15) turns n≈9 tank-to-tank points into
//  per-trip fuel consumption — hundreds of validation points.
//  iOS can only talk to BLE (or Wi-Fi) adapters, NOT "Bluetooth Classic" ones — buy a BLE model
//  (e.g. Vgate iCar Pro BLE, Veepeak OBDCheck BLE+, OBDLink CX).
//
//  Polls 010D speed, 010C RPM and 015E fuel rate (or 0110 MAF if 5E isn't supported) and logs
//  `obd` lines into the drive's sensors.jsonl on the same monotonic clock.

import CoreBluetooth
import Foundation
import Observation

@MainActor
@Observable
final class OBDManager {
    enum Phase: Equatable { case off, unsupported, scanning, connecting, initializing, ready, error(String) }

    struct Found: Identifiable, Hashable { var id: UUID; var name: String; var rssi: Int }

    struct PIDReport: Identifiable, Hashable {
        var pid: OBDPID
        var supported: Bool?
        var lastValue: Double?
        var id: String { pid.rawValue }
    }

    private(set) var phase: Phase = .off
    private(set) var found: [Found] = []
    private(set) var connectedName: String?
    private(set) var report: [PIDReport] = OBDPID.allCases.map { PIDReport(pid: $0) }
    private(set) var live = OBDSample(t: 0)
    private(set) var log: [String] = []

    private let link = ELMLink()
    @ObservationIgnored var preferredPeripheral: String?

    init() {
        link.onEvent = { [weak self] event in
            guard let self else { return }
            Task { @MainActor in self.handle(event) }
        }
    }

    private func handle(_ e: ELMLink.Event) {
        switch e {
        case .state(let s):
            switch s {
            case .poweredOff: phase = .error("Bluetooth is off")
            case .unauthorized: phase = .error("Bluetooth permission is off — Settings → Driveby → Bluetooth")
            case .unsupported: phase = .unsupported
            case .poweredOn: if phase == .off || phase == .unsupported { phase = .off }
            default: break
            }
        case .discovered(let id, let name, let rssi):
            if let i = found.firstIndex(where: { $0.id == id }) { found[i].rssi = rssi } else { found.append(Found(id: id, name: name, rssi: rssi)) }
            found.sort { $0.rssi > $1.rssi }
            if let pref = preferredPeripheral, pref == id.uuidString, phase == .scanning { connect(id) }
        case .connected(let name): connectedName = name; phase = .initializing
        case .ready(let supported):
            phase = .ready
            for i in report.indices { report[i].supported = supported.isEmpty ? nil : supported.contains(report[i].pid.rawValue) }
        case .disconnected(let reason):
            connectedName = nil
            if let reason { phase = Phase.error(reason) } else { phase = .off }
        case .sample(let s):
            live = s
            for i in report.indices {
                let v: Double?
                switch report[i].pid {
                case .rpm: v = s.rpm
                case .speed: v = s.kph
                case .maf: v = s.maf
                case .fuelRate: v = s.fuelLph
                }
                if let v { report[i].lastValue = v }
            }
        case .log(let line):
            log.append(line)
            if log.count > 200 { log.removeFirst(log.count - 200) }
        }
    }

    func scan() { found = []; phase = .scanning; link.scan() }
    func stopScan() { link.stopScan(); if phase == .scanning { phase = .off } }
    func connect(_ id: UUID) { phase = .connecting; preferredPeripheral = id.uuidString; link.connect(id) }
    func disconnect() { link.disconnect() }

    /// Start writing `obd` samples into the drive log (t relative to `t0` on the monotonic clock).
    func startLogging(writer: SampleFileWriter, t0: TimeInterval) { link.startLogging(writer: writer, t0: t0) }
    func stopLogging() { link.stopLogging() }

    /// Week-0 compatibility check: "Which PIDs respond? Log the answer."
    func testPIDs() { link.testPIDs() }

    var isReady: Bool { phase == .ready }
}

// MARK: - Transport (runs on its own serial queue)

final class ELMLink: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {
    enum Event {
        case state(CBManagerState)
        case discovered(UUID, String, Int)
        case connected(String)
        case ready(Set<String>)
        case disconnected(String?)
        case sample(OBDSample)
        case log(String)
    }

    var onEvent: ((Event) -> Void)?

    private let queue = DispatchQueue(label: "driveby.obd")
    private lazy var central = CBCentralManager(delegate: self, queue: queue, options: [CBCentralManagerOptionShowPowerAlertKey: true])
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var notifyChar: CBCharacteristic?

    private var response = ""
    private var pending: ((String) -> Void)?
    private var timeout: DispatchWorkItem?
    private var supported = Set<String>()
    private var polling = false
    private var writer: SampleFileWriter?
    private var t0: TimeInterval = 0
    private var pendingScan = false
    private var initScheduled = false
    private var pendingConnect: UUID?

    /// Service/characteristic pairs used by common ELM327 BLE clones.
    private static let knownServices = [CBUUID(string: "FFF0"), CBUUID(string: "FFE0"), CBUUID(string: "18F0"),
                                        CBUUID(string: "E7810A71-73AE-499D-8C15-FAA9AEF0C3F2")]

    func scan() {
        queue.async {
            guard self.central.state == .poweredOn else { self.pendingScan = true; return }  // resumes in didUpdateState
            self.central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        }
    }

    func stopScan() { queue.async { if self.central.isScanning { self.central.stopScan() } } }

    func connect(_ id: UUID) {
        queue.async {
            guard self.central.state == .poweredOn else { self.pendingConnect = id; return }
            let p = self.peripherals[id] ?? self.central.retrievePeripherals(withIdentifiers: [id]).first
            guard let p else { self.onEvent?(.disconnected("Adapter not found — scan again")); return }
            self.central.stopScan()
            self.peripheral = p
            p.delegate = self
            self.central.connect(p)
        }
    }

    func disconnect() {
        queue.async {
            self.polling = false
            if let p = self.peripheral { self.central.cancelPeripheralConnection(p) }
        }
    }

    func startLogging(writer: SampleFileWriter, t0: TimeInterval) {
        queue.async {
            self.writer = writer
            self.t0 = t0
            if !self.polling && self.writeChar != nil { self.polling = true; self.pollLoop() }
        }
    }

    func stopLogging() { queue.async { self.writer = nil; self.polling = false } }

    func testPIDs() {
        queue.async {
            guard self.writeChar != nil else { self.onEvent?(.log("Not connected")); return }
            guard !self.polling, self.pending == nil else { self.onEvent?(.log("Busy logging a drive — test after it ends")); return }
            self.querySupport { sup in
                self.supported = sup
                self.onEvent?(.ready(sup))
                self.pollOnce { _ in }
            }
        }
    }

    // MARK: Central

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        onEvent?(.state(central.state))
        guard central.state == .poweredOn else { return }
        if pendingScan {
            pendingScan = false
            central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        }
        if let id = pendingConnect {
            pendingConnect = nil
            connect(id)
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        guard !name.isEmpty else { return }
        peripherals[peripheral.identifier] = peripheral
        onEvent?(.discovered(peripheral.identifier, name, RSSI.intValue))
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        onEvent?(.connected(peripheral.name ?? "OBD adapter"))
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        onEvent?(.disconnected(error?.localizedDescription ?? "Connection failed"))
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        writeChar = nil; notifyChar = nil; polling = false; initScheduled = false; supported = []; pending = nil
        onEvent?(.disconnected(error?.localizedDescription))
    }

    // MARK: Peripheral

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for s in peripheral.services ?? [] { peripheral.discoverCharacteristics(nil, for: s) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let preferred = Self.knownServices.contains(service.uuid)
        for c in service.characteristics ?? [] {
            if c.properties.contains(.notify) || c.properties.contains(.indicate), notifyChar == nil || preferred {
                notifyChar = c
                peripheral.setNotifyValue(true, for: c)
            }
            if c.properties.contains(.write) || c.properties.contains(.writeWithoutResponse), writeChar == nil || preferred {
                writeChar = c
            }
        }
        if writeChar != nil && notifyChar != nil && pending == nil && supported.isEmpty && !initScheduled {
            // Give the adapter a moment, then run the ELM327 init sequence (once — this callback fires per service).
            initScheduled = true
            queue.asyncAfter(deadline: .now() + 0.5) { self.initialize() }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value, let s = String(data: data, encoding: .ascii) else { return }
        response += s
        if response.contains(">") {
            let r = response
            response = ""
            timeout?.cancel()
            let cb = pending
            pending = nil
            cb?(r)
        }
    }

    // MARK: ELM327 protocol

    private func send(_ cmd: String, wait: Double = 2.0, _ completion: @escaping (String) -> Void) {
        guard let p = peripheral, let c = writeChar else { completion(""); return }
        response = ""
        pending = completion
        let type: CBCharacteristicWriteType = c.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        p.writeValue(Data((cmd + "\r").utf8), for: c, type: type)
        let item = DispatchWorkItem { [weak self] in
            guard let self, let cb = self.pending else { return }
            self.pending = nil
            let r = self.response
            self.response = ""
            cb(r)
        }
        timeout = item
        queue.asyncAfter(deadline: .now() + wait, execute: item)
    }

    private func sequence(_ cmds: [String], _ done: @escaping () -> Void) {
        guard let first = cmds.first else { done(); return }
        send(first, wait: first == "ATZ" ? 3 : 2) { r in
            self.onEvent?(.log("\(first) → \(r.replacingOccurrences(of: "\r", with: " ").trimmingCharacters(in: .whitespaces))"))
            self.sequence(Array(cmds.dropFirst()), done)
        }
    }

    private func initialize() {
        sequence(OBDParser.initCommands) {
            self.querySupport { sup in
                self.supported = sup
                self.onEvent?(.ready(sup))
                if self.writer != nil && !self.polling { self.polling = true; self.pollLoop() }
            }
        }
    }

    private func querySupport(_ done: @escaping (Set<String>) -> Void) {
        var all = Set<String>()
        send("0100", wait: 6) { r0 in   // first query can take seconds while the protocol is detected
            all.formUnion(OBDParser.supportedPIDs(r0, base: 0x00))
            self.send("0120") { r1 in
                all.formUnion(OBDParser.supportedPIDs(r1, base: 0x20))
                self.send("0140") { r2 in
                    all.formUnion(OBDParser.supportedPIDs(r2, base: 0x40))
                    self.onEvent?(.log("Supported PIDs: \(all.sorted().joined(separator: " "))"))
                    done(all)
                }
            }
        }
    }

    /// One cycle: speed, RPM, fuel rate (or MAF). ≈1–2 Hz depending on the adapter.
    private func pollOnce(_ done: @escaping (OBDSample) -> Void) {
        let useFuelRate = supported.isEmpty || supported.contains(OBDPID.fuelRate.rawValue)
        var sample = OBDSample(t: MonotonicClock.now() - t0)
        send(OBDPID.speed.command, wait: 1) { r in
            sample.kph = OBDParser.decode(.speed, raw: r)
            self.send(OBDPID.rpm.command, wait: 1) { r in
                sample.rpm = OBDParser.decode(.rpm, raw: r)
                let fuelPID: OBDPID = useFuelRate ? .fuelRate : .maf
                self.send(fuelPID.command, wait: 1) { r in
                    if useFuelRate { sample.fuelLph = OBDParser.decode(.fuelRate, raw: r) }
                    else { sample.maf = OBDParser.decode(.maf, raw: r) }
                    // If fuel rate turns out unsupported in practice, fall back to MAF next cycle.
                    if useFuelRate && sample.fuelLph == nil && OBDParser.isNoData(r) {
                        self.supported.remove(OBDPID.fuelRate.rawValue)
                        self.supported.insert(OBDPID.maf.rawValue)
                    }
                    sample.t = MonotonicClock.now() - self.t0
                    self.onEvent?(.sample(sample))
                    done(sample)
                }
            }
        }
    }

    private func pollLoop() {
        guard polling, writeChar != nil else { return }
        pollOnce { s in
            if let w = self.writer, s.t >= 0, s.rpm != nil || s.kph != nil || s.fuelLph != nil || s.maf != nil {
                w.append(SampleLine.obd(s))
            }
            self.queue.asyncAfter(deadline: .now() + 0.2) { self.pollLoop() }
        }
    }
}
