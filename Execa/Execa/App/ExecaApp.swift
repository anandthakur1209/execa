import SwiftUI

@main
struct ExecaApp: App {
    @State private var coordinator: AppCoordinator?
    @State private var initError: String?

    var body: some Scene {
        WindowGroup {
            RootView(coordinator: coordinator, initError: initError)
                .frame(minWidth: 520, minHeight: 360)
                .task {
                    guard coordinator == nil, initError == nil else { return }
                    do {
                        coordinator = try await AppCoordinator()
                    } catch {
                        initError = String(describing: error)
                    }
                }
        }
    }
}

private struct RootView: View {
    let coordinator: AppCoordinator?
    let initError: String?

    var body: some View {
        if let coordinator {
            SetupWizardView(coordinator: coordinator)
        } else if let initError {
            VStack(spacing: 8) {
                Text("execa failed to start").font(.headline)
                Text(initError).font(.caption).foregroundStyle(.secondary)
            }
            .padding()
        } else {
            ProgressView("Starting execa…").padding()
        }
    }
}
