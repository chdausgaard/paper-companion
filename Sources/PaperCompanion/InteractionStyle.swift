import AppKit
import SwiftUI

/// Shared look and motion for things the pointer acts on: annotation cards,
/// PDF highlights, and region markers later. The look stays native: system
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

/// Which annotation the pointer is on, shared by the PDF page and the cards so
/// each can light up the other. Annotations are keyed by their highlight
/// record's ID, so any kind drawn on the page under that ID takes part.
///
/// Not a published property of `AppState`: a change there re-renders the whole
/// window and rebuilds the sorted list, and hover changes many times a second.
/// Here each card observes only its own `Flag`, and the PDF side is told
/// through `cardHoverObserver`, so a change reaches only the two annotations
/// that gained and lost hover.
@MainActor
final class AnnotationHover {
    /// One card's share of the hover state.
    @MainActor
    final class Flag: ObservableObject {
        /// The pointer is on this annotation on the PDF page.
        @Published fileprivate(set) var isHoveredOnPage = false
    }

    /// How long the pointer must rest on a card before its highlight lights
    /// up on the page. Scrolling the list passes cards under a still pointer;
    /// without the wait the page would strobe.
    static var cardHoverDelay: TimeInterval = 0.12

    /// The annotation under the pointer on the PDF page.
    private(set) var pageHoveredID: UUID?
    /// The annotation whose card the pointer rests on, once the delay passed.
    private(set) var cardHoveredID: UUID?
    /// Told when `cardHoveredID` changes: the PDF reader's coordinator.
    weak var cardHoverObserver: AnnotationHoverObserver?

    private var flags: [UUID: Flag] = [:]
    /// The annotation whose flag is published as hovered.
    private var publishedPageID: UUID?
    private var flagSyncScheduled = false
    private var pendingCardID: UUID?
    private var cardHoverTask: Task<Void, Never>?

    /// The flag for one annotation's card. Flags are never dropped, so a card
    /// that is rebuilt finds the same one.
    func flag(for id: UUID) -> Flag {
        if let flag = flags[id] { return flag }
        let flag = Flag()
        flags[id] = flag
        return flag
    }

    /// The annotation under the pointer on the page. The cards' flags follow
    /// on the next turn of the run loop: this is also called from inside
    /// SwiftUI updates (a redraw of the page, a scroll during navigation),
    /// where publishing is not allowed. The flags then publish whatever is
    /// current at that moment, so a later change can never be undone by an
    /// earlier one.
    func setPageHovered(_ id: UUID?) {
        pageHoveredID = id
        guard !flagSyncScheduled else { return }
        flagSyncScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.flagSyncScheduled = false
            self.publishPageHover()
        }
    }

    private func publishPageHover() {
        guard publishedPageID != pageHoveredID else { return }
        if let old = publishedPageID { flags[old]?.isHoveredOnPage = false }
        publishedPageID = pageHoveredID
        if let id = pageHoveredID { flag(for: id).isHoveredOnPage = true }
    }

    /// A card gained or lost the pointer. Applied after `cardHoverDelay`, and
    /// only the last change within that time counts.
    func cardHoverChanged(_ id: UUID, isHovering: Bool) {
        if isHovering {
            pendingCardID = id
        } else if pendingCardID == id {
            pendingCardID = nil
        } else {
            // Leaving a card after the next one was entered: nothing to undo.
            return
        }
        cardHoverTask?.cancel()
        let delay = Self.cardHoverDelay
        cardHoverTask = Task { @MainActor [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard !Task.isCancelled, let self else { return }
            self.commitCardHover()
        }
    }

    /// A new document: nothing is hovered until the pointer is found on it
    /// again. Synchronous, so it cannot land after a newer hover.
    func reset() {
        setPageHovered(nil)
        cardHoverTask?.cancel()
        pendingCardID = nil
        cardHoveredID = nil
    }

    private func commitCardHover() {
        guard cardHoveredID != pendingCardID else { return }
        cardHoveredID = pendingCardID
        cardHoverObserver?.cardHoverDidChange()
    }
}

@MainActor
protocol AnnotationHoverObserver: AnyObject {
    func cardHoverDidChange()
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

private struct PointerOverridesKey: EnvironmentKey {
    static let defaultValue: [String: PointerState] = [:]
}

extension EnvironmentValues {
    /// Draws the surfaces with these keys (a Library row's paper path, an
    /// inspector tab's name) as hovered or pressed regardless of the real
    /// pointer, for the snapshot harness. `cardPointerOverrides` does the
    /// same for annotation cards.
    var pointerOverrides: [String: PointerState] {
        get { self[PointerOverridesKey.self] }
        set { self[PointerOverridesKey.self] = newValue }
    }
}

/// The background of a row that stands on its own, like a paper in the
/// Library: a faint fill at rest, lifted on hover (an opaque surface with a
/// soft offset shadow), pressed back down while the mouse is down. A row
/// that cannot do its job (the PDF is missing) never lifts: a faint fill on
/// hover says it still answers a click, with an explanation.
struct RowSurfaceBackground: View {
    var pointer: PointerState
    var isAvailable = true
    var cornerRadius: CGFloat = 10
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let dark = colorScheme == .dark
        let lifted = pointer == .hovered && isAvailable
        ZStack {
            if lifted {
                // Light: the white control surface. Dark: a lighter gray, since
                // the dark control surface is darker than the window and would
                // read as sunk.
                shape
                    .fill(dark ? Color.white.opacity(0.1) : Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(dark ? 0.4 : 0.11), radius: 6, x: 0, y: 2)
            } else {
                shape.fill(Color.primary.opacity(restingFill(dark: dark)))
            }
            shape.strokeBorder(Color.primary.opacity(lifted ? (dark ? 0.12 : 0.07) : 0), lineWidth: 1)
        }
    }

    private func restingFill(dark: Bool) -> Double {
        switch pointer {
        case .idle: return dark ? 0.05 : 0.035
        case .hovered: return dark ? 0.08 : 0.06
        case .pressed: return dark ? 0.13 : 0.09
        }
    }
}

/// A borderless control that is a whole area (a disclosure header, the
/// session path): no fill at rest, a faint one on hover, a firmer one while
/// pressed, like the icon buttons and the cards.
struct SurfaceButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 6
    /// A key into `pointerOverrides`, for the snapshot harness.
    var overrideKey: String?

    func makeBody(configuration: Configuration) -> some View {
        SurfaceButtonBody(configuration: configuration, cornerRadius: cornerRadius, overrideKey: overrideKey)
    }

    private struct SurfaceButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let cornerRadius: CGFloat
        let overrideKey: String?
        @State private var hovering = false
        @Environment(\.pointerOverrides) private var overrides
        @Environment(\.colorScheme) private var colorScheme

        private var pointer: PointerState {
            if let key = overrideKey, let forced = overrides[key] { return forced }
            if configuration.isPressed { return .pressed }
            return hovering ? .hovered : .idle
        }

        var body: some View {
            let dark = colorScheme == .dark
            configuration.label
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.primary.opacity(pointer == .pressed ? (dark ? 0.13 : 0.09) : pointer == .hovered ? (dark ? 0.08 : 0.05) : 0))
                )
                .environment(\.surfacePointer, pointer)
                .onHover { hovering = $0 }
                .animation(InteractionStyle.hover, value: pointer)
        }
    }
}

private struct SurfacePointerKey: EnvironmentKey {
    static let defaultValue = PointerState.idle
}

extension EnvironmentValues {
    /// The pointer state of the enclosing `SurfaceButtonStyle` button, so its
    /// label can show a detail (a copy glyph) only on hover.
    var surfacePointer: PointerState {
        get { self[SurfacePointerKey.self] }
        set { self[SurfacePointerKey.self] = newValue }
    }
}

/// A hover look for the system's bordered buttons, which have none on macOS:
/// the button brightens a little under the pointer, as a pressed one darkens.
struct ButtonHoverHighlight: ViewModifier {
    @State private var hovering = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content
            .brightness(hovering && isEnabled ? (colorScheme == .dark ? 0.07 : -0.035) : 0)
            .onHover { hovering = $0 }
            .animation(InteractionStyle.hover, value: hovering)
    }
}

extension View {
    func hoverHighlight() -> some View { modifier(ButtonHoverHighlight()) }
}

/// A read-only block of text set into the surface around it (the agent's
/// previews): a slightly darker well with a hairline edge.
struct InsetPanelBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        let dark = colorScheme == .dark
        ZStack {
            shape.fill(Color.black.opacity(dark ? 0.2 : 0.035))
            shape.strokeBorder(Color.primary.opacity(dark ? 0.1 : 0.08), lineWidth: 1)
        }
    }
}

/// A disclosure section whose whole header row is the toggle, with the hover
/// and pressed look of `SurfaceButtonStyle`. The chevron turns and the
/// content fades in; Reduce Motion drops the turn and the height animation.
struct HoverDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverDisclosureBody(configuration: configuration)
    }

    private struct HoverDisclosureBody: View {
        let configuration: DisclosureGroupStyleConfiguration
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    withAnimation(InteractionStyle.expand(reduceMotion: reduceMotion)) {
                        configuration.isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                            .frame(width: 12)
                        configuration.label
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                }
                .buttonStyle(SurfaceButtonStyle())
                // The hover fill reaches past the text column; the chevron
                // stays aligned with the text above and below.
                .padding(.horizontal, -6)
                // SwiftUI still announces the section as a disclosure with its
                // expanded state, as it does for the system style.

                if configuration.isExpanded {
                    configuration.content
                        .transition(.opacity)
                }
            }
        }
    }
}

/// The frame of a multi-line text box (the comment box, the notes): a
/// hairline edge at rest, the system's focus ring outside it while it has the
/// keyboard, and a placeholder while it is empty. The placeholder sits where
/// the first line of text starts.
struct TextBoxChrome: ViewModifier {
    var isFocused: Bool
    /// Shown while the box is empty; nil when it has text.
    var placeholder: String?
    var textInset: NSSize

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topLeading) {
                if let placeholder {
                    Text(placeholder)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        // NSTextView pads each line by 5 pt.
                        .padding(.leading, textInset.width + 5)
                        .padding(.top, textInset.height)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.primary.opacity(isFocused ? 0 : 0.15), lineWidth: 1)
            )
            .overlay(
                // The focus ring sits outside the box, like the system's.
                RoundedRectangle(cornerRadius: 8.5, style: .continuous)
                    .strokeBorder(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: 3)
                    .padding(-2.5)
                    .opacity(isFocused ? 1 : 0)
                    .allowsHitTesting(false)
            )
            .animation(InteractionStyle.hover, value: isFocused)
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
