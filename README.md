# ScreenView

Deferred model creation and structured lifecycle work for SwiftUI destinations using Observation.

`Screen` creates a model from SwiftUI's managed task, configures it before startup,
passes it to the content view, and tears down its work when that task exits.
`ScreenSubscribers` runs live updates in a structured task group.

Read [why ScreenView was created](https://anciltech.com/blog/why-screenview-was-created).

## Requirements

- Swift 6.0 or later; Xcode 16 or later.
- iOS 17+, macOS 14+, tvOS 17+, watchOS 10+, or visionOS 1+.
- No third-party dependencies.

## Installation

Add `https://github.com/anciltech/ScreenView` in Xcode's **Package Dependencies**,
or add the package and product to your manifest:

```swift
dependencies: [
    .package(url: "https://github.com/anciltech/ScreenView.git", from: "0.1.0")
],
targets: [
    .target(name: "YourApp", dependencies: ["ScreenView"])
]
```

## Content and model

```swift
import Observation
import ScreenView
import SwiftUI

struct AccountView: ScreenView {
    let viewModel: AccountViewModel

    var body: some View {
        @Bindable var viewModel = viewModel
        TextField("Name", text: $viewModel.name)
    }
}

@MainActor
@Observable
final class AccountViewModel: ScreenViewModel {
    var name = ""
    init() {}

    func onStartup() async {
        // Perform finite, cancellation-aware setup here.
    }
}

// At a navigation boundary:
Screen<AccountView, AccountViewModel>()
```

The content struct's `init(viewModel:)` is synthesized. Add an explicit public
initializer when exposing the content type from another module. `@Bindable` is
needed for bindings, not for reading observable properties.

Keep model initializers free of startup work. The package uses `ProgressView`
before creation; place app-specific loading treatment and keyboard behavior in
your own views.

## Route input

```swift
Screen<DocumentUploadView, DocumentUploadViewModel>(
    configure: { $0.configure(urls: documentURLs) }
)
```

Configuration runs once, before `onStartup()`. Give a different route input a
different SwiftUI identity when it needs a new model. Updating the configure
closure on an existing screen does not reconfigure its retained model.

## Subscriptions

A source conforms to `ChangesSubscription`, supplying an `AsyncStream` of
`Sendable` values. Actor-based repositories can conform directly:

```swift
actor AccountChanges: ChangesSubscription {
    typealias Value = String

    func subscribe() async -> AsyncStream<String> {
        // Replace this finite example with your stream producer.
        AsyncStream { continuation in
            continuation.yield("Taylor")
            continuation.finish()
        }
    }
}

// Inside the model; accountChanges is an AccountChanges instance:
func subscriptions() -> ScreenSubscribers {
    ScreenSubscribers {
        subscribe(to: accountChanges).react { [weak self] name in
            self?.name = name
        }
    }
}
```

You can also use `subscribe(to: { await service.changes() })` without introducing
a source type. Supply a **fresh stream each time**. Use the continuation's
`onTermination` to release producer resources.

The result builder supports multiple subscribers, `if`/`else`, optional branches,
and loops. Subscribers run concurrently, and each subscriber processes values
in order. Reactions run on the main actor; delegate expensive work to a service
or another actor. Do not spawn detached tasks to implement a subscriber.

## Lifecycle contract

| Hook | When it runs |
| --- | --- |
| `onStartup()` | Once per model, after configuration. |
| `onFirstFocus()` | The first observed active app scene after startup. |
| `onLostFocus()` | A previously active scene becomes inactive/background. |
| `onRegainedFocus()` | The scene becomes active again; defaults to `onFirstFocus()`. |
| `onReturn()` | SwiftUI starts another task for a retained model; defaults to restarting subscriptions. |
| `teardown()` | Synchronously when every screen task exits, after structured children finish. |

When overriding `onReturn()`, perform finite return-specific work, then call
`await runSubscribers()` to restart live updates. An override that only returns
leaves the screen alive without restarting its subscribers.

Scene hooks are serialized in a structured child task after startup. They
describe **scene activation**, not route visibility. Scene transitions observed
during startup are buffered and handled afterwards. The focus state survives a
task restart so a navigation return alone does not count as scene activation.

SwiftUI controls the destination's task lifetime. Native navigation may retain
the model while cancelling its task; `onReturn()` then reuses that model. Models
must be usable again after teardown. Teardown releases work/resources; it does
not imply that SwiftUI has destroyed the model.

Cancellation is **cooperative**. The task group waits for all children, and
`defer` runs when the task exits. Hooks and subscribers that ignore cancellation
can delay teardown. An empty/finished subscriber group suspends without a timer
until cancellation, keeping the screen task alive.

ScreenView does not replace a navigation coordinator, choose routes, enforce
authentication, or claim exact visual visibility. For simple local state use
plain `@State`; for child content, pass a model owned by the parent. An optional
`@State` model initialized in `.task` remains a good small-view solution.

## Example and verification

[`Examples/AccountExample.swift`](Examples/AccountExample.swift) is complete
content you can use from an app's `WindowGroup`. It includes a source actor,
observable model, bindings, and native navigation.

```sh
swift test
package_build_path="$(swift build --show-bin-path)"
swiftc -swift-version 6 -typecheck -I "$package_build_path" -I "$package_build_path/Modules" Examples/AccountExample.swift
```

Swift Testing covers deferred creation, configuration/startup order, retained
model returns, teardown on first and return tasks, cancellation during startup,
empty subscriptions, focus serialization/cancellation, concurrent subscribers,
ordered reactions, fresh streams, and producer termination.

These tests exercise the lifecycle runner directly. They do not prove native
push/pop task timing across all supported OS versions or physical devices.

## Background

This package adapts the supplied app-level ScreenView pattern into a dependency-free
library. It replaces app-specific loading, keyboard modifiers, logging, and
publisher context with standard SwiftUI and `AsyncStream`. The public extraction
also ensures return tasks call teardown and moves scene hooks from unstructured
tasks into the screen task's structured scope.

- [Apple: migrating to Observation](https://developer.apple.com/documentation/swiftui/migrating-from-the-observable-object-protocol-to-the-observable-macro)
- [Apple: SwiftUI view tasks](https://developer.apple.com/documentation/swiftui/view/task(priority:_:))

## License

MIT. See [LICENSE](LICENSE).
