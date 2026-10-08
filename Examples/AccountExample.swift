import Observation
import ScreenView
import SwiftUI

/// Replace this actor with a repository that supplies fresh streams.
actor AccountChanges: ChangesSubscription {
    typealias Value = String
    static let shared = AccountChanges()

    func subscribe() async -> AsyncStream<String> {
        // A finite stream keeps the example self-contained. Real producers
        // should release their resources in continuation.onTermination.
        AsyncStream { continuation in
            continuation.yield("Taylor")
            continuation.finish()
        }
    }
}

@MainActor
@Observable
final class AccountViewModel: ScreenViewModel {
    var name = ""
    var status = "Ready"
    init() {}

    func onStartup() async { status = "Started" }

    func subscriptions() -> ScreenSubscribers {
        ScreenSubscribers {
            subscribe(to: AccountChanges.shared).react { [weak self] name in
                self?.name = name
            }
        }
    }

    func onReturn() async {
        status = "Returned"
        await runSubscribers()
    }

    func teardown() { status = "Stopped" }
}

struct AccountView: ScreenView {
    let viewModel: AccountViewModel

    var body: some View {
        @Bindable var viewModel = viewModel
        Form {
            TextField("Name", text: $viewModel.name)
            Text(viewModel.status)
            NavigationLink("Another destination") {
                Text("Go back to restart the retained account screen.")
            }
        }
        .navigationTitle("Account")
    }
}

/// Use as your app's root content to exercise native navigation.
struct AccountExample: View {
    var body: some View {
        NavigationStack {
            NavigationLink("Open account") {
                Screen<AccountView, AccountViewModel>()
            }
            .navigationTitle("ScreenView example")
        }
    }
}
