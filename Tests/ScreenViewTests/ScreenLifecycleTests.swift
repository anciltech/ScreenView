import SwiftUI
import Testing
@testable import ScreenView

@MainActor
private final class Model: ScreenViewModel {
    var events: [String] = []
    var activeSubscribers = 0
    var activeFocusHooks = 0
    var subscriberCount = 2
    var startupGate: AsyncStream<Void>?
    var focusGate: AsyncStream<Void>?
    init() {}

    func onStartup() async {
        events.append("startup")
        if let startupGate { for await _ in startupGate {} }
        events.append("startup finished")
    }

    func onFirstFocus() async {
        activeFocusHooks += 1
        defer { activeFocusHooks -= 1 }
        events.append("first focus")
        if let focusGate { for await _ in focusGate {} }
        events.append("first focus finished")
    }

    func onLostFocus() async { events.append("lost focus") }
    func onRegainedFocus() async { events.append("regained focus") }

    func onReturn() async {
        events.append("return")
        await runSubscribers()
    }

    func subscriptions() -> ScreenSubscribers {
        ScreenSubscribers {
            for index in 0..<subscriberCount {
                ScreenSubscriber { [self] in
                    activeSubscribers += 1
                    events.append("subscriber \(index)")
                    defer { activeSubscribers -= 1 }
                    await suspendUntilCancelled()
                }
            }
        }
    }

    func teardown() {
        // The structured children must have exited before cleanup.
        #expect(activeSubscribers == 0)
        #expect(activeFocusHooks == 0)
        events.append("teardown")
    }
}

@MainActor
private func waitFor(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while !condition() {
        if ContinuousClock.now >= deadline {
            throw Timeout()
        }
        try await Task.sleep(for: .milliseconds(1))
    }
}
private struct Timeout: Error {}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ScreenLifecycleTests {
    @Test func deferredConstructionConfigurationAndReturn() async throws {
        let lifecycle = ScreenLifecycle<Model>()
        #expect(lifecycle.model == nil)
        var configurations = 0
        let first = Task {
            await lifecycle.run(phase: .active) { model in
                configurations += 1
                model.events.append("configure")
            }
        }
        defer { first.cancel() }
        try await waitFor { lifecycle.model?.activeSubscribers == 2 }
        let model = try #require(lifecycle.model)
        #expect(model.events.prefix(3) == ["configure", "startup", "startup finished"])
        first.cancel()
        await first.value
        #expect(model.events.last == "teardown")

        let second = Task {
            await lifecycle.run(phase: .active) { _ in configurations += 1 }
        }
        defer { second.cancel() }
        try await waitFor { model.activeSubscribers == 2 }
        #expect(lifecycle.model === model)
        #expect(configurations == 1)
        #expect(model.events.filter { $0 == "startup" }.count == 1)
        #expect(model.events.filter { $0 == "return" }.count == 1)
        second.cancel()
        await second.value
        #expect(model.events.filter { $0 == "teardown" }.count == 2)
    }

    @Test func cancellationDuringStartupSkipsSubscribersAndFocus() async throws {
        let lifecycle = ScreenLifecycle<Model>()
        let task = Task {
            await lifecycle.run(phase: .active) { model in
                model.startupGate = AsyncStream { _ in }
            }
        }
        defer { task.cancel() }
        try await waitFor { lifecycle.model?.events == ["startup"] }
        task.cancel()
        await task.value
        let model = try #require(lifecycle.model)
        #expect(model.events == ["startup", "startup finished", "teardown"])
    }

    @Test func emptySubscribersStayAliveUntilCancellation() async throws {
        let lifecycle = ScreenLifecycle<Model>()
        let task = Task {
            await lifecycle.run(phase: .active) { $0.subscriberCount = 0 }
        }
        defer { task.cancel() }
        try await waitFor { lifecycle.model?.events.contains("first focus finished") == true }
        #expect(lifecycle.model?.events.contains("teardown") == false)
        task.cancel()
        await task.value
        #expect(lifecycle.model?.events.last == "teardown")
    }

    @Test func sceneHooksAreSerializedAfterStartup() async throws {
        let lifecycle = ScreenLifecycle<Model>()
        let startup = AsyncStream<Void>.makeStream()
        let focus = AsyncStream<Void>.makeStream()
        let task = Task {
            await lifecycle.run(phase: .active) { model in
                model.startupGate = startup.stream
                model.focusGate = focus.stream
            }
        }
        defer { task.cancel() }
        try await waitFor { lifecycle.model?.events == ["startup"] }
        lifecycle.updatePhase(.inactive)
        lifecycle.updatePhase(.active)
        #expect(lifecycle.model?.activeFocusHooks == 0)
        startup.continuation.finish()
        try await waitFor { lifecycle.model?.activeFocusHooks == 1 }
        #expect(lifecycle.model?.events.contains("lost focus") == false)
        focus.continuation.finish()
        try await waitFor { lifecycle.model?.events.contains("regained focus") == true }
        let model = try #require(lifecycle.model)
        let focusEvents = model.events.filter { $0.contains("focus") }
        #expect(focusEvents == ["first focus", "first focus finished", "lost focus", "regained focus"])
        lifecycle.updatePhase(.active)
        lifecycle.updatePhase(.background)
        try await waitFor { model.events.filter { $0 == "lost focus" }.count == 2 }
        task.cancel()
        await task.value
        #expect(model.events.last == "teardown")
    }

    @Test func cancellationWaitsForFocusHookBeforeTeardown() async throws {
        let lifecycle = ScreenLifecycle<Model>()
        let task = Task {
            await lifecycle.run(phase: .active) { model in
                model.focusGate = AsyncStream { _ in }
            }
        }
        defer { task.cancel() }
        try await waitFor { lifecycle.model?.activeFocusHooks == 1 }
        task.cancel()
        await task.value
        #expect(lifecycle.model?.events.last == "teardown")
    }

    @Test func overlappingReturnWaitsForPreviousTeardown() async throws {
        let lifecycle = ScreenLifecycle<Model>()
        let first = Task { await lifecycle.run(phase: .active) { _ in } }
        defer { first.cancel() }
        try await waitFor { lifecycle.model?.activeSubscribers == 2 }
        let second = Task {
            await lifecycle.run(phase: .active) { _ in Issue.record("Must not configure twice") }
        }
        defer { second.cancel() }
        await Task.yield()
        #expect(lifecycle.model?.events.contains("return") == false)
        first.cancel()
        await first.value
        #expect(lifecycle.model?.events.filter { $0 == "teardown" }.count == 1)
        try await waitFor { lifecycle.model?.events.contains("return") == true }
        let model = try #require(lifecycle.model)
        let teardown = try #require(model.events.firstIndex(of: "teardown"))
        let returned = try #require(model.events.firstIndex(of: "return"))
        #expect(teardown < returned)
        second.cancel()
        await second.value
        #expect(model.events.filter { $0 == "teardown" }.count == 2)
    }

    @Test func cancelledWaitingReturnDoesNotRestartTheModel() async throws {
        let lifecycle = ScreenLifecycle<Model>()
        let first = Task { await lifecycle.run(phase: .active) { _ in } }
        defer { first.cancel() }
        try await waitFor { lifecycle.model?.activeSubscribers == 2 }
        let second = Task { await lifecycle.run(phase: .active) { _ in } }
        await Task.yield()
        second.cancel()
        await second.value
        #expect(lifecycle.model?.events.contains("return") == false)
        first.cancel()
        await first.value
        #expect(lifecycle.model?.events.filter { $0 == "teardown" }.count == 1)
    }
}
