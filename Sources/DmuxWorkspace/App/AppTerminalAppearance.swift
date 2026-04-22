import AppKit
import Foundation
import SwiftUI

struct AppTerminalThemeDefinition {
    let localizationKey: String
    let fallbackTitle: String
    let backgroundHex: UInt
    let foregroundHex: UInt
    let cursorHex: UInt
    let cursorTextHex: UInt
    let selectionBackgroundHex: UInt
    let selectionForegroundHex: UInt
    let paletteHexes: [UInt]
    let isLight: Bool

    var backgroundColor: NSColor { .dmuxHex(backgroundHex) }
    var foregroundColor: NSColor { .dmuxHex(foregroundHex) }
    var cursorColor: NSColor { .dmuxHex(cursorHex) }
    var cursorTextColor: NSColor { .dmuxHex(cursorTextHex) }
    var selectionBackgroundColor: NSColor { .dmuxHex(selectionBackgroundHex) }
    var selectionForegroundColor: NSColor { .dmuxHex(selectionForegroundHex) }
    var paletteHexStrings: [String] { paletteHexes.map { String(format: "#%06X", $0) } }
    var minimumContrast: Double { isLight ? 1.05 : 1.0 }
}

struct AppEffectiveTerminalAppearance {
    let backgroundColor: NSColor
    let foregroundColor: NSColor
    let cursorColor: NSColor
    let cursorTextColor: NSColor
    let selectionBackgroundColor: NSColor
    let selectionForegroundColor: NSColor
    let paletteHexStrings: [String]
    let isLight: Bool
    let minimumContrast: Double

    var mutedForegroundColor: NSColor {
        foregroundColor.blended(
            withFraction: isLight ? 0.42 : 0.36,
            of: backgroundColor
        ) ?? foregroundColor.withAlphaComponent(isLight ? 0.58 : 0.74)
    }

    var dividerColor: NSColor {
        isLight
            ? NSColor.black.withAlphaComponent(0.12)
            : NSColor.white.withAlphaComponent(0.14)
    }

    var inactiveDimOpacity: CGFloat {
        isLight ? 0.07 : 0.22
    }

    var inactiveDimColor: NSColor {
        NSColor.black.withAlphaComponent(inactiveDimOpacity)
    }

    var inactiveBackgroundColor: NSColor {
        backgroundColor.blended(withFraction: inactiveDimOpacity, of: .black) ?? backgroundColor
    }

    func windowGlassTintColor(forDarkAppearance isDarkAppearance: Bool) -> NSColor {
        let base = backgroundColor.usingColorSpace(.extendedSRGB) ?? backgroundColor
        let blended: NSColor

        if isDarkAppearance {
            let fraction: CGFloat = isLight ? 0.58 : 0.18
            blended = base.blended(withFraction: fraction, of: .black) ?? base
            return blended.withAlphaComponent(isLight ? 0.34 : 0.46)
        }

        let fraction: CGFloat = isLight ? 0.10 : 0.78
        blended = base.blended(withFraction: fraction, of: .white) ?? base
        return blended.withAlphaComponent(isLight ? 0.68 : 0.78)
    }
}

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

enum AppTerminalBackgroundPreset: String, Codable, CaseIterable, Identifiable {
    case automatic
    case catppuccinMocha
    case catppuccinLatte
    case dracula
    case flexokiDark
    case flexokiLight
    case gruvboxDark
    case gruvboxLight
    case tokyoNight
    case nord
    case githubDark
    case rosePine
    case rosePineDawn
    case nightOwl
    case kanagawaWave
    case kanagawaLotus
    case everforestDarkHard
    case githubLight
    case ayuLight
    case draculaPlus
    case rosePineMoon
    case tokyoNightStorm
    case materialOcean
    case gruvboxMaterialDark
    case gruvboxMaterialLight
    case atomOneLight
    case nordLight
    case ayuMirage

    private static let legacyMappings: [String: Self] = [
        "auto": .automatic,
        "obsidian": .flexokiDark,
        "graphite": .githubDark,
        "midnight": .tokyoNight,
        "forest": .gruvboxDark,
        "paper": .flexokiLight,
        "sand": .gruvboxLight,
        "mist": .catppuccinLatte,
        "dawn": .catppuccinLatte,
    ]

    var id: String { rawValue }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        if let preset = Self(rawValue: rawValue) ?? Self.legacyMappings[rawValue] {
            self = preset
        } else {
            self = .automatic
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var title: String {
        // Theme names are proper nouns — always display in English.
        if isAutomatic { return "Auto" }
        return definition.fallbackTitle
    }

    var isAutomatic: Bool {
        self == .automatic
    }

    private static let catalog: [Self: AppTerminalThemeDefinition] = [
        .catppuccinMocha: theme(
            localizationKey: "settings.terminal_theme.preset.catppuccin_mocha",
            fallbackTitle: "Catppuccin Mocha",
            backgroundHex: 0x1E1E2E,
            foregroundHex: 0xCDD6F4,
            cursorHex: 0xF5E0DC,
            cursorTextHex: 0x1E1E2E,
            selectionBackgroundHex: 0x585B70,
            selectionForegroundHex: 0xCDD6F4,
            paletteHexes: [
                0x45475A, 0xF38BA8, 0xA6E3A1, 0xF9E2AF,
                0x89B4FA, 0xF5C2E7, 0x94E2D5, 0xA6ADC8,
                0x585B70, 0xF37799, 0x89D88B, 0xEBD391,
                0x74A8FC, 0xF2AEDE, 0x6BD7CA, 0xBAC2DE,
            ],
            isLight: false
        ),
        .catppuccinLatte: theme(
            localizationKey: "settings.terminal_theme.preset.catppuccin_latte",
            fallbackTitle: "Catppuccin Latte",
            backgroundHex: 0xEFF1F5,
            foregroundHex: 0x4C4F69,
            cursorHex: 0xDC8A78,
            cursorTextHex: 0xEFF1F5,
            selectionBackgroundHex: 0xACB0BE,
            selectionForegroundHex: 0x4C4F69,
            paletteHexes: [
                0x5C5F77, 0xD20F39, 0x40A02B, 0xDF8E1D,
                0x1E66F5, 0xEA76CB, 0x179299, 0xACB0BE,
                0x6C6F85, 0xDE293E, 0x49AF3D, 0xEEA02D,
                0x456EFF, 0xFE85D8, 0x2D9FA8, 0xBCC0CC,
            ],
            isLight: true
        ),
        .dracula: theme(
            localizationKey: "settings.terminal_theme.preset.dracula",
            fallbackTitle: "Dracula",
            backgroundHex: 0x282A36,
            foregroundHex: 0xF8F8F2,
            cursorHex: 0xF8F8F2,
            cursorTextHex: 0x282A36,
            selectionBackgroundHex: 0x44475A,
            selectionForegroundHex: 0xFFFFFF,
            paletteHexes: [
                0x21222C, 0xFF5555, 0x50FA7B, 0xF1FA8C,
                0xBD93F9, 0xFF79C6, 0x8BE9FD, 0xF8F8F2,
                0x6272A4, 0xFF6E6E, 0x69FF94, 0xFFFFA5,
                0xD6ACFF, 0xFF92DF, 0xA4FFFF, 0xFFFFFF,
            ],
            isLight: false
        ),
        .flexokiDark: theme(
            localizationKey: "settings.terminal_theme.preset.flexoki_dark",
            fallbackTitle: "Flexoki Dark",
            backgroundHex: 0x100F0F,
            foregroundHex: 0xCECDC3,
            cursorHex: 0xCECDC3,
            cursorTextHex: 0x100F0F,
            selectionBackgroundHex: 0x403E3C,
            selectionForegroundHex: 0xCECDC3,
            paletteHexes: [
                0x100F0F, 0xD14D41, 0x879A39, 0xD0A215,
                0x4385BE, 0xCE5D97, 0x3AA99F, 0x878580,
                0x575653, 0xAF3029, 0x66800B, 0xAD8301,
                0x205EA6, 0xA02F6F, 0x24837B, 0xCECDC3,
            ],
            isLight: false
        ),
        .flexokiLight: theme(
            localizationKey: "settings.terminal_theme.preset.flexoki_light",
            fallbackTitle: "Flexoki Light",
            backgroundHex: 0xFFFCF0,
            foregroundHex: 0x100F0F,
            cursorHex: 0x100F0F,
            cursorTextHex: 0xFFFCF0,
            selectionBackgroundHex: 0xCECDC3,
            selectionForegroundHex: 0x100F0F,
            paletteHexes: [
                0x100F0F, 0xAF3029, 0x66800B, 0xAD8301,
                0x205EA6, 0xA02F6F, 0x24837B, 0x6F6E69,
                0xB7B5AC, 0xD14D41, 0x879A39, 0xD0A215,
                0x4385BE, 0xCE5D97, 0x3AA99F, 0xCECDC3,
            ],
            isLight: true
        ),
        .gruvboxDark: theme(
            localizationKey: "settings.terminal_theme.preset.gruvbox_dark",
            fallbackTitle: "Gruvbox Dark",
            backgroundHex: 0x282828,
            foregroundHex: 0xEBDBB2,
            cursorHex: 0xEBDBB2,
            cursorTextHex: 0x282828,
            selectionBackgroundHex: 0x665C54,
            selectionForegroundHex: 0xEBDBB2,
            paletteHexes: [
                0x282828, 0xCC241D, 0x98971A, 0xD79921,
                0x458588, 0xB16286, 0x689D6A, 0xA89984,
                0x928374, 0xFB4934, 0xB8BB26, 0xFABD2F,
                0x83A598, 0xD3869B, 0x8EC07C, 0xEBDBB2,
            ],
            isLight: false
        ),
        .gruvboxLight: theme(
            localizationKey: "settings.terminal_theme.preset.gruvbox_light",
            fallbackTitle: "Gruvbox Light",
            backgroundHex: 0xFBF1C7,
            foregroundHex: 0x3C3836,
            cursorHex: 0x3C3836,
            cursorTextHex: 0xFBF1C7,
            selectionBackgroundHex: 0x3C3836,
            selectionForegroundHex: 0xFBF1C7,
            paletteHexes: [
                0xFBF1C7, 0xCC241D, 0x98971A, 0xD79921,
                0x458588, 0xB16286, 0x689D6A, 0x7C6F64,
                0x928374, 0x9D0006, 0x79740E, 0xB57614,
                0x076678, 0x8F3F71, 0x427B58, 0x3C3836,
            ],
            isLight: true
        ),
        .tokyoNight: theme(
            localizationKey: "settings.terminal_theme.preset.tokyonight_night",
            fallbackTitle: "TokyoNight Night",
            backgroundHex: 0x1A1B26,
            foregroundHex: 0xC0CAF5,
            cursorHex: 0xC0CAF5,
            cursorTextHex: 0x1A1B26,
            selectionBackgroundHex: 0x283457,
            selectionForegroundHex: 0xC0CAF5,
            paletteHexes: [
                0x15161E, 0xF7768E, 0x9ECE6A, 0xE0AF68,
                0x7AA2F7, 0xBB9AF7, 0x7DCFFF, 0xA9B1D6,
                0x414868, 0xF7768E, 0x9ECE6A, 0xE0AF68,
                0x7AA2F7, 0xBB9AF7, 0x7DCFFF, 0xC0CAF5,
            ],
            isLight: false
        ),
        .nord: theme(
            localizationKey: "settings.terminal_theme.preset.nord",
            fallbackTitle: "Nord",
            backgroundHex: 0x2E3440,
            foregroundHex: 0xD8DEE9,
            cursorHex: 0xECEFF4,
            cursorTextHex: 0x282828,
            selectionBackgroundHex: 0xECEFF4,
            selectionForegroundHex: 0x4C566A,
            paletteHexes: [
                0x3B4252, 0xBF616A, 0xA3BE8C, 0xEBCB8B,
                0x81A1C1, 0xB48EAD, 0x88C0D0, 0xE5E9F0,
                0x596377, 0xBF616A, 0xA3BE8C, 0xEBCB8B,
                0x81A1C1, 0xB48EAD, 0x8FBCBB, 0xECEFF4,
            ],
            isLight: false
        ),
        .githubDark: theme(
            localizationKey: "settings.terminal_theme.preset.github_dark",
            fallbackTitle: "GitHub Dark",
            backgroundHex: 0x101216,
            foregroundHex: 0x8B949E,
            cursorHex: 0xC9D1D9,
            cursorTextHex: 0x101216,
            selectionBackgroundHex: 0x3B5070,
            selectionForegroundHex: 0xFFFFFF,
            paletteHexes: [
                0x000000, 0xF78166, 0x56D364, 0xE3B341,
                0x6CA4F8, 0xDB61A2, 0x2B7489, 0xFFFFFF,
                0x4D4D4D, 0xF78166, 0x56D364, 0xE3B341,
                0x6CA4F8, 0xDB61A2, 0x2B7489, 0xFFFFFF,
            ],
            isLight: false
        ),
        .rosePine: theme(
            localizationKey: "settings.terminal_theme.preset.rose_pine",
            fallbackTitle: "Rose Pine",
            backgroundHex: 0x191724,
            foregroundHex: 0xE0DEF4,
            cursorHex: 0xE0DEF4,
            cursorTextHex: 0x191724,
            selectionBackgroundHex: 0x403D52,
            selectionForegroundHex: 0xE0DEF4,
            paletteHexes: [
                0x26233A, 0xEB6F92, 0x31748F, 0xF6C177,
                0x9CCFD8, 0xC4A7E7, 0xEBBCBA, 0xE0DEF4,
                0x6E6A86, 0xEB6F92, 0x31748F, 0xF6C177,
                0x9CCFD8, 0xC4A7E7, 0xEBBCBA, 0xE0DEF4,
            ],
            isLight: false
        ),
        .rosePineDawn: theme(
            localizationKey: "settings.terminal_theme.preset.rose_pine_dawn",
            fallbackTitle: "Rose Pine Dawn",
            backgroundHex: 0xFAF4ED,
            foregroundHex: 0x575279,
            cursorHex: 0x575279,
            cursorTextHex: 0xFAF4ED,
            selectionBackgroundHex: 0xDFDAD9,
            selectionForegroundHex: 0x575279,
            paletteHexes: [
                0xF2E9E1, 0xB4637A, 0x286983, 0xEA9D34,
                0x56949F, 0x907AA9, 0xD7827E, 0x575279,
                0x9893A5, 0xB4637A, 0x286983, 0xEA9D34,
                0x56949F, 0x907AA9, 0xD7827E, 0x575279,
            ],
            isLight: true
        ),
        .nightOwl: theme(
            localizationKey: "settings.terminal_theme.preset.night_owl",
            fallbackTitle: "Night Owl",
            backgroundHex: 0x011627,
            foregroundHex: 0xD6DEEB,
            cursorHex: 0x7E57C2,
            cursorTextHex: 0xFFFFFF,
            selectionBackgroundHex: 0x5F7E97,
            selectionForegroundHex: 0xDFE5EE,
            paletteHexes: [
                0x011627, 0xEF5350, 0x22DA6E, 0xADDB67,
                0x82AAFF, 0xC792EA, 0x21C7A8, 0xFFFFFF,
                0x575656, 0xEF5350, 0x22DA6E, 0xFFEB95,
                0x82AAFF, 0xC792EA, 0x7FDBCA, 0xFFFFFF,
            ],
            isLight: false
        ),
        .kanagawaWave: theme(
            localizationKey: "settings.terminal_theme.preset.kanagawa_wave",
            fallbackTitle: "Kanagawa Wave",
            backgroundHex: 0x1F1F28,
            foregroundHex: 0xDCD7BA,
            cursorHex: 0xDCD7BA,
            cursorTextHex: 0x1F1F28,
            selectionBackgroundHex: 0xDCD7BA,
            selectionForegroundHex: 0x1F1F28,
            paletteHexes: [
                0x090618, 0xC34043, 0x76946A, 0xC0A36E,
                0x7E9CD8, 0x957FB8, 0x6A9589, 0xC8C093,
                0x727169, 0xE82424, 0x98BB6C, 0xE6C384,
                0x7FB4CA, 0x938AA9, 0x7AA89F, 0xDCD7BA,
            ],
            isLight: false
        ),
        .kanagawaLotus: theme(
            localizationKey: "settings.terminal_theme.preset.kanagawa_lotus",
            fallbackTitle: "Kanagawa Lotus",
            backgroundHex: 0xF2ECBC,
            foregroundHex: 0x545464,
            cursorHex: 0x43436C,
            cursorTextHex: 0xF2ECBC,
            selectionBackgroundHex: 0x545464,
            selectionForegroundHex: 0xF2ECBC,
            paletteHexes: [
                0x1F1F28, 0xC84053, 0x6F894E, 0x77713F,
                0x4D699B, 0xB35B79, 0x597B75, 0x545464,
                0x8A8980, 0xD7474B, 0x6E915F, 0x836F4A,
                0x6693BF, 0x624C83, 0x5E857A, 0x43436C,
            ],
            isLight: true
        ),
        .everforestDarkHard: theme(
            localizationKey: "settings.terminal_theme.preset.everforest_dark_hard",
            fallbackTitle: "Everforest Dark Hard",
            backgroundHex: 0x1E2326,
            foregroundHex: 0xD3C6AA,
            cursorHex: 0xE69875,
            cursorTextHex: 0x4C3743,
            selectionBackgroundHex: 0x4C3743,
            selectionForegroundHex: 0xD3C6AA,
            paletteHexes: [
                0x7A8478, 0xE67E80, 0xA7C080, 0xDBBC7F,
                0x7FBBB3, 0xD699B6, 0x83C092, 0xF2EFDF,
                0xA6B0A0, 0xF85552, 0x8DA101, 0xDFA000,
                0x3A94C5, 0xDF69BA, 0x35A77C, 0xFFFBEF,
            ],
            isLight: false
        ),
        .githubLight: theme(
            localizationKey: "settings.terminal_theme.preset.github_light",
            fallbackTitle: "GitHub Light",
            backgroundHex: 0xFFFFFF,
            foregroundHex: 0x1F2328,
            cursorHex: 0x0969DA,
            cursorTextHex: 0x3C9CFF,
            selectionBackgroundHex: 0x1F2328,
            selectionForegroundHex: 0xFFFFFF,
            paletteHexes: [
                0x24292F, 0xCF222E, 0x116329, 0x4D2D00,
                0x0969DA, 0x8250DF, 0x1B7C83, 0x6E7781,
                0x57606A, 0xA40E26, 0x1A7F37, 0x633C01,
                0x218BFF, 0xA475F9, 0x3192AA, 0x8C959F,
            ],
            isLight: true
        ),
        .ayuLight: theme(
            localizationKey: "settings.terminal_theme.preset.ayu_light",
            fallbackTitle: "Ayu Light",
            backgroundHex: 0xF8F9FA,
            foregroundHex: 0x5C6166,
            cursorHex: 0xFFAA33,
            cursorTextHex: 0xF8F9FA,
            selectionBackgroundHex: 0x035BD6,
            selectionForegroundHex: 0xF8F9FA,
            paletteHexes: [
                0x000000, 0xEA6C6D, 0x6CBF43, 0xECA944,
                0x3199E1, 0x9E75C7, 0x46BA94, 0xBABABA,
                0x686868, 0xF07171, 0x86B300, 0xF2AE49,
                0x399EE6, 0xA37ACC, 0x4CBF99, 0xD1D1D1,
            ],
            isLight: true
        ),
        .draculaPlus: theme(
            localizationKey: "settings.terminal_theme.preset.dracula_plus",
            fallbackTitle: "Dracula+",
            backgroundHex: 0x212121,
            foregroundHex: 0xF8F8F2,
            cursorHex: 0xECEFF4,
            cursorTextHex: 0x282828,
            selectionBackgroundHex: 0xF8F8F2,
            selectionForegroundHex: 0x545454,
            paletteHexes: [
                0x21222C, 0xFF5555, 0x50FA7B, 0xFFCB6B,
                0x82AAFF, 0xC792EA, 0x8BE9FD, 0xF8F8F2,
                0x545454, 0xFF6E6E, 0x69FF94, 0xFFCB6B,
                0xD6ACFF, 0xFF92DF, 0xA4FFFF, 0xF8F8F2,
            ],
            isLight: false
        ),
        .rosePineMoon: theme(
            localizationKey: "settings.terminal_theme.preset.rose_pine_moon",
            fallbackTitle: "Rose Pine Moon",
            backgroundHex: 0x232136,
            foregroundHex: 0xE0DEF4,
            cursorHex: 0xE0DEF4,
            cursorTextHex: 0x232136,
            selectionBackgroundHex: 0x44415A,
            selectionForegroundHex: 0xE0DEF4,
            paletteHexes: [
                0x393552, 0xEB6F92, 0x3E8FB0, 0xF6C177,
                0x9CCFD8, 0xC4A7E7, 0xEA9A97, 0xE0DEF4,
                0x6E6A86, 0xEB6F92, 0x3E8FB0, 0xF6C177,
                0x9CCFD8, 0xC4A7E7, 0xEA9A97, 0xE0DEF4,
            ],
            isLight: false
        ),
        .tokyoNightStorm: theme(
            localizationKey: "settings.terminal_theme.preset.tokyonight_storm",
            fallbackTitle: "TokyoNight Storm",
            backgroundHex: 0x24283B,
            foregroundHex: 0xC0CAF5,
            cursorHex: 0xC0CAF5,
            cursorTextHex: 0x1D202F,
            selectionBackgroundHex: 0x364A82,
            selectionForegroundHex: 0xC0CAF5,
            paletteHexes: [
                0x1D202F, 0xF7768E, 0x9ECE6A, 0xE0AF68,
                0x7AA2F7, 0xBB9AF7, 0x7DCFFF, 0xA9B1D6,
                0x4E5575, 0xF7768E, 0x9ECE6A, 0xE0AF68,
                0x7AA2F7, 0xBB9AF7, 0x7DCFFF, 0xC0CAF5,
            ],
            isLight: false
        ),
        .materialOcean: theme(
            localizationKey: "settings.terminal_theme.preset.material_ocean",
            fallbackTitle: "Material Ocean",
            backgroundHex: 0x0F111A,
            foregroundHex: 0x8F93A2,
            cursorHex: 0xFFCC00,
            cursorTextHex: 0x0F111A,
            selectionBackgroundHex: 0x1F2233,
            selectionForegroundHex: 0x8F93A2,
            paletteHexes: [
                0x546E7A, 0xFF5370, 0xC3E88D, 0xFFCB6B,
                0x82AAFF, 0xC792EA, 0x89DDFF, 0xFFFFFF,
                0x546E7A, 0xFF5370, 0xC3E88D, 0xFFCB6B,
                0x82AAFF, 0xC792EA, 0x89DDFF, 0xFFFFFF,
            ],
            isLight: false
        ),
        .gruvboxMaterialDark: theme(
            localizationKey: "settings.terminal_theme.preset.gruvbox_material_dark",
            fallbackTitle: "Gruvbox Material Dark",
            backgroundHex: 0x282828,
            foregroundHex: 0xD4BE98,
            cursorHex: 0xD4BE98,
            cursorTextHex: 0x282828,
            selectionBackgroundHex: 0xD4BE98,
            selectionForegroundHex: 0x282828,
            paletteHexes: [
                0x282828, 0xEA6962, 0xA9B665, 0xD8A657,
                0x7DAEA3, 0xD3869B, 0x89B482, 0xD4BE98,
                0x7C6F64, 0xEA6962, 0xA9B665, 0xD8A657,
                0x7DAEA3, 0xD3869B, 0x89B482, 0xDDC7A1,
            ],
            isLight: false
        ),
        .gruvboxMaterialLight: theme(
            localizationKey: "settings.terminal_theme.preset.gruvbox_material_light",
            fallbackTitle: "Gruvbox Material Light",
            backgroundHex: 0xFBF1C7,
            foregroundHex: 0x654735,
            cursorHex: 0x654735,
            cursorTextHex: 0xFBF1C7,
            selectionBackgroundHex: 0x654735,
            selectionForegroundHex: 0xFBF1C7,
            paletteHexes: [
                0xFBF1C7, 0xC14A4A, 0x6C782E, 0xB47109,
                0x45707A, 0x945E80, 0x4C7A5D, 0x654735,
                0xA89984, 0xC14A4A, 0x6C782E, 0xB47109,
                0x45707A, 0x945E80, 0x4C7A5D, 0x4F3829,
            ],
            isLight: true
        ),
        .atomOneLight: theme(
            localizationKey: "settings.terminal_theme.preset.atom_one_light",
            fallbackTitle: "Atom One Light",
            backgroundHex: 0xF9F9F9,
            foregroundHex: 0x2A2C33,
            cursorHex: 0xBBBBBB,
            cursorTextHex: 0xFFFFFF,
            selectionBackgroundHex: 0xEDEDED,
            selectionForegroundHex: 0x2A2C33,
            paletteHexes: [
                0x000000, 0xDE3E35, 0x3F953A, 0xD2B67C,
                0x2F5AF3, 0x950095, 0x3F953A, 0xBBBBBB,
                0x000000, 0xDE3E35, 0x3F953A, 0xD2B67C,
                0x2F5AF3, 0xA00095, 0x3F953A, 0xFFFFFF,
            ],
            isLight: true
        ),
        .nordLight: theme(
            localizationKey: "settings.terminal_theme.preset.nord_light",
            fallbackTitle: "Nord Light",
            backgroundHex: 0xE5E9F0,
            foregroundHex: 0x414858,
            cursorHex: 0x7BB3C3,
            cursorTextHex: 0x3B4252,
            selectionBackgroundHex: 0xD8DEE9,
            selectionForegroundHex: 0x4C556A,
            paletteHexes: [
                0x3B4252, 0xBF616A, 0x96B17F, 0xC5A565,
                0x81A1C1, 0xB48EAD, 0x7BB3C3, 0xA5ABB6,
                0x4C566A, 0xBF616A, 0x96B17F, 0xC5A565,
                0x81A1C1, 0xB48EAD, 0x82AFAE, 0xECEFF4,
            ],
            isLight: true
        ),
        .ayuMirage: theme(
            localizationKey: "settings.terminal_theme.preset.ayu_mirage",
            fallbackTitle: "Ayu Mirage",
            backgroundHex: 0x1F2430,
            foregroundHex: 0xCCCAC2,
            cursorHex: 0xFFCC66,
            cursorTextHex: 0x1F2430,
            selectionBackgroundHex: 0x409FFF,
            selectionForegroundHex: 0x1F2430,
            paletteHexes: [
                0x171B24, 0xED8274, 0x87D96C, 0xFACC6E,
                0x6DCBFA, 0xDABAFA, 0x90E1C6, 0xC7C7C7,
                0x686868, 0xF28779, 0xD5FF80, 0xFFD173,
                0x73D0FF, 0xDFBFFF, 0x95E6CB, 0xFFFFFF,
            ],
            isLight: false
        ),
    ]

    var definition: AppTerminalThemeDefinition {
        Self.catalog[self] ?? Self.catalog[.flexokiDark]!
    }

    static func automaticFallbackPreset(prefersDarkAppearance: Bool) -> Self {
        prefersDarkAppearance ? .flexokiDark : .flexokiLight
    }

    static func automaticMatch(forGhosttyThemeName name: String) -> Self? {
        let normalized = normalizeGhosttyThemeName(name)
        guard !normalized.isEmpty else {
            return nil
        }
        return automaticThemeAliases[normalized]
    }

    private static let automaticThemeAliases: [String: Self] = {
        var aliases: [String: Self] = [:]

        func register(_ value: String, preset: Self) {
            aliases[normalizeGhosttyThemeName(value)] = preset
        }

        for preset in Self.allCases where preset.isAutomatic == false {
            register(preset.rawValue, preset: preset)
            register(preset.definition.fallbackTitle, preset: preset)
        }

        register("tokyonight", preset: .tokyoNight)
        register("tokyonightnight", preset: .tokyoNight)
        register("tokyonightstorm", preset: .tokyoNightStorm)
        register("catppuccinmocha", preset: .catppuccinMocha)
        register("catppuccinlatte", preset: .catppuccinLatte)
        register("rosepinedawn", preset: .rosePineDawn)
        register("rosepinemoon", preset: .rosePineMoon)
        register("rosepine", preset: .rosePine)
        register("kanagawawave", preset: .kanagawaWave)
        register("kanagawalotus", preset: .kanagawaLotus)
        register("githubdark", preset: .githubDark)
        register("githublight", preset: .githubLight)
        register("gruvboxmaterialdark", preset: .gruvboxMaterialDark)
        register("gruvboxmateriallight", preset: .gruvboxMaterialLight)
        register("everforestdarkhard", preset: .everforestDarkHard)
        register("atomonelight", preset: .atomOneLight)
        register("nightowl", preset: .nightOwl)

        return aliases
    }()

    private static func normalizeGhosttyThemeName(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(
                of: #"[^a-z0-9]+"#,
                with: "",
                options: .regularExpression
            )
    }

    private static func theme(
        localizationKey: String,
        fallbackTitle: String,
        backgroundHex: UInt,
        foregroundHex: UInt,
        cursorHex: UInt,
        cursorTextHex: UInt,
        selectionBackgroundHex: UInt,
        selectionForegroundHex: UInt,
        paletteHexes: [UInt],
        isLight: Bool
    ) -> AppTerminalThemeDefinition {
        AppTerminalThemeDefinition(
            localizationKey: localizationKey,
            fallbackTitle: fallbackTitle,
            backgroundHex: backgroundHex,
            foregroundHex: foregroundHex,
            cursorHex: cursorHex,
            cursorTextHex: cursorTextHex,
            selectionBackgroundHex: selectionBackgroundHex,
            selectionForegroundHex: selectionForegroundHex,
            paletteHexes: paletteHexes,
            isLight: isLight
        )
    }

    func effectiveAppearance(
        backgroundColorPreset: AppBackgroundColorPreset,
        automaticAppearance: AppEffectiveTerminalAppearance? = nil
    ) -> AppEffectiveTerminalAppearance {
        let baseAppearance: AppEffectiveTerminalAppearance
        if isAutomatic {
            baseAppearance = automaticAppearance ?? Self.automaticFallbackPreset(prefersDarkAppearance: true)
                .effectiveAppearance(backgroundColorPreset: .automatic)
        } else {
            let definition = self.definition
            baseAppearance = AppEffectiveTerminalAppearance(
                backgroundColor: definition.backgroundColor,
                foregroundColor: definition.foregroundColor,
                cursorColor: definition.cursorColor,
                cursorTextColor: definition.cursorTextColor,
                selectionBackgroundColor: definition.selectionBackgroundColor,
                selectionForegroundColor: definition.selectionForegroundColor,
                paletteHexStrings: definition.paletteHexStrings,
                isLight: definition.isLight,
                minimumContrast: definition.minimumContrast
            )
        }

        let backgroundColor = backgroundColorPreset.swatchColor ?? baseAppearance.backgroundColor
        let overrideActive = backgroundColorPreset.isAutomatic == false
        let appearanceIsLight = overrideActive ? backgroundColorPreset.isLight : baseAppearance.isLight
        let shouldUseContrastFallback = overrideActive && appearanceIsLight != baseAppearance.isLight

        let foregroundColor: NSColor = shouldUseContrastFallback
            ? (appearanceIsLight ? .dmuxHex(0x282726) : .dmuxHex(0xFFFCF0))
            : baseAppearance.foregroundColor
        let cursorColor: NSColor = shouldUseContrastFallback ? foregroundColor : baseAppearance.cursorColor
        let cursorTextColor: NSColor = shouldUseContrastFallback ? backgroundColor : baseAppearance.cursorTextColor
        let selectionBackgroundColor: NSColor = shouldUseContrastFallback
            ? (backgroundColor.blended(withFraction: appearanceIsLight ? 0.18 : 0.24, of: foregroundColor) ?? backgroundColor)
            : baseAppearance.selectionBackgroundColor
        let selectionForegroundColor: NSColor = shouldUseContrastFallback ? foregroundColor : baseAppearance.selectionForegroundColor

        return AppEffectiveTerminalAppearance(
            backgroundColor: backgroundColor,
            foregroundColor: foregroundColor,
            cursorColor: cursorColor,
            cursorTextColor: cursorTextColor,
            selectionBackgroundColor: selectionBackgroundColor,
            selectionForegroundColor: selectionForegroundColor,
            paletteHexStrings: baseAppearance.paletteHexStrings,
            isLight: appearanceIsLight,
            minimumContrast: baseAppearance.minimumContrast
        )
    }

    var backgroundColor: NSColor { effectiveAppearance(backgroundColorPreset: .automatic).backgroundColor }
    var foregroundColor: NSColor { effectiveAppearance(backgroundColorPreset: .automatic).foregroundColor }
    var mutedForegroundColor: NSColor { effectiveAppearance(backgroundColorPreset: .automatic).mutedForegroundColor }
    var dividerColor: NSColor { effectiveAppearance(backgroundColorPreset: .automatic).dividerColor }
    var isLight: Bool { effectiveAppearance(backgroundColorPreset: .automatic).isLight }
    var inactiveDimOpacity: CGFloat { effectiveAppearance(backgroundColorPreset: .automatic).inactiveDimOpacity }
    var inactiveDimColor: NSColor { effectiveAppearance(backgroundColorPreset: .automatic).inactiveDimColor }
    var inactiveBackgroundColor: NSColor { effectiveAppearance(backgroundColorPreset: .automatic).inactiveBackgroundColor }
    func windowGlassTintColor(forDarkAppearance isDarkAppearance: Bool) -> NSColor {
        effectiveAppearance(backgroundColorPreset: .automatic).windowGlassTintColor(forDarkAppearance: isDarkAppearance)
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
