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
    static let hover = dynamic(light: NSColor(white: 0, alpha: 0.035), dark: NSColor(white: 1, alpha: 0.06))
}

extension View {
    /// A white rounded surface with a soft shadow.
    func card(radius: CGFloat = 14) -> some View {
        background(Theme.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
    }
}

/// Row background: selected, hovered, or none.
private struct RowHighlight: ViewModifier {
    let selected: Bool
    let radius: CGFloat
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(selected ? Theme.selected : hovering ? Theme.hover : Color.clear,
                        in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

extension View {
    func rowHighlight(selected: Bool = false, radius: CGFloat = 9) -> some View {
        modifier(RowHighlight(selected: selected, radius: radius))
    }
}

/// Header of a full-width section (Board, Library, Schedules).
struct SectionHeader<Trailing: View>: View {
    let title: String
    let trailing: Trailing

    init(title: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(title).font(.title2.weight(.semibold))
            trailing
        }
        .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 8)
    }
}

/// An error with a way out, for a section that could not load.
struct ErrorBanner: View {
    let text: String
    var symbol = "exclamationmark.triangle.fill"
    var action = "Retry"
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.orange)
            Text(text).font(.callout).lineLimit(3).textSelection(.enabled)
            Spacer(minLength: 8)
            Button(action, action: retry).controlSize(.small)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Grey placeholder rows while a list loads for the first time.
struct SkeletonRows: View {
    var count = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(0..<count, id: \.self) { i in
                VStack(alignment: .leading, spacing: 5) {
                    RoundedRectangle(cornerRadius: 4).fill(.quaternary).frame(width: CGFloat(180 + (i * 53) % 140), height: 11)
                    RoundedRectangle(cornerRadius: 4).fill(.quaternary.opacity(0.6)).frame(width: CGFloat(120 + (i * 37) % 90), height: 9)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel("Loading")
    }
}

func stamp(_ seconds: Double?) -> String {
    guard let seconds, seconds > 0 else { return "—" }
    let date = Date(timeIntervalSince1970: seconds)
    return date.formatted(date: Calendar.current.isDateInToday(date) ? .omitted : .abbreviated, time: .shortened)
}
