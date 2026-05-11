import AppKit
import SwiftUI

struct ProjectFileEditorTheme: Equatable {
    var colorScheme: ColorScheme
    var foreground: String
    var background: String
    var caret: String
    var selectionBackground: String
    var palette: [String]
    var fontSize: Int

    init(
        colorScheme: ColorScheme = .light,
        foreground: String = "#24292F",
        background: String = "#FFFFFF",
        caret: String = "#24292F",
        selectionBackground: String = "#0969DA33",
        palette: [String] = [],
        fontSize: Int = 14
    ) {
        self.colorScheme = colorScheme
        self.foreground = foreground
        self.background = background
        self.caret = caret
        self.selectionBackground = selectionBackground
        self.palette = palette
        self.fontSize = Self.normalizedFontSize(fontSize)
    }

    init(appearance: AppEffectiveTerminalAppearance, fontSize: Int = 14) {
        self.init(
            colorScheme: appearance.isLight ? .light : .dark,
            foreground: appearance.foregroundColor.ghosttyHexString,
            background: appearance.backgroundColor.ghosttyHexString,
            caret: appearance.cursorColor.ghosttyHexString,
            selectionBackground: appearance.selectionBackgroundColor.ghosttyHexString,
            palette: appearance.paletteHexStrings,
            fontSize: fontSize
        )
    }

    var nsBackgroundColor: NSColor {
        Self.nsColor(hexString: background, fallback: .textBackgroundColor)
    }

    private static func normalizedFontSize(_ value: Int) -> Int {
        max(10, min(28, value))
    }

    static func nsColor(hexString: String, fallback: NSColor) -> NSColor {
        let cleaned = hexString.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard cleaned.count == 6,
              let value = UInt64(cleaned, radix: 16) else {
            return fallback
        }
        let red = CGFloat((value & 0xFF0000) >> 16) / 255.0
        let green = CGFloat((value & 0x00FF00) >> 8) / 255.0
        let blue = CGFloat(value & 0x0000FF) / 255.0
        return NSColor(red: red, green: green, blue: blue, alpha: 1)
    }
}
