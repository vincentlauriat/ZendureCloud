import Foundation

/// Orchestration de l'historique d'énergie : login app Zendure (identifiants
/// dans le Keychain), rapprochement des appareils par numéro de série, cache
/// disque des jours déjà connus, récupération séquentielle des jours
/// manquants (l'API est privée et le cloud Zendure fragile — on le ménage :
/// un appel à la fois, petite pause entre deux).
@MainActor @Observable
final class HistoryService {
    enum Phase: Equatable {
        case notConfigured          // pas d'identifiants app saisis
        case idle                   // prêt (ou terminé)
        case connecting             // login en cours
        case loading(done: Int, total: Int)
        case failed(String)
    }

    private(set) var phase: Phase = .notConfigured
    /// Jours triés par date croissante, par deviceKey.
    private(set) var days: [String: [EnergyDay]] = [:]
    /// Totaux vie entière, par deviceKey.
    private(set) var lifetime: [String: [String: Double]] = [:]
    /// Journal de débogage : les derniers échanges HTTP avec l'API app
    /// (mot de passe masqué), affiché dans la fenêtre Historique.
    private(set) var exchanges: [ZendureAppAPI.Exchange] = []

    private var session: ZendureAppAPI.Session?
    private var appDevices: [ZendureAppAPI.AppDevice] = []
    private var exchangeCounter = 0
    private static let exchangeLimit = 50

    static let accountKeychainKey = "appAccount"
    static let passwordKeychainKey = "appPassword"

    /// Pause entre deux appels tdengine (ns) — 365 jours ≈ 1 min de fetch,
    /// mais une seule fois grâce au cache.
    private static let throttleNanoseconds: UInt64 = 150_000_000

    init() {
        if isConfigured { phase = .idle }
    }

    var isConfigured: Bool {
        KeychainHelper.read(account: Self.accountKeychainKey) != nil
            && KeychainHelper.read(account: Self.passwordKeychainKey) != nil
    }

    func saveCredentials(account: String, password: String) {
        KeychainHelper.save(account.trimmingCharacters(in: .whitespacesAndNewlines), account: Self.accountKeychainKey)
        KeychainHelper.save(password, account: Self.passwordKeychainKey)
        session = nil
        appDevices = []
        phase = .idle
    }

    func forgetCredentials() {
        KeychainHelper.delete(account: Self.accountKeychainKey)
        KeychainHelper.delete(account: Self.passwordKeychainKey)
        session = nil
        appDevices = []
        days = [:]
        lifetime = [:]
        phase = .notConfigured
    }

    /// La base API : celle du Cloud Key (même région), sinon EU par défaut.
    private var base: URL {
        if let token = KeychainHelper.read(account: "cloudKey"),
           let key = try? CloudKey.decode(token) {
            return key.apiUrl
        }
        return ZendureAppAPI.defaultBase
    }

    /// Charge `rangeDays` jours d'historique pour les appareils donnés.
    /// Idempotent : les jours en cache ne sont pas re-téléchargés (sauf
    /// aujourd'hui, qui évolue en cours de journée).
    func load(rangeDays: Int, devices: [ZendureDevice]) async {
        guard isConfigured else {
            phase = .notConfigured
            return
        }
        if case .loading = phase { return }  // déjà en cours

        do {
            let session = try await ensureSession()
            let dates = ZendureAppAPI.dateStrings(back: rangeDays)
            guard let today = dates.last else { return }

            // Plan de travail : jours manquants (ou aujourd'hui) par appareil.
            var plan: [(device: ZendureDevice, appDevice: ZendureAppAPI.AppDevice, dates: [String])] = []
            for device in devices {
                guard let appDevice = matchAppDevice(for: device) else { continue }
                if days[device.deviceKey] == nil {
                    days[device.deviceKey] = HistoryCache.load(deviceKey: device.deviceKey)
                }
                let known = Set((days[device.deviceKey] ?? []).map(\.date))
                let missing = dates.filter { !known.contains($0) || $0 == today }
                plan.append((device, appDevice, missing))
            }
            guard !plan.isEmpty else {
                phase = .failed(String(localized: "Aucun appareil du Cloud Key retrouvé côté compte app (rapprochement par numéro de série)."))
                return
            }

            let total = plan.reduce(0) { $0 + $1.dates.count } + plan.count  // + totaux vie entière
            var done = 0
            phase = .loading(done: done, total: total)

            for item in plan {
                var stored = days[item.device.deviceKey] ?? []
                for date in item.dates {
                    let data = try await send(
                        ZendureAppAPI.energyRequest(session: session, device: item.appDevice, date: date),
                        label: String(localized: "Énergie \(date)")
                    )
                    let fields = try ZendureAppAPI.parseEnergyFields(data)
                    stored.removeAll { $0.date == date }
                    stored.append(EnergyDay(date: date, fields: fields))
                    done += 1
                    phase = .loading(done: done, total: total)
                    try? await Task.sleep(nanoseconds: Self.throttleNanoseconds)
                }
                stored.sort { $0.date < $1.date }
                days[item.device.deviceKey] = stored
                HistoryCache.save(stored, deviceKey: item.device.deviceKey)

                let totalsData = try await send(
                    ZendureAppAPI.energyRequest(session: session, device: item.appDevice, date: nil),
                    label: String(localized: "Totaux vie entière")
                )
                lifetime[item.device.deviceKey] = try ZendureAppAPI.parseEnergyFields(totalsData)
                done += 1
                phase = .loading(done: done, total: total)
            }
            phase = .idle
        } catch {
            session = nil  // jeton possiblement expiré : re-login au prochain essai
            phase = .failed(error.localizedDescription)
        }
    }

    /// Les `rangeDays` derniers jours pour un appareil, prêts à tracer.
    func range(_ rangeDays: Int, deviceKey: String) -> [EnergyDay] {
        let wanted = Set(ZendureAppAPI.dateStrings(back: rangeDays))
        return (days[deviceKey] ?? []).filter { wanted.contains($0.date) }
    }

    func clearDebugLog() {
        exchanges = []
    }

    // MARK: - Internes

    /// Exécute une requête en journalisant l'échange (débogage) et en
    /// transformant les statuts HTTP non-2xx en erreurs lisibles.
    private func send(_ request: URLRequest, label: String) async throws -> Data {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(decoding: data.prefix(4000), as: UTF8.self)
            record(label: label, request: request, status: status, responseBody: body)
            guard (200..<300).contains(status) else {
                throw ZendureAppAPI.APIError.badResponse(
                    String(localized: "\(label) : HTTP \(status) — \(String(body.prefix(300)))")
                )
            }
            return data
        } catch let error as ZendureAppAPI.APIError {
            throw error
        } catch {
            record(label: label, request: request, status: 0,
                   responseBody: String(localized: "Erreur transport : \(error.localizedDescription)"))
            throw ZendureAppAPI.APIError.badResponse(
                String(localized: "\(label) : \(error.localizedDescription)")
            )
        }
    }

    private func record(label: String, request: URLRequest, status: Int, responseBody: String) {
        exchangeCounter += 1
        exchanges.append(ZendureAppAPI.Exchange(
            id: exchangeCounter,
            date: Date(),
            label: label,
            method: request.httpMethod ?? "POST",
            url: request.url?.absoluteString ?? "?",
            status: status,
            requestBody: ZendureAppAPI.redactedBody(request.httpBody),
            responseBody: responseBody
        ))
        if exchanges.count > Self.exchangeLimit {
            exchanges.removeFirst(exchanges.count - Self.exchangeLimit)
        }
    }

    private func ensureSession() async throws -> ZendureAppAPI.Session {
        if let session { return session }
        guard let account = KeychainHelper.read(account: Self.accountKeychainKey),
              let password = KeychainHelper.read(account: Self.passwordKeychainKey) else {
            throw ZendureAppAPI.APIError.badResponse(String(localized: "Identifiants app absents du trousseau."))
        }
        phase = .connecting
        let loginData = try await send(
            ZendureAppAPI.loginRequest(base: base, account: account, password: password),
            label: String(localized: "Login")
        )
        let new = try ZendureAppAPI.parseLogin(loginData)
        session = new
        let devicesData = try await send(
            ZendureAppAPI.appDeviceListRequest(base: base, session: new),
            label: String(localized: "Liste des appareils (app)")
        )
        appDevices = try ZendureAppAPI.parseAppDevices(devicesData)
        return new
    }

    /// Rapprochement Cloud Key ↔ compte app : par numéro de série d'abord,
    /// par nom sinon (les deux listes viennent de mondes différents).
    private func matchAppDevice(for device: ZendureDevice) -> ZendureAppAPI.AppDevice? {
        if let sn = device.snNumber, !sn.isEmpty,
           let match = appDevices.first(where: { $0.snNumber == sn }) {
            return match
        }
        if let name = device.deviceName, !name.isEmpty,
           let match = appDevices.first(where: { $0.name == name }) {
            return match
        }
        return nil
    }
}
