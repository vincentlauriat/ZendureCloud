import Foundation

/// Formatage des grandeurs électriques et énergétiques affichées dans l'app.
/// Même pattern que MacInside : un enum de statics, aucune instance.
enum Format {
    /// Puissance en watts : "1 234 W" ou "1,23 kW" au-delà de 10 kW.
    static func watts(_ value: Double) -> String {
        if abs(value) >= 10_000 {
            return String(format: "%.2f kW", value / 1000)
        }
        return "\(Int(value.rounded())) W"
    }

    /// Énergie en Wh : "820 Wh" ou "1,24 kWh".
    static func wattHours(_ value: Double) -> String {
        if abs(value) >= 1000 {
            return String(format: "%.2f kWh", value / 1000)
        }
        return "\(Int(value.rounded())) Wh"
    }

    static func percent(_ value: Double) -> String {
        "\(Int(value.rounded())) %"
    }

    static func voltage(_ value: Double) -> String {
        String(format: "%.1f V", value)
    }

    static func temperature(_ celsius: Double) -> String {
        String(format: "%.1f °C", celsius)
    }

    /// Durée en minutes → "3 h 25" ou "45 min".
    static func minutes(_ value: Int) -> String {
        guard value > 0 else { return "—" }
        let h = value / 60, m = value % 60
        return h > 0 ? "\(h) h \(String(format: "%02d", m))" : "\(m) min"
    }

    /// Température Zendure brute en dixièmes de kelvin → °C.
    static func kelvinTenths(_ raw: Double) -> Double {
        raw / 10 - 273.15
    }
}
