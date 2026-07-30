import Foundation

extension ToolExecutor {
    func manageVast(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        let action = args.string("action") ?? "status"

        switch action {
        case "status":
            let instances = (try? await VastAIClient.listInstances()) ?? []
            let activeInstance = instances.first(where: { $0.isRunning })
            let tunnelState = SSHTunnelManager.shared.state
            let (isComfyOnline, comfyStats) = await ComfyUIClient.checkHealth()
            let prices = await VastAIClient.fetchLiveGpuPrices()

            var info: [String: Any] = [
                "activeInstancesCount": instances.count,
                "runningInstance": activeInstance?.displayName ?? "none",
                "sshHost": activeInstance?.ssh_host ?? "none",
                "sshPort": activeInstance?.ssh_port ?? 0,
                "tunnelState": String(describing: tunnelState),
                "comfyUIOnline": isComfyOnline,
                "liveMarketPrices": prices
            ]
            if let stats = comfyStats?.system {
                info["comfyuiVersion"] = stats.comfyui_version ?? "unknown"
                info["pytorchVersion"] = stats.pytorch_version ?? "unknown"
            }
            if let devices = comfyStats?.devices?.compactMap(\.name) {
                info["gpus"] = devices
            }

            if isComfyOnline {
                info["checkpoints"] = await ComfyUIClient.fetchAvailableCheckpoints()
            }

            guard let jsonStr = Self.jsonString(info) else {
                return .error("Failed to encode Vast status")
            }
            return .ok(jsonStr)

        case "download_model":
            let instances = try await VastAIClient.listInstances()
            guard let running = instances.first(where: { $0.isRunning }),
                  let host = running.ssh_host,
                  let port = running.ssh_port else {
                throw ToolError("No running Vast.ai instance found to download model into.")
            }
            let modelUrl = args.string("url") ?? "https://huggingface.co/runwayml/stable-diffusion-v1-5/resolve/main/v1-5-pruned-emaonly.safetensors"
            let modelName = args.string("modelName") ?? "v1-5-pruned-emaonly.safetensors"

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            var sshArgs = [
                "-p", "\(port)",
                "root@\(host)",
                "-o", "StrictHostKeyChecking=no",
                "-o", "UserKnownHostsFile=/dev/null"
            ]
            if let keyPath = SSHTunnelManager.findDefaultPrivateKeyPath() {
                sshArgs.append(contentsOf: ["-i", keyPath])
            }
            sshArgs.append("wget -q -O /opt/ComfyUI/models/checkpoints/\(modelName) '\(modelUrl)' &")
            proc.arguments = sshArgs
            try? proc.run()
            proc.waitUntilExit()

            return .ok("Initiated download of model '\(modelName)' into ComfyUI checkpoints folder on root@\(host):\(port). Check status in ~30 seconds.")

        case "list_instances":
            let instances = try await VastAIClient.listInstances()
            let list = instances.map { inst in
                [
                    "id": inst.id,
                    "status": inst.actual_status ?? "unknown",
                    "displayName": inst.displayName,
                    "sshHost": inst.ssh_host ?? "",
                    "sshPort": inst.ssh_port ?? 0
                ] as [String: Any]
            }
            guard let jsonStr = Self.jsonString(["instances": list]) else {
                return .error("Failed to encode instances")
            }
            return .ok(jsonStr)

        case "connect_tunnel":
            let instances = try await VastAIClient.listInstances()
            let targetInstance: VastAIClient.VastInstance?
            if let targetId = args.int("instanceId") {
                targetInstance = instances.first(where: { $0.id == targetId })
            } else {
                targetInstance = instances.first(where: { $0.isRunning }) ?? instances.first
            }
            guard let target = targetInstance,
                  let host = target.ssh_host,
                  let port = target.ssh_port else {
                throw ToolError("No Vast.ai instance found with valid SSH credentials.")
            }
            if case .connected(let currentHost, let currentPort, _) = SSHTunnelManager.shared.state,
               currentHost == host, currentPort == port {
                return .ok("SSH Local Tunnel is already CONNECTED and active to root@\(host):\(port) (http://127.0.0.1:8188 🟢).")
            }

            await MainActor.run {
                SSHTunnelManager.shared.connect(sshHost: host, sshPort: port)
            }
            return .ok("Initiated SSH Local Tunnel to root@\(host):\(port) (forwarding 127.0.0.1:8188). Check status in a few seconds.")

        case "generate_image":
            let prompt = try args.requireString("prompt")
            let width = args.int("width") ?? 1024
            let height = args.int("height") ?? 1024

            let (online, _) = await ComfyUIClient.checkHealth()
            if !online {
                let instances = (try? await VastAIClient.listInstances()) ?? []
                if let running = instances.first(where: { $0.isRunning }),
                   let host = running.ssh_host,
                   let port = running.ssh_port {
                    await MainActor.run {
                        SSHTunnelManager.shared.connect(sshHost: host, sshPort: port)
                    }
                    try await Task.sleep(nanoseconds: 3_000_000_000)
                }
            }

            let fileURL = try await ComfyUIClient.generateImage(prompt: prompt, width: width, height: height)

            guard editor.projectURL != nil else {
                throw ToolError("No project is open to import generated image")
            }

            let name = args.string("name") ?? "VastAI_\(UUID().uuidString.prefix(6)).png"
            let asset = try editor.undo.perform("Generate Image via Vast.ai (Agent)") {
                guard let asset = editor.addMediaAsset(from: fileURL, finalize: false) else {
                    throw ToolError("Failed to register generated image asset")
                }
                applyImportMetadata(editor: editor, asset: asset, name: name, folderId: String?.none)
                return asset
            }

            return .ok("Successfully generated image via ComfyUI on GPU! Media asset ID: '\(asset.id)' (\(asset.name)). Use add_clips to place it on the timeline.")

        default:
            throw ToolError("Unknown action '\(action)'. Valid actions: status, list_instances, connect_tunnel, download_model, generate_image")
        }
    }
}
