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
@MainActor
public protocol ScreenViewModel: AnyObject, Sendable {
    init()
    func onStartup() async
    func onFirstFocus() async
    func onLostFocus() async
    func onRegainedFocus() async
    func onReturn() async
    func subscriptions() -> ScreenSubscribers
    func teardown()
}

public extension ScreenViewModel {
    func onStartup() async {}
    func onFirstFocus() async {}
    func onLostFocus() async {}
    func onRegainedFocus() async { await onFirstFocus() }

    /// Restarts subscribers when SwiftUI restarts a retained destination's task.
    /// An override should call `await runSubscribers()` after its finite work.
    func onReturn() async { await runSubscribers() }
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
        Group {
            if let model = lifecycle.model {
                Content(viewModel: model)
            } else {
                ProgressView()
            }
        }
        .task {
            await lifecycle.run(phase: scenePhase, configure: configure)
        }
        .onChange(of: scenePhase) { _, phase in
            lifecycle.updatePhase(phase)
        }
    }
}
