import SwiftUI

/// Colours of the CK.VPN panel.
enum Theme {
    static let bg = Color(hex: 0x0B1120)
    static let card = Color(hex: 0x111827)
    static let border = Color(hex: 0x1F2937)
    static let input = Color(hex: 0x080C17)
    static let text = Color(hex: 0xF3F4F6)
    static let muted = Color(hex: 0x9CA3AF)
    static let primary = Color(hex: 0x06B6D4)
    static let ok = Color(hex: 0x10B981)
    static let error = Color(hex: 0xEF4444)
    static let warn = Color(hex: 0xF59E0B)
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card)
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.border))
            .clipShape(RoundedRectangle(cornerRadius: 18))
    }
}

struct BigButtonStyle: ButtonStyle {
    var color: Color
    var foreground: Color = .white
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(color.opacity(configuration.isPressed ? 0.8 : 1))
            .foregroundColor(foreground)
            .clipShape(RoundedRectangle(cornerRadius: 15))
    }
}

func formatBytes(_ n: Int64) -> String {
    let units = ["B", "KB", "MB", "GB", "TB"]
    var v = Double(n), i = 0
    while v >= 1024 && i < units.count - 1 { v /= 1024; i += 1 }
    return i == 0 ? "\(n) B" : String(format: "%.1f %@", v, units[i])
}
