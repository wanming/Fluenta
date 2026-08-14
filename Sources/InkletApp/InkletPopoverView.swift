import Combine
import AppKit
import SwiftUI
import InkletCore

@MainActor
final class InkletPopoverViewModel: ObservableObject {
    @Published var sourceText = ""
    @Published var resultText = ""
    @Published var errorMessage: String?
    @Published var isTransforming = false
    @Published var isInserting = false
    @Published var selectedModeID: String
    @Published var openRevision = 0
    @Published var modes: [PromptMode]
    @Published var preferredPopoverHeight: CGFloat = 168
    @Published var appearance: AppAppearance
    @Published var voiceShortcutHint: VoiceInputConfig.Shortcut?

    var onHidePopover: (() -> Void)?
    var onFocusPopover: (() -> Void)?
    var onOpenSettings: (() -> Void)?

    var currentProviderName: String {
        LLMProviderPreset.preset(id: config.providerID).name
    }

    var currentModelName: String {
        config.model
    }

    private var stateMachine: PopoverStateMachine
    private let configStore: UserDefaultsConfigStore
    private let apiKeyStore: LocalAPIKeyStore
    private let insertionService: InsertionService
    private let transformationServiceFactory: (any LLMProvider) -> TransformationService
    private let historyStore: any HistoryStore
    private var config: AppConfig
    private var previousApplication: NSRunningApplication?
    private var transformationTask: Task<Void, Never>?
    private var sessionID = 0
    private var draftSourceText = ""
    private var hasTransformedInSession = false

    init(
        stateMachine: PopoverStateMachine = PopoverStateMachine(),
        configStore: UserDefaultsConfigStore = UserDefaultsConfigStore(),
        apiKeyStore: LocalAPIKeyStore = LocalAPIKeyStore(),
        transformationServiceFactory: @escaping (any LLMProvider) -> TransformationService = { TransformationService(provider: $0) },
        insertionService: InsertionService = InsertionService(),
        historyStore: any HistoryStore = JSONLHistoryStore()
    ) {
        self.stateMachine = stateMachine
        self.configStore = configStore
        self.apiKeyStore = apiKeyStore
        self.transformationServiceFactory = transformationServiceFactory
        self.insertionService = insertionService
        self.historyStore = historyStore

        let loadedConfig = (try? configStore.load()) ?? AppConfig.defaultConfig()
        self.config = loadedConfig
        self.modes = loadedConfig.visiblePromptModes
        self.selectedModeID = loadedConfig.defaultVisibleModeID
        self.appearance = loadedConfig.appearance
        self.voiceShortcutHint = nil
    }

    func resetForOpen(previousApplication: NSRunningApplication?) {
        transformationTask?.cancel()
        transformationTask = nil
        sessionID += 1
        self.previousApplication = previousApplication
        stateMachine = PopoverStateMachine()

        config = (try? configStore.load()) ?? AppConfig.defaultConfig()
        modes = config.visiblePromptModes
        selectedModeID = config.defaultVisibleModeID
        appearance = config.appearance
        refreshVoiceShortcutHint()
        sourceText = draftSourceText
        resultText = ""
        errorMessage = nil
        isTransforming = false
        isInserting = false
        hasTransformedInSession = false
        preferredPopoverHeight = 168
        openRevision += 1

        handle(actions: stateMachine.send(.open))
        if !sourceText.isEmpty {
            _ = stateMachine.send(.sourceChanged(sourceText))
        }
    }

    private func refreshVoiceShortcutHint() {
        let openAIAPIKey = apiKeyStore.loadAPIKey(forProviderID: LLMProviderPreset.openAI.id)
        voiceShortcutHint = OnboardingPolicy.shouldShowVoiceShortcutHint(
            openAIAPIKey: openAIAPIKey,
            shortcut: config.voiceInput.shortcut
        ) ? config.voiceInput.shortcut : nil
    }

    func updateSourceText(_ text: String) {
        guard !isTransforming, !isInserting else {
            return
        }

        sourceText = text
        if !resultText.isEmpty {
            resultText = ""
        }

        _ = stateMachine.send(.sourceChanged(text))
    }

    func updateResultText(_ text: String) {
        guard !isTransforming, !isInserting else {
            return
        }

        resultText = text
        _ = stateMachine.send(.resultChanged(text))
    }

    func cyclePromptMode(direction: Int) {
        guard !modes.isEmpty else {
            return
        }

        let currentIndex = modes.firstIndex { $0.id == selectedModeID } ?? 0
        let nextIndex = (currentIndex + direction + modes.count) % modes.count
        selectedModeID = modes[nextIndex].id
    }

    func submit() {
        guard !isTransforming, !isInserting else {
            return
        }

        errorMessage = nil
        if !resultText.isEmpty {
            removeSingleTrailingNewlineFromResult()
            let currentResult = resultText
            _ = stateMachine.send(.resultChanged(currentResult))
            let actions = stateMachine.send(.submit)
            if actions.isEmpty {
                insert(
                    text: currentResult,
                    fallbackState: .previewingResult(source: sourceText, result: currentResult)
                )
            } else {
                handle(actions: actions)
            }
            return
        }

        removeSingleTrailingNewlineFromSource()
        _ = stateMachine.send(.sourceChanged(sourceText))
        handle(actions: stateMachine.send(.submit))
    }

    private func removeSingleTrailingNewlineFromSource() {
        if sourceText.hasSuffix("\r\n") {
            sourceText.removeLast(2)
        } else if sourceText.hasSuffix("\n") || sourceText.hasSuffix("\r") {
            sourceText.removeLast()
        }
    }

    private func removeSingleTrailingNewlineFromResult() {
        if resultText.hasSuffix("\r\n") {
            resultText.removeLast(2)
        } else if resultText.hasSuffix("\n") || resultText.hasSuffix("\r") {
            resultText.removeLast()
        }
    }

    func insertOriginal() {
        guard !isTransforming, !isInserting else {
            return
        }

        let trimmedSource = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSource.isEmpty else {
            errorMessage = L10n.text("popover.error.emptyOriginal")
            return
        }

        errorMessage = nil
        let fallbackState: PopoverStateMachine.State = resultText.isEmpty
            ? .editingSource(source: sourceText, errorMessage: nil)
            : .previewingResult(source: sourceText, result: resultText)

        if resultText.isEmpty {
            _ = stateMachine.send(.sourceChanged(sourceText))
            let actions = stateMachine.send(.insertOriginal)
            if !actions.isEmpty {
                handle(actions: actions)
                return
            }
        }

        insert(text: sourceText, fallbackState: fallbackState)
    }

    func escape() {
        transformationTask?.cancel()
        transformationTask = nil

        if !resultText.isEmpty {
            draftSourceText = ""
            resultText = ""
            errorMessage = nil
            handle(actions: stateMachine.send(.escape))
            return
        }

        draftSourceText = hasTransformedInSession ? "" : sourceText
        var actions = stateMachine.send(.escape)
        if actions.isEmpty {
            actions = stateMachine.send(.close)
        }
        handle(actions: actions)
    }

    func openSettings() {
        onHidePopover?()
        onOpenSettings?()
    }

    private func handle(actions: [PopoverStateMachine.Action]) {
        for action in actions {
            switch action {
            case .showPopover:
                onFocusPopover?()
            case .hidePopover:
                onHidePopover?()
            case .focusSourceInput:
                openRevision += 1
            case .startTransformation(let source):
                startTransformation(source: source)
            case .showResult(let result):
                hasTransformedInSession = true
                draftSourceText = ""
                resultText = result
            case .showError(let message):
                errorMessage = localizedStateMachineMessage(message)
            case .insertText(let text):
                let fallbackState: PopoverStateMachine.State
                if !resultText.isEmpty {
                    fallbackState = .previewingResult(source: sourceText, result: resultText)
                } else {
                    fallbackState = .editingSource(source: sourceText, errorMessage: nil)
                }
                insert(text: text, fallbackState: fallbackState)
            }
        }
    }

    private func startTransformation(source: String) {
        transformationTask?.cancel()
        resultText = ""
        errorMessage = nil
        isTransforming = true

        selectedModeID = config.visibleModeID(preferredModeID: selectedModeID)
        let promptModeStore = config.promptModeStore
        let mode = promptModeStore.resolve(modeID: selectedModeID, sourceText: source)
        let model = config.model
        let timeoutSeconds = config.timeoutSeconds
        let providerPreset = config.resolvedProviderPreset
        let providerID = config.providerID
        let apiKeyStore = self.apiKeyStore
        let provider = LLMProviderFactory.provider(for: providerPreset) {
            try LocalAPIKeyProvider(
                apiKeyStore: apiKeyStore,
                providerID: providerID,
                providerName: providerPreset.name
            ).loadAPIKey()
        }
        let transformationService = transformationServiceFactory(provider)

        transformationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await transformationService.transform(
                    sourceText: source,
                    mode: mode,
                    model: model,
                    timeoutSeconds: timeoutSeconds
                )
                guard !Task.isCancelled else { return }
                try? historyStore.append(HistoryItem(
                    source: .write,
                    inputText: source,
                    outputText: result.outputText,
                    modeName: mode.localizedName,
                    targetLanguageName: nil,
                    model: model,
                    metadata: [
                        "modeID": mode.id,
                        "providerID": providerID
                    ]
                ))
                isTransforming = false
                handle(actions: stateMachine.send(.transformationSucceeded(result: result.outputText)))
            } catch {
                guard !Task.isCancelled else { return }
                isTransforming = false
                resultText = ""
                handle(actions: stateMachine.send(.transformationFailed(message: error.userFacingMessage)))
            }
        }
    }

    private func localizedStateMachineMessage(_ message: String) -> String {
        switch message {
        case "请输入要转换的文本":
            L10n.text("error.emptySource")
        default:
            message
        }
    }

    private func insert(text: String, fallbackState: PopoverStateMachine.State) {
        guard let previousApplication else {
            stateMachine = PopoverStateMachine(state: fallbackState)
            errorMessage = L10n.text("popover.error.missingTarget")
            return
        }

        errorMessage = nil
        onHidePopover?()
        isInserting = true

        let insertionSessionID = sessionID
        Task { [weak self] in
            guard let self else { return }
            do {
                try await insertionService.insert(text: text, into: previousApplication)
                guard sessionID == insertionSessionID else {
                    return
                }
                isInserting = false
                draftSourceText = ""
                sourceText = ""
                resultText = ""
                handle(actions: stateMachine.send(.insertionFinished))
            } catch {
                guard sessionID == insertionSessionID else {
                    return
                }
                isInserting = false
                stateMachine = PopoverStateMachine(state: fallbackState)
                errorMessage = error.userFacingMessage
                onFocusPopover?()
            }
        }
    }
}

private struct LocalAPIKeyProvider: @unchecked Sendable {
    let apiKeyStore: LocalAPIKeyStore
    let providerID: String
    let providerName: String

    func loadAPIKey() throws -> String {
        guard let apiKey = apiKeyStore.loadAPIKey(forProviderID: providerID),
              !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw TransformationError.provider(L10n.format("popover.error.missingAPIKey", providerName))
        }
        return apiKey
    }
}

private extension Error {
    var userFacingMessage: String {
        if let transformationError = self as? TransformationError {
            switch transformationError {
            case .emptySource:
                return L10n.text("error.emptySource")
            case .emptyResponse:
                return L10n.text("error.emptyResponse")
            case .timeout:
                return L10n.text("error.timeout")
            case .provider(let message):
                return localizedProviderMessage(message)
            }
        }

        if let localizedError = self as? LocalizedError,
           let description = localizedError.errorDescription {
            return description
        }

        if let insertionError = self as? InsertionError {
            switch insertionError {
            case .accessibilityPermissionMissing:
                return L10n.text("insertion.error.accessibility")
            case .activationFailed:
                return L10n.text("insertion.error.activation")
            case .cannotCreatePasteEvent:
                return L10n.text("insertion.error.pasteEvent")
            case .clipboardRestoreFailed:
                return L10n.text("insertion.error.clipboardRestore")
            }
        }

        return String(describing: self)
    }

    private func localizedProviderMessage(_ message: String) -> String {
        for providerName in LLMProviderPreset.all.map(\.name) {
            let prefix = "\(providerName) 请求失败："
            guard message.hasPrefix(prefix) else {
                continue
            }

            let detail = String(message.dropFirst(prefix.count))
            if detail == "URL 无效" {
                return L10n.format("error.provider.urlInvalid", providerName)
            }
            if detail == "HTTP unknown" {
                return L10n.format("error.provider.httpUnknown", providerName)
            }
            return L10n.format("error.provider.prefix", providerName, detail)
        }

        return message
    }
}

struct InkletPopoverView: View {
    @ObservedObject var model: InkletPopoverViewModel
    @FocusState private var isSourceFocused: Bool
    @FocusState private var isResultFocused: Bool
    @State private var sourceMeasuredHeight: CGFloat = 0
    @State private var resultMeasuredHeight: CGFloat = 0

    private let minEditorRows: CGFloat = 2
    private let maxSourceEditorRows: CGFloat = 7
    private let maxResultEditorRows: CGFloat = 13
    private let editorLineHeight: CGFloat = 20
    private let editorVerticalPadding: CGFloat = 24
    private let editorEstimatedCharactersPerLine: CGFloat = 72
    private let headerHeight: CGFloat = 46
    private let actionBarHeight: CGFloat = 36
    private let dividerHeight: CGFloat = 1
    private let statusHeight: CGFloat = 34
    private var isBusy: Bool {
        model.isTransforming || model.isInserting
    }

    private var selectedMode: PromptMode? {
        model.modes.first { $0.id == model.selectedModeID }
    }

    private var primaryActionTitle: String {
        model.resultText.isEmpty ? L10n.text("popover.action.transform") : L10n.text("popover.action.insert")
    }

    private var busyTitle: String {
        model.isInserting ? L10n.text("popover.busy.inserting") : L10n.text("popover.busy.transforming")
    }

    private var modeIconName: String {
        modeIcon(for: model.selectedModeID)
    }

    private var selectedModeDisplayName: String {
        guard let selectedMode else {
            return L10n.text("popover.mode.picker")
        }
        return selectedMode.localizedName
    }

    private var popoverHeight: CGFloat {
        headerHeight
            + dividerHeight
            + inputHeight
            + (model.resultText.isEmpty ? 0 : dividerHeight + resultHeight)
            + (model.errorMessage == nil ? 0 : dividerHeight + statusHeight)
            + dividerHeight
            + actionBarHeight
    }

    private var inputHeight: CGFloat {
        editorHeight(
            for: model.sourceText,
            measuredHeight: sourceMeasuredHeight,
            maxRows: maxSourceEditorRows
        )
    }

    private var resultHeight: CGFloat {
        editorHeight(
            for: model.resultText,
            measuredHeight: resultMeasuredHeight,
            maxRows: maxResultEditorRows
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.45)
            commandInput
            resultPanel
            statusStrip
            Divider().opacity(0.45)
            actionBar
        }
        .background(
            PopoverKeyEventHandler(
                onSubmit: { model.submit() },
                onInsertOriginal: { model.insertOriginal() },
                onEscape: { model.escape() },
                onCycleMode: { model.cyclePromptMode(direction: $0) }
            )
        )
        .frame(width: 600, height: popoverHeight, alignment: .top)
        .background(InkletTheme.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(InkletTheme.strongBorder)
        }
        .shadow(color: .black.opacity(0.75), radius: 48, x: 0, y: 28)
        .shadow(color: .white.opacity(0.03), radius: 0, x: 0, y: 1)
        .onAppear {
            publishPopoverHeight()
            focusSourceEditor()
        }
        .onChange(of: popoverHeight) {
            publishPopoverHeight()
        }
        .onChange(of: model.openRevision) {
            focusSourceEditor()
        }
    }

    private var commandInput: some View {
        ZStack(alignment: .bottomTrailing) {
            InkletTextView(
                text: Binding(
                    get: { model.sourceText },
                    set: { model.updateSourceText($0) }
                ),
                placeholder: L10n.text("popover.input.placeholder"),
                isEditable: !isBusy,
                onSubmit: { model.submit() },
                onInsertOriginal: { model.insertOriginal() },
                onEscape: { model.escape() }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(height: inputHeight)
        .background {
            editorHeightReader(for: model.sourceText, key: SourceEditorHeightPreferenceKey.self)
        }
        .onPreferenceChange(SourceEditorHeightPreferenceKey.self) { height in
            sourceMeasuredHeight = height
        }
    }

    @ViewBuilder
    private var resultPanel: some View {
        if !model.resultText.isEmpty {
            Divider().opacity(0.45)
            ZStack(alignment: .topTrailing) {
                InkletTextView(
                    text: Binding(
                        get: { model.resultText },
                        set: { model.updateResultText($0) }
                    ),
                    isEditable: !isBusy,
                    onSubmit: { model.submit() },
                    onInsertOriginal: { model.insertOriginal() },
                    onEscape: { model.escape() }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(InkletTheme.primary.opacity(0.08))
            }
            .frame(height: resultHeight)
            .background {
                editorHeightReader(for: model.resultText, key: ResultEditorHeightPreferenceKey.self)
            }
            .onPreferenceChange(ResultEditorHeightPreferenceKey.self) { height in
                resultMeasuredHeight = height
            }
            .transition(.opacity.combined(with: .move(edge: .bottom)))
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                    isResultFocused = true
                }
            }
        }
    }

    @ViewBuilder
    private var statusStrip: some View {
        if let errorMessage = model.errorMessage {
            Divider().opacity(0.45)
            Text(errorMessage)
                .font(.system(size: 12))
                .foregroundStyle(.red.opacity(0.9))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.13))
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 6) {
            Menu {
                ForEach(model.modes) { mode in
                    Button {
                        model.selectedModeID = mode.id
                    } label: {
                        Label(mode.localizedName, systemImage: modeIcon(for: mode.id))
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: modeIconName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(InkletTheme.primary.opacity(0.82))
                    Text(selectedModeDisplayName)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(InkletTheme.textSecondary.opacity(0.78))
                }
                .foregroundStyle(InkletTheme.textPrimary.opacity(0.92))
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .background(Color.clear, in: RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(.plain)
            .menuIndicator(.hidden)

            Spacer()

            Text("\(model.currentProviderName) · \(model.currentModelName)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(InkletTheme.textSecondary.opacity(0.62))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 188, alignment: .trailing)
                .padding(.trailing, 1)

            Button {
                model.openSettings()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(InkletTheme.textSecondary.opacity(0.72))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.text("app.menu.settings"))
        }
        .padding(.horizontal, 14)
        .frame(height: headerHeight)
        .background(Color.white.opacity(0.018))
    }

    private var actionBar: some View {
        HStack(alignment: .center, spacing: 3) {
            if isBusy {
                loadingIndicator
            } else {
                shortcutHint(keys: ["↵"], label: primaryActionTitle, primary: !model.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.resultText.isEmpty) {
                    model.submit()
                }
                shortcutHint(keys: ["⌘", "↵"], label: L10n.text("popover.action.insertOriginal")) {
                    model.insertOriginal()
                }
                shortcutHint(keys: ["⇧", "↵"], label: L10n.text("popover.hint.newLine")) {
                    insertNewLine()
                }
                shortcutHint(keys: ["⌘", "↑/↓"], label: L10n.text("popover.hint.mode")) {
                    model.cyclePromptMode(direction: 1)
                }

                Spacer()

                if let voiceShortcutHint = model.voiceShortcutHint {
                    voiceHint(shortcut: voiceShortcutHint)
                }

                shortcutHint(keys: ["esc"], label: model.resultText.isEmpty ? L10n.text("popover.hint.close") : L10n.text("popover.hint.back")) {
                    model.escape()
                }
            }
        }
        .padding(.horizontal, 7)
        .frame(height: actionBarHeight)
        .background(InkletTheme.toolbarBackground)
        .accessibilityLabel(L10n.text("popover.hint.accessibility"))
    }

    private func voiceHint(shortcut: VoiceInputConfig.Shortcut) -> some View {
        HStack(spacing: 2) {
            Image(systemName: "mic")
                .font(.system(size: 8))
            Keycap(title: shortcut.localizedName, compact: true)
            Text(L10n.text("popover.hint.voice"))
                .font(.system(size: 8))
                .lineLimit(1)
        }
        .foregroundStyle(InkletTheme.textSecondary.opacity(0.78))
        .padding(.horizontal, 2)
        .accessibilityLabel("\(L10n.text("settings.quickStart.voice")): \(shortcut.localizedName)")
    }

    private var loadingIndicator: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                ForEach(0..<3) { index in
                    Circle()
                        .fill(InkletTheme.primary.opacity(0.85))
                        .frame(width: 5, height: 5)
                        .opacity(index == 1 ? 0.65 : 1)
                }
            }
            Text(busyTitle)
                .font(.system(size: 11))
                .foregroundStyle(InkletTheme.textSecondary)
            Spacer()
        }
        .padding(.horizontal, 4)
    }

    private func shortcutHint(keys: [String], label: String, primary: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 2) {
                ForEach(keys, id: \.self) { key in
                    Keycap(title: key, compact: true)
                }
                Text(label)
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(primary ? Color.white : InkletTheme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .padding(.horizontal, primary ? 5 : 2)
            .padding(.vertical, 2)
            .background(primary ? InkletTheme.primary : Color.white.opacity(0.001), in: RoundedRectangle(cornerRadius: 7))
            .shadow(color: primary ? InkletTheme.primary.opacity(0.35) : .clear, radius: 8, x: 0, y: 1)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .help(label)
    }

    private func insertNewLine() {
        guard !model.isTransforming, !model.isInserting else {
            return
        }

        if isResultFocused || !model.resultText.isEmpty && !isSourceFocused {
            model.updateResultText(model.resultText + "\n")
            isResultFocused = true
        } else {
            model.updateSourceText(model.sourceText + "\n")
            isSourceFocused = true
        }
    }

    private func modeIcon(for modeID: String) -> String {
        switch modeID {
        case PromptMode.autoID:
            "sparkles"
        case PromptMode.chineseToEnglishID:
            "globe.asia.australia"
        case PromptMode.chineseSummaryID:
            "text.alignleft"
        case PromptMode.polishEnglishID:
            "wand.and.stars"
        default:
            "arrow.right"
        }
    }

    private func focusSourceEditor() {
        DispatchQueue.main.async {
            isSourceFocused = true
        }
    }

    private func editorHeight(for text: String, measuredHeight: CGFloat, maxRows: CGFloat) -> CGFloat {
        max(
            clampedEditorHeight(measuredHeight, maxRows: maxRows),
            estimatedEditorHeight(for: text, maxRows: maxRows)
        )
    }

    private func clampedEditorHeight(_ measuredHeight: CGFloat, maxRows: CGFloat) -> CGFloat {
        let minHeight = minEditorRows * editorLineHeight + editorVerticalPadding
        let maxHeight = maxRows * editorLineHeight + editorVerticalPadding
        return min(max(measuredHeight, minHeight), maxHeight)
    }

    private func estimatedEditorHeight(for text: String, maxRows: CGFloat) -> CGFloat {
        let minHeight = minEditorRows * editorLineHeight + editorVerticalPadding
        let maxHeight = maxRows * editorLineHeight + editorVerticalPadding
        guard !text.isEmpty else {
            return minHeight
        }

        let rows = text
            .components(separatedBy: .newlines)
            .map { line -> CGFloat in
                let characterCount = max(line.count, 1)
                return max(ceil(CGFloat(characterCount) / editorEstimatedCharactersPerLine), 1)
            }
            .reduce(CGFloat(0), +)

        return min(max(rows * editorLineHeight + editorVerticalPadding, minHeight), maxHeight)
    }

    private func publishPopoverHeight() {
        guard model.preferredPopoverHeight != popoverHeight else {
            return
        }
        model.preferredPopoverHeight = popoverHeight
    }

    private func editorHeightReader<Key: PreferenceKey>(
        for text: String,
        key: Key.Type
    ) -> some View where Key.Value == CGFloat {
        Text(text.isEmpty ? " \n " : text)
            .font(.system(size: 14))
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .hidden()
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: key,
                        value: proxy.size.height
                    )
                }
            }
    }
}

private struct SourceEditorHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 60

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct ResultEditorHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 60

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private final class InkletTextContainerView: NSView {
    let scrollView = NSScrollView()
    let placeholderLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.font = .systemFont(ofSize: 14)
        placeholderLabel.textColor = .placeholderTextColor
        placeholderLabel.lineBreakMode = .byTruncatingTail
        placeholderLabel.maximumNumberOfLines = 1
        placeholderLabel.isEditable = false
        placeholderLabel.isSelectable = false
        placeholderLabel.backgroundColor = .clear
        placeholderLabel.drawsBackground = false

        addSubview(scrollView)
        addSubview(placeholderLabel)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            placeholderLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            placeholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            placeholderLabel.topAnchor.constraint(equalTo: topAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @MainActor
    func updatePlaceholderVisibility() {
        let textView = scrollView.documentView as? NSTextView
        placeholderLabel.isHidden = placeholderLabel.stringValue.isEmpty
            || textView?.string.isEmpty == false
            || textView?.hasMarkedText() == true
    }
}

private final class InkletNativeTextView: NSTextView {
    var onInputStateChange: (() -> Void)?

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        onInputStateChange?()
    }

    override func unmarkText() {
        super.unmarkText()
        onInputStateChange?()
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        super.insertText(insertString, replacementRange: replacementRange)
        onInputStateChange?()
    }
}

private struct InkletTextView: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String?
    var isEditable: Bool
    var onSubmit: (() -> Void)?
    var onInsertOriginal: (() -> Void)?
    var onEscape: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            onSubmit: onSubmit,
            onInsertOriginal: onInsertOriginal,
            onEscape: onEscape
        )
    }

    func makeNSView(context: Context) -> InkletTextContainerView {
        let container = InkletTextContainerView()
        let scrollView = container.scrollView
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.contentInsets = NSEdgeInsetsZero
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.horizontalScrollElasticity = .none

        let textView = InkletNativeTextView()
        textView.string = text
        textView.delegate = context.coordinator
        textView.onInputStateChange = { [weak coordinator = context.coordinator, weak textView, weak container] in
            guard let textView else {
                return
            }
            coordinator?.syncText(from: textView)
            container?.updatePlaceholderVisibility()
        }
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = false
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.font = .systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.insertionPointColor = .controlAccentColor
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        scrollView.documentView = textView
        context.coordinator.textView = textView
        container.placeholderLabel.stringValue = placeholder ?? ""
        container.updatePlaceholderVisibility()
        return container
    }

    func updateNSView(_ container: InkletTextContainerView, context: Context) {
        let scrollView = container.scrollView
        guard let textView = scrollView.documentView as? NSTextView else {
            return
        }

        context.coordinator.text = $text
        context.coordinator.onSubmit = onSubmit
        context.coordinator.onInsertOriginal = onInsertOriginal
        context.coordinator.onEscape = onEscape
        context.coordinator.textView = textView

        textView.isEditable = isEditable
        textView.font = .systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.insertionPointColor = .controlAccentColor
        container.placeholderLabel.stringValue = placeholder ?? ""

        if !textView.hasMarkedText(), textView.string != text {
            textView.string = text
        }
        container.updatePlaceholderVisibility()
    }

    final class Coordinator: NSObject, NSTextViewDelegate, @unchecked Sendable {
        var text: Binding<String>
        var onSubmit: (() -> Void)?
        var onInsertOriginal: (() -> Void)?
        var onEscape: (() -> Void)?
        weak var textView: NSTextView?

        init(
            text: Binding<String>,
            onSubmit: (() -> Void)?,
            onInsertOriginal: (() -> Void)?,
            onEscape: (() -> Void)?
        ) {
            self.text = text
            self.onSubmit = onSubmit
            self.onInsertOriginal = onInsertOriginal
            self.onEscape = onEscape
            super.init()
        }

        @MainActor
        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else {
                return
            }

            syncText(from: textView)
            textView.enclosingScrollView?.superview
                .flatMap { $0 as? InkletTextContainerView }?
                .updatePlaceholderVisibility()
        }

        @MainActor
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else {
                return
            }

            textView.enclosingScrollView?.superview
                .flatMap { $0 as? InkletTextContainerView }?
                .updatePlaceholderVisibility()
        }

        @MainActor
        func syncText(from textView: NSTextView) {
            text.wrappedValue = textView.string
        }

        @MainActor
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard !textView.hasMarkedText() else {
                return false
            }

            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                onEscape?()
                return true
            }

            guard commandSelector == #selector(NSResponder.insertNewline(_:))
                    || commandSelector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:))
            else {
                return false
            }

            let modifiers = NSApp.currentEvent?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []
            if modifiers.contains(.command) {
                onInsertOriginal?()
                return true
            }

            if modifiers.contains(.shift) || modifiers.contains(.option) {
                return false
            }

            onSubmit?()
            return true
        }
    }
}

private extension NSView {
    var descendantTextViews: [NSTextView] {
        var textViews: [NSTextView] = []
        if let textView = self as? NSTextView {
            textViews.append(textView)
        }

        for subview in subviews {
            textViews.append(contentsOf: subview.descendantTextViews)
        }

        return textViews
    }
}

private struct PopoverKeyEventHandler: NSViewRepresentable {
    let onSubmit: () -> Void
    let onInsertOriginal: () -> Void
    let onEscape: () -> Void
    let onCycleMode: (Int) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onSubmit = onSubmit
        context.coordinator.onInsertOriginal = onInsertOriginal
        context.coordinator.onEscape = onEscape
        context.coordinator.onCycleMode = onCycleMode
        context.coordinator.attach(to: nsView)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onSubmit: onSubmit,
            onInsertOriginal: onInsertOriginal,
            onEscape: onEscape,
            onCycleMode: onCycleMode
        )
    }

    @MainActor
    final class Coordinator {
        var onSubmit: () -> Void
        var onInsertOriginal: () -> Void
        var onEscape: () -> Void
        var onCycleMode: (Int) -> Void
        private weak var view: NSView?
        private var monitor: Any?

        init(
            onSubmit: @escaping () -> Void,
            onInsertOriginal: @escaping () -> Void,
            onEscape: @escaping () -> Void,
            onCycleMode: @escaping (Int) -> Void
        ) {
            self.onSubmit = onSubmit
            self.onInsertOriginal = onInsertOriginal
            self.onEscape = onEscape
            self.onCycleMode = onCycleMode
        }

        func detach() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        func attach(to view: NSView) {
            self.view = view
            guard monitor == nil else { return }

            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handle(event) ?? event
            }
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard let window = view?.window,
                  event.window === window,
                  window.isKeyWindow
            else {
                return event
            }

            let isReturnKey = event.keyCode == 36 || event.keyCode == 76
            if isComposingText, isReturnKey || event.keyCode == 53 {
                return event
            }

            if event.keyCode == 53 {
                onEscape()
                return nil
            }

            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if modifiers.contains(.command), !modifiers.contains(.shift), !modifiers.contains(.option) {
                if event.keyCode == 126 {
                    onCycleMode(-1)
                    return nil
                }

                if event.keyCode == 125 {
                    onCycleMode(1)
                    return nil
                }
            }

            guard isReturnKey else {
                return event
            }

            if modifiers.contains(.command) {
                onInsertOriginal()
                return nil
            }

            if !modifiers.contains(.shift), !modifiers.contains(.option) {
                onSubmit()
                return nil
            }

            return event
        }

        private var isComposingText: Bool {
            guard let responder = view?.window?.firstResponder as? NSTextInputClient else {
                return false
            }

            return responder.hasMarkedText()
        }
    }
}
