import SwiftUI
import CoreBluetooth

struct Observation: Identifiable {
    let id: UUID
    var name: String
    var rssi: Int
    var lastSeen: Date
    var services: String
}

@MainActor final class Scanner: NSObject, ObservableObject, CBCentralManagerDelegate {
    @Published var devices: [Observation] = []
    @Published var status = "Initializing Bluetooth"
    @Published var scanning = false
    private var manager: CBCentralManager!
    override init() {
        super.init()
        manager = CBCentralManager(delegate: self, queue: nil)
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: status = "Bluetooth ready"
        case .poweredOff: status = "Bluetooth is off"
        case .unauthorized: status = "Bluetooth permission denied"
        case .unsupported: status = "Bluetooth unavailable"
        default: status = "Waiting for Bluetooth"
        }
    }
    func start() {
        guard manager.state == .poweredOn else { return }
        devices.removeAll()
        manager.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        scanning = true
    }
    func stop() {
        manager.stopScan()
        scanning = false
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let id = peripheral.identifier
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? "Unknown BLE device"
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?.map(\.uuidString).joined(separator: ", ") ?? ""
        let value = RSSI.intValue
        guard value != 127 else { return }
        if let index = devices.firstIndex(where: { $0.id == id }) {
            devices[index].name = name
            devices[index].rssi = value
            devices[index].lastSeen = Date()
            devices[index].services = services
        } else {
            devices.append(Observation(id: id, name: name, rssi: value, lastSeen: Date(), services: services))
        }
        devices.sort { $0.rssi > $1.rssi }
    }
    var csv: String {
        let header = "id,name,rssi,last_seen,services\n"
        let lines = devices.map { item in
            [item.id.uuidString, item.name, String(item.rssi), ISO8601DateFormatter().string(from: item.lastSeen), item.services]
                .map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: ",")
        }
        return header + lines.joined(separator: "\n")
    }
}

struct Radar: View {
    let devices: [Observation]
    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            ZStack {
                ForEach(1...4, id: \.self) { ring in
                    Circle().stroke(.green.opacity(0.22), lineWidth: 1)
                        .frame(width: size * CGFloat(ring) / 4, height: size * CGFloat(ring) / 4)
                }
                Circle().fill(.green).frame(width: 12, height: 12)
                ForEach(Array(devices.prefix(24).enumerated()), id: \.element.id) { index, device in
                    let angle = Double(index) * 2.399963
                    let fraction = min(0.92, max(0.12, Double(-device.rssi - 25) / 85))
                    Circle().fill(.cyan).frame(width: 9, height: 9)
                        .offset(x: cos(angle) * size * 0.45 * fraction, y: sin(angle) * size * 0.45 * fraction)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.accessibilityLabel("Illustrative radar. Dot positions are not actual device directions or distances.")
    }
}

struct ContentView: View {
    @StateObject private var scanner = Scanner()
    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Text(scanner.status).font(.caption).foregroundStyle(.secondary)
                Text("Radar positions are illustrative, not physical locations").font(.caption2).foregroundStyle(.secondary)
                Radar(devices: scanner.devices).frame(height: 260)
                HStack {
                    Button(scanner.scanning ? "Stop scanning" : "Scan nearby BLE") {
                        if scanner.scanning { scanner.stop() } else { scanner.start() }
                    }.buttonStyle(.borderedProminent)
                    ShareLink(item: scanner.csv) { Label("Export CSV", systemImage: "square.and.arrow.up") }
                        .buttonStyle(.bordered)
                }
                Text("\(scanner.devices.count) detected devices").font(.headline)
                List(scanner.devices) { device in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(device.name).font(.headline)
                        Text("RSSI: \(device.rssi) dBm").font(.subheadline)
                        Text(device.id.uuidString).font(.caption2).foregroundStyle(.secondary)
                        if !device.services.isEmpty {
                            Text("Services: \(device.services)").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(.horizontal)
            .navigationTitle("FieldWatch")
            .preferredColorScheme(.dark)
        }
    }
}
@main struct FieldWatchApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}
