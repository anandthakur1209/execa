import SwiftUI

@main
struct ExecaApp: App {
    @State private var coordinator: AppCoordinator?
    @State private var initError: String?
    @State private var firstRunComplete: Bool = false
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some Scene {
        WindowGroup(id: "execa-setup") {
            RootView(
                coordinator: coordinator,
                initError: initError,
                firstRunComplete: firstRunComplete,
                onWizardComplete: {
                    firstRunComplete = true
                    dismissWindow(id: "execa-setup")
                }
            )
            .frame(minWidth: 520, minHeight: 360)
            .task {
                guard coordinator == nil, initError == nil else { return }
                do {
                    let coord = try await AppCoordinator()
                    coordinator = coord
                    firstRunComplete = await (try? coord.isFirstRunComplete()) ?? false
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
    let firstRunComplete: Bool
    let onWizardComplete: () -> Void

    var body: some View {
        if let coordinator {
            if firstRunComplete {
                AlreadySetUpView()
            } else {
                SetupWizardView(coordinator: coordinator, onComplete: onWizardComplete)
            }
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

private struct AlreadySetUpView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("execa is set up.").bold()
            Text("Look for the execa icon in your menu bar to start a meeting.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
    }
}
