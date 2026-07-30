import Foundation
import Combine
@preconcurrency import ConvexMobile

@MainActor
final class DirectGenerationBackend {
    static let shared = DirectGenerationBackend()

    private var activeJobs: [String: BackendGenerationJob] = [:]
    private var jobPublishers: [String: CurrentValueSubject<BackendGenerationJob?, ClientError>] = [:]
    private var pollingTasks: [String: Task<Void, Never>] = [:]

    private init() {}

    static func canHandle(model: String) -> Bool {
        return DirectKeyStore.hasKey(for: model)
    }

    static func submit(
        model: String,
        params: BackendGenerationParams
    ) async throws -> String {
        if model.lowercased().contains("leonardo") || (DirectKeyStore.hasLeonardoKey && !DirectKeyStore.hasFalKey) {
            if case .image(let imgParams) = params {
                let genId = try await LeonardoAIClient.submit(params: imgParams)
                let jobId = "direct-leonardo-\(UUID().uuidString)"
                shared.startLeonardoPolling(jobId: jobId, generationId: genId)
                return jobId
            }
        }
        if DirectKeyStore.hasFalKey {
            let handle = try await FalAIClient.submit(modelId: model, params: params)
            let jobId = "direct-fal-\(UUID().uuidString)"
            shared.startPolling(jobId: jobId, handle: handle)
            return jobId
        }
        throw FalAIClient.FalError.missingAPIKey
    }

    static func subscribe(
        jobId: String
    ) -> AnyPublisher<BackendGenerationJob?, ClientError>? {
        guard let subject = shared.jobPublishers[jobId] else { return nil }
        return subject.eraseToAnyPublisher()
    }

    private func startPolling(jobId: String, handle: String) {
        let initialJob = BackendGenerationJob(
            _id: jobId,
            status: .queued,
            resultUrls: nil,
            errorMessage: nil,
            costCredits: 0,
            completedAt: nil
        )
        activeJobs[jobId] = initialJob
        let subject = CurrentValueSubject<BackendGenerationJob?, ClientError>(initialJob)
        jobPublishers[jobId] = subject

        pollingTasks[jobId] = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self else { return }

                do {
                    let (status, urls, err) = try await FalAIClient.pollStatus(handle: handle)
                    let updatedJob = BackendGenerationJob(
                        _id: jobId,
                        status: status,
                        resultUrls: urls,
                        errorMessage: err,
                        costCredits: 0,
                        completedAt: status == .succeeded ? Date().timeIntervalSince1970 : nil
                    )
                    self.activeJobs[jobId] = updatedJob
                    subject.send(updatedJob)

                    if status == .succeeded || status == .failed {
                        subject.send(completion: .finished)
                        self.pollingTasks[jobId]?.cancel()
                        self.pollingTasks.removeValue(forKey: jobId)
                        break
                    }
                } catch {
                    let failedJob = BackendGenerationJob(
                        _id: jobId,
                        status: .failed,
                        resultUrls: nil,
                        errorMessage: error.localizedDescription,
                        costCredits: 0,
                        completedAt: nil
                    )
                    self.activeJobs[jobId] = failedJob
                    subject.send(failedJob)
                    subject.send(completion: .finished)
                    self.pollingTasks[jobId]?.cancel()
                    self.pollingTasks.removeValue(forKey: jobId)
                    break
                }
            }
        }
    }

    private func startLeonardoPolling(jobId: String, generationId: String) {
        let initialJob = BackendGenerationJob(
            _id: jobId,
            status: .queued,
            resultUrls: nil,
            errorMessage: nil,
            costCredits: 0,
            completedAt: nil
        )
        activeJobs[jobId] = initialJob
        let subject = CurrentValueSubject<BackendGenerationJob?, ClientError>(initialJob)
        jobPublishers[jobId] = subject

        pollingTasks[jobId] = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self else { return }

                do {
                    let (status, urls, err) = try await LeonardoAIClient.pollStatus(generationId: generationId)
                    let updatedJob = BackendGenerationJob(
                        _id: jobId,
                        status: status,
                        resultUrls: urls,
                        errorMessage: err,
                        costCredits: 0,
                        completedAt: status == .succeeded ? Date().timeIntervalSince1970 : nil
                    )
                    self.activeJobs[jobId] = updatedJob
                    subject.send(updatedJob)

                    if status == .succeeded || status == .failed {
                        subject.send(completion: .finished)
                        self.pollingTasks[jobId]?.cancel()
                        self.pollingTasks.removeValue(forKey: jobId)
                        break
                    }
                } catch {
                    let failedJob = BackendGenerationJob(
                        _id: jobId,
                        status: .failed,
                        resultUrls: nil,
                        errorMessage: error.localizedDescription,
                        costCredits: 0,
                        completedAt: nil
                    )
                    self.activeJobs[jobId] = failedJob
                    subject.send(failedJob)
                    subject.send(completion: .finished)
                    self.pollingTasks[jobId]?.cancel()
                    self.pollingTasks.removeValue(forKey: jobId)
                    break
                }
            }
        }
    }
}
