// SettingsView (Plan 4 Task 12): the thin settings — server, SPKI pin,
// account, the local device id row, the stats overlay toggle and the
// offline banner. All state lives in SettingsViewModel; the view only
// maps it.

import DesignSystem
import ServerAPI
import SwiftUI

public struct SettingsView: View {
    @State private var viewModel: SettingsViewModel

    public init(viewModel: SettingsViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    public var body: some View {
        Form {
            if viewModel.showOfflineBanner {
                Section {
                    Banner(message: "Offline — reconnecting…")
                }
            }
            Section("Account") {
                row("Username", viewModel.accountText)
                row("This device", viewModel.deviceIdText)
            }
            Section("Server") {
                row("Address", viewModel.serverText)
                row("SPKI pin", viewModel.pinText)
            }
            Section("Calls") {
                Toggle("Stats overlay", isOn: $viewModel.statsOverlayEnabled)
            }
        }
        .task {
            viewModel.start()
            viewModel.load()
        }
        .onDisappear {
            viewModel.stop()
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        LabeledContent(label, value: value)
    }
}

#Preview {
    SettingsView(viewModel: SettingsViewModel(
        configStore: SessionConfigStore(defaults: UserDefaultsWriter()),
        defaults: UserDefaultsWriter(),
        deviceId: "7",
        events: { AsyncStream { _ in } }
    ))
}
