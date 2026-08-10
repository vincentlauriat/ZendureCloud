import Foundation

/// Une trame MQTT observée sur le broker cloud — la matière première de la
/// console MQTT, qui montre TOUT le trafic, pas seulement les
/// `properties/report` fusionnés dans DeviceState.
struct MQTTLogEntry: Identifiable, Equatable {
    enum Direction: Equatable {
        case incoming   // publié par l'appareil / le cloud
        case outgoing   // publié par l'app (properties/read getAll…)
    }

    let id: Int
    let date: Date
    let direction: Direction
    let topic: String
    /// Payload décodé en UTF-8 (lossy : les octets invalides sont remplacés).
    let payload: String

    /// Sous-topic après `pk/dk/` — ex. `properties/report`. nil si le topic
    /// n'a pas la forme attendue.
    var subTopic: String? {
        let parts = topic.split(separator: "/", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count >= 4 else { return nil }
        return String(parts[3])
    }

    /// Payload re-sérialisé en JSON indenté (clés triées) si c'en est un,
    /// sinon nil — l'affichage retombe alors sur la chaîne brute.
    var prettyPayload: String? {
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        else { return nil }
        return String(decoding: pretty, as: UTF8.self)
    }
}
