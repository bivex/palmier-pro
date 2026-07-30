import SwiftUI

struct VastAIPane: View {
    @State private var vastKeyDraft = ""
    @State private var hasVastKey = false
    @State private var maskedVastKey = ""
    @State private var vastInstances: [VastAIClient.VastInstance] = []
    @State private var vastUserInfo: VastAIClient.VastUserInfo?
    @State private var livePrices: [String: String] = [:]
    @State private var isLoading = false
    @State private var isDeploying = false
    @State private var deployError: String?

    @State private var selectedModelTemplate = "flux-schnell"
    @State private var selectedGPUType = "RTX 4090"
    @State private var selectedRegion = "ANY"
    @State private var selectedStrategy = "dlperf"

    @ObservedObject private var tunnelManager = SSHTunnelManager.shared

    private let modelTemplates = [
        ("flux-schnell", "FLUX.1-Schnell (ComfyUI)", "1-sec ultra-fast photo generation"),
        ("sdxl-turbo", "Fast SDXL (ComfyUI)", "High-speed SDXL image generation"),
        ("video-wan", "Wan2.1 / Seedance Video (ComfyUI)", "Text-to-Video & Image-to-Video generation")
    ]

    private let gpuOptions = [
        ("RTX 4090", "NVIDIA RTX 4090 (24GB VRAM)", "Fetching live API price..."),
        ("RTX 3090", "NVIDIA RTX 3090 (24GB VRAM)", "Fetching live API price..."),
        ("A100", "NVIDIA A100 (80GB VRAM)", "Fetching live API price..."),
        ("ANY", "Any Available GPU (Cheapest)", "Fetching live API price...")
    ]

    private let regionOptions = [
        ("ANY", "Any Region (Global — Lowest Price)"),
        ("US", "North America (US / Canada)"),
        ("EU", "Europe (EU / DE / SE / UK / FR)"),
        ("ASIA", "Asia & Pacific (JP / KR / SG / HK)")
    ]

    private let strategyOptions = [
        ("dlperf", "⚡ Best Performance per $1 (Max DLPerf) — Recommended"),
        ("price", "🏷️ Lowest Price (Cheapest hourly rate)"),
        ("reliability", "🛡️ Ultra Reliability (99%+ Uptime & Datacenter)")
    ]

    @State private var manualSSHCommand = ""
    @State private var manualHost = ""
    @State private var manualPort = ""
    @State private var customHosts: [Int: String] = [:]
    @State private var customPorts: [Int: String] = [:]

    @State private var autoRefreshTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxl) {
            apiKeySection
            if hasVastKey {
                accountHeaderCard
                quickLaunchSection
                activeInstancesSection
                manualSSHSection
            }
        }
        .onAppear {
            refreshData()
            startAutoRefresh()
        }
        .onDisappear {
            autoRefreshTask?.cancel()
            autoRefreshTask = nil
        }
    }

    private var apiKeySection: some View {
        SettingsSection(title: "Vast.ai Cloud GPU API Key") {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                Text("Connect your Vast.ai account to rent cloud GPUs and connect via secure SSH Local Tunnel.")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)

                HStack(spacing: AppTheme.Spacing.md) {
                    SecureField(hasVastKey ? maskedVastKey : "2d7b...", text: $vastKeyDraft)
                        .textFieldStyle(.plain)
                        .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
                        .foregroundStyle(AppTheme.Text.primaryColor)
                        .padding(.horizontal, AppTheme.Spacing.sm)
                        .padding(.vertical, AppTheme.Spacing.xs)
                        .background(AppTheme.Background.surfaceColor)
                        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.xs))
                        .overlay(
                            RoundedRectangle(cornerRadius: AppTheme.Radius.xs)
                                .stroke(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.hairline)
                        )

                    if !vastKeyDraft.trimmingCharacters(in: .whitespaces).isEmpty {
                        Button("Save Key", action: saveKey)
                            .buttonStyle(.capsule(.prominent, size: .regular))
                    } else if hasVastKey {
                        Button(action: removeKey) {
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

    private var accountHeaderCard: some View {
        HStack(spacing: AppTheme.Spacing.lg) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text("Account")
                    .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                Text(vastUserInfo?.username ?? "Loading...")
                    .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.semibold))
                    .foregroundStyle(AppTheme.Text.primaryColor)
            }

            Divider().frame(height: 30).overlay(AppTheme.Border.subtleColor)

            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text("Balance")
                    .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                Text(String(format: "$%.2f USD", vastUserInfo?.credit ?? 0.0))
                    .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.bold))
                    .foregroundStyle((vastUserInfo?.credit ?? 0) > 0 ? Color.green : AppTheme.Text.secondaryColor)
            }

            Divider().frame(height: 30).overlay(AppTheme.Border.subtleColor)

            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text("SSH Key Status")
                    .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                HStack(spacing: 4) {
                    Circle()
                        .fill(vastUserInfo?.ssh_key != nil ? Color.green : Color.orange)
                        .frame(width: 6, height: 6)
                    Text(vastUserInfo?.ssh_key != nil ? "Configured ✓" : "Missing ✗")
                        .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
                        .foregroundStyle(vastUserInfo?.ssh_key != nil ? Color.green : Color.orange)
                }
            }

            Spacer()

            Button(action: refreshData) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
            }
            .buttonStyle(.plain)
        }
        .padding(AppTheme.Spacing.mdLg)
        .background(AppTheme.Background.surfaceColor)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.md))
    }

    private var quickLaunchSection: some View {
        SettingsSection(title: "Launch New GPU Instance") {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                Text("Select model workflow & target GPU to automatically spin up a container with ComfyUI.")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)

                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    Text("Model / Workflow Template")
                        .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                        .foregroundStyle(AppTheme.Text.secondaryColor)

                    Picker("", selection: $selectedModelTemplate) {
                        ForEach(modelTemplates, id: \.0) { tmpl in
                            Text("\(tmpl.1) — \(tmpl.2)").tag(tmpl.0)
                        }
                    }
                    .labelsHidden()
                }

                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    Text("GPU Type & Hourly Rate")
                        .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                        .foregroundStyle(AppTheme.Text.secondaryColor)

                    Picker("", selection: $selectedGPUType) {
                        ForEach(gpuOptions, id: \.0) { gpu in
                            let price = livePrices[gpu.0] ?? gpu.2
                            Text("\(gpu.1) — \(price)").tag(gpu.0)
                        }
                    }
                    .labelsHidden()
                }

                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    Text("Server Region / Country")
                        .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                        .foregroundStyle(AppTheme.Text.secondaryColor)

                    Picker("", selection: $selectedRegion) {
                        ForEach(regionOptions, id: \.0) { reg in
                            Text(reg.1).tag(reg.0)
                        }
                    }
                    .labelsHidden()
                }

                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    Text("Rental Strategy & Optimization")
                        .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                        .foregroundStyle(AppTheme.Text.secondaryColor)

                    Picker("", selection: $selectedStrategy) {
                        ForEach(strategyOptions, id: \.0) { strat in
                            Text(strat.1).tag(strat.0)
                        }
                    }
                    .labelsHidden()
                }

                if let err = deployError {
                    Text("Error: \(err)")
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(Color.red)
                }

                HStack {
                    Button(action: launchInstance) {
                        HStack(spacing: AppTheme.Spacing.xs) {
                            if isDeploying {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "play.circle.fill")
                            }
                            Text(isDeploying ? "Launching GPU Instance..." : "Rent & Launch GPU Instance")
                        }
                    }
                    .buttonStyle(.capsule(.prominent, size: .regular))
                    .disabled(isDeploying)

                    Spacer()
                }
            }
        }
    }

    private var activeInstancesSection: some View {
        SettingsSection(title: "Active Instances & SSH Local Tunnel") {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                tunnelStatusHeader

                if vastInstances.isEmpty {
                    Text(isLoading ? "Fetching instances..." : "No active GPU instances currently running.")
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .padding(.vertical, AppTheme.Spacing.xs)
                } else {
                    ForEach(vastInstances) { inst in
                        instanceCard(inst)
                    }
                }
            }
        }
    }

    private func instanceCard(_ inst: VastAIClient.VastInstance) -> some View {
        let currentHost = customHosts[inst.id] ?? inst.ssh_host ?? ""
        let currentPortStr = customPorts[inst.id] ?? (inst.ssh_port != nil ? String(inst.ssh_port!) : "")
        let currentPort = Int(currentPortStr.trimmingCharacters(in: .whitespaces)) ?? (inst.ssh_port ?? 0)

        return HStack(spacing: AppTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(inst.isRunning ? Color.green : (inst.isLoading ? Color.orange : Color.gray))
                        .frame(width: 8, height: 8)
                    Text(inst.displayName)
                        .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.semibold))
                        .foregroundStyle(AppTheme.Text.primaryColor)
                    
                    if inst.isLoading {
                        Text("⏳ BOOTING UP")
                            .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.bold))
                            .foregroundStyle(Color.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.15))
                            .clipShape(Capsule())
                    }
                }

                if inst.isLoading {
                    Text(inst.status_msg ?? "Downloading Docker image (ComfyUI)...")
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                        .lineLimit(1)
                } else {
                    HStack(spacing: AppTheme.Spacing.xs) {
                        Text("Host:")
                            .font(.system(size: AppTheme.FontSize.xxs))
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                        TextField("Host", text: Binding(
                            get: { customHosts[inst.id] ?? inst.ssh_host ?? "" },
                            set: { customHosts[inst.id] = $0 }
                        ))
                        .textFieldStyle(.plain)
                        .font(.system(size: AppTheme.FontSize.xs, design: .monospaced))
                        .frame(width: 140)

                        Text("Port:")
                            .font(.system(size: AppTheme.FontSize.xxs))
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                        TextField("Port", text: Binding(
                            get: { customPorts[inst.id] ?? (inst.ssh_port != nil ? String(inst.ssh_port!) : "") },
                            set: { customPorts[inst.id] = $0 }
                        ))
                        .textFieldStyle(.plain)
                        .font(.system(size: AppTheme.FontSize.xs, design: .monospaced))
                        .frame(width: 60)
                    }
                }
            }

            Spacer()

            if !currentHost.isEmpty && currentPort > 0 {
                if case .connected(let h, let p, _) = tunnelManager.state, h == currentHost && p == currentPort {
                    Button("Disconnect Tunnel") {
                        tunnelManager.disconnect()
                    }
                    .buttonStyle(.capsule(.secondary, size: .small))
                } else {
                    Button("Connect SSH Tunnel") {
                        tunnelManager.connect(sshHost: currentHost, sshPort: currentPort, remotePort: 8188, localPort: 8188)
                    }
                    .buttonStyle(.capsule(.prominent, size: .small))
                }
            }

            Button(action: { toggleState(inst) }) {
                Image(systemName: inst.isRunning ? "pause.fill" : "play.fill")
                    .foregroundStyle(AppTheme.Text.secondaryColor)
            }
            .buttonStyle(.plain)
            .help(inst.isRunning ? "Pause Instance" : "Resume Instance")

            Button(action: { destroy(inst) }) {
                Image(systemName: "trash")
                    .foregroundStyle(Color.red.opacity(0.8))
            }
            .buttonStyle(.plain)
            .help("Destroy Instance")
        }
        .padding(AppTheme.Spacing.smMd)
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
            return "SSH Tunnel Active ➔ http://127.0.0.1:\(localPort) (\(host))"
        case .connecting:
            return "Connecting SSH Tunnel..."
        case .failed(let reason):
            return "Tunnel Error: \(reason)"
        case .disconnected:
            return "SSH Tunnel Disconnected"
        }
    }

    private func saveKey() {
        let trimmed = vastKeyDraft.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        VastAIKeychain.save(trimmed)
        vastKeyDraft = ""
        refreshData()
    }

    private func removeKey() {
        VastAIKeychain.delete()
        tunnelManager.disconnect()
        hasVastKey = false
        maskedVastKey = ""
        vastInstances = []
        vastUserInfo = nil
    }

    private func refreshData() {
        if let k = VastAIKeychain.load(), !k.isEmpty {
            hasVastKey = true
            maskedVastKey = mask(k)
            isLoading = true
            Task {
                async let instsTask = VastAIClient.listInstances()
                async let infoTask = VastAIClient.fetchUserInfo()
                async let pricesTask = VastAIClient.fetchLiveGpuPrices()

                let insts = (try? await instsTask) ?? []
                let info = try? await infoTask
                let prices = await pricesTask

                await MainActor.run {
                    self.vastInstances = insts
                    self.vastUserInfo = info
                    self.livePrices = prices
                    self.isLoading = false
                }
            }
        } else {
            hasVastKey = false
            maskedVastKey = ""
            vastInstances = []
            vastUserInfo = nil
        }
    }

    private func launchInstance() {
        isDeploying = true
        deployError = nil
        let targetGPU = selectedGPUType
        let targetRegion = selectedRegion
        let targetStrategy = selectedStrategy
        Task {
            do {
                let offer = try await VastAIClient.searchBestOffer(gpuType: targetGPU, region: targetRegion, strategy: targetStrategy)
                try await VastAIClient.createInstance(offerId: offer.id)

                try? await Task.sleep(for: .seconds(2))
                let insts = (try? await VastAIClient.listInstances()) ?? []

                await MainActor.run {
                    self.vastInstances = insts
                    self.isDeploying = false

                    if let newInst = insts.first, let host = newInst.ssh_host, let port = newInst.ssh_port {
                        print("[ssh-tunnel] NOTICE: Auto-initiating SSH Local Tunnel connection for newly rented instance #\(newInst.id) (root@\(host):\(port))...")
                        SSHTunnelManager.shared.connect(sshHost: host, sshPort: port, remotePort: 8188, localPort: 8188)
                    }
                }
            } catch {
                await MainActor.run {
                    self.deployError = error.localizedDescription
                    self.isDeploying = false
                }
            }
        }
    }

    private func toggleState(_ inst: VastAIClient.VastInstance) {
        let newState = inst.isRunning ? "stopped" : "running"
        Task {
            try? await VastAIClient.setInstanceState(id: inst.id, state: newState)
            refreshData()
        }
    }

    private func destroy(_ inst: VastAIClient.VastInstance) {
        Task {
            try? await VastAIClient.destroyInstance(id: inst.id)
            refreshData()
        }
    }

    private func startAutoRefresh() {
        autoRefreshTask?.cancel()
        autoRefreshTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                if Task.isCancelled { break }
                if hasVastKey {
                    let insts = (try? await VastAIClient.listInstances()) ?? []
                    if !Task.isCancelled {
                        self.vastInstances = insts
                    }
                }
            }
        }
    }

    private var manualSSHSection: some View {
        SettingsSection(title: "Connect via Custom / Direct SSH Command") {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text("Paste full SSH command (e.g. ssh -p 50189 root@92.138.166.13 -L 8080:localhost:8080) to auto-fill Host and Port:")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)

                TextField("ssh -p 13796 root@ssh4.vast.ai", text: $manualSSHCommand)
                    .textFieldStyle(.plain)
                    .font(.system(size: AppTheme.FontSize.xs, design: .monospaced))
                    .padding(.horizontal, AppTheme.Spacing.xs)
                    .padding(.vertical, 6)
                    .background(AppTheme.Background.surfaceColor)
                    .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.xs))
                    .overlay(
                        RoundedRectangle(cornerRadius: AppTheme.Radius.xs)
                            .stroke(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.hairline)
                    )
                    .onChange(of: manualSSHCommand) { _, newValue in
                        parseAndSetSSHCommand(newValue)
                    }

                HStack(spacing: AppTheme.Spacing.md) {
                    HStack(spacing: AppTheme.Spacing.xs) {
                        Text("Host:")
                            .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                            .foregroundStyle(AppTheme.Text.secondaryColor)
                        TextField("ssh4.vast.ai or IP", text: $manualHost)
                            .textFieldStyle(.plain)
                            .font(.system(size: AppTheme.FontSize.xs, design: .monospaced))
                            .frame(width: 140)
                            .padding(.horizontal, AppTheme.Spacing.xs)
                            .padding(.vertical, 4)
                            .background(AppTheme.Background.surfaceColor)
                            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.xs))
                    }

                    HStack(spacing: AppTheme.Spacing.xs) {
                        Text("Port:")
                            .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                            .foregroundStyle(AppTheme.Text.secondaryColor)
                        TextField("13796", text: $manualPort)
                            .textFieldStyle(.plain)
                            .font(.system(size: AppTheme.FontSize.xs, design: .monospaced))
                            .frame(width: 70)
                            .padding(.horizontal, AppTheme.Spacing.xs)
                            .padding(.vertical, 4)
                            .background(AppTheme.Background.surfaceColor)
                            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.xs))
                    }

                    Spacer()

                    let targetHost = manualHost.trimmingCharacters(in: .whitespaces)
                    let targetPort = Int(manualPort.trimmingCharacters(in: .whitespaces)) ?? 0

                    if case .connected(let h, let p, _) = tunnelManager.state, h == targetHost && p == targetPort {
                        Button("Disconnect") {
                            tunnelManager.disconnect()
                        }
                        .buttonStyle(.capsule(.secondary, size: .small))
                    } else {
                        Button("Connect Custom SSH") {
                            guard !targetHost.isEmpty, targetPort > 0 else { return }
                            tunnelManager.connect(sshHost: targetHost, sshPort: targetPort, remotePort: 8188, localPort: 8188)
                        }
                        .buttonStyle(.capsule(.prominent, size: .small))
                        .disabled(targetHost.isEmpty || targetPort == 0)
                    }
                }
            }
        }
    }

    private func parseAndSetSSHCommand(_ input: String) {
        let str = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !str.isEmpty else { return }

        if str.contains("-p") {
            let tokens = str.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            for (idx, token) in tokens.enumerated() {
                if token == "-p", idx + 1 < tokens.count {
                    manualPort = tokens[idx + 1]
                }
                if token.contains("@") {
                    manualHost = token.components(separatedBy: "@").last ?? token
                }
            }
        } else if str.contains(":") {
            let parts = str.components(separatedBy: ":")
            if parts.count == 2 {
                let h = parts[0].contains("@") ? parts[0].components(separatedBy: "@").last! : parts[0]
                manualHost = h
                manualPort = parts[1]
            }
        }
    }

    private func mask(_ key: String) -> String {
        guard key.count > 8 else { return "••••••••" }
        return "\(key.prefix(4))••••••••\(key.suffix(4))"
    }
}
