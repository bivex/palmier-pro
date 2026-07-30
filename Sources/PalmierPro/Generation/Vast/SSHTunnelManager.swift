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

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        proc.arguments = [
            "-N",
            "-L", "\(localPort):127.0.0.1:\(remotePort)",
            "-p", "\(sshPort)",
            "root@\(sshHost)",
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=15"
        ]

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
            for attempt in 1...30 {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }

                if await checkPortResponsive(localPort: localPort) {
                    self.state = .connected(host: host, port: port, localPort: localPort)
                    print("[ssh-tunnel] NOTICE: SSH Local Tunnel connected successfully on port \(localPort) to \(host):\(port)")
                    return
                }

                if let proc = self.process, !proc.isRunning {
                    print("[ssh-tunnel] NOTICE: Container SSH starting up (attempt \(attempt)/30). Retrying connection...")
                    self.state = .connecting(host: host, port: port, localPort: localPort)
                    self.restartSSHProcess(localPort: localPort, host: host, port: port)
                }
            }

            guard let self else { return }
            if case .connecting = self.state {
                self.state = .failed(reason: "SSH connection timed out. Container may still be downloading Docker image.")
            }
        }
    }

    private func restartSSHProcess(localPort: Int, host: String, port: Int) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        proc.arguments = [
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
        guard let url = URL(string: "http://127.0.0.1:\(localPort)/system_stats") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 2.0
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            return (resp as? HTTPURLResponse) != nil
        } catch {
            return false
        }
    }
}
