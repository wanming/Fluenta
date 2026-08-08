import AppKit
import SwiftUI
import InkletCore

struct WritingModePickerView: View {
    static let maxVisibleRows = 6
    static let searchHeight: CGFloat = 46
    static let rowHeight: CGFloat = 40
    static let footerHeight: CGFloat = 36

    @ObservedObject var model: InkletPopoverViewModel
    @State private var hoveredModeID: String?
    @State private var mouseHighlightedModeID: String?

    private var filteredItems: [WritingModePickerItem] {
        model.modePickerState.filteredItems
    }

    private var resultsHeight: CGFloat {
        let rowCount = min(max(filteredItems.count, 1), Self.maxVisibleRows)
        return CGFloat(rowCount) * Self.rowHeight
    }

    static func preferredHeight(resultCount: Int) -> CGFloat {
        let rowCount = min(max(resultCount, 1), maxVisibleRows)
        return searchHeight + CGFloat(rowCount) * rowHeight + footerHeight + 2
    }

    var body: some View {
        VStack(spacing: 0) {
            searchHeader
            Divider().opacity(0.45)
            results
            Divider().opacity(0.45)
            footer
        }
        .frame(
            width: 600,
            height: Self.preferredHeight(resultCount: filteredItems.count),
            alignment: .top
        )
        .background(InkletTheme.panelBackground)
    }

    private var searchHeader: some View {
        HStack(spacing: 10) {
            WritingModeSearchField(
                text: Binding(
                    get: { model.modePickerState.query },
                    set: { model.updateModeSearchQuery($0) }
                ),
                placeholder: L10n.text("popover.modeSearch.placeholder"),
                accessibilityLabel: L10n.text("popover.modeSearch.placeholder"),
                focusRevision: model.modeSearchFocusRevision
            )
            .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28)

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
            .accessibilityLabel(L10n.text("app.menu.settings"))
        }
        .padding(.horizontal, 14)
        .frame(height: Self.searchHeight)
        .background(Color.white.opacity(0.018))
    }

    private var results: some View {
        ScrollViewReader { proxy in
            Group {
                if filteredItems.isEmpty {
                    Text(L10n.text("popover.modeSearch.empty"))
                        .font(.system(size: 12))
                        .foregroundStyle(InkletTheme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .frame(height: Self.rowHeight)
                } else {
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVStack(spacing: 0) {
                            ForEach(filteredItems) { item in
                                modeRow(item)
                                    .id(item.id)
                            }
                        }
                    }
                    .frame(height: resultsHeight)
                    .onAppear {
                        guard let highlightedModeID = model.modePickerState.highlightedModeID else {
                            return
                        }
                        proxy.scrollTo(highlightedModeID, anchor: .center)
                    }
                    .onChange(of: model.modePickerState.highlightedModeID) { _, modeID in
                        guard let modeID else {
                            return
                        }
                        if let mouseHighlightedModeID {
                            self.mouseHighlightedModeID = nil
                            if mouseHighlightedModeID == modeID {
                                return
                            }
                        }
                        withAnimation(.easeOut(duration: 0.08)) {
                            proxy.scrollTo(modeID, anchor: .center)
                        }
                    }
                }
            }
            .frame(height: resultsHeight)
        }
    }

    private func modeRow(_ item: WritingModePickerItem) -> some View {
        let isHighlighted = model.modePickerState.highlightedModeID == item.id
        let isHovered = hoveredModeID == item.id

        return Button {
            highlightModeFromMouse(modeID: item.id)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: writingModeIconName(for: item.id))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(
                        isHighlighted
                            ? InkletTheme.primary.opacity(0.92)
                            : InkletTheme.textSecondary.opacity(0.78)
                    )
                    .frame(width: 18)

                Text(item.title)
                    .font(.system(size: 13, weight: isHighlighted ? .semibold : .regular))
                    .foregroundStyle(InkletTheme.textPrimary.opacity(0.94))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 8)

                if isHighlighted {
                    HStack(spacing: 4) {
                        Keycap(title: "tab", compact: true)
                        Text(L10n.text("popover.modeSearch.write"))
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(InkletTheme.textSecondary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: Self.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(WritingModeRowButtonStyle(
            isHighlighted: isHighlighted,
            isHovered: isHovered
        ))
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                model.commitMode(modeID: item.id)
            }
        )
        .onHover { isHovering in
            if isHovering {
                hoveredModeID = item.id
            } else if hoveredModeID == item.id {
                hoveredModeID = nil
            }
        }
        .help(item.title)
        .accessibilityLabel(item.title)
        .modifier(SelectedWritingModeAccessibilityModifier(isSelected: isHighlighted))
        .accessibilityAction(named: L10n.text("popover.modeSearch.write")) {
            model.commitMode(modeID: item.id)
        }
    }

    private func highlightModeFromMouse(modeID: String) {
        mouseHighlightedModeID = modeID
        model.highlightMode(modeID: modeID)
        DispatchQueue.main.asyncAfter(
            deadline: .now() + NSEvent.doubleClickInterval
        ) {
            guard mouseHighlightedModeID == modeID else {
                return
            }
            mouseHighlightedModeID = nil
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            HStack(spacing: 2) {
                Keycap(title: "↑", compact: true)
                Keycap(title: "↓", compact: true)
                Text(L10n.text("popover.modeSearch.select"))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(InkletTheme.textSecondary)
                    .lineLimit(1)
                    .padding(.leading, 2)
            }
            .accessibilityElement(children: .combine)
            footerHint(key: "tab", label: L10n.text("popover.modeSearch.write"))
            Spacer()
            footerHint(key: "esc", label: L10n.text("popover.hint.close"))
        }
        .padding(.horizontal, 12)
        .frame(height: Self.footerHeight)
        .background(InkletTheme.toolbarBackground)
    }

    private func footerHint(key: String, label: String) -> some View {
        HStack(spacing: 4) {
            Keycap(title: key, compact: true)
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(InkletTheme.textSecondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

func writingModeIconName(for modeID: String) -> String {
    switch modeID {
    case PromptMode.autoID:
        "sparkles"
    case PromptMode.translateToEnglishID, PromptMode.chineseToEnglishID:
        "globe.asia.australia"
    case PromptMode.chineseSummaryID:
        "text.alignleft"
    case PromptMode.polishEnglishID, PromptMode.improveWritingID:
        "wand.and.stars"
    default:
        "arrow.right"
    }
}

private struct WritingModeRowButtonStyle: ButtonStyle {
    let isHighlighted: Bool
    let isHovered: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity)
            .frame(height: WritingModePickerView.rowHeight)
            .background(backgroundColor(isPressed: configuration.isPressed))
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        if isPressed {
            return InkletTheme.primary.opacity(0.24)
        }
        if isHighlighted {
            return InkletTheme.primary.opacity(0.16)
        }
        if isHovered {
            return Color.white.opacity(0.055)
        }
        return .clear
    }
}

private struct SelectedWritingModeAccessibilityModifier: ViewModifier {
    let isSelected: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isSelected {
            content.accessibilityAddTraits(.isSelected)
        } else {
            content
        }
    }
}

private struct WritingModeSearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let accessibilityLabel: String
    let focusRevision: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let searchField = NSSearchField(frame: .zero)
        searchField.delegate = context.coordinator
        searchField.stringValue = text
        searchField.placeholderString = placeholder
        searchField.font = .systemFont(ofSize: 15)
        searchField.focusRingType = .none
        searchField.isBezeled = false
        searchField.drawsBackground = false
        searchField.sendsSearchStringImmediately = true
        searchField.setAccessibilityLabel(accessibilityLabel)
        return searchField
    }

    func updateNSView(_ searchField: NSSearchField, context: Context) {
        context.coordinator.text = $text
        searchField.placeholderString = placeholder
        searchField.font = .systemFont(ofSize: 15)
        searchField.setAccessibilityLabel(accessibilityLabel)

        let currentEditor = searchField.currentEditor() as? NSTextView
        if currentEditor?.hasMarkedText() != true, searchField.stringValue != text {
            searchField.stringValue = text
        }

        guard context.coordinator.focusedRevision != focusRevision else {
            return
        }
        context.coordinator.focusedRevision = focusRevision
        DispatchQueue.main.async { [weak searchField] in
            guard let searchField else {
                return
            }
            searchField.window?.makeFirstResponder(searchField)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        var focusedRevision: Int?

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let searchField = notification.object as? NSSearchField else {
                return
            }
            text.wrappedValue = searchField.stringValue
        }
    }
}
