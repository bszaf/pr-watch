import SwiftUI
import AppKit

extension View {
    /// Shows the pointing-hand cursor while hovering (for buttons that open a project,
    /// worktree, or URL).
    func linkCursor() -> some View { modifier(LinkCursor()) }
}

private struct LinkCursor: ViewModifier {
    func body(content: Content) -> some View {
        content.onHover { hovering in
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}
