import AppKit
import SwiftUI

/// Shared look and motion for things the pointer acts on: annotation cards
/// now, PDF highlights and region markers later. The look stays native: system
/// colors only, and depth from a fill, a hairline and a soft shadow rather than
/// from a theme.
enum InteractionStyle {
    static let cornerRadius: CGFloat = 8

    /// Hover and press: a short ease, which Reduce Motion keeps because it is
    /// a fade, not movement.
    static let hover = Animation.easeOut(duration: 0.15)

    /// Expanding and collapsing a card. Reduce Motion gets no animation:
    /// a change of height is movement.
    static func expand(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.86)
    }
}

/// Where the pointer is relative to an interactive surface.
enum PointerState: Equatable {
    case idle, hovered, pressed
}

/// The background of a card: clear at rest, a faint fill on hover, a firmer
/// one while pressed, and lifted when selected (opaque fill tinted with the
/// accent, a hairline accent outline and a soft offset shadow).
struct InteractiveSurfaceBackground: View {
    var pointer: PointerState
    var isSelected: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: InteractionStyle.cornerRadius, style: .continuous)
        ZStack {
            if isSelected {
                shape
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0.45 : 0.13), radius: 5, x: 0, y: 2)
                shape.fill(Color.accentColor.opacity(selectedTint))
                shape.strokeBorder(Color.accentColor.opacity(colorScheme == .dark ? 0.7 : 0.55), lineWidth: 1)
            } else {
                shape.fill(Color.primary.opacity(restingFill))
            }
        }
    }

    private var restingFill: Double {
        let dark = colorScheme == .dark
        switch pointer {
        case .idle: return 0
        case .hovered: return dark ? 0.07 : 0.05
        case .pressed: return dark ? 0.12 : 0.09
        }
    }

    private var selectedTint: Double {
        switch pointer {
        case .idle: return 0.10
        case .hovered: return 0.13
        case .pressed: return 0.17
        }
    }
}

/// Small borderless icon buttons (edit, delete) with a hover and a pressed
/// look, so they answer the pointer like the card around them does.
struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        IconButtonBody(configuration: configuration)
    }

    private struct IconButtonBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: 12))
                .foregroundStyle(hovering && isEnabled ? .primary : .secondary)
                .frame(width: 22, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.14 : hovering ? 0.08 : 0))
                )
                .contentShape(Rectangle())
                .opacity(isEnabled ? 1 : 0.4)
                .onHover { hovering = $0 }
                .animation(InteractionStyle.hover, value: hovering)
        }
    }
}

/// Puts the keyboard in a view when a pending focus request is granted to it.
@MainActor
enum KeyboardFocus {
    /// Whether the main mouse button is down. A test can replace it.
    static var mouseIsDown: () -> Bool = { NSEvent.pressedMouseButtons & 1 != 0 }
    static var pollInterval: UInt64 = 50_000_000
    /// How long to wait for the mouse to come up: the life of a request.
    static var maxPolls: Int { Int(AppState.focusRequestLifetime * 1_000_000_000 / Double(pollInterval)) }

    /// Claims the request with `take` when the view can take focus now, then
    /// hands the keyboard over once the mouse is up, if `isCurrent` still
    /// holds at that moment.
    static func takeIfRequested(
        _ view: NSView,
        take: () -> UUID?,
        isCurrent: @escaping @MainActor (UUID) -> Bool
    ) {
        guard canFocus(view), let id = take() else { return }
        focus(view, poll: 0) { isCurrent(id) }
    }

    /// In a window that is key (or no window is key, as in tests), and shown.
    private static func canFocus(_ view: NSView) -> Bool {
        guard let window = view.window, !view.isHiddenOrHasHiddenAncestor else { return false }
        return window.isKeyWindow || NSApplication.shared.keyWindow == nil
    }

    /// Asynchronous, so it never runs inside a SwiftUI view update. Waits
    /// while the mouse button is down: auto-highlight can fire during a pause
    /// in a drag, and focus must not move mid-gesture. Gives up if the button
    /// is still down when the request's life runs out, and checks everything
    /// again just before focusing, so a stale request never takes the keyboard.
    private static func focus(_ view: NSView, poll: Int, isCurrent: @escaping @MainActor () -> Bool) {
        Task { @MainActor in
            if poll > 0 { try? await Task.sleep(nanoseconds: pollInterval) }
            if mouseIsDown() {
                if poll < maxPolls { focus(view, poll: poll + 1, isCurrent: isCurrent) }
                return
            }
            guard canFocus(view), isCurrent(), let window = view.window, window.firstResponder !== view else { return }
            window.makeFirstResponder(view)
        }
    }
}
