import SwiftUI

/// Fenêtre principale : header d'agrégats + masonry de cartes par appareil.
/// Masonry maison (pas LazyVGrid) : les colonnes s'empilent indépendamment,
/// remplies en round-robin — même choix que MacInside, pour éviter que toutes
/// les cartes d'une ligne partagent la hauteur de la plus haute.
struct DashboardView: View {
    @Environment(AppModel.self) private var model

    private let minColumnWidth: CGFloat = 300
    private let spacing: CGFloat = 16
    private let horizontalPadding: CGFloat = 20

    var body: some View {
        // GeometryReader AUTOUR de la ScrollView : la largeur sert au calcul
        // des colonnes, et le contenu garde sa hauteur intrinsèque.
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: spacing) {
                    HeaderView()
                    switch model.phase {
                    case .notConfigured:
                        SetupCard()
                    case .failed(let message) where model.devices.isEmpty:
                        SetupCard(errorMessage: message)
                    default:
                        if model.devices.isEmpty {
                            loadingCard
                        } else {
                            ForEach(model.devices) { device in
                                deviceSection(device, width: proxy.size.width - horizontalPadding * 2)
                            }
                        }
                        if case .failed(let message) = model.phase, !model.devices.isEmpty {
                            bannerError(message)
                        }
                    }
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, 16)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { model.start() }
    }

    // MARK: - Section par appareil

    /// Une section = en-tête (nom, modèle, fraîcheur), cartes compactes en
    /// colonnes (masonry), puis la table documentée des propriétés en pleine
    /// largeur — elle est trop large pour vivre dans une colonne.
    private func deviceSection(_ device: ZendureDevice, width: CGFloat) -> some View {
        let state = model.states[device.deviceKey]
        return VStack(alignment: .leading, spacing: spacing) {
            sectionHeader(device, state: state)
            masonry(cards: compactCards(for: device, state: state), width: width)
            RawPropertiesCard(device: device, state: state ?? DeviceState())
        }
        .padding(.top, 8)
    }

    private func sectionHeader(_ device: ZendureDevice, state: DeviceState?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "bolt.batteryblock.fill")
                .foregroundStyle(.green)
            Text(device.displayName)
                .font(.title3.weight(.semibold))
            if let model = device.productModel, model != device.displayName {
                Text(model)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let date = state?.lastUpdate {
                (Text("Mis à jour ") + Text(date, style: .relative))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func compactCards(for device: ZendureDevice, state: DeviceState?) -> [DeviceCardRef] {
        var cards: [DeviceCardRef] = [
            .init(device: device, kind: .overview),
            .init(device: device, kind: .power),
        ]
        if let state, state.energy.hasData {
            cards.append(.init(device: device, kind: .energy))
        }
        if let state, !state.packs.isEmpty {
            cards.append(.init(device: device, kind: .packs))
        }
        cards.append(.init(device: device, kind: .info))
        return cards
    }

    private func masonry(cards: [DeviceCardRef], width: CGFloat) -> some View {
        let columnCount = max(1, Int((width + spacing) / (minColumnWidth + spacing)))
        var columns: [[DeviceCardRef]] = Array(repeating: [], count: columnCount)
        for (index, card) in cards.enumerated() {
            columns[index % columnCount].append(card)
        }
        return HStack(alignment: .top, spacing: spacing) {
            ForEach(0..<columnCount, id: \.self) { column in
                VStack(spacing: spacing) {
                    ForEach(columns[column]) { ref in
                        DeviceCardView(device: ref.device, kind: ref.kind)
                    }
                }
            }
        }
    }

    private var loadingCard: some View {
        MetricCard(title: "Connexion", systemImage: "icloud") {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(phaseLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var phaseLabel: LocalizedStringKey {
        switch model.phase {
        case .fetchingDevices: "Récupération des appareils…"
        case .connectingMQTT: "Connexion au flux temps réel…"
        case .live: "Connecté — en attente du premier rapport…"
        default: "Connexion…"
        }
    }

    private func bannerError(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(10)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct DeviceCardRef: Identifiable {
    let device: ZendureDevice
    let kind: DeviceCardKind
    var id: String { "\(device.deviceKey)-\(kind.rawValue)" }
}

/// En-tête : agrégats globaux + horodatage de fraîcheur (une donnée cloud a
/// toujours un âge, autant l'afficher — idée MacInside/WidgetTimestamp).
private struct HeaderView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 24) {
            headline

            Spacer()

            if model.phase == .live {
                if let soc = model.averageSoc {
                    stat(label: "Batterie", value: Format.percent(soc), color: .green)
                }
                stat(label: "Solaire", value: Format.watts(model.totalSolarPower), color: .yellow)
                stat(label: "Maison", value: Format.watts(model.totalHomePower), color: .blue)
            }
        }
    }

    private var headline: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("ZendureCloud")
                .font(.title2.weight(.semibold))
            HStack(spacing: 6) {
                Circle()
                    .fill(model.phase == .live ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)
                if let date = model.lastUpdate {
                    Text("Mis à jour ") + Text(date, style: .relative)
                } else {
                    Text(statusText)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var statusText: LocalizedStringKey {
        switch model.phase {
        case .notConfigured: "Non configuré"
        case .fetchingDevices, .connectingMQTT: "Connexion…"
        case .live: "En attente de données…"
        case .failed: "Erreur de connexion"
        }
    }

    private func stat(label: LocalizedStringKey, value: String, color: Color) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(color)
        }
    }
}

/// Carte de configuration : saisie du Cloud Key.
struct SetupCard: View {
    @Environment(AppModel.self) private var model
    @State private var token = ""
    var errorMessage: String? = nil

    var body: some View {
        MetricCard(title: "Connexion au Cloud Zendure", systemImage: "key.icloud") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Dans l'app Zendure : **Profil → Authorization Cloud Key** (ou **Réglages → Développeur** selon la version), copiez le jeton du compte principal puis collez-le ici.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    SecureField("Cloud Key", text: $token)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(apply)
                    Button("Se connecter", action: apply)
                        .keyboardShortcut(.defaultAction)
                        .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if let errorMessage {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .frame(maxWidth: 480)
    }

    private func apply() {
        model.applyCloudKey(token)
        token = ""
    }
}
