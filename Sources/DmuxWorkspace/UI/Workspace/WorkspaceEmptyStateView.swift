import SwiftUI

struct WorkspaceEmptyStateView: View {
    let model: AppModel

    private var titleColor: Color {
        model.terminalBackgroundPreset.isLight
            ? model.terminalTextColor.opacity(0.9)
            : model.terminalTextColor.opacity(0.82)
    }

    private var subtitleColor: Color {
        model.terminalBackgroundPreset.isLight
            ? model.terminalMutedTextColor.opacity(0.84)
            : model.terminalMutedTextColor.opacity(0.78)
    }

    private var tertiaryColor: Color {
        model.terminalBackgroundPreset.isLight
            ? model.terminalMutedTextColor.opacity(0.72)
            : model.terminalMutedTextColor.opacity(0.74)
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 20) {
                Image(nsImage: model.appIconImage)
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .frame(width: 72, height: 72)
                    .shadow(color: .black.opacity(0.08), radius: 6, y: 3)

                VStack(spacing: 6) {
                    Text(String(format: String(localized: "welcome.title_format", defaultValue: "Welcome to %@", bundle: .module), model.appDisplayName))
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(titleColor)

                    Text(String(localized: "welcome.subtitle", defaultValue: "Create a project in the sidebar to get started", bundle: .module))
                    .font(.system(size: 13))
                    .foregroundStyle(subtitleColor)
                }

                Button {
                    model.addProject()
                } label: {
                    Label(String(localized: "menu.file.new_project", defaultValue: "New Project", bundle: .module), systemImage: "plus")
                        .font(.system(size: 14, weight: .semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            Spacer()

            WelcomeShortcutHintsView(model: model)
                .foregroundStyle(subtitleColor)
                .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct WelcomeShortcutHintsView: View {
    let model: AppModel

    private var subtitleColor: Color {
        model.terminalBackgroundPreset.isLight
            ? model.terminalMutedTextColor.opacity(0.84)
            : model.terminalMutedTextColor.opacity(0.78)
    }

    private var tertiaryColor: Color {
        model.terminalBackgroundPreset.isLight
            ? model.terminalMutedTextColor.opacity(0.72)
            : model.terminalMutedTextColor.opacity(0.74)
    }

    var body: some View {
        HStack(spacing: 24) {
            if let shortcut = model.appSettings.shortcuts.splitPane {
                shortcutHint(
                    symbol: "rectangle.split.2x1",
                    label: String(localized: "titlebar.split", defaultValue: "Split", bundle: .module),
                    keys: shortcut.title
                )
            }
            if let shortcut = model.appSettings.shortcuts.createTab {
                shortcutHint(
                    symbol: "plus.rectangle.on.rectangle",
                    label: String(localized: "titlebar.tab", defaultValue: "Tab", bundle: .module),
                    keys: shortcut.title
                )
            }
            if let shortcut = model.appSettings.shortcuts.toggleGitPanel {
                shortcutHint(
                    symbol: "arrow.triangle.branch",
                    label: String(localized: "titlebar.git", defaultValue: "Git", bundle: .module),
                    keys: shortcut.title
                )
            }
            if let shortcut = model.appSettings.shortcuts.toggleAIPanel {
                shortcutHint(
                    symbol: "sparkles",
                    label: String(localized: "titlebar.ai", defaultValue: "AI", bundle: .module),
                    keys: shortcut.title
                )
            }
        }
    }

    private func shortcutHint(symbol: String, label: String, keys: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(tertiaryColor)

            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(subtitleColor)

            Text(keys)
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(tertiaryColor)
        }
    }
}
