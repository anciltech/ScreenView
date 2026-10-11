import SwiftUI

/// Content that receives a model owned by a `Screen` destination.
@MainActor
public protocol ScreenView: View {
    associatedtype ViewModel: ScreenViewModel
    init(viewModel: ViewModel)
}

/// A model whose work follows the SwiftUI destination task.
///
/// Keep `init()` free of startup work. Async hooks and subscribers must cooperate
/// with cancellation. A retained model can be used again after `teardown()`.
/// Startup may be retried after cancellation or failure; tolerate partial work.
@MainActor
public protocol ScreenViewModel: AnyObject, Sendable {
    init()
    func onStartup() async throws
    func onFirstFocus() async
    func onLostFocus() async
    func onRegainedFocus() async
    func onReturn() async
    func subscriptions() -> ScreenSubscribers
    func teardown()
}

public extension ScreenViewModel {
    func onStartup() async throws {}
    func onFirstFocus() async {}
    func onLostFocus() async {}
    func onRegainedFocus() async { await onFirstFocus() }

    /// Performs finite work when a successfully started model's task restarts.
    /// Screen restarts subscribers after this returns; do not run them here.
    func onReturn() async {}
    func subscriptions() -> ScreenSubscribers { ScreenSubscribers {} }
    func teardown() {}

    /// Runs subscriptions, then suspends until cancellation if they all finish.
    func runSubscribers() async {
        guard !Task.isCancelled else { return }
        await subscriptions().run()
        await suspendUntilCancelled()
    }
}

/// Creates its model in SwiftUI's task, configures it, and owns its lifecycle.
///
/// Scene focus describes app activation, not which route is in front. SwiftUI
/// controls task lifetime; native navigation can retain the model between tasks.
@MainActor
public struct Screen<Content: ScreenView, ViewModel: ScreenViewModel>: View
where Content.ViewModel == ViewModel {
    @Environment(\.scenePhase) private var scenePhase
    @State private var lifecycle = ScreenLifecycle<ViewModel>()
    private let configure: @MainActor (ViewModel) -> Void

    public init(configure: @escaping @MainActor (ViewModel) -> Void = { _ in }) {
        self.configure = configure
    }

    public var body: some View {
        // Keep task ownership stable when loading, content, and failure views change.
        ZStack {
            if lifecycle.startupError != nil {
                VStack {
                    Text("Unable to load this screen.")
                    Button("Retry") { lifecycle.retryStartup() }
                }
            } else if let model = lifecycle.model {
                Content(viewModel: model)
            } else {
                ProgressView()
            }
        }
        .task(id: lifecycle.startupAttempt) {
            await lifecycle.run(phase: scenePhase, configure: configure)
        }
        .onChange(of: scenePhase) { _, phase in
            lifecycle.updatePhase(phase)
        }
    }
}
