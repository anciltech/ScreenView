/// Owns structured child tasks for a screen's live updates.
@MainActor
public struct ScreenSubscribers {
    private let subscribers: [ScreenSubscriber]

    public init(@ScreenSubscribersBuilder _ content: () -> [ScreenSubscriber]) {
        subscribers = content()
    }

    public func run() async {
        guard !Task.isCancelled else { return }
        await withTaskGroup(of: Void.self) { group in
            for subscriber in subscribers {
                group.addTask { await subscriber.run() }
            }
        }
    }
}

@resultBuilder
public enum ScreenSubscribersBuilder {
    public static func buildExpression(_ subscriber: ScreenSubscriber) -> [ScreenSubscriber] {
        [subscriber]
    }
    public static func buildBlock(_ components: [ScreenSubscriber]...) -> [ScreenSubscriber] {
        components.flatMap { $0 }
    }
    public static func buildOptional(_ component: [ScreenSubscriber]?) -> [ScreenSubscriber] {
        component ?? []
    }
    public static func buildEither(first: [ScreenSubscriber]) -> [ScreenSubscriber] { first }
    public static func buildEither(second: [ScreenSubscriber]) -> [ScreenSubscriber] { second }
    public static func buildArray(_ components: [[ScreenSubscriber]]) -> [ScreenSubscriber] {
        components.flatMap { $0 }
    }
}

@MainActor
public struct ScreenSubscriber {
    private let action: @MainActor @Sendable () async -> Void

    public init(action: @escaping @MainActor @Sendable () async -> Void) {
        self.action = action
    }

    public func run() async {
        guard !Task.isCancelled else { return }
        await action()
    }
}

/// A sendable source that supplies a fresh stream for each screen task.
/// Release producer resources in the stream continuation's `onTermination`.
public protocol ChangesSubscription: Sendable {
    associatedtype Value: Sendable
    func subscribe() async -> AsyncStream<Value>
}

@MainActor
public struct Subscription<Value: Sendable> {
    private let publisher: @MainActor @Sendable () async -> AsyncStream<Value>

    public init(publisher: @escaping @MainActor @Sendable () async -> AsyncStream<Value>) {
        self.publisher = publisher
    }

    public func react(
        _ reaction: @escaping @MainActor @Sendable (Value) async -> Void
    ) -> ScreenSubscriber {
        let publisher = publisher
        return ScreenSubscriber {
            guard !Task.isCancelled else { return }
            for await value in await publisher() {
                guard !Task.isCancelled else { return }
                await reaction(value)
            }
        }
    }
}

@MainActor
public func subscribe<Source: ChangesSubscription>(to source: Source) -> Subscription<Source.Value> {
    Subscription { await source.subscribe() }
}

/// Supplies a fresh AsyncStream without requiring a custom source type.
@MainActor
public func subscribe<Value: Sendable>(
    to publisher: @escaping @MainActor @Sendable () async -> AsyncStream<Value>
) -> Subscription<Value> {
    Subscription(publisher: publisher)
}
