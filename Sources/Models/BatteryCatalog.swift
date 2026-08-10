import Foundation

/// Identification des packs batterie à partir du préfixe du numéro de série.
///
/// Source : Zendure-HA (`ZendureBattery.get_battery_type`), qui déduit le
/// modèle et la capacité nominale du 1er (et parfois 4e) caractère du SN.
enum BatteryCatalog {
    struct Battery: Equatable {
        let model: String
        /// Capacité nominale en kWh.
        let kwh: Double
    }

    static func battery(forSerial sn: String) -> Battery? {
        guard let first = sn.first else { return nil }
        let fourth: Character? = sn.count >= 4 ? sn[sn.index(sn.startIndex, offsetBy: 3)] : nil
        switch first {
        case "A":
            if fourth == "3" { return Battery(model: "AIO 2400", kwh: 2.4) }
            return Battery(model: "AB1000", kwh: 0.96)
        case "B":
            return Battery(model: "AB1000S", kwh: 0.96)
        case "C":
            let suffix = fourth == "F" ? "S" : fourth == "E" ? "X" : ""
            return Battery(model: "AB2000\(suffix)", kwh: 1.92)
        case "F":
            return Battery(model: "AB3000", kwh: 2.88)
        case "G":
            return Battery(model: "AB3000L", kwh: 2.88)
        case "J":
            return Battery(model: "I2400", kwh: 2.4)
        default:
            return nil
        }
    }
}
