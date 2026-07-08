import InkletCore
import SwiftUI

enum SelectionActionViewState: Equatable {
    case menu(errorMessage: String?, feedback: SelectionActionFeedback?)
    case preparingPronunciation
    case playingPronunciation
    case notice(String)
    case translating
    case translationResult(String, errorMessage: String?, feedback: SelectionActionFeedback?)
    case translationError(String)
}

enum SelectionActionFeedback: Equatable {
    case loadingMenuTranslation
    case loadingMenuPronunciation
    case playingMenuPronunciation
    case copiedTranslation
    case loadingOriginalPronunciation
    case playingOriginalPronunciation
    case loadingTranslationPronunciation
    case playingTranslationPronunciation
}

struct SelectionActionView: View {
    let state: SelectionActionViewState
    let onTranslate: () -> Void
    let onPronounce: () -> Void
    let onPronounceOriginal: () -> Void
    let onPronounceTranslation: () -> Void
    let onCopyTranslation: () -> Void
    let onRetryTranslation: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch state {
            case .menu(let errorMessage, let feedback):
                HStack(spacing: 6) {
                    compactButton(
                        title: L10n.text("selection.action.translate"),
                        systemImage: "character.bubble",
                        isLoading: feedback == .loadingMenuTranslation,
                        action: onTranslate
                    )
                    compactButton(
                        title: L10n.text("selection.action.pronounce"),
                        systemImage: "speaker.wave.2",
                        isLoading: feedback == .loadingMenuPronunciation,
                        isPlaying: feedback == .playingMenuPronunciation,
                        action: onPronounce
                    )
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(InkletTheme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }

            case .preparingPronunciation:
                progressRow(title: L10n.text("selection.action.preparingPronunciation"))

            case .playingPronunciation:
                progressRow(title: L10n.text("selection.action.playingPronunciation"))

            case .notice(let message):
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(InkletTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

            case .translating:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(L10n.text("selection.action.translating"))
                        .font(.system(size: 12))
                        .foregroundStyle(InkletTheme.textSecondary)
                }

            case .translationResult(let text, let errorMessage, let feedback):
                VStack(alignment: .leading, spacing: 8) {
                    translationResultText(text)
                    translationToolbar(feedback: feedback)

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.system(size: 11))
                            .foregroundStyle(InkletTheme.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

            case .translationError(let message):
                VStack(alignment: .leading, spacing: 8) {
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(InkletTheme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                    compactButton(
                        title: L10n.text("selection.action.retry"),
                        systemImage: "arrow.clockwise",
                        action: onRetryTranslation
                    )
                }
            }
        }
        .padding(panelPadding)
        .frame(
            minWidth: preferredWidth,
            maxWidth: usesFlexiblePanelSize ? .infinity : preferredWidth,
            alignment: .leading
        )
        .frame(maxHeight: usesFlexiblePanelSize ? .infinity : nil, alignment: .topLeading)
        .background(InkletTheme.panelBackground)
    }

    var preferredWidth: CGFloat {
        switch state {
        case .menu:
            224
        case .preparingPronunciation, .playingPronunciation, .translating:
            210
        case .translationResult(let text, _, _):
            text.count >= 240 ? 420 : 300
        default:
            300
        }
    }

    private var usesFlexiblePanelSize: Bool {
        if case .translationResult = state {
            return true
        }
        return false
    }

    private var panelPadding: EdgeInsets {
        switch state {
        case .menu:
            EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)
        default:
            EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10)
        }
    }

    private var toolbarDisplayStyle: SelectionAudioControlDisplayStyle {
        .flatToolbarAction
    }

    private var toolbarIconSize: CGFloat {
        CGFloat(toolbarDisplayStyle.iconPointSize)
    }

    private var toolbarForegroundColor: Color {
        InkletTheme.textSecondary.opacity(toolbarDisplayStyle.foregroundOpacity)
    }

    private func translationResultText(_ text: String) -> some View {
        ScrollView {
            Text(text)
                .font(.system(size: 13))
                .lineSpacing(2)
                .foregroundStyle(InkletTheme.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
        }
        .frame(maxHeight: usesFlexiblePanelSize ? .infinity : 180)
        .background(InkletTheme.controlFill.opacity(0.58), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(InkletTheme.subtleBorder)
        }
    }

    private func translationToolbar(feedback: SelectionActionFeedback?) -> some View {
        HStack(spacing: 4) {
            compactIconButton(
                title: L10n.text("selection.action.copyTranslation"),
                systemImage: feedback == .copiedTranslation ? "checkmark" : "doc.on.doc",
                action: onCopyTranslation
            )
            Spacer(minLength: 12)
            compactAudioButton(
                title: L10n.text("selection.action.pronounceOriginal"),
                systemImage: "speaker.wave.2",
                role: .original,
                isLoading: feedback == .loadingOriginalPronunciation,
                isPlaying: feedback == .playingOriginalPronunciation,
                action: onPronounceOriginal
            )
            compactAudioButton(
                title: L10n.text("selection.action.pronounceTranslation"),
                systemImage: "speaker.wave.2.fill",
                role: .translation,
                isLoading: feedback == .loadingTranslationPronunciation,
                isPlaying: feedback == .playingTranslationPronunciation,
                action: onPronounceTranslation
            )
        }
        .padding(.top, 6)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(InkletTheme.subtleBorder.opacity(0.55))
                .frame(height: 1)
        }
    }

    private func compactButton(
        title: String,
        systemImage: String,
        isLoading: Bool = false,
        isPlaying: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                ZStack {
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else if isPlaying {
                        buttonIcon(
                            systemImage: systemImage,
                            fontSize: 12,
                            weight: .semibold,
                            isPlaying: true
                        )
                    } else {
                        buttonIcon(
                            systemImage: systemImage,
                            fontSize: 12,
                            weight: .semibold,
                            isPlaying: false
                        )
                    }
                }
                .frame(width: 15, height: 15)

                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            .frame(height: 30)
            .padding(.horizontal, 9)
            .background(InkletTheme.controlFill, in: RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(InkletTheme.subtleBorder)
                }
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
    }

    private func compactIconButton(
        title: String,
        systemImage: String,
        isLoading: Bool = false,
        isPlaying: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ZStack {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else if isPlaying {
                    buttonIcon(
                        systemImage: systemImage,
                        fontSize: toolbarIconSize,
                        weight: .medium,
                        isPlaying: true,
                        color: toolbarForegroundColor
                    )
                } else {
                    buttonIcon(
                        systemImage: systemImage,
                        fontSize: toolbarIconSize,
                        weight: .medium,
                        isPlaying: false,
                        color: toolbarForegroundColor
                    )
                }
            }
            .frame(width: 14, height: 14)
            .frame(width: 30, height: 30)
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(FlatToolbarButtonStyle())
        .help(title)
        .accessibilityLabel(title)
        .disabled(isLoading)
    }

    private func compactAudioButton(
        title: String,
        systemImage: String,
        role: SelectionAudioControlRole,
        isLoading: Bool = false,
        isPlaying: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                ZStack {
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        buttonIcon(
                            systemImage: systemImage,
                            fontSize: toolbarIconSize,
                            weight: .medium,
                            isPlaying: isPlaying,
                            color: toolbarForegroundColor
                        )
                    }
                }
                .frame(width: 14, height: 14)

                Text(L10n.text(role.labelLocalizationKey))
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(toolbarForegroundColor)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .frame(height: 30)
            .padding(.horizontal, 7)
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(FlatToolbarButtonStyle())
        .help(title)
        .accessibilityLabel(title)
        .disabled(isLoading)
    }

    @ViewBuilder
    private func buttonIcon(
        systemImage: String,
        fontSize: CGFloat,
        weight: Font.Weight,
        isPlaying: Bool,
        color: Color = InkletTheme.textPrimary
    ) -> some View {
        if systemImage.hasPrefix("speaker.wave") {
            SpeakerWaveIcon(
                state: isPlaying ? .playing : .idle,
                fontSize: fontSize,
                weight: weight,
                isFilled: systemImage.hasSuffix(".fill"),
                foregroundColor: color
            )
        } else {
            Image(systemName: systemImage)
                .font(.system(size: fontSize, weight: weight))
                .foregroundStyle(color)
        }
    }

    private func progressRow(title: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(InkletTheme.textSecondary)
                .lineLimit(1)
        }
        .frame(minHeight: 28)
    }
}

private struct FlatToolbarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                configuration.isPressed
                    ? InkletTheme.controlFill.opacity(0.46)
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
    }
}
