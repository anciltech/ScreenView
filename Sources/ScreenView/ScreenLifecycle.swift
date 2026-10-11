import Observation
import SwiftUI

/// Separated from view rendering so lifecycle ordering and cancellation can be tested.
@MainActor
@Observable
final class ScreenLifecycle<Model: ScreenViewModel> {
    private(set) var model: Model?
    private(set) var startupError: (any Error)?
    private(set) var startupAttempt = 0
    @ObservationIgnored private var startupCompleted = false
    @ObservationIgnored private var isRunning = false
    @ObservationIgnored private var isFocused = false
    @ObservationIgnored private var hasGainedFocus = false
    @ObservationIgnored private var phaseContinuation: AsyncStream<ScenePhase>.Continuation?
    @ObservationIgnored private var runWaiters: [UUID: AsyncStream<Void>.Continuation] = [:]

    func updatePhase(_ phase: ScenePhase) {
        phaseContinuation?.yield(phase)
    }

    func retryStartup() {
        guard startupError != nil, !isRunning else { return }
        startupError = nil
        startupAttempt += 1
    }

    func run(phase: ScenePhase, configure: @MainActor (Model) -> Void) async {
        // A rapid reappearance can start a task while the cancelled predecessor
        // is still draining its children. Wait for cleanup before reusing the model.
        while isRunning {
            guard !Task.isCancelled else { return }
            let id = UUID()
            let waiter = AsyncStream<Void>.makeStream()
            runWaiters[id] = waiter.continuation
            for await _ in waiter.stream {}
            runWaiters.removeValue(forKey: id)
        }
        guard !Task.isCancelled else { return }
        isRunning = true
        let isReturningAfterStartup = startupCompleted
        let currentModel: Model
        if let model {
            currentModel = model
        } else {
            currentModel = Model()
            configure(currentModel)
            model = currentModel
        }

        // Buffer transitions during startup; consume them in order afterwards.
        let phases = AsyncStream<ScenePhase>.makeStream()
        phaseContinuation = phases.continuation
        phases.continuation.yield(phase)
        defer {
            phases.continuation.finish()
            phaseContinuation = nil
            currentModel.teardown()
            isRunning = false
            for waiter in runWaiters.values { waiter.finish() }
            runWaiters.removeAll()
        }

        if !startupCompleted {
            startupError = nil
            do {
                try await currentModel.onStartup()
                try Task.checkCancellation()
                startupCompleted = true
            } catch {
                if !Task.isCancelled { startupError = error }
                return
            }
        }
        guard !Task.isCancelled else { return }

        // Hooks are serialized in one child task. They cannot outlive the screen
        // task or overlap startup, unlike an unstructured Task in onChange.
        let phaseStream = phases.stream
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await self.observeFocus(phaseStream, model: currentModel)
            }
            if isReturningAfterStartup { await currentModel.onReturn() }
            if !Task.isCancelled {
                await currentModel.subscriptions().run()
                await suspendUntilCancelled()
            }
            phases.continuation.finish()
            group.cancelAll()
        }
    }

    private func observeFocus(_ phases: AsyncStream<ScenePhase>, model: Model) async {
        for await phase in phases {
            guard !Task.isCancelled else { return }
            await handleFocus(phase, model: model)
        }
    }

    private func handleFocus(_ phase: ScenePhase, model: Model) async {
        switch phase {
        case .active:
            guard !isFocused else { return }
            isFocused = true
            if hasGainedFocus {
                await model.onRegainedFocus()
            } else {
                hasGainedFocus = true
                await model.onFirstFocus()
            }
        case .inactive, .background:
            guard isFocused else { return }
            isFocused = false
            await model.onLostFocus()
        @unknown default:
            break
        }
    }
}

/// An empty async stream suspends without a timer and ends on task cancellation.
func suspendUntilCancelled() async {
    guard !Task.isCancelled else { return }
    let stream = AsyncStream<Void> { _ in }
    for await _ in stream {}
}
