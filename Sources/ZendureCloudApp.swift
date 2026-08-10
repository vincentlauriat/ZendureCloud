import Sparkle
import SwiftUI

@main
struct ZendureCloudApp: App {
    @State private var settings: AppSettings
    @State private var model: AppModel

    /// Updater Sparkle démarré au lancement (vérification périodique + menu).
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil
    )

    init() {
        let settings = AppSettings()
        _settings = State(initialValue: settings)
        _model = State(initialValue: AppModel(settings: settings))
    }

    var body: some Scene {
        Window("Tableau de bord", id: "dashboard") {
            DashboardView()
                .environment(settings)
                .environment(model)
                .preferredColorScheme(settings.appearance.colorScheme)
                .frame(minWidth: 700, minHeight: 500)
        }
        .defaultSize(width: 1100, height: 760)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }
        }

        Window("Console MQTT", id: "mqtt-console") {
            MQTTConsoleView()
                .environment(settings)
                .environment(model)
                .preferredColorScheme(settings.appearance.colorScheme)
                .frame(minWidth: 560, minHeight: 360)
        }
        .defaultSize(width: 860, height: 560)

        // Chaque scène ré-injecte l'environnement (les scènes ne le partagent
        // pas) et appelle model.start() en .onAppear — pattern MacInside.
        MenuBarExtra(isInserted: menuBarBinding) {
            MenuBarView()
                .environment(settings)
                .environment(model)
        } label: {
            MenuBarLabel()
                .environment(model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(settings)
                .environment(model)
                .preferredColorScheme(settings.appearance.colorScheme)
        }
    }

    /// Binding en lecture seule : la visibilité est pilotée par les réglages,
    /// le set est un no-op volontaire (pattern MacInside).
    private var menuBarBinding: Binding<Bool> {
        Binding(
            get: { settings.showMenuBarExtra },
            set: { _ in }
        )
    }
}
