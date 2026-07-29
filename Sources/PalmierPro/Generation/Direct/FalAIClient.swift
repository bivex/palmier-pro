import Foundation
import Combine

/// Direct REST API runner for Fal.ai models (Kling, Seedance, Flux, Veo, etc.)
enum FalAIClient {
    private static let queueBaseURL = "https://queue.fal.run"

    enum FalError: LocalizedError {
        case missingAPIKey
        case invalidResponse
        case apiError(status: Int, message: String)
        case jobFailed(message: String)

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "Fal.ai API key is missing. Add it in Settings → Models."
            case .invalidResponse:
                return "Invalid response received from Fal.ai."
            case .apiError(let status, let message):
                return "Fal.ai API error (\(status)): \(message)"
            case .jobFailed(let message):
                return "Fal.ai generation failed: \(message)"
            }
        }
    }

    /// Map catalog model IDs to Fal.ai API endpoints
    static func falEndpoint(for modelId: String) -> String {
        let id = modelId.lowercased()
        if id.contains("kling") {
            return "fal-ai/kling-video/v1.6/pro/text-to-video"
        } else if id.contains("seedance") {
            return "fal-ai/bytedance/seedance"
        } else if id.contains("luma") {
            return "fal-ai/luma-dream-machine"
        } else if id.contains("nano-banana") || id.contains("flux") {
            return "fal-ai/flux/dev"
        }
        return "fal-ai/fast-sdxl"
    }

    struct SubmitResponse: Decodable {
        let requestId: String
        let statusUrl: String?
        let responseUrl: String?

        enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case statusUrl = "status_url"
            case responseUrl = "response_url"
        }
    }

    struct StatusResponse: Decodable {
        let status: String
        let error: String?
    }

    /// Submit a generation request to Fal.ai queue
    static func submit(
        modelId: String,
        params: BackendGenerationParams
    ) async throws -> String {
        guard let apiKey = FalAIKeychain.load() else {
            throw FalError.missingAPIKey
        }

        let endpoint = falEndpoint(for: modelId)
        guard let url = URL(string: "\(queueBaseURL)/\(endpoint)") else {
            throw FalError.invalidResponse
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Key \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var payload: [String: Any] = [:]
        switch params {
        case .video(let p):
            payload["prompt"] = p.prompt
            payload["aspect_ratio"] = p.aspectRatio
            payload["duration"] = "\(p.duration)s"
            if let start = p.startFrameURL { payload["image_url"] = start }
        case .image(let p):
            payload["prompt"] = p.prompt
            payload["aspect_ratio"] = p.aspectRatio
        case .audio(let p):
            payload["prompt"] = p.prompt
        case .upscale(let p):
            payload["image_url"] = p.sourceURL
        }

        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw FalError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw FalError.apiError(status: http.statusCode, message: body)
        }

        let decoded = try JSONDecoder().decode(SubmitResponse.self, from: data)
        return "\(endpoint)||\(decoded.requestId)"
    }

    /// Poll Fal.ai job status and retrieve final media URLs
    static func pollStatus(
        handle: String
    ) async throws -> (status: BackendGenerationStatus, urls: [String]?, error: String?) {
        guard let apiKey = FalAIKeychain.load() else {
            return (.failed, nil, "Missing Fal.ai API key")
        }

        let parts = handle.components(separatedBy: "||")
        guard parts.count == 2 else {
            return (.failed, nil, "Invalid job handle")
        }
        let endpoint = parts[0]
        let requestId = parts[1]

        let statusURLString = "\(queueBaseURL)/\(endpoint)/requests/\(requestId)/status"
        guard let url = URL(string: statusURLString) else {
            return (.failed, nil, "Invalid status URL")
        }

        var req = URLRequest(url: url)
        req.setValue("Key \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            return (.failed, nil, "Fal.ai status check failed")
        }

        let statusResp = try JSONDecoder().decode(StatusResponse.self, from: data)
        switch statusResp.status.uppercased() {
        case "IN_QUEUE":
            return (.queued, nil, nil)
        case "IN_PROGRESS":
            return (.running, nil, nil)
        case "COMPLETED":
            // Fetch final output
            let resultURLString = "\(queueBaseURL)/\(endpoint)/requests/\(requestId)"
            guard let resultURL = URL(string: resultURLString) else {
                return (.failed, nil, "Invalid result URL")
            }
            var resReq = URLRequest(url: resultURL)
            resReq.setValue("Key \(apiKey)", forHTTPHeaderField: "Authorization")
            let (resData, resHttp) = try await URLSession.shared.data(for: resReq)
            guard let resResp = resHttp as? HTTPURLResponse, (200...299).contains(resResp.statusCode) else {
                return (.failed, nil, "Fal.ai result fetch failed")
            }

            let json = try JSONSerialization.jsonObject(with: resData) as? [String: Any]
            var urls: [String] = []
            if let videoDict = json?["video"] as? [String: Any], let urlStr = videoDict["url"] as? String {
                urls.append(urlStr)
            } else if let images = json?["images"] as? [[String: Any]] {
                for img in images {
                    if let urlStr = img["url"] as? String { urls.append(urlStr) }
                }
            } else if let audioDict = json?["audio"] as? [String: Any], let urlStr = audioDict["url"] as? String {
                urls.append(urlStr)
            }

            return (.succeeded, urls, nil)
        case "FAILED":
            return (.failed, nil, statusResp.error ?? "Fal.ai job failed")
        default:
            return (.running, nil, nil)
        }
    }
}
