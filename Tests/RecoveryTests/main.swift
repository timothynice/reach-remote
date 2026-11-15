import Foundation

@main struct RecoveryPolicyTests {
    // CI executors can take longer than the timer interval to schedule a child task.
    @MainActor static func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor static func main() async throws {
        let expected: [Double] = [2, 4, 8, 16, 20, 20]
        for (offset, delay) in expected.enumerated() {
            precondition(SessionRecovery.delay(attempt: offset + 1) == delay)
        }
        precondition(SessionRecovery.delay(attempt: Int.max) == 20)
        precondition(SessionRecovery.delay(attempt: Int.min) == 2)
        let retry = SessionRetry()
        var calls = 0
        retry.schedule(after: 0.01) { calls += 1; precondition(!retry.pending) }
        retry.schedule(after: 0.01) { calls += 100 }
        precondition(retry.pending)
        try await waitUntil { calls >= 1 }
        precondition(calls == 1 && !retry.pending, "Duplicate retries must coalesce")
        retry.schedule(after: 0.01) { calls += 100 }
        retry.cancel()
        try await Task.sleep(for: .milliseconds(40))
        precondition(calls == 1 && !retry.pending, "Background/manual cancellation must suppress a stale attempt")
        retry.schedule(after: 0.01) { calls += 1 }
        try await waitUntil { calls >= 2 }
        precondition(calls == 2 && !retry.pending, "Foreground retry must work after cancellation")
        print("PASS: bounded backoff, duplicate coalescing, cancellation, slot clearing, and rescheduling")
    }
}
