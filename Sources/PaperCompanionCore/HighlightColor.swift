import AppKit

public enum HighlightColor: String, CaseIterable, Sendable {
    case yellow, green, blue, pink, purple, orange

    // Fixed document colors: system colors adapt to appearance and their semantic
    // names (especially systemPink) do not describe familiar highlighter hues.
    public var nsColor: NSColor {
        switch self {
        case .yellow: return NSColor(srgbRed: 1, green: 0.88, blue: 0, alpha: 1)
        case .green: return NSColor(srgbRed: 0.2, green: 0.8, blue: 0.25, alpha: 1)
        case .blue: return NSColor(srgbRed: 0.15, green: 0.5, blue: 1, alpha: 1)
        case .pink: return NSColor(srgbRed: 1, green: 0.35, blue: 0.7, alpha: 1)
        case .purple: return NSColor(srgbRed: 0.65, green: 0.3, blue: 0.9, alpha: 1)
        case .orange: return NSColor(srgbRed: 1, green: 0.5, blue: 0.05, alpha: 1)
        }
    }
}
