import SwiftUI

enum DeviceCardKind: String {
    case overview, power, energy, packs, info, raw
}

/// Dispatcher : une carte d'un type donné pour un appareil donné.
struct DeviceCardView: View {
    @Environment(AppModel.self) private var model
    let device: ZendureDevice
    let kind: DeviceCardKind

    private var state: DeviceState { model.states[device.deviceKey] ?? DeviceState() }
    private var history: PowerHistory { model.histories[device.deviceKey] ?? PowerHistory() }

    var body: some View {
        switch kind {
        case .overview: OverviewCard(device: device, state: state)
        case .power: PowerCard(device: device, state: state, history: history)
        case .energy: EnergyCard(device: device, state: state)
        case .packs: PacksCard(device: device, state: state)
        case .info: InfoCard(device: device, state: state)
        case .raw: RawPropertiesCard(device: device, state: state)
        }
    }
}

// MARK: - Vue d'ensemble (jauge SOC + état)

private struct OverviewCard: View {
    let device: ZendureDevice
    let state: DeviceState

    var body: some View {
        MetricCard(title: device.displayName, systemImage: "battery.100percent.bolt") {
            HStack(alignment: .center, spacing: 16) {
                CircularGauge(
                    segments: [GaugeSegment(value: state.electricLevel ?? 0, color: gaugeColor)],
                    centerText: state.electricLevel.map { Format.percent($0) } ?? "—",
                    centerSubtext: packStateLabel
                )
                .frame(width: 88, height: 88)

                VStack(alignment: .leading, spacing: 6) {
                    if let minutes = state.remainOutMinutes {
                        LegendRow(color: .orange, label: "Autonomie", value: Format.minutes(minutes))
                    }
                    if let minutes = state.remainInputMinutes {
                        LegendRow(color: .green, label: "Pleine charge", value: Format.minutes(minutes))
                    }
                    if let min = state.socMin, let max = state.socMax {
                        LegendRow(color: .secondary, label: "Plage SOC", value: "\(Int(min))–\(Int(max)) %")
                    }
                    if let temp = state.deviceTemperature {
                        LegendRow(color: .red, label: "Température", value: Format.temperature(temp))
                    }
                    if let available = state.availableKwh, let total = state.totalCapacityKwh {
                        LegendRow(color: .blue, label: "Disponible",
                                  value: "\(Format.wattHours(available * 1000)) / \(Format.wattHours(total * 1000))")
                    }
                    if state.remainOutMinutes == nil, let estimated = state.estimatedRemainMinutes {
                        LegendRow(color: .orange, label: "Autonomie (est.)", value: Format.minutes(estimated))
                    }
                }
            }
        }
    }

    private var gaugeColor: Color {
        guard let soc = state.electricLevel else { return .gray }
        if soc < 20 { return .red }
        if soc < 40 { return .orange }
        return .green
    }

    private var packStateLabel: String? {
        switch state.packState {
        case 0: String(localized: "veille")
        case 1: String(localized: "charge")
        case 2: String(localized: "décharge")
        default: nil
        }
    }
}

// MARK: - Flux de puissance

private struct PowerCard: View {
    let device: ZendureDevice
    let state: DeviceState
    let history: PowerHistory

    var body: some View {
        MetricCard(title: "Puissance", systemImage: "bolt.fill") {
            VStack(alignment: .leading, spacing: 14) {
                flowRows

                if history.solar.count >= 2 {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Solaire")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        SparklineChart(values: history.solar, color: .yellow)
                            .frame(height: 40)
                    }
                }
                if history.home.count >= 2 {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Maison")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        SparklineChart(values: history.home, color: .blue)
                            .frame(height: 40)
                    }
                }
            }
        }
    }

    private var flowRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            flow("sun.max.fill", .yellow, "Solaire", state.solarInputPower)
            if !state.solarChannels.isEmpty, state.solarChannels.count > 1 {
                Text(state.solarChannels.enumerated()
                    .map { "MPPT\($0.offset + 1) \(Format.watts($0.element))" }
                    .joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 22)
            }
            flow("house.fill", .blue, "Maison", state.outputHomePower)
            flow("bolt.horizontal.fill", .purple, "Réseau", state.gridInputPower)
            flow("battery.100percent.bolt", .green, "Charge batterie", state.outputPackPower)
            flow("battery.25percent", .orange, "Décharge batterie", state.packInputPower)
            flow("powerplug.fill", .teal, "Hors réseau", state.offGridPower)
        }
    }

    @ViewBuilder
    private func flow(_ icon: String, _ color: Color, _ label: LocalizedStringKey, _ value: Double?) -> some View {
        if let value {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                    .font(.caption)
                    .frame(width: 16)
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(Format.watts(value))
                    .font(.caption.monospacedDigit())
            }
        }
    }
}

// MARK: - Énergie cumulée (session)

/// Compteurs d'énergie intégrés localement (puissance × temps entre deux
/// rapports), comme les capteurs `aggr*` de Zendure-HA — remis à zéro au
/// lancement de l'app.
private struct EnergyCard: View {
    let device: ZendureDevice
    let state: DeviceState

    var body: some View {
        MetricCard(title: "Énergie (session)", systemImage: "chart.bar.fill") {
            VStack(alignment: .leading, spacing: 6) {
                row("sun.max.fill", .yellow, "Solaire", state.energy.solarWh)
                row("house.fill", .blue, "Maison", state.energy.homeWh)
                row("bolt.horizontal.fill", .purple, "Réseau", state.energy.gridWh)
                row("battery.100percent.bolt", .green, "Charge batterie", state.energy.chargeWh)
                row("battery.25percent", .orange, "Décharge batterie", state.energy.dischargeWh)
                if let efficiency = state.energy.roundtripEfficiency {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .foregroundStyle(.teal)
                            .font(.caption)
                            .frame(width: 16)
                        Text("Efficacité aller-retour")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(String(format: "%.0f %%", efficiency))
                            .font(.caption.monospacedDigit())
                    }
                }
                Text("Cumuls depuis le lancement de l'app.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func row(_ icon: String, _ color: Color, _ label: LocalizedStringKey, _ wattHours: Double) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .font(.caption)
                .frame(width: 16)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(Format.wattHours(wattHours))
                .font(.caption.monospacedDigit())
        }
    }
}

// MARK: - Packs batterie

private struct PacksCard: View {
    let device: ZendureDevice
    let state: DeviceState

    var body: some View {
        MetricCard(title: "Batteries", systemImage: "square.stack.3d.up.fill") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(state.packs) { pack in
                    packRow(pack)
                }
            }
        }
    }

    private func packRow(_ pack: PackInfo) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(pack.sn)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                if let battery = pack.battery {
                    Text("\(battery.model) · \(String(format: "%.2f", battery.kwh)) kWh")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if pack.heatState == 1 {
                    Image(systemName: "flame.fill")
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .help("Chauffage batterie actif")
                }
                Spacer()
                if let soc = pack.socLevel {
                    Text(Format.percent(soc))
                        .font(.caption.monospacedDigit().weight(.semibold))
                }
            }
            if let soc = pack.socLevel {
                ProgressView(value: soc, total: 100)
                    .tint(soc < 20 ? .red : .green)
            }
            HStack(spacing: 10) {
                if let power = pack.power {
                    detail("bolt.fill", Format.watts(power))
                }
                if let temp = pack.maxTemp {
                    detail("thermometer.medium", Format.temperature(temp))
                }
                if let vol = pack.totalVol {
                    detail("minus.plus.batteryblock.fill", Format.voltage(vol))
                }
                if let current = pack.current {
                    detail("arrow.left.arrow.right", String(format: "%.1f A", current))
                }
                if let delta = pack.deltaVoltage {
                    // Écart cellule haute/basse : > ~50 mV = déséquilibre.
                    detail("chart.line.flattrend.xyaxis", "Δ \(Int((delta * 1000).rounded())) mV")
                }
                Spacer()
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private func detail(_ icon: String, _ value: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption2.monospacedDigit())
        }
    }
}

// MARK: - Infos appareil

private struct InfoCard: View {
    let device: ZendureDevice
    let state: DeviceState

    var body: some View {
        MetricCard(title: "Appareil", systemImage: "info.circle") {
            VStack(alignment: .leading, spacing: 6) {
                row("Modèle", device.productModel ?? "—")
                row("Numéro de série", device.snNumber ?? "—")
                row("Device key", device.deviceKey)
                if let ip = device.ip, !ip.isEmpty {
                    row("IP locale", ip)
                }
                if let rssi = state.rssi {
                    row("Wi-Fi", "\(Int(rssi)) dBm")
                }
                if let packNum = state.packNum {
                    row("Packs", String(packNum))
                }
                if let acMode = state.acMode {
                    row("Mode AC", acMode == 1 ? String(localized: "charge secteur") : String(localized: "injection"))
                }
                if let limit = state.inputLimit {
                    row("Limite d'entrée", Format.watts(limit))
                }
                if let limit = state.outputLimit {
                    row("Limite de sortie", Format.watts(limit))
                }
                if let inverse = state.inverseMaxPower {
                    row("Onduleur max", Format.watts(inverse))
                }
                if let voltage = state.batteryVoltage {
                    row("Tension batterie", Format.voltage(voltage))
                }
                if let passMode = state.passMode {
                    row("Bypass", bypassLabel(passMode))
                }
                if let heat = state.heatState {
                    row("Chauffage batterie", heat == 1
                        ? String(localized: "actif")
                        : String(localized: "inactif"))
                }
                if let total = state.totalCapacityKwh {
                    row("Capacité installée", String(format: "%.2f kWh", total))
                }
            }
        }
    }

    private func row(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption.monospacedDigit())
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    /// Valeurs `passMode` documentées par Zendure-HA.
    private func bypassLabel(_ mode: Int) -> String {
        switch mode {
        case 0: String(localized: "automatique")
        case 1: String(localized: "toujours inactif")
        case 2: String(localized: "toujours actif")
        default: "\(mode)"
        }
    }
}

// MARK: - Toutes les propriétés brutes

/// La carte « maximum d'informations » : chaque clé publiée par le cloud,
/// filtrable, avec horodatage relatif de dernière mise à jour.
struct RawPropertiesCard: View {
    let device: ZendureDevice
    let state: DeviceState
    @State private var filter = ""
    @State private var expanded = false

    private var filtered: [RawProperty] {
        let all = state.sortedRawProperties
        guard !filter.isEmpty else { return all }
        return all.filter { property in
            property.key.localizedCaseInsensitiveContains(filter)
                || property.value.localizedCaseInsensitiveContains(filter)
                || (PropertyCatalog.doc(for: property.key)?.description.localizedCaseInsensitiveContains(filter) ?? false)
        }
    }

    var body: some View {
        MetricCard(title: "Toutes les propriétés — \(device.displayName)", systemImage: "list.bullet.rectangle") {
            VStack(alignment: .leading, spacing: 8) {
                if state.rawProperties.isEmpty {
                    Text("Aucune donnée reçue pour le moment.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    HStack {
                        TextField("Filtrer (clé, valeur ou description)…", text: $filter)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                        Text("\(filtered.count)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    let visible = expanded ? filtered : Array(filtered.prefix(10))
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(visible.enumerated()), id: \.element.id) { index, property in
                            propertyRow(property)
                                .padding(.vertical, 6)
                            if index < visible.count - 1 {
                                Divider()
                            }
                        }
                    }

                    if filtered.count > 10 {
                        Button(expanded ? "Réduire" : "Tout afficher (\(filtered.count))") {
                            expanded.toggle()
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                }
            }
        }
    }

    private func propertyRow(_ property: RawProperty) -> some View {
        let doc = PropertyCatalog.doc(for: property.key)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(property.key)
                    .font(.caption.monospaced().weight(.medium))
                    .lineLimit(1)
                if let unit = doc?.unit {
                    Text(unit)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer()
                Text(property.value)
                    .font(.caption.monospaced())
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }
            Text(doc?.description ?? String(localized: "Propriété non documentée — signification à identifier."))
                .font(.caption2)
                .foregroundStyle(doc == nil ? .tertiary : .secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
