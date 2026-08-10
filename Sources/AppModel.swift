import SwiftUI

/// Historique de valeurs pour les sparklines — borné, style MacInside.
struct PowerHistory: Equatable {
    private(set) var solar: [Double] = []
    private(set) var home: [Double] = []
    private(set) var soc: [Double] = []
    private static let limit = 120

    mutating func append(state: DeviceState) {
        func push(_ array: inout [Double], _ value: Double?) {
            guard let value else { return }
            array.append(value)
            if array.count > Self.limit { array.removeFirst(array.count - Self.limit) }
        }
        push(&solar, state.solarInputPower)
        push(&home, state.outputHomePower)
        push(&soc, state.electricLevel)
    }
}

/// Modèle central de l'app — @Observable, injecté par .environment() dans
/// chaque scène (fenêtre, menu bar, réglages).
@Observable @MainActor
final class AppModel {
    private(set) var phase: CloudService.Phase = .notConfigured
    private(set) var devices: [ZendureDevice] = []
    private(set) var states: [String: DeviceState] = [:]
    private(set) var histories: [String: PowerHistory] = [:]

    // Console MQTT — journal borné de toutes les trames (entrantes/sortantes).
    private(set) var mqttLog: [MQTTLogEntry] = []
    var mqttLogPaused = false
    private static let mqttLogLimit = 500

    let settings: AppSettings
    private let cloud = CloudService()
    private var started = false

    init(settings: AppSettings) {
        self.settings = settings

        cloud.onPhaseChanged = { [weak self] phase in
            self?.phase = phase
        }
        cloud.onDevicesChanged = { [weak self] devices in
            self?.devices = devices
        }
        cloud.onStateChanged = { [weak self] deviceKey, state in
            guard let self else { return }
            self.states[deviceKey] = state
            var history = self.histories[deviceKey] ?? PowerHistory()
            history.append(state: state)
            self.histories[deviceKey] = history
        }
        cloud.onMQTTLog = { [weak self] entry in
            guard let self, !self.mqttLogPaused else { return }
            self.mqttLog.append(entry)
            if self.mqttLog.count > Self.mqttLogLimit {
                self.mqttLog.removeFirst(self.mqttLog.count - Self.mqttLogLimit)
            }
        }
    }

    func clearMQTTLog() {
        mqttLog = []
    }

    /// Idempotent — appelé en .onAppear de chaque scène pour garantir le
    /// démarrage même si la fenêtre principale n'est jamais ouverte.
    func start() {
        guard !started else { return }
        started = true
        cloud.pollInterval = Int(settings.refreshInterval)
        if let token = KeychainHelper.read(account: "cloudKey") {
            cloud.start(cloudKeyToken: token)
        }
    }

    /// Enregistre un nouveau Cloud Key et (re)lance la session.
    func applyCloudKey(_ token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        KeychainHelper.save(trimmed, account: "cloudKey")
        started = true
        cloud.start(cloudKeyToken: trimmed)
    }

    func forgetCloudKey() {
        KeychainHelper.delete(account: "cloudKey")
        cloud.stop()
        phase = .notConfigured
        devices = []
        states = [:]
        histories = [:]
        mqttLog = []
    }

    var hasStoredCloudKey: Bool {
        KeychainHelper.read(account: "cloudKey") != nil
    }

    func refreshNow() {
        cloud.requestRefresh()
    }

    // MARK: - Agrégats (header + menu bar)

    var totalSolarPower: Double {
        states.values.compactMap(\.solarInputPower).reduce(0, +)
    }

    var totalHomePower: Double {
        states.values.compactMap(\.outputHomePower).reduce(0, +)
    }

    var averageSoc: Double? {
        let socs = states.values.compactMap(\.electricLevel)
        guard !socs.isEmpty else { return nil }
        return socs.reduce(0, +) / Double(socs.count)
    }

    var lastUpdate: Date? {
        states.values.compactMap(\.lastUpdate).max()
    }
}
