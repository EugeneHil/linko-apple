// ConversationView (Plan 4 Task 12): the thin conversation — DesignSystem
// MessageBubble / FileBubble / ReceiptLabel rows, a send bar and the
// offline banner, scrolled to the newest message (the rehearsal's 6th
// finding). All state lives in ConversationViewModel; the view only
// maps it.

import DesignSystem
import FileTransfer
import SwiftUI

public struct ConversationView: View {
    @State private var viewModel: ConversationViewModel
    /// The newest row the view scrolled to. Rows are rebuilt on EVERY
    /// messaging event (receipt label flips included) — scrolling on each
    /// rebuild would yank the reader away from history; only a NEW newest
    /// row (a message just sent or delivered) scrolls.
    @State private var lastScrolledRowID: String?

    public init(viewModel: ConversationViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    public var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: LKTokens.Spacing.s8) {
                if viewModel.showOfflineBanner {
                    Banner(message: "Offline — messages send when you are back")
                }
                ScrollView {
                    // A plain VStack, NOT LazyVStack: scrollTo cannot reach
                    // rows the lazy layout has not rendered (it misses
                    // silently — the rehearsal's 6th finding's first fix
                    // did exactly that). v0.1 histories are small; revisit
                    // laziness only if they grow.
                    VStack(alignment: .leading, spacing: LKTokens.Spacing.s12) {
                        ForEach(viewModel.rows) { row in
                            rowView(row)
                                .id(row.id)
                        }
                    }
                    .padding(LKTokens.Spacing.s16)
                }
                // Open at the newest message even before the first
                // programmatic scroll lands.
                .defaultScrollAnchor(.bottom)
                sendBar
            }
            .task {
                viewModel.start()
                await viewModel.refresh()
                await viewModel.markOpened()
                scrollToNewest(rows: viewModel.rows, proxy: proxy)
            }
            .onChange(of: viewModel.rows) { _, rows in
                scrollToNewest(rows: rows, proxy: proxy)
            }
            .onDisappear {
                viewModel.stop()
            }
        }
    }

    private func scrollToNewest(rows: [ConversationRow], proxy: ScrollViewProxy) {
        guard let lastID = rows.last?.id, lastID != lastScrolledRowID else { return }
        lastScrolledRowID = lastID
        // The scroll must run AFTER the new row's layout pass: calling it
        // inside the same transaction as the rows change reads a frame
        // that does not exist yet and silently no-ops.
        DispatchQueue.main.async {
            proxy.scrollTo(lastID, anchor: .bottom)
        }
    }

    private var sendBar: some View {
        HStack(spacing: LKTokens.Spacing.s8) {
            TextField("Message", text: $viewModel.draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
            LKButton(title: "Send") {
                Task { await viewModel.send() }
            }
        }
        .padding(LKTokens.Spacing.s12)
    }

    private func rowView(_ row: ConversationRow) -> some View {
        VStack(alignment: row.outgoing ? .trailing : .leading, spacing: LKTokens.Spacing.s4) {
            if let file = row.file {
                FileBubble(
                    fileName: file.name,
                    sizeText: ByteCountFormatter().string(fromByteCount: file.size),
                    progress: viewModel.progress(for: file.fileId),
                    transport: FileBubble.Transport(transport: file.transport)
                )
            } else {
                MessageBubble(
                    text: row.text ?? "",
                    timestamp: row.timestamp,
                    outgoing: row.outgoing
                )
            }
            if let receipt = row.receipt {
                ReceiptLabel(
                    state: ReceiptLabel.State(receipt: receipt),
                    timestamp: receipt.timestamp
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: row.outgoing ? .trailing : .leading)
    }
}

extension FileBubble.Transport {
    /// Maps the wire's transport string ("p2p"/"server") onto the bubble.
    init(transport: String) {
        self = transport == "p2p" ? .peerToPeer : .server
    }
}

extension ReceiptLabel.State {
    /// Maps the row's receipt onto the label's states.
    init(receipt: ConversationReceipt) {
        if receipt.read {
            self = .read
        } else if receipt.delivered {
            self = .delivered
        } else {
            self = .sent
        }
    }
}
