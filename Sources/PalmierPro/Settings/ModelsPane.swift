import SwiftUI

struct ModelsPane: View {
    private var prefs = ModelPreferences.shared
    private var catalog = ModelCatalog.shared
    private var account = AccountService.shared

    @State private var query = ""

    private struct Row: Identifiable {
        let id: String
        let displayName: String
        let paidOnly: Bool
    }

    private struct Section: Identifiable {
        let id: String
        let title: String
        let rows: [Row]
    }

    private func isLocked(_ row: Row) -> Bool { row.paidOnly && !account.isPaid }

    private var sections: [Section] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        func prepare(_ rows: [Row]) -> [Row] {
            let matched = q.isEmpty ? rows : rows.filter { $0.displayName.lowercased().contains(q) }
            // Available models first, locked (paid-only) ones grouped at the bottom.
            return matched.filter { !isLocked($0) } + matched.filter { isLocked($0) }
        }
        return [
            Section(id: "image", title: "Image",
                    rows: prepare(catalog.image.map { Row(id: $0.id, displayName: $0.displayName, paidOnly: $0.paidOnly) })),
            Section(id: "video", title: "Video",
                    rows: prepare(catalog.video.map { Row(id: $0.id, displayName: $0.displayName, paidOnly: $0.paidOnly) })),
            Section(id: "audio", title: "Audio",
                    rows: prepare(catalog.audio.map { Row(id: $0.id, displayName: $0.displayName, paidOnly: $0.paidOnly) })),
        ].filter { !$0.rows.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            searchBar

            onDeviceModelsSection

            if sections.isEmpty {
                Text(catalog.isLoaded ? "No models match \"\(query)\"." : "Loading models…")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .padding(.top, AppTheme.Spacing.lg)
            } else {
                ForEach(sections) { section in
                    sectionView(section)
                }
            }
        }
    }

    private var onDeviceModelsSection: some View {
        let isSigLIPInstalled = ModelDownloader.installed(for: SearchIndexConfig.manifest) != nil
        let isWhisperMLXAvailable = MLXWhisperTranscriber.isAvailable()

        let siglipFolder = ModelDownloader.modelsDir
        let whisperFolder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("scripts/transcription")

        return SettingsSection(title: "On-Device Models (Local Mac)") {
            VStack(spacing: 0) {
                onDeviceRow(
                    name: "SigLIP 2 CoreML (Visual Search)",
                    source: "Hugging Face (palmier-io/siglip2-base-coreml)",
                    size: "355 MB • SHA256 Verified",
                    statusText: isSigLIPInstalled ? "Downloaded & Ready" : "On Demand",
                    isInstalled: isSigLIPInstalled,
                    folderURL: siglipFolder
                )
                Divider().overlay(AppTheme.Border.subtleColor)

                onDeviceRow(
                    name: "Whisper Large V3 Turbo (MLX)",
                    source: "mlx-community/whisper-large-v3-turbo",
                    size: "1.6 GB • Metal / NPU",
                    statusText: isWhisperMLXAvailable ? "Downloaded & Ready" : "Script Ready",
                    isInstalled: isWhisperMLXAvailable,
                    folderURL: whisperFolder
                )
            }
            .padding(.vertical, AppTheme.Spacing.xs)
        }
    }

    private func onDeviceRow(
        name: String,
        source: String,
        size: String,
        statusText: String,
        isInstalled: Bool,
        folderURL: URL? = nil
    ) -> some View {
        HStack(spacing: AppTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                HStack(spacing: AppTheme.Spacing.xs) {
                    Text(name)
                        .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.medium))
                        .foregroundStyle(AppTheme.Text.primaryColor)

                    Image(systemName: isInstalled ? "checkmark.circle.fill" : "arrow.down.circle")
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(isInstalled ? Color.green : AppTheme.Text.secondaryColor)
                }
                Text("\(source) • \(size)")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
            }
            Spacer(minLength: AppTheme.Spacing.lg)

            if let folderURL {
                Button(action: {
                    try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(folderURL)
                }) {
                    HStack(spacing: AppTheme.Spacing.xxs) {
                        Image(systemName: "folder")
                            .font(.system(size: AppTheme.FontSize.xs))
                        Text("Show in Finder")
                            .font(.system(size: AppTheme.FontSize.xs))
                    }
                }
                .buttonStyle(.capsule(.secondary))
                .help("Open model directory on disk")
            }

            Text(statusText)
                .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.semibold))
                .padding(.horizontal, AppTheme.Spacing.sm)
                .padding(.vertical, AppTheme.Spacing.xxs)
                .background(
                    Capsule()
                        .fill(isInstalled ? Color.green.opacity(0.15) : Color.blue.opacity(0.15))
                )
                .foregroundStyle(isInstalled ? Color.green : Color.blue)
        }
        .padding(.vertical, AppTheme.Spacing.smMd)
    }

    private var searchBar: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.mutedColor)
            TextField("Search models", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.primaryColor)
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.smMd)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                .fill(Color.white.opacity(AppTheme.Opacity.subtle))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                .strokeBorder(AppTheme.Border.primaryColor, lineWidth: AppTheme.BorderWidth.thin)
        )
    }

    private func sectionView(_ section: Section) -> some View {
        SettingsSection(title: section.title) {
            VStack(spacing: 0) {
                ForEach(Array(section.rows.enumerated()), id: \.element.id) { index, row in
                    modelRow(row)
                    if index < section.rows.count - 1 {
                        Divider().overlay(AppTheme.Border.subtleColor)
                    }
                }
            }
            .padding(.vertical, AppTheme.Spacing.xs)
        }
    }

    @ViewBuilder
    private func modelRow(_ row: Row) -> some View {
        let locked = isLocked(row)
        HStack(spacing: AppTheme.Spacing.md) {
            Text(row.displayName)
                .font(.system(size: AppTheme.FontSize.md))
                .foregroundStyle(locked ? AppTheme.Text.tertiaryColor : AppTheme.Text.primaryColor)
            Spacer(minLength: AppTheme.Spacing.lg)
            if locked {
                Button("Subscribe") {
                    SettingsWindowController.shared.show(tab: .account)
                }
                .buttonStyle(.capsule(.secondary))
            } else {
                Toggle("", isOn: Binding(
                    get: { prefs.isEnabled(row.id) },
                    set: { prefs.setEnabled(row.id, $0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .accessibilityLabel(row.displayName)
            }
        }
        .padding(.vertical, AppTheme.Spacing.smMd)
    }
}
