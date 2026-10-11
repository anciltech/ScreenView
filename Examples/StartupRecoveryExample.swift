import Foundation
import Observation
import ScreenView
import SwiftUI

/// Retains downloaded data across tasks, but releases each task's session.
@MainActor
@Observable
final class StartupRecoveryModel: ScreenViewModel {
    var url: URL?
    private(set) var downloadedBytes = 0
    private(set) var startupCompleted = false
    @ObservationIgnored private var session: URLSession?

    init() {}

    func onStartup() async throws {
        guard let url else { throw RecoveryError.missingURL }
        // Acquire before suspension: cancellation can interrupt partial setup.
        let session = sessionForCurrentTask()
        let (data, response) = try await session.data(from: url)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else {
            throw RecoveryError.invalidResponse
        }
        // Publish initialized state only after the operation succeeds.
        downloadedBytes = data.count
        startupCompleted = true
    }

    func onReturn() async {
        // Startup data survives teardown; the released resource does not.
        // Reopen resources needed by this task without repeating initial loading.
        _ = sessionForCurrentTask()
    }

    func teardown() {
        session?.invalidateAndCancel()
        session = nil
    }

    private func sessionForCurrentTask() -> URLSession {
        if let session { return session }
        let created = URLSession(configuration: .ephemeral)
        session = created
        return created
    }

    private enum RecoveryError: Error {
        case missingURL
        case invalidResponse
    }
}

struct StartupRecoveryView: ScreenView {
    let viewModel: StartupRecoveryModel

    var body: some View {
        if viewModel.startupCompleted {
            Text("Loaded \(viewModel.downloadedBytes) bytes")
        } else {
            ProgressView("Loading…")
        }
    }
}

/// Supply an HTTP(S) URL. A slow response makes mid-startup cancellation visible.
struct StartupRecoveryExample: View {
    let url: URL

    var body: some View {
        Screen<StartupRecoveryView, StartupRecoveryModel> {
            $0.url = url
        }
        .id(url)
    }
}
