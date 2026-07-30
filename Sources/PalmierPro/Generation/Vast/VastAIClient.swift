import Foundation

/// Swift API client for Vast.ai cloud GPU management
enum VastAIClient {
    private static let baseURL = "https://console.vast.ai/api/v0"

    enum VastError: LocalizedError {
        case missingAPIKey
        case invalidResponse
        case apiError(status: Int, message: String)

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "Vast.ai API key is missing. Add it in Settings → Models."
            case .invalidResponse:
                return "Invalid response received from Vast.ai."
            case .apiError(let status, let message):
                return "Vast.ai API error (\(status)): \(message)"
            }
        }
    }

    struct VastInstance: Decodable, Identifiable {
        let id: Int
        let actual_status: String?
        let gpu_name: String?
        let num_gpus: Int?
        let dph_total: Double?
        let ssh_host: String?
        let ssh_port: Int?
        let cur_state: String?
        let direct_port_start: Int?
        let direct_port_end: Int?

        var isRunning: Bool {
            (actual_status == "running" || cur_state == "running")
        }

        var displayName: String {
            let gpu = gpu_name ?? "GPU"
            let count = num_gpus ?? 1
            let price = dph_total != nil ? String(format: "$%.2f/hr", dph_total!) : ""
            return "\(count)x \(gpu) (\(price))"
        }
    }

    struct InstancesResponse: Decodable {
        let instances: [VastInstance]
    }

    /// List active and stopped instances for current user
    static func listInstances() async throws -> [VastInstance] {
        guard let apiKey = VastAIKeychain.load() else {
            throw VastError.missingAPIKey
        }

        guard let url = URL(string: "\(baseURL)/instances/?api_key=\(apiKey)") else {
            throw VastError.invalidResponse
        }

        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw VastError.invalidResponse
        }

        guard (200...299).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw VastError.apiError(status: http.statusCode, message: msg)
        }

        let decoded = try JSONDecoder().decode(InstancesResponse.self, from: data)
        return decoded.instances
    }

    /// Change state of an instance ("running" or "stopped")
    static func setInstanceState(id: Int, state: String) async throws {
        guard let apiKey = VastAIKeychain.load() else {
            throw VastError.missingAPIKey
        }

        guard let url = URL(string: "\(baseURL)/instances/\(id)/?api_key=\(apiKey)") else {
            throw VastError.invalidResponse
        }

        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = ["state": state]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            let status = (response as? HTTPURLResponse)?.statusCode ?? 500
            throw VastError.apiError(status: status, message: msg)
        }
    }

    /// Destroy an instance
    static func destroyInstance(id: Int) async throws {
        guard let apiKey = VastAIKeychain.load() else {
            throw VastError.missingAPIKey
        }

        guard let url = URL(string: "\(baseURL)/instances/\(id)/?api_key=\(apiKey)") else {
            throw VastError.invalidResponse
        }

        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            let status = (response as? HTTPURLResponse)?.statusCode ?? 500
            throw VastError.apiError(status: status, message: msg)
        }
    }

    struct VastUserInfo: Decodable {
        let username: String?
        let credit: Double?
        let ssh_key: String?
    }

    /// Fetch current user account info (email, balance, ssh key status)
    static func fetchUserInfo() async throws -> VastUserInfo {
        guard let apiKey = VastAIKeychain.load() else {
            throw VastError.missingAPIKey
        }

        guard let url = URL(string: "\(baseURL)/users/current/?api_key=\(apiKey)") else {
            throw VastError.invalidResponse
        }

        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            let status = (response as? HTTPURLResponse)?.statusCode ?? 500
            throw VastError.apiError(status: status, message: msg)
        }

        return try JSONDecoder().decode(VastUserInfo.self, from: data)
    }
}
