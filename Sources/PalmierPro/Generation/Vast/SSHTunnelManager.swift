import Foundation
import Combine
import AppKit

@MainActor
final class SSHTunnelManager: ObservableObject {
    static let shared = SSHTunnelManager()

    enum TunnelState: Equatable {
        case disconnected
        case connecting(host: String, port: Int, localPort: Int)
        case connected(host: String, port: Int, localPort: Int)
        case failed(reason: String)
    }

    @Published private(set) var state: TunnelState = .disconnected
    @Published private(set) var activeLocalPort: Int = 8188

    private var process: Process?
    private var healthCheckTask: Task<Void, Never>?

    private init() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.disconnect()
            }
        }
    }

    /// Connect SSH Local Tunnel to remote Vast.ai instance
    func connect(
        sshHost: String,
        sshPort: Int,
        remotePort: Int = 8188,
        localPort: Int = 8188
    ) {
        disconnect()

        self.activeLocalPort = localPort
        self.state = .connecting(host: sshHost, port: sshPort, localPort: localPort)
        print("[ssh-tunnel] NOTICE: Connecting SSH Local Tunnel to root@\(sshHost):\(sshPort) (forwarding 127.0.0.1:\(localPort))...")

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        var args = [
            "-N",
            "-L", "\(localPort):127.0.0.1:8188",
            "-L", "8080:127.0.0.1:8080",
            "-p", "\(sshPort)",
            "root@\(sshHost)",
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null",
            "-o", "ServerAliveInterval=15"
        ]
        if let keyPath = SSHTunnelManager.findDefaultPrivateKeyPath() {
            args.append(contentsOf: ["-i", keyPath, "-o", "IdentitiesOnly=yes"])
        }
        proc.arguments = args
        proc.standardError = FileHandle.nullDevice
        proc.standardOutput = FileHandle.nullDevice

        proc.terminationHandler = { [weak self] p in
            Task { @MainActor in
                guard let self else { return }
                if case .connected = self.state {
                    self.state = .failed(reason: "SSH process exited unexpectedly (code \(p.terminationStatus))")
                }
            }
        }

        do {
            try proc.run()
            self.process = proc
            startHealthCheck(localPort: localPort, host: sshHost, port: sshPort)
        } catch {
            self.state = .failed(reason: "Failed to launch SSH: \(error.localizedDescription)")
        }
    }

    /// Disconnect current SSH Local Tunnel
    func disconnect() {
        healthCheckTask?.cancel()
        healthCheckTask = nil

        if let proc = process, proc.isRunning {
            proc.terminate()
        }
        process = nil
        state = .disconnected
    }

    private func startHealthCheck(localPort: Int, host: String, port: Int) {
        healthCheckTask?.cancel()
        healthCheckTask = Task { @MainActor [weak self] in
            for attempt in 1...90 {
                try? await Task.sleep(for: .seconds(3))
                guard let self else { return }

                if await checkPortResponsive(localPort: localPort) {
                    self.state = .connected(host: host, port: port, localPort: localPort)
                    print("[ssh-tunnel] NOTICE: SSH Local Tunnel connected successfully! Port \(localPort) -> root@\(host):\(port) is READY")
                    return
                }

                if let proc = self.process, !proc.isRunning {
                    print("[ssh-tunnel] NOTICE: Container SSH starting up (attempt \(attempt)/90). Retrying connection...")
                    self.state = .connecting(host: host, port: port, localPort: localPort)
                    self.restartSSHProcess(localPort: localPort, host: host, port: port)
                }
            }

            guard let self else { return }
            if case .connecting = self.state {
                self.state = .failed(reason: "SSH connection timed out. Container entrypoint script takes ~3 minutes on first boot.")
            }
        }
    }

    private func restartSSHProcess(localPort: Int, host: String, port: Int) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        var args = [
            "-N",
            "-L", "\(localPort):127.0.0.1:8188",
            "-p", "\(port)",
            "root@\(host)",
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=15",
            "-o", "ConnectTimeout=5"
        ]
        if let keyPath = SSHTunnelManager.findDefaultPrivateKeyPath() {
            args.append(contentsOf: ["-i", keyPath, "-o", "IdentitiesOnly=yes"])
        }
        proc.arguments = args
        proc.standardError = FileHandle.nullDevice
        proc.standardOutput = FileHandle.nullDevice

        proc.terminationHandler = { [weak self] p in
            Task { @MainActor in
                guard let self else { return }
                if case .connected = self.state {
                    self.state = .failed(reason: "SSH process exited unexpectedly (code \(p.terminationStatus))")
                }
            }
        }

        try? proc.run()
        self.process = proc
    }

    private func checkPortResponsive(localPort: Int) async -> Bool {
        let candidateUrls = [
            "http://127.0.0.1:\(localPort)/system_stats",
            "http://127.0.0.1:8080/system_stats",
            "http://127.0.0.1:\(localPort)/",
            "http://127.0.0.1:8080/"
        ]
        for urlStr in candidateUrls {
            guard let url = URL(string: urlStr) else { continue }
            var req = URLRequest(url: url)
            req.timeoutInterval = 1.5
            if let (_, resp) = try? await URLSession.shared.data(for: req),
               let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                return true
            }
        }
        return false
    }

    private static func findDefaultPrivateKeyPath() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.ssh/id_ed25519",
            "\(home)/.ssh/id_rsa",
            "\(home)/.ssh/id_vast_ai"
        ]
        for path in candidates {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        return nil
    }
}
