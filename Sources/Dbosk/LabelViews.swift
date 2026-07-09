import Connections
import SwiftUI

extension ColorTag {
    var color: Color {
        switch self {
        case .red: return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green: return .green
        case .blue: return .blue
        case .purple: return .purple
        case .gray: return .gray
        }
    }

    var displayName: String { rawValue.capitalized }
}

/// A named, colored pill for a connection label. Deliberately not a dot — a dot
/// reads as a status light; a badge reads as a tag.
struct LabelBadge: View {
    let label: ConnectionLabel

    var body: some View {
        Text(label.name)
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(label.colorTag.color.opacity(0.18), in: Capsule())
            .overlay(Capsule().strokeBorder(label.colorTag.color.opacity(0.55), lineWidth: 1))
            .foregroundStyle(label.colorTag.color)
    }
}

/// Preferences pane for defining the labels connections can carry.
struct LabelSettingsView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var model = appModel
        VStack(alignment: .leading, spacing: 12) {
            Text("Labels").font(.headline)
            Text("""
                Define labels to tag connections. Each connection can carry one \
                label, shown as a badge in the list and as a colored stripe \
                across the top of its window.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if model.labels.isEmpty {
                ContentUnavailableView(
                    "No Labels", systemImage: "tag",
                    description: Text("Add a label to start tagging connections."))
                    .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                List {
                    ForEach($model.labels) { $label in
                        LabelRow(label: $label) {
                            appModel.saveLabels()
                        } onDelete: {
                            appModel.deleteLabel(label)
                        }
                    }
                }
                .frame(minHeight: 180)
            }

            HStack {
                Button {
                    appModel.upsertLabel(ConnectionLabel(name: "New Label", colorTag: .blue))
                } label: {
                    Label("Add Label", systemImage: "plus")
                }
                Spacer()
            }
        }
        .padding(20)
        .frame(width: 460, height: 360)
        // Backstop so in-progress name edits persist even without a submit.
        .onDisappear { appModel.saveLabels() }
    }
}

/// One editable row in the labels preference pane.
private struct LabelRow: View {
    @Binding var label: ConnectionLabel
    let onCommit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            LabelBadge(label: label)
                .frame(width: 96, alignment: .leading)

            TextField("Name", text: $label.name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(onCommit)

            Menu {
                ForEach(ColorTag.allCases, id: \.self) { tag in
                    Button {
                        label.colorTag = tag
                    } label: {
                        Label(
                            tag.displayName,
                            systemImage: label.colorTag == tag ? "checkmark" : "circle.fill")
                    }
                }
            } label: {
                Circle().fill(label.colorTag.color).frame(width: 14, height: 14)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Color")

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete label")
        }
        .onChange(of: label.colorTag) { _, _ in onCommit() }
    }
}
