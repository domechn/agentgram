import SwiftUI

/// The look of the app: warm off-white canvas, white rounded surfaces, thin dividers.
/// Dark mode follows the system.
enum Theme {
    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    static let canvas = dynamic(light: NSColor(red: 0.975, green: 0.968, blue: 0.955, alpha: 1), dark: NSColor(white: 0.115, alpha: 1))
    static let sidebar = dynamic(light: NSColor(red: 0.955, green: 0.946, blue: 0.928, alpha: 1), dark: NSColor(white: 0.09, alpha: 1))
    static let surface = dynamic(light: .white, dark: NSColor(white: 0.18, alpha: 1))
    static let selected = dynamic(light: NSColor(white: 0, alpha: 0.065), dark: NSColor(white: 1, alpha: 0.11))
}

extension View {
    /// A white rounded surface with a soft shadow.
    func card(radius: CGFloat = 14) -> some View {
        background(Theme.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
    }
}
