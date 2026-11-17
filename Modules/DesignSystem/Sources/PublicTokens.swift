// Public token surface (Plan 4 Task 12): the generated `Tokens` enum is
// internal and byte-fixed (Scripts/check-tokens.sh), so consuming modules
// cannot reach it directly. This thin re-export is the only public way for
// feature views to lay out with the design tokens — no hard-coded values.
// Extend it alongside generate.py when new values are needed.

import SwiftUI

public enum LKTokens {
    public enum Spacing {
        public static let s4: CGFloat = Tokens.Spacing.s4
        public static let s8: CGFloat = Tokens.Spacing.s8
        public static let s12: CGFloat = Tokens.Spacing.s12
        public static let s16: CGFloat = Tokens.Spacing.s16
        public static let s24: CGFloat = Tokens.Spacing.s24
        public static let s32: CGFloat = Tokens.Spacing.s32
    }
}
