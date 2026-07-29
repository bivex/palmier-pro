import Foundation

/// Swift runner bridge for local Whisper Large V3 Turbo (MLX format)
enum MLXWhisperTranscriber {
    private struct MLXWord: Decodable {
        let word: String
        let start: Double?
        let end: Double?
    }

    private struct MLXSegment: Decodable {
        let text: String
        let start: Double
        let end: Double
        let words: [MLXWord]?
    }

    private struct MLXResult: Decodable {
        let text: String
        let language: String?
        let segments: [MLXSegment]?
    }

    static func isAvailable() -> Bool {
        findScriptURL() != nil
    }

    static func transcribe(
        fileURL: URL,
        language: String? = nil,
        modelPath: String = "mlx-community/whisper-large-v3-turbo"
    ) async throws -> TranscriptionResult {
        try await Task.detached(priority: .userInitiated) {
            let outputJSON = FileManager.default.temporaryDirectory
                .appendingPathComponent("mlx-whisper-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: outputJSON) }

            guard let scriptURL = findScriptURL() else {
                throw TranscriptionError.analysisFailed("MLX Whisper script not found at scripts/transcription/transcribe.py")
            }

            let pythonURL = findPythonExecutable()

            let process = Process()
            process.executableURL = pythonURL
            var args = [scriptURL.path, fileURL.path, "-m", modelPath, "-o", outputJSON.path]
            if let language, !language.isEmpty {
                args.append(contentsOf: ["-l", language])
            }
            process.arguments = args

            let errPipe = Pipe()
            process.standardError = errPipe

            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let errStr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown process error"
                throw TranscriptionError.analysisFailed("MLX Whisper process failed (\(process.terminationStatus)): \(errStr)")
            }

            guard FileManager.default.fileExists(atPath: outputJSON.path) else {
                throw TranscriptionError.analysisFailed("MLX Whisper output JSON file was not generated.")
            }

            let data = try Data(contentsOf: outputJSON)
            return try parseResult(data)
        }.value
    }

    private static func parseResult(_ data: Data) throws -> TranscriptionResult {
        let decoded = try JSONDecoder().decode(MLXResult.self, from: data)

        var words: [TranscriptionWord] = []
        var segments: [TranscriptionSegment] = []

        if let rawSegments = decoded.segments {
            for seg in rawSegments {
                let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    segments.append(TranscriptionSegment(text: text, start: seg.start, end: seg.end))
                }
                if let rawWords = seg.words {
                    for w in rawWords {
                        let wordText = w.word.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !wordText.isEmpty {
                            words.append(TranscriptionWord(text: wordText, start: w.start, end: w.end))
                        }
                    }
                }
            }
        }

        return TranscriptionResult(
            text: decoded.text.trimmingCharacters(in: .whitespacesAndNewlines),
            language: decoded.language,
            words: words,
            segments: segments
        )
    }

    private static func findScriptURL() -> URL? {
        let currentDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let candidates = [
            currentDir.appendingPathComponent("scripts/transcription/transcribe.py"),
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/scripts/transcription/transcribe.py"),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func findPythonExecutable() -> URL {
        let venvPython = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("venv/bin/python3")
        if FileManager.default.fileExists(atPath: venvPython.path) {
            return venvPython
        }
        return URL(fileURLWithPath: "/usr/bin/env")
    }
}
