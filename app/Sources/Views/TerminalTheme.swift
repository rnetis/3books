import SwiftUI

/// Dark-terminal look: near-black background, phosphor green/red, monospaced.
enum TerminalTheme {
    static let background = Color(red: 0.04, green: 0.05, blue: 0.05)
    static let panel = Color(red: 0.08, green: 0.10, blue: 0.10)
    static let grid = Color(red: 0.15, green: 0.18, blue: 0.18)
    static let green = Color(red: 0.20, green: 0.95, blue: 0.55)
    static let red = Color(red: 1.00, green: 0.32, blue: 0.33)
    static let amber = Color(red: 1.00, green: 0.78, blue: 0.30)
    static let dim = Color.secondary

    static func directionColor(_ d: TradeDirection) -> Color {
        switch d {
        case .long: return green
        case .short: return red
        case .neutral: return amber
        }
    }

    static func scoreColor(_ score: Int) -> Color {
        switch score {
        case ..<40: return dim
        case 40..<60: return amber
        default: return green
        }
    }
}

extension View {
    func terminalCard() -> some View {
        padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(TerminalTheme.panel))
    }

    func mono() -> some View {
        font(.system(.caption, design: .monospaced))
    }
}
