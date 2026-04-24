import SwiftUI

enum FloatingTooltipPlacement {
    case below
    case right
}

private struct FloatingTooltipBubbleView: View {
    let text: String
    private static let maxWidth: CGFloat = 240

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(AppTheme.textPrimary)
            .multilineTextAlignment(.leading)
            .lineLimit(nil)
            .frame(maxWidth: Self.maxWidth - 20, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(AppTheme.panel.opacity(0.98))
            )
            .fixedSize(horizontal: false, vertical: true)
            .shadow(color: Color.black.opacity(0.16), radius: 10, x: 0, y: 4)
            .allowsHitTesting(false)
    }
}

struct FloatingTooltipModifier: ViewModifier {
    let text: String
    let enabled: Bool
    let placement: FloatingTooltipPlacement

    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .overlay(alignment: overlayAlignment) {
                if enabled, isHovered, !text.isEmpty {
                    FloatingTooltipBubbleView(text: text)
                        .offset(tooltipOffset)
                        .zIndex(1_000)
                }
            }
            .onHover { hovering in
                isHovered = hovering && enabled
            }
            .onChange(of: enabled) { _, newValue in
                if !newValue {
                    isHovered = false
                }
            }
            .onDisappear {
                isHovered = false
            }
    }

    private var overlayAlignment: Alignment {
        switch placement {
        case .below:
            return .bottom
        case .right:
            return .trailing
        }
    }

    private var tooltipOffset: CGSize {
        switch placement {
        case .below:
            return CGSize(width: 0, height: 28)
        case .right:
            return CGSize(width: 18, height: 0)
        }
    }
}

extension View {
    func floatingTooltip(_ text: String, enabled: Bool = true, placement: FloatingTooltipPlacement) -> some View {
        modifier(FloatingTooltipModifier(text: text, enabled: enabled, placement: placement))
    }
}
