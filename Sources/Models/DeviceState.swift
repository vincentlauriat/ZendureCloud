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

    /// Modèle et capacité déduits du SN (mapping Zendure-HA).
    var battery: BatteryCatalog.Battery? { BatteryCatalog.battery(forSerial: sn) }

    /// Écart entre cellule haute et cellule basse, en volts — indicateur de
    /// l'équilibrage (Zendure-HA expose la même donnée sous `deltaVoltage`).
    var deltaVoltage: Double? {
        guard let maxVol, let minVol else { return nil }
        return max(0, maxVol - minVol)
    }
}

/// Compteurs d'énergie intégrés dans le temps (méthode Zendure-HA `aggregate` :
/// puissance × durée entre deux rapports). Cumuls depuis le lancement de l'app.
struct EnergyCounters: Equatable {
    var solarWh: Double = 0
    var homeWh: Double = 0
    var gridWh: Double = 0
    var chargeWh: Double = 0
    var dischargeWh: Double = 0

    /// Efficacité aller-retour batterie (décharge / charge). Pertinente
    /// seulement après un minimum d'énergie cumulée.
    var roundtripEfficiency: Double? {
        guard chargeWh > 50, dischargeWh > 0 else { return nil }
        return min(100, dischargeWh / chargeWh * 100)
    }

    var hasData: Bool {
        solarWh + homeWh + gridWh + chargeWh + dischargeWh > 0
    }

    mutating func accumulate(solar: Double?, home: Double?, grid: Double?,
                             charge: Double?, discharge: Double?, seconds: TimeInterval) {
        let hours = seconds / 3600
        solarWh += (solar ?? 0) * hours
        homeWh += (home ?? 0) * hours
        gridWh += (grid ?? 0) * hours
        chargeWh += (charge ?? 0) * hours
        dischargeWh += (discharge ?? 0) * hours
    }
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
    var passMode: Int?               // bypass : 0 auto, 1 off, 2 on
    var heatState: Int?              // chauffage batterie 0/1

    // Énergie cumulée (session)
    var energy = EnergyCounters()

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

        // Intégration énergie AVANT mise à jour : les puissances encore en
        // mémoire ont été valables pendant l'intervalle écoulé. Les trous
        // (> 10 min : veille, coupure) ne sont pas intégrés.
        if let last = lastUpdate {
            let dt = date.timeIntervalSince(last)
            if dt > 0 && dt <= 600 {
                energy.accumulate(solar: solarInputPower, home: outputHomePower,
                                  grid: gridInputPower, charge: outputPackPower,
                                  discharge: packInputPower, seconds: dt)
            }
        }

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
        if let v = num("passMode") { passMode = Int(v) }
        if let v = num("heatState") { heatState = Int(v) }
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

    // MARK: - Capacité et autonomie dérivées (méthode Zendure-HA)

    /// Capacité nominale totale : somme des capacités des packs identifiés
    /// par leur SN. nil si aucun pack reconnu.
    var totalCapacityKwh: Double? {
        let capacities = packs.compactMap { $0.battery?.kwh }
        guard !capacities.isEmpty else { return nil }
        return capacities.reduce(0, +)
    }

    /// Énergie encore utilisable : capacité × (SOC − SOC min) / 100.
    var availableKwh: Double? {
        guard let total = totalCapacityKwh, let level = electricLevel else { return nil }
        let floor = socMin ?? 0
        return max(0, total * (level - floor) / 100)
    }

    /// Autonomie estimée côté app (kWh disponibles / puissance nette de
    /// décharge) — utile quand le firmware renvoie la sentinelle 59940.
    var estimatedRemainMinutes: Int? {
        guard let available = availableKwh else { return nil }
        let net = (packInputPower ?? 0) - (outputPackPower ?? 0)
        guard net > 10 else { return nil }
        return Int(available * 1000 / net * 60)
    }
}
