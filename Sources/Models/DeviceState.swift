import Foundation

/// Un pack batterie (une entrée du tableau `packData`).
struct PackInfo: Identifiable, Equatable {
    var sn: String
    var socLevel: Double?
    /// 0 veille / 1 charge / 2 décharge.
    var state: Int?
    var power: Double?
    /// °C (converti depuis les dixièmes de kelvin).
    var maxTemp: Double?
    /// V (converti depuis les centièmes de volt).
    var maxVol: Double?
    var minVol: Double?
    var totalVol: Double?
    /// A, signé (charge négative selon firmware).
    var current: Double?
    var softVersion: String?
    var heatState: Int?

    var id: String { sn }
}

/// Une propriété brute reçue, avec son horodatage — pour la vue « toutes les
/// informations » qui affiche l'intégralité de ce que le cloud publie.
struct RawProperty: Identifiable, Equatable {
    var key: String
    var value: String
    var updatedAt: Date

    var id: String { key }
}

/// État fusionné d'un appareil, alimenté par les messages MQTT
/// `properties/report`. Les rapports sont PARTIELS : on fusionne champ par
/// champ, on ne remplace jamais l'état entier.
struct DeviceState: Equatable {
    // Énergie / puissance (W)
    var electricLevel: Double?
    var solarInputPower: Double?
    var solarChannels: [Double] = []
    var outputHomePower: Double?
    var gridInputPower: Double?
    var packInputPower: Double?      // décharge batterie
    var outputPackPower: Double?     // charge batterie
    var offGridPower: Double?

    // Configuration / limites
    var acMode: Int?
    var inputLimit: Double?
    var outputLimit: Double?
    var socMin: Double?              // %
    var socMax: Double?              // %
    var inverseMaxPower: Double?

    // Divers
    var deviceTemperature: Double?   // °C
    var remainOutMinutes: Int?
    var remainInputMinutes: Int?
    var rssi: Double?
    var packState: Int?
    var packNum: Int?
    var batteryVoltage: Double?      // V

    // Packs
    var packs: [PackInfo] = []

    // Toutes les clés reçues, brutes, horodatées.
    var rawProperties: [String: RawProperty] = [:]

    var lastUpdate: Date?

    /// `remainOutTime`/`remainInputTime` : 59940 = indisponible.
    private static let invalidRemainMinutes = 59940

    /// Fusionne un payload JSON `properties/report` dans l'état.
    /// Le payload peut être `{"properties": {...}, "packData": [...]}` ou à
    /// plat selon le firmware.
    mutating func merge(payload root: [String: Any], at date: Date = Date()) {
        let props = (root["properties"] as? [String: Any]) ?? root

        for (key, anyValue) in props where !(anyValue is [Any]) && !(anyValue is [String: Any]) {
            rawProperties[key] = RawProperty(key: key, value: Self.describe(anyValue), updatedAt: date)
        }

        func num(_ key: String) -> Double? { Self.number(props[key]) }

        if let v = num("electricLevel") ?? num("socLevel") { electricLevel = v }
        if let v = num("solarInputPower") { solarInputPower = v }
        if let v = num("outputHomePower") { outputHomePower = v }
        if let v = num("gridInputPower") { gridInputPower = v }
        if let v = num("packInputPower") { packInputPower = v }
        if let v = num("outputPackPower") { outputPackPower = v }
        if let v = num("gridOffPower") ?? num("offGridPower") { offGridPower = v }
        if let v = num("acMode") { acMode = Int(v) }
        if let v = num("inputLimit") { inputLimit = v }
        if let v = num("outputLimit") { outputLimit = v }
        if let v = num("inverseMaxPower") { inverseMaxPower = v }
        if let v = num("minSoc") { socMin = Self.autoScaleSoc(v) }
        if let v = num("socSet") { socMax = Self.autoScaleSoc(v) }
        if let v = num("hyperTmp") { deviceTemperature = Self.kelvinTenthsToCelsius(v) }
        if let v = num("rssi") { rssi = v }
        if let v = num("packState") { packState = Int(v) }
        if let v = num("packNum") { packNum = Int(v) }
        if let v = num("BatVolt") { batteryVoltage = v / 100 }
        if let v = num("remainOutTime") {
            remainOutMinutes = Int(v) == Self.invalidRemainMinutes ? nil : Int(v)
        }
        if let v = num("remainInputTime") {
            remainInputMinutes = Int(v) == Self.invalidRemainMinutes ? nil : Int(v)
        }

        // Canaux solaires solarPower1…solarPower6 — tableau dense jusqu'au
        // dernier canal présent dans CE payload, sinon canaux existants gardés.
        var channels = solarChannels
        for i in 1...6 {
            if let v = num("solarPower\(i)") {
                while channels.count < i { channels.append(0) }
                channels[i - 1] = v
            }
        }
        solarChannels = channels

        if let packArray = root["packData"] as? [[String: Any]] ?? props["packData"] as? [[String: Any]] {
            mergePacks(packArray, at: date)
        }

        lastUpdate = date
    }

    private mutating func mergePacks(_ packArray: [[String: Any]], at date: Date) {
        for entry in packArray {
            guard let sn = entry["sn"] as? String, !sn.isEmpty else { continue }
            var pack = packs.first(where: { $0.sn == sn }) ?? PackInfo(sn: sn)
            func num(_ key: String) -> Double? { Self.number(entry[key]) }
            if let v = num("socLevel") { pack.socLevel = v }
            if let v = num("state") { pack.state = Int(v) }
            if let v = num("power") { pack.power = v }
            if let v = num("maxTemp") { pack.maxTemp = Self.kelvinTenthsToCelsius(v) }
            if let v = num("maxVol") { pack.maxVol = v / 100 }
            if let v = num("minVol") { pack.minVol = v / 100 }
            if let v = num("totalVol") {
                // Documenté tantôt en volts, tantôt en centièmes : auto-détection.
                pack.totalVol = v > 500 ? v / 100 : v
            }
            if let v = num("batcur") {
                // Complément à deux 16 bits → ampères signés /10.
                let signed = v > 32767 ? v - 65536 : v
                pack.current = signed / 10
            }
            if let v = entry["softVersion"] { pack.softVersion = Self.describe(v) }
            if let v = num("heatState") { pack.heatState = Int(v) }
            if let idx = packs.firstIndex(where: { $0.sn == sn }) {
                packs[idx] = pack
            } else {
                packs.append(pack)
            }
            rawProperties["packData[\(sn)]"] = RawProperty(
                key: "packData[\(sn)]",
                value: entry.keys.sorted().map { "\($0)=\(Self.describe(entry[$0] ?? ""))" }.joined(separator: " "),
                updatedAt: date
            )
        }
    }

    // MARK: - Conversions et parsing tolérant

    /// Les nombres arrivent indifféremment en Int, Double, NSNumber ou String
    /// selon le firmware (leçon ZendureMonitor).
    static func number(_ value: Any?) -> Double? {
        switch value {
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s)
        default: return nil
        }
    }

    /// Dixièmes de kelvin → °C (`hyperTmp: 2981` = 25 °C).
    static func kelvinTenthsToCelsius(_ raw: Double) -> Double {
        (raw - 2731) / 10
    }

    /// `socSet`/`minSoc` : deux échelles observées selon la source (80 ou 800).
    static func autoScaleSoc(_ raw: Double) -> Double {
        raw > 100 ? raw / 10 : raw
    }

    static func describe(_ value: Any) -> String {
        // Bool d'abord : un NSNumber(bool) se cast aussi en Double (1.0/0.0).
        if let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() {
            return n.boolValue ? "true" : "false"
        }
        switch value {
        case let d as Double: return d == d.rounded() ? String(Int(d)) : String(d)
        default: return String(describing: value)
        }
    }

    /// Propriétés brutes triées pour l'affichage.
    var sortedRawProperties: [RawProperty] {
        rawProperties.values.sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
    }
}
