// ConversationView (Plan 4 Task 12): the thin conversation — DesignSystem
// MessageBubble / FileBubble / ReceiptLabel rows, a send bar and the
// offline banner. All state lives in ConversationViewModel; the view only
// maps it.

import DesignSystem
import FileTransfer
import SwiftUI

public struct ConversationView: View {
    @State private var viewModel: ConversationViewModel

    public init(viewModel: ConversationViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    public var body: some View {
        VStack(spacing: LKTokens.Spacing.s8) {
            if viewModel.showOfflineBanner {
                Banner(message: "Offline — messages send when you are back")
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: LKTokens.Spacing.s12) {
                    ForEach(viewModel.rows) { row in
                        rowView(row)
                    }
                }
                .padding(LKTokens.Spacing.s16)
            }
            sendBar
        }
        .task {
            viewModel.start()
            await viewModel.refresh()
            await viewModel.markOpened()
        }
        .onDisappear {
            viewModel.stop()
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
