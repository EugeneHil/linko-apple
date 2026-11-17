// ConversationKey (Plan 4 Task 6): the conversation identifier both peers
// and the server agree on — lexicographic min + '\u{1f}' + max, exactly
// linko-server's conversationKey (src/store.cpp) so receipts and syncs land
// on the same conversation on both sides.

import Foundation

public enum ConversationKey {
    public static func key(_ a: String, _ b: String) -> String {
        a < b ? a + "\u{1F}" + b : b + "\u{1F}" + a
    }
}
