import SwiftUI

struct ModelsPane: View {
    private var prefs = ModelPreferences.shared
    private var catalog = ModelCatalog.shared
    private var account = AccountService.shared

    @State private var query = ""
    @State private var isDownloadingSigLIP = false
    @State private var siglipProgress: Double = 0.0
    @State private var isDownloadingWhisper = false
    @State private var whisperProgress: Double = 0.0
    @State private var downloadError: String?

    @State private var googleKeyDraft = ""
    @State private var hasGoogleKey = false
    @State private var maskedGoogleKey = ""

    @State private var falKeyDraft = ""
    @State private var hasFalKey = false
    @State private var maskedFalKey = ""

    @State private var klingKeyDraft = ""
    @State private var hasKlingKey = false
    @State private var maskedKlingKey = ""

    @State private var leonardoKeyDraft = ""
    @State private var hasLeonardoKey = false
    @State private var maskedLeonardoKey = ""

    @State private var vastKeyDraft = ""
    @State private var hasVastKey = false
    @State private var maskedVastKey = ""
    @State private var vastInstances: [VastAIClient.VastInstance] = []
    @State private var vastUserInfo: VastAIClient.VastUserInfo?
    @State private var isLoadingVastInstances = false
    @ObservedObject private var tunnelManager = SSHTunnelManager.shared

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

    private func isLocked(_ row: Row) -> Bool {
        row.paidOnly && !account.isPaid && !DirectKeyStore.hasKey(for: row.id)
    }

    private var sections: [Section] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        func prepare(_ rows: [Row]) -> [Row] {
            let matched = q.isEmpty ? rows : rows.filter { $0.displayName.lowercased().contains(q) }
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

            directProviderKeysSection

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
        .onAppear(perform: refreshKeys)
    }

    private var directProviderKeysSection: some View {
        SettingsSection(title: "Direct API Keys (BYOK - Bring Your Own Key)") {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
                Text("Use your own API keys for Google Gemini/Imagen, Fal.ai (Kling, Seedance, Veo), Leonardo.Ai, or Kling directly without requiring a Palmier subscription.")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)

                keyInputRow(
                    label: "Google AI API Key (Gemini / Imagen 3)",
                    placeholder: "AIzaSy...",
                    hasKey: hasGoogleKey,
                    maskedKey: maskedGoogleKey,
                    draft: $googleKeyDraft,
                    onSave: {
                        let trimmed = googleKeyDraft.trimmingCharacters(in: .whitespaces)
                        if !trimmed.isEmpty { GoogleAIKeychain.save(trimmed); googleKeyDraft = ""; refreshKeys() }
                    },
                    onRemove: { GoogleAIKeychain.delete(); refreshKeys() }
                )

                Divider().overlay(AppTheme.Border.subtleColor)

                keyInputRow(
                    label: "Fal.ai API Key (Kling, Seedance, Flux, Veo)",
                    placeholder: "fal_key_...",
                    hasKey: hasFalKey,
                    maskedKey: maskedFalKey,
                    draft: $falKeyDraft,
                    onSave: {
                        let trimmed = falKeyDraft.trimmingCharacters(in: .whitespaces)
                        if !trimmed.isEmpty { FalAIKeychain.save(trimmed); falKeyDraft = ""; refreshKeys() }
                    },
                    onRemove: { FalAIKeychain.delete(); refreshKeys() }
                )

                Divider().overlay(AppTheme.Border.subtleColor)

                keyInputRow(
                    label: "Kling API Key (Direct Kling AI)",
                    placeholder: "kling_...",
                    hasKey: hasKlingKey,
                    maskedKey: maskedKlingKey,
                    draft: $klingKeyDraft,
                    onSave: {
                        let trimmed = klingKeyDraft.trimmingCharacters(in: .whitespaces)
                        if !trimmed.isEmpty { KlingKeychain.save(trimmed); klingKeyDraft = ""; refreshKeys() }
                    },
                    onRemove: { KlingKeychain.delete(); refreshKeys() }
                )

                Divider().overlay(AppTheme.Border.subtleColor)

                keyInputRow(
                    label: "Leonardo.Ai API Key (Image Generation)",
                    placeholder: "leo_key_...",
                    hasKey: hasLeonardoKey,
                    maskedKey: maskedLeonardoKey,
                    draft: $leonardoKeyDraft,
                    onSave: {
                        let trimmed = leonardoKeyDraft.trimmingCharacters(in: .whitespaces)
                        if !trimmed.isEmpty { LeonardoKeychain.save(trimmed); leonardoKeyDraft = ""; refreshKeys() }
                    },
                    onRemove: { LeonardoKeychain.delete(); refreshKeys() }
                )

                Text("Note: Leonardo API access requires paid API Credits from the Leonardo API Access page (separate from web app free tokens).")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)

                Divider().overlay(AppTheme.Border.subtleColor)

                keyInputRow(
                    label: "Vast.ai API Key (Cloud GPU & ComfyUI SSH Tunnel)",
                    placeholder: "vast_key_...",
                    hasKey: hasVastKey,
                    maskedKey: maskedVastKey,
                    draft: $vastKeyDraft,
                    onSave: {
                        let trimmed = vastKeyDraft.trimmingCharacters(in: .whitespaces)
                        if !trimmed.isEmpty {
                            VastAIKeychain.save(trimmed)
                            vastKeyDraft = ""
                            refreshKeys()
                            fetchVastInstances()
                        }
                    },
                    onRemove: {
                        VastAIKeychain.delete()
                        refreshKeys()
                        vastInstances = []
                    }
                )

                if hasVastKey {
                    vastInstancesSection
                }
            }
            .padding(.vertical, AppTheme.Spacing.xs)
        }
    }

    private var vastInstancesSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            HStack {
                Text("Vast.ai Instances & SSH Local Tunnel")
                    .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.semibold))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                Spacer()
                Button(action: fetchVastInstances) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: AppTheme.FontSize.xs))
                }
                .buttonStyle(.plain)
            }

            if let info = vastUserInfo {
                HStack(spacing: AppTheme.Spacing.sm) {
                    if let user = info.username, !user.isEmpty {
                        Text("Account: \(user)")
                            .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.medium))
                            .foregroundStyle(AppTheme.Text.secondaryColor)
                    }
                    if let balance = info.credit {
                        Text(String(format: "Balance: $%.2f", balance))
                            .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.semibold))
                            .foregroundStyle(balance > 0 ? Color.green : AppTheme.Text.tertiaryColor)
                    }
                    Text(info.ssh_key != nil ? "SSH: Configured ✓" : "SSH: Missing ✗")
                        .font(.system(size: AppTheme.FontSize.xxs))
                        .foregroundStyle(info.ssh_key != nil ? Color.green : Color.orange)
                }
                .padding(.horizontal, AppTheme.Spacing.xs)
                .padding(.vertical, 2)
                .background(AppTheme.Background.surfaceColor)
                .clipShape(Capsule())
            }

            tunnelStatusHeader

            if vastInstances.isEmpty {
                Text(isLoadingVastInstances ? "Loading instances..." : "No active Vast.ai instances found.")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            } else {
                ForEach(vastInstances) { inst in
                    vastInstanceRow(inst)
                }
            }
        }
    }

    private func vastInstanceRow(_ inst: VastAIClient.VastInstance) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(inst.displayName)
                    .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                if let host = inst.ssh_host, let port = inst.ssh_port {
                    Text("\(host):\(port)")
                        .font(.system(size: AppTheme.FontSize.xxs, design: .monospaced))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }
            }
            Spacer()
            if let host = inst.ssh_host, let port = inst.ssh_port {
                if case .connected(let h, let p, _) = tunnelManager.state, h == host && p == port {
                    Button("Disconnect SSH Tunnel") {
                        tunnelManager.disconnect()
                    }
                    .buttonStyle(.capsule(.secondary, size: .small))
                } else {
                    Button("Connect SSH Tunnel (Port 8188)") {
                        tunnelManager.connect(sshHost: host, sshPort: port, remotePort: 8188, localPort: 8188)
                    }
                    .buttonStyle(.capsule(.prominent, size: .small))
                }
            }
        }
        .padding(AppTheme.Spacing.xs)
        .background(AppTheme.Background.surfaceColor)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.xs))
    }

    private var tunnelStatusHeader: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            Circle()
                .fill(tunnelColor)
                .frame(width: 8, height: 8)
            Text(tunnelText)
                .font(.system(size: AppTheme.FontSize.xs, design: .monospaced))
                .foregroundStyle(AppTheme.Text.secondaryColor)
        }
    }

    private var tunnelColor: Color {
        switch tunnelManager.state {
        case .connected: return Color.green
        case .connecting: return Color.orange
        case .failed: return Color.red
        case .disconnected: return AppTheme.Text.tertiaryColor
        }
    }

    private var tunnelText: String {
        switch tunnelManager.state {
        case .connected(let host, _, let localPort):
            return "SSH Tunnel Active: 127.0.0.1:\(localPort) ➔ \(host)"
        case .connecting:
            return "Connecting SSH Tunnel..."
        case .failed(let reason):
            return "Tunnel Error: \(reason)"
        case .disconnected:
            return "SSH Tunnel Disconnected"
        }
    }

    private func keyInputRow(
        label: String,
        placeholder: String,
        hasKey: Bool,
        maskedKey: String,
        draft: Binding<String>,
        onSave: @escaping () -> Void,
        onRemove: @escaping () -> Void
    ) -> some View {
        HStack(spacing: AppTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text(label)
                    .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(AppTheme.Text.primaryColor)

                HStack(spacing: AppTheme.Spacing.sm) {
                    SecureField(hasKey ? maskedKey : placeholder, text: draft)
                        .textFieldStyle(.plain)
                        .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
                        .foregroundStyle(AppTheme.Text.primaryColor)
                        .onSubmit(onSave)
                        .padding(.horizontal, AppTheme.Spacing.sm)
                        .padding(.vertical, AppTheme.Spacing.xs)
                        .background(
                            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                                .fill(Color.black.opacity(AppTheme.Opacity.muted))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                                .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
                        )

                    let trimmed = draft.wrappedValue.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty {
                        Button("Save", action: onSave)
                            .buttonStyle(.capsule(.prominent, size: .regular))
                    } else if hasKey {
                        Button(action: onRemove) {
                            Image(systemName: "trash")
                                .font(.system(size: AppTheme.FontSize.md))
                                .foregroundStyle(AppTheme.Text.secondaryColor)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func refreshKeys() {
        if let k = GoogleAIKeychain.load(), !k.isEmpty {
            hasGoogleKey = true
            maskedGoogleKey = mask(k)
        } else {
            hasGoogleKey = false
            maskedGoogleKey = ""
        }
        if let k = FalAIKeychain.load(), !k.isEmpty {
            hasFalKey = true
            maskedFalKey = mask(k)
        } else {
            hasFalKey = false
            maskedFalKey = ""
        }
        if let k = KlingKeychain.load(), !k.isEmpty {
            hasKlingKey = true
            maskedKlingKey = mask(k)
        } else {
            hasKlingKey = false
            maskedKlingKey = ""
        }
        if let k = LeonardoKeychain.load(), !k.isEmpty {
            hasLeonardoKey = true
            maskedLeonardoKey = mask(k)
        } else {
            hasLeonardoKey = false
            maskedLeonardoKey = ""
        }
        if let k = VastAIKeychain.load(), !k.isEmpty {
            hasVastKey = true
            maskedVastKey = mask(k)
            fetchVastInstances()
        } else {
            hasVastKey = false
            maskedVastKey = ""
            vastInstances = []
        }
    }

    private func fetchVastInstances() {
        guard hasVastKey else { return }
        isLoadingVastInstances = true
        Task {
            do {
                async let instsTask = VastAIClient.listInstances()
                async let infoTask = VastAIClient.fetchUserInfo()

                let insts = try await instsTask
                let info = try? await infoTask

                await MainActor.run {
                    self.vastInstances = insts
                    self.vastUserInfo = info
                    self.isLoadingVastInstances = false
                }
            } catch {
                await MainActor.run {
                    self.isLoadingVastInstances = false
                }
            }
        }
    }

    private func mask(_ key: String) -> String {
        guard key.count > 8 else { return "••••••••" }
        return "\(key.prefix(4))••••••••\(key.suffix(4))"
    }

    private var onDeviceModelsSection: some View {
        let isSigLIPInstalled = ModelDownloader.installed(for: SearchIndexConfig.manifest) != nil
        let isWhisperMLXDownloaded = MLXWhisperTranscriber.isModelDownloaded()

        let siglipFolder = ModelDownloader.modelsDir
        let hfWhisperDir = MLXWhisperTranscriber.modelWeightsURL
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let hfCacheDir = homeDir.appendingPathComponent(".cache/huggingface/hub")
        let scriptsDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("scripts/transcription")

        let whisperFolder: URL = {
            if FileManager.default.fileExists(atPath: hfWhisperDir.path) {
                return hfWhisperDir
            } else if FileManager.default.fileExists(atPath: hfCacheDir.path) {
                return hfCacheDir
            } else {
                return scriptsDir
            }
        }()

        return SettingsSection(title: "On-Device Models (Local Mac)") {
            VStack(spacing: 0) {
                onDeviceRow(
                    name: "SigLIP 2 CoreML (Visual Search)",
                    source: "Hugging Face (palmier-io/siglip2-base-coreml)",
                    size: "355 MB • SHA256 Verified",
                    statusText: isSigLIPInstalled ? "Downloaded & Ready" : (isDownloadingSigLIP ? "\(Int(siglipProgress * 100))%" : "On Demand"),
                    isInstalled: isSigLIPInstalled,
                    isDownloading: isDownloadingSigLIP,
                    progress: siglipProgress,
                    folderURL: siglipFolder,
                    onDownload: { downloadSigLIP() }
                )
                Divider().overlay(AppTheme.Border.subtleColor)

                onDeviceRow(
                    name: "Whisper Large V3 Turbo (MLX)",
                    source: "mlx-community/whisper-large-v3-turbo",
                    size: "1.6 GB • Metal / NPU",
                    statusText: isWhisperMLXDownloaded ? "Downloaded & Ready" : (isDownloadingWhisper ? "Downloading…" : "On Demand"),
                    isInstalled: isWhisperMLXDownloaded,
                    isDownloading: isDownloadingWhisper,
                    progress: whisperProgress,
                    folderURL: whisperFolder,
                    onDownload: { downloadWhisper() }
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
        isDownloading: Bool = false,
        progress: Double = 0.0,
        folderURL: URL? = nil,
        onDownload: (() -> Void)? = nil
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

            if isDownloading {
                HStack(spacing: AppTheme.Spacing.xs) {
                    ProgressView(value: max(progress, 0.05))
                        .progressViewStyle(.linear)
                        .frame(width: 80)
                    Text("\(Int(progress * 100))%")
                        .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.bold))
                        .foregroundStyle(Color.orange)
                }
            }

            if !isInstalled && !isDownloading, let onDownload {
                Button(action: onDownload) {
                    HStack(spacing: AppTheme.Spacing.xxs) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: AppTheme.FontSize.xs))
                        Text("Download")
                            .font(.system(size: AppTheme.FontSize.xs))
                    }
                }
                .buttonStyle(.capsule(.prominent))
            }

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
                        .fill(isInstalled ? Color.green.opacity(0.15) : (isDownloading ? Color.orange.opacity(0.15) : Color.blue.opacity(0.15)))
                )
                .foregroundStyle(isInstalled ? Color.green : (isDownloading ? Color.orange : Color.blue))
        }
        .padding(.vertical, AppTheme.Spacing.smMd)
    }

    private func downloadSigLIP() {
        guard !isDownloadingSigLIP else { return }
        isDownloadingSigLIP = true
        siglipProgress = 0.01

        Task { @MainActor in
            do {
                _ = try await ModelDownloader().install(
                    manifest: SearchIndexConfig.manifest,
                    baseURL: SearchIndexConfig.baseURL,
                    progress: { p in
                        Task { @MainActor in
                            self.siglipProgress = p
                        }
                    }
                )
                isDownloadingSigLIP = false
            } catch {
                isDownloadingSigLIP = false
                downloadError = error.localizedDescription
            }
        }
    }

    private func downloadWhisper() {
        guard !isDownloadingWhisper else { return }
        isDownloadingWhisper = true
        whisperProgress = 0.05

        Task { @MainActor in
            let scriptURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("scripts/transcription/download_whisper.py")
            let venvPython = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("venv/bin/python3")
            let pythonURL = FileManager.default.fileExists(atPath: venvPython.path) ? venvPython : URL(fileURLWithPath: "/usr/bin/env")

            do {
                try await Task.detached(priority: .userInitiated) {
                    let process = Process()
                    process.executableURL = pythonURL
                    if pythonURL.path == "/usr/bin/env" {
                        process.arguments = ["python3", scriptURL.path]
                    } else {
                        process.arguments = [scriptURL.path]
                    }

                    let pipe = Pipe()
                    process.standardOutput = pipe
                    try process.run()

                    let reader = pipe.fileHandleForReading
                    while process.isRunning {
                        if let data = try? reader.read(upToCount: 256), let str = String(data: data, encoding: .utf8) {
                            if str.contains("PROGRESS:") {
                                let parts = str.components(separatedBy: "PROGRESS:")
                                if let last = parts.last, let val = Double(last.prefix(4)) {
                                    Task { @MainActor in
                                        self.whisperProgress = min(max(val, 0.05), 0.99)
                                    }
                                }
                            }
                        }
                        try await Task.sleep(nanoseconds: 200_000_000)
                    }
                    process.waitUntilExit()
                }.value

                whisperProgress = 1.0
                isDownloadingWhisper = false
            } catch {
                isDownloadingWhisper = false
            }
        }
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
