import SwiftUI

/// Label compact dans la barre de menus : icône + SOC moyen.
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let soc = model.averageSoc {
            Text("\(Image(systemName: batteryIcon(soc))) \(Int(soc.rounded())) %")
                .monospacedDigit()
        } else {
            Image(systemName: "bolt.badge.clock")
        }
    }

    private func batteryIcon(_ soc: Double) -> String {
        switch soc {
        case ..<15: "battery.25percent"
        case ..<45: "battery.50percent"
        case ..<75: "battery.75percent"
        default: "battery.100percent"
        }
    }
}

/// Dropdown de la barre de menus : résumé par appareil + accès au dashboard.
struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("ZendureCloud")
                    .font(.headline)
                Spacer()
                if let date = model.lastUpdate {
                    Text(date, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            switch model.phase {
            case .notConfigured:
                Text("Aucun compte configuré — ouvrez le tableau de bord pour coller votre Cloud Key.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .failed(let message):
                Label {
                    Text(message).font(.caption)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            case .fetchingDevices, .connectingMQTT:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Connexion…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .live:
                ForEach(model.devices) { device in
                    deviceRow(device)
                }
            }

            Divider()

            HStack {
                Button("Tableau de bord") {
                    openWindow(id: "dashboard")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                Button("Actualiser") { model.refreshNow() }
                SettingsLink { Text("Réglages…") }
            }
            .controlSize(.small)

            HStack {
                Spacer()
                Button("Quitter") { NSApplication.shared.terminate(nil) }
                    .controlSize(.small)
            }
        }
        .padding(12)
        .frame(width: 320)
        .onAppear { model.start() }
    }

    private func deviceRow(_ device: ZendureDevice) -> some View {
        let state = model.states[device.deviceKey]
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(device.displayName)
                    .font(.caption.weight(.medium))
                Spacer()
                if let soc = state?.electricLevel {
                    Text(Format.percent(soc))
                        .font(.caption.monospacedDigit().weight(.semibold))
                }
            }
            HStack(spacing: 12) {
                if let solar = state?.solarInputPower {
                    miniStat("sun.max.fill", .yellow, Format.watts(solar))
                }
                if let home = state?.outputHomePower {
                    miniStat("house.fill", .blue, Format.watts(home))
                }
                if let charge = state?.outputPackPower, charge > 0 {
                    miniStat("arrow.down.to.line", .green, Format.watts(charge))
                }
                if let discharge = state?.packInputPower, discharge > 0 {
                    miniStat("arrow.up.to.line", .orange, Format.watts(discharge))
                }
                Spacer()
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func miniStat(_ icon: String, _ color: Color, _ value: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(color)
            Text(value)
                .font(.caption2.monospacedDigit())
        }
    }
}
