import Foundation

/// Orchestration complète du Cloud Zendure : décodage du Cloud Key, appel
/// deviceList, connexion MQTT, abonnements, poll de secours `getAll`, et
/// fusion des rapports dans un état par appareil.
///
/// Tourne hors MainActor ; publie ses mises à jour via les callbacks
/// `onDevicesChanged` / `onStateChanged` / `onPhaseChanged`, toujours
/// dispatchés sur le main thread.
final class CloudService: @unchecked Sendable {
    /// Les causes distinctes restent distinctes (pattern MacInside
    /// `WidgetSnapshotStore.ReadResult`) : chaque cas correspond à un geste
    /// utilisateur différent.
    enum Phase: Equatable {
        case notConfigured                 // pas de Cloud Key saisi
        case fetchingDevices               // requête HTTP en cours
        case connectingMQTT
        case live                          // MQTT connecté, données en flux
        case failed(String)                // erreur affichable
    }

    private(set) var phase: Phase = .notConfigured
    private(set) var devices: [ZendureDevice] = []
    private(set) var states: [String: DeviceState] = [:]  // clé = deviceKey

    var onPhaseChanged: ((Phase) -> Void)?
    var onDevicesChanged: (([ZendureDevice]) -> Void)?
    var onStateChanged: ((_ deviceKey: String, _ state: DeviceState) -> Void)?

    private var mqtt: MQTTClient?
    private var pollTimer: DispatchSourceTimer?
    private var reconnectTask: Task<Void, Never>?
    private var messageCounter = 0
    private let stateQueue = DispatchQueue(label: "fr.lauriat.ZendureCloud.state")
    private let pollQueue = DispatchQueue(label: "fr.lauriat.ZendureCloud.poll")

    /// Intervalle du poll de secours `properties/read getAll` (secondes).
    var pollInterval: Int = 60

    // MARK: - Cycle de vie

    /// Démarre (ou redémarre) la session cloud avec le jeton donné.
    func start(cloudKeyToken: String) {
        stop()
        let token = cloudKeyToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            setPhase(.notConfigured)
            return
        }

        let cloudKey: CloudKey
        do {
            cloudKey = try CloudKey.decode(token)
        } catch {
            setPhase(.failed("Cloud Key invalide : \(error.localizedDescription)"))
            return
        }

        setPhase(.fetchingDevices)
        Task { [weak self] in
            guard let self else { return }
            do {
                let (devices, mqtt) = try await ZendureAPI.fetchDeviceList(cloudKey: cloudKey)
                self.stateQueue.sync { self.devices = devices }
                DispatchQueue.main.async { self.onDevicesChanged?(devices) }
                self.connectMQTT(credentials: mqtt, devices: devices)
            } catch {
                self.setPhase(.failed(error.localizedDescription))
            }
        }
    }

    func stop() {
        reconnectTask?.cancel()
        reconnectTask = nil
        pollTimer?.cancel()
        pollTimer = nil
        mqtt?.onStateChange = nil
        mqtt?.onMessage = nil
        mqtt?.disconnect()
        mqtt = nil
    }

    /// Demande un rafraîchissement immédiat de tous les appareils.
    func requestRefresh() {
        publishGetAll()
    }

    // MARK: - MQTT

    private func connectMQTT(credentials: MQTTCredentials, devices: [ZendureDevice]) {
        setPhase(.connectingMQTT)
        let client = MQTTClient(
            host: credentials.host,
            port: credentials.port,
            clientId: credentials.clientId,
            username: credentials.username,
            password: credentials.password
        )
        mqtt = client

        client.onStateChange = { [weak self] state in
            guard let self else { return }
            switch state {
            case .connected:
                // Les deux formes de topic : selon le firmware, les appareils
                // publient sur l'une ou l'autre.
                var topics: [String] = []
                for device in devices {
                    topics.append("/\(device.productKey)/\(device.deviceKey)/#")
                    topics.append("iot/\(device.productKey)/\(device.deviceKey)/#")
                }
                client.subscribe(topics: topics)
                self.setPhase(.live)
                self.publishGetAll()
                self.startPollTimer()
            case .disconnected(let reason):
                self.pollTimer?.cancel()
                self.pollTimer = nil
                self.scheduleReconnect(reason: reason)
            case .idle, .connecting:
                break
            }
        }

        client.onMessage = { [weak self] topic, payload in
            self?.handleMessage(topic: topic, payload: payload)
        }

        client.connect()
    }

    /// Reconnexion avec backoff simple : le jeton peut avoir expiré, donc on
    /// repart du deviceList complet (qui re-fournit aussi les credentials MQTT).
    private func scheduleReconnect(reason: String?) {
        guard reconnectTask == nil else { return }
        setPhase(.failed("Connexion MQTT perdue\(reason.map { " : \($0)" } ?? "") — reconnexion dans 15 s…"))
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard let self, !Task.isCancelled else { return }
            self.reconnectTask = nil
            if let token = KeychainHelper.read(account: "cloudKey") {
                self.start(cloudKeyToken: token)
            }
        }
    }

    /// `properties/read` + `getAll` sur chaque appareil — le filet de sécurité
    /// pour forcer un rapport complet (les rapports spontanés sont partiels).
    private func publishGetAll() {
        guard let mqtt else { return }
        // Un seul sync : devices + incrément du compteur (appelé depuis la
        // queue MQTT, la pollQueue ou le main thread — jamais stateQueue).
        let (devices, firstMessageId) = stateQueue.sync {
            messageCounter += self.devices.count
            return (self.devices, messageCounter - self.devices.count + 1)
        }
        for (index, device) in devices.enumerated() {
            let payload: [String: Any] = [
                "properties": ["getAll"],
                "deviceId": device.deviceKey,
                "messageId": firstMessageId + index,
                "timestamp": Int(Date().timeIntervalSince1970),
            ]
            if let data = try? JSONSerialization.data(withJSONObject: payload) {
                mqtt.publish(topic: "iot/\(device.productKey)/\(device.deviceKey)/properties/read", payload: data)
            }
        }
    }

    private func startPollTimer() {
        pollTimer?.cancel()
        // JAMAIS sur stateQueue : le handler appelle publishGetAll() qui fait
        // un stateQueue.sync — sur la même queue ce serait un deadlock
        // (crash SIGTRAP __DISPATCH_WAIT_FOR_QUEUE__, vu le 2026-08-09).
        let timer = DispatchSource.makeTimerSource(queue: pollQueue)
        timer.schedule(deadline: .now() + .seconds(pollInterval), repeating: .seconds(pollInterval))
        timer.setEventHandler { [weak self] in
            self?.publishGetAll()
        }
        timer.resume()
        pollTimer = timer
    }

    // MARK: - Messages entrants

    private func handleMessage(topic: String, payload: Data) {
        // Découpage en 4 segments max : marche pour `/pk/dk/sous/topic` (1er
        // segment vide) comme pour `iot/pk/dk/sous/topic`.
        let parts = topic.split(separator: "/", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count >= 4 else { return }
        let deviceKey = String(parts[2])
        let subTopic = String(parts[3])

        guard subTopic.hasPrefix("properties/report") || subTopic.hasPrefix("properties/energy") else { return }
        guard let root = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] else { return }

        let updated: DeviceState = stateQueue.sync {
            var state = states[deviceKey] ?? DeviceState()
            state.merge(payload: root)
            states[deviceKey] = state
            return state
        }
        DispatchQueue.main.async { [weak self] in
            self?.onStateChanged?(deviceKey, updated)
        }
    }

    private func setPhase(_ new: Phase) {
        stateQueue.sync { phase = new }
        DispatchQueue.main.async { [weak self] in
            self?.onPhaseChanged?(new)
        }
    }
}
