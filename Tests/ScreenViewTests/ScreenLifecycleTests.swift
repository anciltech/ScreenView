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
    var startupFailuresRemaining = 0
    var returnGate: AsyncStream<Void>?
    var focusGate: AsyncStream<Void>?
    init() {}

    func onStartup() async throws {
        events.append("startup")
        if let startupGate { for await _ in startupGate {} }
        try Task.checkCancellation()
        if startupFailuresRemaining > 0 {
            startupFailuresRemaining -= 1
            throw StartupFailure.unavailable
        }
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
        if let returnGate { for await _ in returnGate {} }
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

private enum StartupFailure: Error { case unavailable }

/// A fake lease makes resource acquisition/release observable without networking.
@MainActor
private final class ResourceModel: ScreenViewModel {
    var startupGate: AsyncStream<Void>?
    var startupCalls = 0
    var returnCalls = 0
    var resourceGeneration: Int?
    var resourcesAcquired = 0
    var resourcesReleased = 0
    var activeSubscribers = 0
    var initialized = false
    init() {}

    func onStartup() async throws {
        startupCalls += 1
        acquireResource()
        if let startupGate { for await _ in startupGate {} }
        try Task.checkCancellation()
        initialized = true
    }

    func onReturn() async {
        #expect(initialized)
        returnCalls += 1
        acquireResource()
    }

    func subscriptions() -> ScreenSubscribers {
        ScreenSubscribers {
            ScreenSubscriber { [self] in
                #expect(initialized)
                #expect(resourceGeneration != nil)
                activeSubscribers += 1
                defer { activeSubscribers -= 1 }
                await suspendUntilCancelled()
            }
        }
    }

    func teardown() {
        #expect(activeSubscribers == 0)
        if resourceGeneration != nil { resourcesReleased += 1 }
        resourceGeneration = nil
    }

    private func acquireResource() {
        guard resourceGeneration == nil else { return }
        resourcesAcquired += 1
        resourceGeneration = resourcesAcquired
    }
}

@MainActor
private final class NonThrowingStartupModel: ScreenViewModel {
    var startupCalls = 0
    var returnCalls = 0
    var blockStartup = true
    var subscriberStarts = 0
    init() {}

    func onStartup() async {
        startupCalls += 1
        if blockStartup { await suspendUntilCancelled() }
        // Deliberately return normally when cancelled; the runner must still
        // avoid considering this a successful startup.
    }

    func onReturn() async { returnCalls += 1 }

    func subscriptions() -> ScreenSubscribers {
        ScreenSubscribers {
            ScreenSubscriber { [self] in
                subscriberStarts += 1
                await suspendUntilCancelled()
            }
        }
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
        // The finite onReturn override does not call runSubscribers itself.
        #expect(model.events.filter { $0 == "subscriber 0" }.count == 2)
        #expect(model.events.filter { $0 == "subscriber 1" }.count == 2)
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
        #expect(model.events == ["startup", "teardown"])
        #expect(lifecycle.startupError == nil)
    }

    @Test func cancelledStartupRetriesOnTheSameModelBeforeReturn() async throws {
        let lifecycle = ScreenLifecycle<Model>()
        var configurations = 0
        let first = Task {
            await lifecycle.run(phase: .active) { model in
                configurations += 1
                model.startupGate = AsyncStream { _ in }
            }
        }
        defer { first.cancel() }
        try await waitFor { lifecycle.model?.events == ["startup"] }
        let model = try #require(lifecycle.model)
        first.cancel()
        await first.value
        model.startupGate = nil

        let second = Task {
            await lifecycle.run(phase: .active) { _ in configurations += 1 }
        }
        defer { second.cancel() }
        try await waitFor { model.activeSubscribers == 2 }
        #expect(lifecycle.model === model)
        #expect(configurations == 1)
        #expect(model.events.filter { $0 == "startup" }.count == 2)
        #expect(model.events.filter { $0 == "startup finished" }.count == 1)
        #expect(!model.events.contains("return"))
        #expect(lifecycle.startupError == nil)
        second.cancel()
        await second.value

        let third = Task { await lifecycle.run(phase: .active) { _ in } }
        defer { third.cancel() }
        try await waitFor { model.activeSubscribers == 2 }
        #expect(model.events.filter { $0 == "startup" }.count == 2)
        #expect(model.events.filter { $0 == "return" }.count == 1)
        third.cancel()
        await third.value
        #expect(model.events.filter { $0 == "teardown" }.count == 3)
    }

    @Test func interruptedStartupReacquiresReleasedResourcesBeforeSuccessfulReturn() async throws {
        let lifecycle = ScreenLifecycle<ResourceModel>()
        var configurations = 0
        let first = Task {
            await lifecycle.run(phase: .background) { model in
                configurations += 1
                model.startupGate = AsyncStream { _ in }
            }
        }
        defer { first.cancel() }
        try await waitFor { lifecycle.model?.resourceGeneration == 1 }
        let model = try #require(lifecycle.model)
        #expect(!model.initialized)
        #expect(model.activeSubscribers == 0)
        first.cancel()
        await first.value
        #expect(model.resourceGeneration == nil)
        #expect(model.resourcesReleased == 1)
        #expect(!model.initialized)

        model.startupGate = nil
        let retry = Task {
            await lifecycle.run(phase: .background) { _ in configurations += 1 }
        }
        defer { retry.cancel() }
        try await waitFor { model.activeSubscribers == 1 }
        #expect(lifecycle.model === model)
        #expect(configurations == 1)
        #expect(model.startupCalls == 2)
        #expect(model.returnCalls == 0)
        #expect(model.initialized)
        #expect(model.resourceGeneration == 2)
        retry.cancel()
        await retry.value
        #expect(model.resourceGeneration == nil)
        #expect(model.resourcesReleased == 2)
        #expect(model.initialized)

        let returning = Task { await lifecycle.run(phase: .background) { _ in } }
        defer { returning.cancel() }
        try await waitFor { model.activeSubscribers == 1 }
        #expect(model.startupCalls == 2)
        #expect(model.returnCalls == 1)
        #expect(model.resourceGeneration == 3)
        returning.cancel()
        await returning.value
        #expect(model.resourcesAcquired == 3)
        #expect(model.resourcesReleased == 3)
        #expect(model.resourceGeneration == nil)
    }

    @Test func failedStartupExposesErrorAndSupportsExplicitRetry() async throws {
        let lifecycle = ScreenLifecycle<Model>()
        var configurations = 0
        await lifecycle.run(phase: .active) { model in
            configurations += 1
            model.startupFailuresRemaining = 1
        }
        let model = try #require(lifecycle.model)
        #expect(lifecycle.startupError as? StartupFailure == .unavailable)
        #expect(model.events == ["startup", "teardown"])
        #expect(model.activeSubscribers == 0)

        lifecycle.retryStartup()
        #expect(lifecycle.startupError == nil)
        #expect(lifecycle.startupAttempt == 1)
        let retry = Task {
            await lifecycle.run(phase: .active) { _ in configurations += 1 }
        }
        defer { retry.cancel() }
        try await waitFor { model.activeSubscribers == 2 }
        #expect(lifecycle.model === model)
        #expect(configurations == 1)
        #expect(model.events.filter { $0 == "startup" }.count == 2)
        #expect(model.events.filter { $0 == "startup finished" }.count == 1)
        #expect(!model.events.contains("return"))
        #expect(lifecycle.startupError == nil)
        retry.cancel()
        await retry.value
        #expect(model.events.filter { $0 == "teardown" }.count == 2)
    }

    @Test func startupReturningNormallyAfterCancellationStillRetries() async throws {
        let lifecycle = ScreenLifecycle<NonThrowingStartupModel>()
        let first = Task { await lifecycle.run(phase: .active) { _ in } }
        defer { first.cancel() }
        try await waitFor { lifecycle.model?.startupCalls == 1 }
        let model = try #require(lifecycle.model)
        first.cancel()
        await first.value
        #expect(lifecycle.startupError == nil)
        #expect(model.subscriberStarts == 0)
        model.blockStartup = false

        let second = Task { await lifecycle.run(phase: .active) { _ in } }
        defer { second.cancel() }
        try await waitFor { model.subscriberStarts == 1 }
        #expect(model.startupCalls == 2)
        #expect(model.returnCalls == 0)
        second.cancel()
        await second.value
    }

    @Test func cancellationDuringReturnDoesNotRestartSubscribers() async throws {
        let lifecycle = ScreenLifecycle<Model>()
        let first = Task { await lifecycle.run(phase: .active) { _ in } }
        defer { first.cancel() }
        try await waitFor { lifecycle.model?.activeSubscribers == 2 }
        let model = try #require(lifecycle.model)
        first.cancel()
        await first.value
        model.returnGate = AsyncStream { _ in }

        let second = Task { await lifecycle.run(phase: .active) { _ in } }
        defer { second.cancel() }
        try await waitFor { model.events.contains("return") }
        #expect(model.activeSubscribers == 0)
        second.cancel()
        await second.value
        #expect(model.events.filter { $0 == "subscriber 0" }.count == 1)
        #expect(model.events.filter { $0 == "subscriber 1" }.count == 1)
        #expect(model.events.filter { $0 == "teardown" }.count == 2)
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
