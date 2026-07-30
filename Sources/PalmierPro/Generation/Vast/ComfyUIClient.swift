import Foundation
import AppKit

/// Async client for interacting with the local/forwarded ComfyUI server over SSH tunnel
enum ComfyUIClient {
    private static let baseURL = "http://127.0.0.1:8188"

    struct SystemStats: Decodable, Sendable {
        struct Device: Decodable, Sendable {
            let name: String?
            let type: String?
            let vram_total: Int64?
            let vram_free: Int64?
        }
        struct SystemInfo: Decodable, Sendable {
            let comfyui_version: String?
            let pytorch_version: String?
            let python_version: String?
        }
        let system: SystemInfo?
        let devices: [Device]?
    }

    /// Check if ComfyUI server on 127.0.0.1:8188 is accessible and return stats
    static func checkHealth() async -> (isOnline: Bool, stats: SystemStats?) {
        guard let url = URL(string: "\(baseURL)/system_stats") else {
            return (false, nil)
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 3
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return (false, nil)
            }
            let stats = try? JSONDecoder().decode(SystemStats.self, from: data)
            return (true, stats)
        } catch {
            return (false, nil)
        }
    }

    /// Submit a text-to-image prompt workflow to ComfyUI and return generated image file URL
    static func generateImage(
        prompt: String,
        negativePrompt: String = "ugly, blurry, low quality, distorted",
        width: Int = 1024,
        height: Int = 1024,
        seed: Int64 = Int64.random(in: 100000...99999999)
    ) async throws -> URL {
        guard let promptURL = URL(string: "\(baseURL)/prompt") else {
            throw NSError(domain: "ComfyUIClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid ComfyUI URL"])
        }

        // Standard ComfyUI API workflow definition
        let workflow: [String: Any] = [
            "3": [
                "class_type": "KSampler",
                "inputs": [
                    "cfg": 7.0,
                    "denoise": 1.0,
                    "latent_image": ["5", 0],
                    "model": ["4", 0],
                    "negative": ["7", 0],
                    "positive": ["6", 0],
                    "sampler_name": "euler_ancestral",
                    "scheduler": "normal",
                    "seed": seed,
                    "steps": 20
                ]
            ],
            "4": [
                "class_type": "CheckpointLoaderSimple",
                "inputs": [
                    "ckpt_name": "v1-5-pruned-emaonly.safetensors"
                ]
            ],
            "5": [
                "class_type": "EmptyLatentImage",
                "inputs": [
                    "batch_size": 1,
                    "height": height,
                    "width": width
                ]
            ],
            "6": [
                "class_type": "CLIPTextEncode",
                "inputs": [
                    "clip": ["4", 1],
                    "text": prompt
                ]
            ],
            "7": [
                "class_type": "CLIPTextEncode",
                "inputs": [
                    "clip": ["4", 1],
                    "text": negativePrompt
                ]
            ],
            "8": [
                "class_type": "VAEDecode",
                "inputs": [
                    "samples": ["3", 0],
                    "vae": ["4", 2]
                ]
            ],
            "9": [
                "class_type": "SaveImage",
                "inputs": [
                    "filename_prefix": "PalmierPro_VastAI",
                    "images": ["8", 0]
                ]
            ]
        ]

        let payload: [String: Any] = ["prompt": workflow]
        var req = URLRequest(url: promptURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "HTTP failure"
            throw NSError(domain: "ComfyUIClient", code: -2, userInfo: [NSLocalizedDescriptionKey: "ComfyUI prompt submission failed: \(msg)"])
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let promptId = json["prompt_id"] as? String else {
            throw NSError(domain: "ComfyUIClient", code: -3, userInfo: [NSLocalizedDescriptionKey: "Invalid prompt_id from ComfyUI"])
        }

        // Poll history for completion (max 60 seconds)
        let startTime = Date()
        while Date().timeIntervalSince(startTime) < 60 {
            try await Task.sleep(nanoseconds: 1_500_000_000)
            guard let historyURL = URL(string: "\(baseURL)/history/\(promptId)") else { continue }
            let (hData, hResp) = try await URLSession.shared.data(from: historyURL)
            guard let hHttp = hResp as? HTTPURLResponse, (200...299).contains(hHttp.statusCode) else { continue }
            guard let hJson = try? JSONSerialization.jsonObject(with: hData) as? [String: Any],
                  let promptHistory = hJson[promptId] as? [String: Any],
                  let outputs = promptHistory["outputs"] as? [String: Any],
                  let nodeOutput = outputs["9"] as? [String: Any],
                  let images = nodeOutput["images"] as? [[String: Any]],
                  let firstImage = images.first,
                  let filename = firstImage["filename"] as? String else {
                continue
            }

            let subfolder = (firstImage["subfolder"] as? String) ?? ""
            let type = (firstImage["type"] as? String) ?? "output"

            var queryItems = [
                URLQueryItem(name: "filename", value: filename),
                URLQueryItem(name: "subfolder", value: subfolder),
                URLQueryItem(name: "type", value: type)
            ]
            var viewComponents = URLComponents(string: "\(baseURL)/view")!
            viewComponents.queryItems = queryItems

            guard let viewURL = viewComponents.url else { continue }
            let (imageData, iResp) = try await URLSession.shared.data(from: viewURL)
            guard let iHttp = iResp as? HTTPURLResponse, (200...299).contains(iHttp.statusCode) else { continue }

            // Write image to temp file
            let tempDir = FileManager.default.temporaryDirectory
            let targetURL = tempDir.appendingPathComponent("comfy_\(UUID().uuidString).png")
            try imageData.write(to: targetURL)
            return targetURL
        }

        throw NSError(domain: "ComfyUIClient", code: -4, userInfo: [NSLocalizedDescriptionKey: "ComfyUI generation timed out after 60s"])
    }
}
