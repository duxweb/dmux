import AppKit
import Foundation

enum AppBackgroundColorPreset: String, Codable, CaseIterable, Identifiable {
    case automatic
    case black
    case base950
    case base900
    case base850
    case base800
    case base700
    case base600
    case paper
    case red600
    case orange600
    case yellow600
    case green600
    case cyan600
    case blue600
    case purple600
    case magenta600
    case red400
    case orange400
    case yellow400
    case green400
    case cyan400
    case blue400
    case purple400
    case magenta400

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic:   return "Auto"
        case .black:       return "Black"
        case .base950:     return "Ink"
        case .base900:     return "Charcoal"
        case .base850:     return "Graphite"
        case .base800:     return "Slate"
        case .base700:     return "Stone"
        case .base600:     return "Ash"
        case .paper:       return "Paper"
        case .red600:      return "Crimson"
        case .orange600:   return "Burnt"
        case .yellow600:   return "Amber"
        case .green600:    return "Moss"
        case .cyan600:     return "Teal"
        case .blue600:     return "Navy"
        case .purple600:   return "Iris"
        case .magenta600:  return "Plum"
        case .red400:      return "Red"
        case .orange400:   return "Orange"
        case .yellow400:   return "Gold"
        case .green400:    return "Sage"
        case .cyan400:     return "Cyan"
        case .blue400:     return "Blue"
        case .purple400:   return "Lavender"
        case .magenta400:  return "Rose"
        }
    }

    var swatchColor: NSColor? {
        switch self {
        case .automatic:
            return nil
        case .black:
            return .dmuxHex(0x100F0F)
        case .base950:
            return .dmuxHex(0x1C1B1A)
        case .base900:
            return .dmuxHex(0x282726)
        case .base850:
            return .dmuxHex(0x343331)
        case .base800:
            return .dmuxHex(0x403E3C)
        case .base700:
            return .dmuxHex(0x575653)
        case .base600:
            return .dmuxHex(0x878580)
        case .paper:
            return .dmuxHex(0xFFFCF0)
        case .red600:
            return .dmuxHex(0xAF3029)
        case .orange600:
            return .dmuxHex(0xBC5215)
        case .yellow600:
            return .dmuxHex(0xAD8301)
        case .green600:
            return .dmuxHex(0x66800B)
        case .cyan600:
            return .dmuxHex(0x24837B)
        case .blue600:
            return .dmuxHex(0x205EA6)
        case .purple600:
            return .dmuxHex(0x5E409D)
        case .magenta600:
            return .dmuxHex(0xA02F6F)
        case .red400:
            return .dmuxHex(0xD14D41)
        case .orange400:
            return .dmuxHex(0xDA702C)
        case .yellow400:
            return .dmuxHex(0xD0A215)
        case .green400:
            return .dmuxHex(0x879A39)
        case .cyan400:
            return .dmuxHex(0x3AA99F)
        case .blue400:
            return .dmuxHex(0x4385BE)
        case .purple400:
            return .dmuxHex(0x8B7EC8)
        case .magenta400:
            return .dmuxHex(0xCE5D97)
        }
    }

    var isAutomatic: Bool {
        self == .automatic
    }

    var isLight: Bool {
        guard let swatchColor else {
            return false
        }
        return swatchColor.dmuxPerceivedBrightness >= 0.72
    }
}

extension NSColor {
    var dmuxPerceivedBrightness: CGFloat {
        let resolved = usingColorSpace(.deviceRGB) ?? self
        return (resolved.redComponent * 0.299) + (resolved.greenComponent * 0.587) + (resolved.blueComponent * 0.114)
    }
}

enum AppIconStyle: String, Codable, CaseIterable, Identifiable {
    case `default`
    case cobalt
    case sunset
    case forest

    var id: String { rawValue }

    var title: String {
        switch self {
        case .default: return String(localized: "settings.app_icon.option.default", defaultValue: "Default", bundle: .module)
        case .cobalt: return String(localized: "settings.app_icon.option.cobalt", defaultValue: "Cobalt", bundle: .module)
        case .sunset: return String(localized: "settings.app_icon.option.sunset", defaultValue: "Sunset", bundle: .module)
        case .forest: return String(localized: "settings.app_icon.option.forest", defaultValue: "Forest", bundle: .module)
        }
    }

    var iconFill: (top: NSColor, bottom: NSColor) {
        switch self {
        case .default:
            return (
                NSColor(calibratedRed: 0.24, green: 0.50, blue: 0.98, alpha: 1),
                NSColor(calibratedRed: 0.16, green: 0.36, blue: 0.86, alpha: 1)
            )
        case .cobalt:
            return (
                NSColor(calibratedRed: 0.12, green: 0.14, blue: 0.20, alpha: 1),
                NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.13, alpha: 1)
            )
        case .sunset:
            return (
                NSColor(calibratedRed: 0.96, green: 0.42, blue: 0.32, alpha: 1),
                NSColor(calibratedRed: 0.88, green: 0.30, blue: 0.26, alpha: 1)
            )
        case .forest:
            return (
                NSColor(calibratedRed: 0.18, green: 0.62, blue: 0.45, alpha: 1),
                NSColor(calibratedRed: 0.12, green: 0.50, blue: 0.36, alpha: 1)
            )
        }
    }
}

enum AppTerminalProfile: String, Codable, CaseIterable, Identifiable {
    case zsh
    case bash
    case sh
    case fish

    var id: String { rawValue }

    var title: String {
        switch self {
        case .zsh: return "zsh"
        case .bash: return "bash"
        case .sh: return "sh"
        case .fish: return "fish"
        }
    }

    var shellPath: String {
        switch self {
        case .zsh: return "/bin/zsh"
        case .bash: return "/bin/bash"
        case .sh: return "/bin/sh"
        case .fish: return "/opt/homebrew/bin/fish"
        }
    }

    static var available: [AppTerminalProfile] {
        let fileManager = FileManager.default
        return allCases.filter { fileManager.fileExists(atPath: $0.shellPath) }
    }

    static var allShellPaths: Set<String> {
        Set(allCases.map(\.shellPath))
    }
}
