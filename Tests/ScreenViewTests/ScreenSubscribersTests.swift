import os
import Testing
@testable import ScreenView

private actor Changes: ChangesSubscription {
    typealias Value = Int
    func subscribe() async -> AsyncStream<Int> {
        AsyncStream { continuation in
            continuation.yield(1)
            continuation.yield(2)
            continuation.finish()
        }
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ScreenSubscribersTests {
    @Test func sourceReactionsAreOrderedAndFreshOnEachRun() async {
        var values: [Int] = []
        let subscriber = subscribe(to: Changes()).react { values.append($0) }
        await subscriber.run()
        await subscriber.run()
        #expect(values == [1, 2, 1, 2])
    }

    @Test func streamProducerReceivesTerminationOnCancellation() async throws {
        let state = OSAllocatedUnfairLock(initialState: (subscribed: false, terminated: false))
        let subscribers = ScreenSubscribers {
            subscribe(to: {
                AsyncStream<Int> { continuation in
                    continuation.onTermination = { _ in
                        state.withLock { $0.terminated = true }
                    }
                    state.withLock { $0.subscribed = true }
                }
            }).react { _ in Issue.record("Empty stream must not emit a value") }
        }
        let task = Task { await subscribers.run() }
        defer { task.cancel() }
        let deadline = ContinuousClock.now + .seconds(3)
        while !state.withLock({ $0.subscribed }) {
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(1))
        }
        task.cancel()
        await task.value
        #expect(state.withLock { $0.terminated })
    }

    @Test func builderSupportsConditionalAndLoopedSubscriptions() async {
        var calls: [Int] = []
        let includeExtra = true
        let subscribers = ScreenSubscribers {
            if includeExtra { ScreenSubscriber { calls.append(0) } }
            for index in 1...2 { ScreenSubscriber { calls.append(index) } }
        }
        await subscribers.run()
        #expect(calls.sorted() == [0, 1, 2])
    }
}
