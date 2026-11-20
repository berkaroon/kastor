import AppKit
import SwiftUI

enum KastorTheme {
    // Approved 2-tone palette: #EEEAF6 (Lavender-Parchment) & #1B132B (Deep Indigo-Plum)
    static let lavenderHex = "#EEEAF6"
    static let indigoHex = "#1B132B"

    static let lavenderParchment = Color(red: 238.0 / 255.0, green: 234.0 / 255.0, blue: 246.0 / 255.0)
    static let indigoPlum = Color(red: 27.0 / 255.0, green: 19.0 / 255.0, blue: 43.0 / 255.0)
    static let plumAccent = Color(red: 92.0 / 255.0, green: 61.0 / 255.0, blue: 148.0 / 255.0)

    static let surface = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 27.0 / 255.0, green: 19.0 / 255.0, blue: 43.0 / 255.0, alpha: 1.0)
            : NSColor(srgbRed: 238.0 / 255.0, green: 234.0 / 255.0, blue: 246.0 / 255.0, alpha: 1.0)
    })

    static let cardSurface = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 39.0 / 255.0, green: 29.0 / 255.0, blue: 60.0 / 255.0, alpha: 1.0)
            : NSColor(srgbRed: 248.0 / 255.0, green: 246.0 / 255.0, blue: 252.0 / 255.0, alpha: 1.0)
    })

    static let ink = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 238.0 / 255.0, green: 234.0 / 255.0, blue: 246.0 / 255.0, alpha: 1.0)
            : NSColor(srgbRed: 27.0 / 255.0, green: 19.0 / 255.0, blue: 43.0 / 255.0, alpha: 1.0)
    })

    static let secondaryInk = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 238.0 / 255.0, green: 234.0 / 255.0, blue: 246.0 / 255.0, alpha: 0.65)
            : NSColor(srgbRed: 27.0 / 255.0, green: 19.0 / 255.0, blue: 43.0 / 255.0, alpha: 0.62)
    })

    static let divider = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 238.0 / 255.0, green: 234.0 / 255.0, blue: 246.0 / 255.0, alpha: 0.14)
            : NSColor(srgbRed: 27.0 / 255.0, green: 19.0 / 255.0, blue: 43.0 / 255.0, alpha: 0.12)
    })

    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 184.0 / 255.0, green: 164.0 / 255.0, blue: 232.0 / 255.0, alpha: 1.0)
            : NSColor(srgbRed: 84.0 / 255.0, green: 54.0 / 255.0, blue: 140.0 / 255.0, alpha: 1.0)
    })

    static let selectedFill = accent.opacity(0.18)
    static let hoverFill = ink.opacity(0.08)
    static let pinnedFill = accent.opacity(0.06)
}
