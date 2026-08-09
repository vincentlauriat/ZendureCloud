import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralPane()
                .tabItem { Label("Général", systemImage: "gearshape") }
            AccountPane()
                .tabItem { Label("Compte", systemImage: "key.icloud") }
        }
        .frame(width: 460, height: 340)
    }
}

private struct GeneralPane: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        // Ligne indispensable pour que Picker/Toggle fonctionnent avec @Observable.
        @Bindable var settings = settings
        Form {
            Picker("Apparence", selection: $settings.appearance) {
                ForEach(AppearanceMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }

            Picker("Poll de secours", selection: $settings.refreshInterval) {
                Text("30 s").tag(30.0)
                Text("60 s").tag(60.0)
                Text("2 min").tag(120.0)
                Text("5 min").tag(300.0)
            }
            .help("Les données arrivent en temps réel par MQTT ; ce poll force un rapport complet à intervalle régulier.")

            Toggle("Icône dans la barre de menus", isOn: $settings.showMenuBarExtra)
            Toggle("Lancer à l'ouverture de session", isOn: $settings.launchAtLogin)
        }
        .formStyle(.grouped)
    }
}

private struct AccountPane: View {
    @Environment(AppModel.self) private var model
    @State private var token = ""
    @State private var confirmForget = false

    var body: some View {
        Form {
            Section("Cloud Key") {
                if model.hasStoredCloudKey {
                    LabeledContent("État") {
                        Label(stateLabel, systemImage: stateIcon)
                            .foregroundStyle(stateColor)
                    }
                    Button("Oublier le Cloud Key…", role: .destructive) {
                        confirmForget = true
                    }
                    .confirmationDialog("Supprimer le Cloud Key du trousseau ?", isPresented: $confirmForget) {
                        Button("Supprimer", role: .destructive) { model.forgetCloudKey() }
                    }
                } else {
                    SecureField("Coller le Cloud Key ici", text: $token)
                    Button("Se connecter") {
                        model.applyCloudKey(token)
                        token = ""
                    }
                    .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            Section {
                Text("Le jeton se trouve dans l'app Zendure : **Profil → Authorization Cloud Key** (ou **Réglages → Développeur** selon la version), sur le compte principal. Il est stocké uniquement dans le trousseau macOS.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var stateLabel: LocalizedStringKey {
        switch model.phase {
        case .live: "Connecté"
        case .fetchingDevices, .connectingMQTT: "Connexion…"
        case .failed: "Erreur"
        case .notConfigured: "Non configuré"
        }
    }

    private var stateIcon: String {
        switch model.phase {
        case .live: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        default: "clock"
        }
    }

    private var stateColor: Color {
        switch model.phase {
        case .live: .green
        case .failed: .orange
        default: .secondary
        }
    }
}
