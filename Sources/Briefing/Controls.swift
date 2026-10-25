import AppKit
import SwiftUI

// MARK: - Underline

/// A one-pixel line under a text button, so "ADD" reads as something to press, not just a word.
struct Underline: View {
    var color: Color
    @Environment(\.displayScale) private var scale

    var body: some View {
        Rectangle()
            .fill(color)
            .frame(height: 1 / max(scale, 1))
            .accessibilityHidden(true)
    }
}

extension View {
    /// Draws a hairline under the view, `offset` points below its bottom edge.
    func underlined(_ color: Color, offset: CGFloat) -> some View {
        overlay(alignment: .bottomLeading) {
            Underline(color: color)
                .offset(y: offset)
        }
    }
}

enum Cursor {
    /// The pointing hand over anything clickable; the arrow again on the way out.
    static func hover(_ inside: Bool) {
        (inside ? NSCursor.pointingHand : NSCursor.arrow).set()
    }
}

/// Pressed: the label dims for as long as the click lasts.
struct PressDim: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.5 : 1)
    }
}

// MARK: - Buttons

/// Small capitals with a permanent underline: Add, Up, Down, Delete, "E — Write them".
/// Dim and quietly underlined at rest; ink, with the line in ink, under the cursor.
struct QuietButton: View {
    let title: String
    let s: CGFloat
    var size: CGFloat = 12
    let action: () -> Void

    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(title.uppercased(with: Theme.locale))
                .font(Theme.font(size * s))
                .tracking(1 * s)
                .foregroundStyle(hover ? Theme.ink : Theme.dim)
                .underlined(hover ? Theme.ink : Theme.dim.opacity(0.6), offset: 2 * s)
                .padding(.vertical, 4 * s)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressDim())
        .onHover { inside in
            hover = inside
            Cursor.hover(inside)
        }
        .animation(Curves.fade(0.4), value: hover)
    }
}

/// The key hints in the lower right ("E — Amend"). They are legends for the keyboard first,
/// so the underline only appears under the cursor — unless `underline` asks for it to stay.
struct HintButton: View {
    let title: String
    let color: Color
    let s: CGFloat
    var underline = false
    var size: CGFloat = 12
    let action: () -> Void

    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(title.uppercased(with: Theme.locale))
                .font(Theme.font(size * s))
                .tracking(size / 12 * s)
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(color)
                .underlined(color.opacity(hover ? 1 : (underline ? 0.6 : 0)), offset: 2 * s)
                .opacity(hover ? 0.7 : 1)
                .padding(.vertical, 14 * s)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressDim())
        .focusable(false)
        .onHover { inside in
            hover = inside
            Cursor.hover(inside)
        }
        .animation(Curves.fade(0.4), value: hover)
    }
}
