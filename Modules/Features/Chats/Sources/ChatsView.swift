// ChatsView (Plan 4 Task 12): the thin chats list — DesignSystem ChatRow
// per summary, a presence dot over the avatar, and the offline banner.
// All state lives in ChatsViewModel; the view only maps it.

import DesignSystem
import SwiftUI

public struct ChatsView: View {
    @State private var viewModel: ChatsViewModel
    /// The row-tap callback (composition root, part 2 / LNK-39): when set,
    /// each row becomes a button that hands over the peer. Nil keeps the
    /// part-1 look-and-feel exactly.
    public var onSelect: ((String) -> Void)?
    @State private var query = ""
    @State private var searchTask: Task<Void, Never>?

    public init(viewModel: ChatsViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: LKTokens.Spacing.s8) {
                if viewModel.showOfflineBanner {
                    Banner(message: "Offline — messages send when you are back")
                }
                TextField("Find a user…", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                #if os(iOS)
                    .textInputAutocapitalization(.never)
                #endif
                    .padding(.horizontal, LKTokens.Spacing.s8)
                    .onChange(of: query) { _, newValue in
                        searchTask?.cancel()
                        searchTask = Task {
                            try? await Task.sleep(for: .milliseconds(250))
                            guard !Task.isCancelled else { return }
                            await viewModel.search(prefix: newValue)
                        }
                    }
                if !query.isEmpty {
                    searchResultsList
                }
                List(viewModel.rows) { row in
                    if let onSelect {
                        Button {
                            onSelect(row.peer)
                        } label: {
                            rowLabel(row)
                        }
                        .buttonStyle(.plain)
                    } else {
                        rowLabel(row)
                    }
                }
                .listStyle(.plain)
            }
            .padding(.top, LKTokens.Spacing.s8)
            .task {
                viewModel.start()
                await viewModel.refresh()
            }
            .onDisappear {
                viewModel.stop()
            }
        }
    }

    /// The peer matches under the search field (spec §10 item 1): tapping
    /// one opens the conversation through the same onSelect path the chat
    /// rows use.
    @ViewBuilder
    private var searchResultsList: some View {
        let results = viewModel.searchResults
        if results.isEmpty {
            Text("No matches")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, LKTokens.Spacing.s8)
        } else {
            List(results, id: \.self) { user in
                Button {
                    query = ""
                    Task { await viewModel.search(prefix: "") }
                    onSelect?(user)
                } label: {
                    Text(user)
                }
            }
            .listStyle(.plain)
        }
    }

    private func rowLabel(_ row: ChatSummary) -> some View {
        ChatRow(
            name: row.peer,
            preview: row.preview,
            timestamp: row.timestamp,
            unreadCount: row.unreadCount
        )
        .overlay(alignment: .topLeading) {
            PresenceDot(visible: row.online)
        }
    }
}

/// The presence dot pinned to the avatar's corner (spec 4.7 presence from
/// presence.changed); the avatar sits at the row's leading inset, 32x32.
private struct PresenceDot: View {
    let visible: Bool

    var body: some View {
        if visible {
            Circle()
                .fill(.green)
                .frame(width: LKTokens.Spacing.s8, height: LKTokens.Spacing.s8)
                .offset(x: LKTokens.Spacing.s32, y: LKTokens.Spacing.s24)
                .accessibilityLabel("Online")
        }
    }
}
