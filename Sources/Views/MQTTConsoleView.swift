import SwiftUI

/// Console MQTT : toutes les trames échangées avec le broker cloud, brutes,
/// sans filtrage — l'outil d'exploration ultime de ce que publie Zendure.
/// Complète la carte « Toutes les propriétés » (qui ne voit que les
/// `properties/report` fusionnés).
struct MQTTConsoleView: View {
    @Environment(AppModel.self) private var model
    @State private var filter = ""
    @State private var expandedIds: Set<Int> = []

    private var filtered: [MQTTLogEntry] {
        // Ordre anté-chronologique : la dernière trame en haut.
        let all = model.mqttLog.reversed()
        guard !filter.isEmpty else { return Array(all) }
        return all.filter {
            $0.topic.localizedCaseInsensitiveContains(filter)
                || $0.payload.localizedCaseInsensitiveContains(filter)
        }
    }

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                TextField("Filtrer (topic ou payload)…", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .frame(maxWidth: 320)
                Text("\(filtered.count) / \(model.mqttLog.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle(isOn: $model.mqttLogPaused) {
                    Label("Pause", systemImage: model.mqttLogPaused ? "play.fill" : "pause.fill")
                }
                .toggleStyle(.button)
                .controlSize(.small)
                Button {
                    model.clearMQTTLog()
                    expandedIds = []
                } label: {
                    Label("Vider", systemImage: "trash")
                }
                .controlSize(.small)
            }
            .padding(10)

            Divider()

            if model.mqttLog.isEmpty {
                ContentUnavailableView(
                    "Aucune trame reçue",
                    systemImage: "dot.radiowaves.left.and.right",
                    description: Text("Les messages MQTT apparaîtront ici dès que le flux temps réel sera connecté.")
                )
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filtered) { entry in
                            row(entry)
                            Divider()
                        }
                    }
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { model.start() }
    }

    private func row(_ entry: MQTTLogEntry) -> some View {
        let expanded = expandedIds.contains(entry.id)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: entry.direction == .incoming ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                    .foregroundStyle(entry.direction == .incoming ? .blue : .orange)
                    .font(.caption)
                    .help(entry.direction == .incoming ? "Reçu du cloud" : "Publié par l'app")
                Text(entry.topic)
                    .font(.caption.monospaced().weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer()
                Text(entry.date, format: .dateTime.hour().minute().second())
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if expanded {
                ScrollView(.horizontal) {
                    Text(entry.prettyPayload ?? entry.payload)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .padding(8)
                }
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            } else {
                Text(entry.payload)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            if expanded {
                expandedIds.remove(entry.id)
            } else {
                expandedIds.insert(entry.id)
            }
        }
    }
}
