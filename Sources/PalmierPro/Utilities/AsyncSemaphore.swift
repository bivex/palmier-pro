/// Bounded-concurrency primitive for async work. Used to gate fan-out tasks that
/// share a finite system resource (e.g. CoreMedia's audio decoders).
actor AsyncSemaphore {
    private var permits: Int
    private var nextWaiterID = 0
    private var waiters: [Int: CheckedContinuation<Void, Error>] = [:]

    init(value: Int) { self.permits = max(0, value) }

    /// Executes an async block safely inside the semaphore gate, guaranteeing
    /// permit release even on failure or task cancellation.
    func withPermit<T: Sendable>(_ operation: () async throws -> T) async throws -> T {
        try await wait()
        defer { signal() }
        return try await operation()
    }

    func wait() async throws {
        try Task.checkCancellation()
        if permits > 0 {
            permits -= 1
            return
        }

        let id = nextWaiterID
        nextWaiterID += 1

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    self.waiters[id] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }
    }

    func signal() {
        if let (id, continuation) = waiters.first {
            waiters.removeValue(forKey: id)
            continuation.resume()
        } else {
            permits += 1
        }
    }

    private func cancelWaiter(id: Int) {
        if let continuation = waiters.removeValue(forKey: id) {
            continuation.resume(throwing: CancellationError())
        }
    }
}
