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

    public init(viewModel: ChatsViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: LKTokens.Spacing.s8) {
                if viewModel.showOfflineBanner {
                    Banner(message: "Offline — messages send when you are back")
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
