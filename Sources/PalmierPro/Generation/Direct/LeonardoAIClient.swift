import Foundation

/// Direct REST API runner for Leonardo.Ai (Image Generation)
enum LeonardoAIClient {
    private static let baseURL = "https://cloud.leonardo.ai/api/rest/v1"

    enum LeonardoError: LocalizedError {
        case missingAPIKey
        case invalidResponse
        case apiError(status: Int, message: String)
        case jobFailed(message: String)

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "Leonardo.Ai API key is missing. Add it in Settings → Models."
            case .invalidResponse:
                return "Invalid response received from Leonardo.Ai."
            case .apiError(let status, let message):
                return "Leonardo.Ai API error (\(status)): \(message)"
            case .jobFailed(let message):
                return "Leonardo.Ai generation failed: \(message)"
            }
        }
    }

    struct GenerationJobResponse: Decodable {
        struct SDGenerationOutput: Decodable {
            let generationId: String
        }
        let sdGenerationJob: SDGenerationOutput
    }

    struct SingleGenerationResponse: Decodable {
        struct GeneratedImage: Decodable {
            let id: String
            let url: String
        }
        struct GenerationDetail: Decodable {
            let status: String
            let generated_images: [GeneratedImage]?
        }
        let generations_by_pk: GenerationDetail?
    }

    /// Submit image generation request to Leonardo.Ai REST API
    static func submit(
        params: ImageGenerationParams
    ) async throws -> String {
        guard let apiKey = LeonardoKeychain.load() else {
            throw LeonardoError.missingAPIKey
        }

        guard let url = URL(string: "\(baseURL)/generations") else {
            throw LeonardoError.invalidResponse
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue("application/json", forHTTPHeaderField: "accept")

        // Parse resolution/aspect ratio
        var width = 1024
        var height = 1024
        if params.aspectRatio == "16:9" {
            width = 1344
            height = 768
        } else if params.aspectRatio == "9:16" {
            width = 768
            height = 1344
        }

        let body: [String: Any] = [
            "prompt": params.prompt,
            "width": width,
            "height": height,
            "num_images": 1,
            "modelId": "6bef4f05-38c6-4b89-9b69-2c3c143b863b" // Leonardo Diffusion XL default
        ]

        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw LeonardoError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? ""
            throw LeonardoError.apiError(status: http.statusCode, message: message)
        }

        let decoded = try JSONDecoder().decode(GenerationJobResponse.self, from: data)
        return decoded.sdGenerationJob.generationId
    }

    /// Poll status for Leonardo.Ai generation
    static func pollStatus(
        generationId: String
    ) async throws -> (status: BackendGenerationStatus, urls: [String]?, error: String?) {
        guard let apiKey = LeonardoKeychain.load() else {
            return (.failed, nil, "Missing Leonardo.Ai API key")
        }

        guard let url = URL(string: "\(baseURL)/generations/\(generationId)") else {
            return (.failed, nil, "Invalid generation URL")
        }

        var req = URLRequest(url: url)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization")
        req.setValue("application/json", forHTTPHeaderField: "accept")

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            return (.failed, nil, "Leonardo.Ai status check failed")
        }

        let decoded = try JSONDecoder().decode(SingleGenerationResponse.self, from: data)
        guard let detail = decoded.generations_by_pk else {
            return (.queued, nil, nil)
        }

        switch detail.status.uppercased() {
        case "PENDING":
            return (.queued, nil, nil)
        case "COMPLETE":
            let urls = detail.generated_images?.map(\.url) ?? []
            return (.succeeded, urls, nil)
        case "FAILED":
            return (.failed, nil, "Leonardo.Ai generation failed")
        default:
            return (.running, nil, nil)
        }
    }
}
