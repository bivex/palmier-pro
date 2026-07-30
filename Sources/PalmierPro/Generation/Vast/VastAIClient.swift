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
        let status_msg: String?
        let direct_port_start: Int?
        let direct_port_end: Int?

        var isRunning: Bool {
            actual_status == "running"
        }

        var isLoading: Bool {
            actual_status == "loading" || (actual_status != "running" && actual_status != "stopped")
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

    /// Upload local SSH public key to Vast.ai account
    static func uploadSSHKey(_ sshKey: String) async throws {
        guard let apiKey = VastAIKeychain.load() else {
            throw VastError.missingAPIKey
        }

        guard let url = URL(string: "\(baseURL)/ssh/?api_key=\(apiKey)") else {
            throw VastError.invalidResponse
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = ["ssh_key": sshKey]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            let status = (response as? HTTPURLResponse)?.statusCode ?? 500
            throw VastError.apiError(status: status, message: msg)
        }
    }

    struct VastOffer: Decodable {
        let id: Int
        let gpu_name: String?
        let dph_total: Double?

        var formattedPrice: String {
            guard let dph_total else { return "$0.00/hr" }
            return String(format: "$%.2f/hr", dph_total)
        }
    }

    struct SearchOffersResponse: Decodable {
        let offers: [VastOffer]
    }

    /// Search cheapest available offer for requested GPU type
    static func searchBestOffer(gpuType: String, region: String = "ANY", strategy: String = "dlperf") async throws -> VastOffer {
        guard let apiKey = VastAIKeychain.load() else {
            print("[vast-ai] ERROR: Vast.ai API key is missing")
            throw VastError.missingAPIKey
        }

        guard let url = URL(string: "\(baseURL)/bundles/?api_key=\(apiKey)") else {
            throw VastError.invalidResponse
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "verified": ["eq": true],
            "external": ["eq": false],
            "rentable": ["eq": true],
            "rented": ["eq": false],
            "type": "on-demand",
            "allocated_storage": 40
        ]

        if strategy == "price" {
            body["order"] = [["dph_total", "asc"]]
        } else if strategy == "reliability" {
            body["order"] = [["reliability2", "desc"], ["dph_total", "asc"]]
            body["reliability2"] = ["gte": 0.99]
        } else {
            body["order"] = [["dlperf_per_dphtotal", "desc"]]
        }

        if gpuType != "ANY" {
            body["gpu_name"] = ["eq": gpuType]
        }

        if region == "US" {
            body["geolocation"] = ["in": ["US", "United States", "CA", "Canada"]]
        } else if region == "EU" {
            body["geolocation"] = ["in": ["DE", "Germany", "FR", "France", "UK", "United Kingdom", "NL", "Netherlands", "SE", "Sweden", "FI", "Finland", "NO", "Norway", "PL", "Poland", "RO", "Romania", "EU", "Europe"]]
        } else if region == "ASIA" {
            body["geolocation"] = ["in": ["JP", "Japan", "KR", "Korea", "South Korea", "SG", "Singapore", "HK", "Hong Kong", "IN", "India", "AU", "Australia"]]
        }

        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            let status = (response as? HTTPURLResponse)?.statusCode ?? 500
            print("[vast-ai] ERROR: Search offers failed (\(status)): \(msg)")
            throw VastError.apiError(status: status, message: msg)
        }

        let decoded = try JSONDecoder().decode(SearchOffersResponse.self, from: data)
        guard let best = decoded.offers.first else {
            print("[vast-ai] WARN: No GPU offers found matching search filter: '\(gpuType)'")
            throw VastError.apiError(status: 404, message: "No available GPU offers found for \(gpuType)")
        }

        print("[vast-ai] NOTICE: Found \(decoded.offers.count) offers for '\(gpuType)'. Selected best offer #\(best.id) (\(best.gpu_name ?? "GPU") @ \(best.formattedPrice))")
        return best
    }

    /// Rent and launch instance for specified offer ID
    static func createInstance(offerId: Int, image: String = "aidockorg/comfyui-cuda:latest", diskGb: Int = 40) async throws {
        guard let apiKey = VastAIKeychain.load() else {
            print("[vast-ai] ERROR: Cannot create instance — missing API key")
            throw VastError.missingAPIKey
        }

        guard let url = URL(string: "\(baseURL)/asks/\(offerId)/?api_key=\(apiKey)") else {
            throw VastError.invalidResponse
        }

        print("[vast-ai] NOTICE: Submitting GPU rental request for offer #\(offerId) (image: \(image), disk: \(diskGb)GB)...")

        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let comfyStartScript = "bash /opt/ai-dock/bin/init.sh >> /var/log/ai-dock-init.log 2>&1 &"
        var body: [String: Any] = [
            "client_id": "me",
            "image": image,
            "disk": diskGb,
            "runtype": "ssh_direc ssh_proxy",
            "onstart_cmd": comfyStartScript
        ]
        if let pubKey = SSHTunnelManager.loadDefaultPublicKey() {
            try? await uploadSSHKey(pubKey)
            body["ssh_key"] = pubKey
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            let status = (response as? HTTPURLResponse)?.statusCode ?? 500
            print("[vast-ai] ERROR: Failed to rent offer #\(offerId) (\(status)): \(msg)")
            throw VastError.apiError(status: status, message: msg)
        }

        print("[vast-ai] NOTICE: Offer #\(offerId) rented successfully! Container starting up.")
    }

    /// Fetch live minimum market prices for all GPU types in a single batched API query (prevents 429 rate limits)
    static func fetchLiveGpuPrices() async -> [String: String] {
        guard let apiKey = VastAIKeychain.load(),
              let url = URL(string: "\(baseURL)/bundles/?api_key=\(apiKey)") else {
            return [:]
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "verified": ["eq": true],
            "external": ["eq": false],
            "rentable": ["eq": true],
            "rented": ["eq": false],
            "order": [["dph_total", "asc"]],
            "type": "on-demand",
            "allocated_storage": 40
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        guard let (data, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let decoded = try? JSONDecoder().decode(SearchOffersResponse.self, from: data) else {
            return [:]
        }

        var prices: [String: String] = [:]
        if let cheapestAny = decoded.offers.first {
            prices["ANY"] = cheapestAny.formattedPrice
        }

        for offer in decoded.offers {
            guard let name = offer.gpu_name else { continue }
            if name.contains("4090") && prices["RTX 4090"] == nil {
                prices["RTX 4090"] = offer.formattedPrice
            } else if name.contains("3090") && prices["RTX 3090"] == nil {
                prices["RTX 3090"] = offer.formattedPrice
            } else if (name.contains("A100") || name.contains("a100")) && prices["A100"] == nil {
                prices["A100"] = offer.formattedPrice
            }
        }

        print("[vast-ai] NOTICE: Live market prices loaded via single batch query: \(prices)")
        return prices
    }
}
