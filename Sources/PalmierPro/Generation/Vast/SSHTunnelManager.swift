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
    private var lastSshError: String?

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
        if case .connected(let h, let p, let lp) = state,
           h == sshHost, p == sshPort, lp == localPort,
           let proc = process, proc.isRunning {
            print("[ssh-tunnel] NOTICE: SSH Tunnel already connected to root@\(sshHost):\(sshPort). Reusing active connection.")
            return
        }

        let currentPid = process?.processIdentifier
        SSHTunnelManager.killStaleSSHProcesses(localPort: localPort, excludePid: currentPid)
        disconnect()

        self.activeLocalPort = localPort
        self.state = .connecting(host: sshHost, port: sshPort, localPort: localPort)
        self.lastSshError = nil
        print("[ssh-tunnel] NOTICE: Connecting SSH Local Tunnel to root@\(sshHost):\(sshPort) (forwarding 127.0.0.1:\(localPort))...")

        launchSSHProcess(localPort: localPort, host: sshHost, port: sshPort)
        startHealthCheck(localPort: localPort, host: sshHost, port: sshPort)
    }

    private func launchSSHProcess(localPort: Int, host: String, port: Int) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        var args = [
            "-N",
            "-L", "\(localPort):127.0.0.1:18188",
            "-p", "\(port)",
            "root@\(host)",
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=15",
            "-o", "ConnectTimeout=5"
        ]
        let keyPaths = SSHTunnelManager.findAllPrivateKeyPaths()
        for keyPath in keyPaths {
            args.append(contentsOf: ["-i", keyPath])
        }
        proc.arguments = args

        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = FileHandle.nullDevice

        proc.terminationHandler = { [weak self] p in
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errStr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            Task { @MainActor in
                guard let self else { return }
                if !errStr.isEmpty {
                    self.lastSshError = errStr
                }
                if case .connected = self.state {
                    self.state = .failed(reason: "SSH process exited unexpectedly (code \(p.terminationStatus)): \(errStr)")
                }
            }
        }

        do {
            try proc.run()
            self.process = proc
        } catch {
            self.state = .failed(reason: "Failed to launch SSH: \(error.localizedDescription)")
        }
    }

    /// Kill any stale SSH processes holding the given local port (e.g. leftover from a previous run)
    private static func killStaleSSHProcesses(localPort: Int, excludePid: Int32? = nil) {
        let lsof = Process()
        lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsof.arguments = ["-t", "-i", ":\(localPort)"]
        let pipe = Pipe()
        lsof.standardOutput = pipe
        lsof.standardError = FileHandle.nullDevice
        try? lsof.run()
        lsof.waitUntilExit()
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        let pids = String(data: out, encoding: .utf8)?
            .components(separatedBy: .newlines)
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? []
        for pid in pids {
            if let excludePid, Int32(pid) == excludePid { continue }
            kill(pid_t(pid), SIGTERM)
            print("[ssh-tunnel] NOTICE: Killed stale SSH process (pid \(pid)) holding port \(localPort)")
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
                if attempt % 5 == 1 {
                    print("[ssh-tunnel] NOTICE: Waiting for container server startup (attempt \(attempt)/90, ~3 min total)...")
                }
                try? await Task.sleep(for: .seconds(3))
                guard let self else { return }

                if await checkPortResponsive(localPort: localPort) {
                    self.state = .connected(host: host, port: port, localPort: localPort)
                    print("[ssh-tunnel] NOTICE: SSH Local Tunnel CONNECTED successfully! http://127.0.0.1:\(localPort) is READY 🟢")
                    return
                }

                if let proc = self.process, !proc.isRunning {
                    let errMsg = self.lastSshError ?? "unknown error"
                    let isAuthError = errMsg.contains("Permission denied") || errMsg.contains("Host key verification failed") || errMsg.contains("Authentication failed")

                    if isAuthError {
                        print("[ssh-tunnel] ERROR: SSH authentication failed for root@\(host):\(port): \(errMsg)")
                        self.state = .failed(reason: "SSH authentication failed for root@\(host):\(port). Double check your SSH public key on Vast.ai account: \(errMsg)")
                        return
                    }

                    print("[ssh-tunnel] NOTICE: SSH process exited (attempt \(attempt)/90: \(errMsg)). Retrying connection...")
                    self.state = .connecting(host: host, port: port, localPort: localPort)
                    self.launchSSHProcess(localPort: localPort, host: host, port: port)
                }
            }

            guard let self else { return }
            if case .connecting = self.state {
                self.state = .failed(reason: "SSH connection timed out after 4.5 minutes. Container entrypoint script takes ~3 minutes on first boot.")
                print("[ssh-tunnel] ERROR: Connection timed out after 90 attempts.")
            }
        }
    }

    private func checkPortResponsive(localPort: Int) async -> Bool {
        let candidateUrls = [
            "http://127.0.0.1:\(localPort)/system_stats",
            "http://127.0.0.1:18188/system_stats",
            "http://127.0.0.1:8080/system_stats",
            "http://127.0.0.1:\(localPort)/",
            "http://127.0.0.1:18188/",
            "http://127.0.0.1:8080/"
        ]
        for urlStr in candidateUrls {
            guard let url = URL(string: urlStr) else { continue }
            var req = URLRequest(url: url)
            req.timeoutInterval = 1.5
            if let (_, resp) = try? await URLSession.shared.data(for: req),
               let http = resp as? HTTPURLResponse, (200...499).contains(http.statusCode) {
                return true
            }
        }
        return false
    }

    nonisolated static func findAllPrivateKeyPaths() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.ssh/id_ed25519",
            "\(home)/.ssh/id_rsa",
            "\(home)/.ssh/id_ecdsa",
            "\(home)/.ssh/id_dsa",
            "\(home)/.ssh/id_vast_ai"
        ]
        return candidates.filter { FileManager.default.fileExists(atPath: $0) }
    }

    nonisolated static func findDefaultPrivateKeyPath() -> String? {
        findAllPrivateKeyPaths().first
    }

    nonisolated static func loadDefaultPublicKey() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.ssh/id_ed25519.pub",
            "\(home)/.ssh/id_rsa.pub",
            "\(home)/.ssh/id_ecdsa.pub",
            "\(home)/.ssh/id_vast_ai.pub"
        ]
        for path in candidates {
            if let content = try? String(contentsOfFile: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty {
                return content
            }
        }
        return nil
    }
}
