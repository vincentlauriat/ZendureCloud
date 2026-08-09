import SwiftUI
import ServiceManagement

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    var label: LocalizedStringKey {
        switch self {
        case .system: "Système"
        case .light: "Clair"
        case .dark: "Sombre"
        }
    }
}

/// Réglages persistés — même pattern que MacInside : classe @Observable dont
/// chaque propriété écrit dans UserDefaults via didSet (pas de @AppStorage,
/// incompatible avec @Observable).
@Observable @MainActor
final class AppSettings {
    private static let defaults = UserDefaults.standard

    var appearanceRaw: String {
        didSet { Self.defaults.set(appearanceRaw, forKey: "appearance") }
    }

    var appearance: AppearanceMode {
        get { AppearanceMode(rawValue: appearanceRaw) ?? .system }
        set { appearanceRaw = newValue.rawValue }
    }

    /// Intervalle de rafraîchissement cloud, en secondes (l'API cloud n'aime
    /// pas être interrogée trop souvent — minimum raisonnable 15 s).
    var refreshInterval: Double {
        didSet { Self.defaults.set(refreshInterval, forKey: "refreshInterval") }
    }

    /// Adresse e-mail du compte Zendure (le mot de passe va dans le Keychain,
    /// jamais dans UserDefaults).
    var accountEmail: String {
        didSet { Self.defaults.set(accountEmail, forKey: "accountEmail") }
    }

    /// Région du compte : "eu" ou "global".
    var region: String {
        didSet { Self.defaults.set(region, forKey: "region") }
    }

    var showMenuBarExtra: Bool {
        didSet { Self.defaults.set(showMenuBarExtra, forKey: "showMenuBarExtra") }
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            // L'état système fait foi — on ne met jamais en cache un booléen.
            try? newValue ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
        }
    }

    init() {
        let d = Self.defaults
        appearanceRaw = d.string(forKey: "appearance") ?? AppearanceMode.system.rawValue
        refreshInterval = d.object(forKey: "refreshInterval") as? Double ?? 30
        accountEmail = d.string(forKey: "accountEmail") ?? ""
        region = d.string(forKey: "region") ?? "eu"
        showMenuBarExtra = d.object(forKey: "showMenuBarExtra") as? Bool ?? true
    }
}
