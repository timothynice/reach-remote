import Foundation

/// Deterministic bounded retry policy. A successful authenticated connection resets the attempt.
enum SessionRecovery {
    static func delay(attempt: Int) -> Double {
        min(20, pow(2, Double(min(5, max(1, attempt)))))
    }
}

/// One cancellable retry at a time. Clearing the slot before invoking the action allows a later
/// connection failure to schedule the next attempt, without overlapping a manual/foreground retry.
@MainActor
final class SessionRetry {
    private var task: Task<Void, Never>?
    var pending: Bool { task != nil }
    func cancel() { task?.cancel(); task = nil }
    func schedule(after seconds: Double, action: @escaping @MainActor () -> Void) {
        guard task == nil else { return }
        task = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) }
            catch { return }
            guard !Task.isCancelled, let self else { return }
            self.task = nil
            action()
        }
    }
    deinit { task?.cancel() }
}
