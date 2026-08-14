import AppKit
import Combine
import SwiftUI
import InkletCore

@MainActor
private final class InkletPopoverPanel: NSPanel {
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    override func keyDown(with event: NSEvent) {
        guard event.keyCode == 53 else {
            super.keyDown(with: event)
            return
        }

        onEscape?()
    }
}

@MainActor
private final class ClearHostingView<Content: View>: NSHostingView<Content> {
    private let cornerRadius: CGFloat = 16

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureLayer()
    }

    override func layout() {
        super.layout()
        configureLayer()
    }

    private func configureLayer() {
        wantsLayer = true
        guard let layer else { return }
        layer.backgroundColor = NSColor.clear.cgColor
        layer.cornerRadius = cornerRadius
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
    }
}

@MainActor
final class InkletPopoverWindowController: NSWindowController {
    private let model: InkletPopoverViewModel
    private var previousApplication: NSRunningApplication?
    private var cancellables = Set<AnyCancellable>()
    private let popoverWidth: CGFloat = 600

    var onOpenSettings: (() -> Void)? {
        get {
            model.onOpenSettings
        }
        set {
            model.onOpenSettings = newValue
        }
    }

    var onBusyChange: ((Bool) -> Void)?

    var isBusy: Bool {
        model.isBusy
    }

    init(historyStore: any HistoryStore = JSONLHistoryStore()) {
        self.model = InkletPopoverViewModel(historyStore: historyStore)

        let panel = InkletPopoverPanel(
            contentRect: NSRect(x: 0, y: 0, width: popoverWidth, height: 168),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.title = "Inklet"
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        panel.contentView = ClearHostingView(rootView: InkletPopoverView(model: model))

        super.init(window: panel)
        panel.onEscape = { [weak self] in
            self?.model.escape()
        }
        shouldCascadeWindows = false

        model.$preferredPopoverHeight
            .removeDuplicates()
            .sink { [weak self] height in
                self?.resizePopover(to: height)
            }
            .store(in: &cancellables)

        Publishers.CombineLatest(model.$isTransforming, model.$isInserting)
            .map { $0 || $1 }
            .removeDuplicates()
            .sink { [weak self] isBusy in
                self?.onBusyChange?(isBusy)
            }
            .store(in: &cancellables)

        model.onHidePopover = { [weak self] in
            self?.window?.orderOut(nil)
        }
        model.onFocusPopover = { [weak self] in
            self?.focusPopover()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(fallbackApplication: NSRunningApplication? = nil) {
        let frontmostApplication = NSWorkspace.shared.frontmostApplication
        if frontmostApplication?.processIdentifier == NSRunningApplication.current.processIdentifier {
            previousApplication = fallbackApplication
        } else {
            previousApplication = frontmostApplication ?? fallbackApplication
        }
        model.resetForOpen(previousApplication: previousApplication)
        window?.appearance = model.appearance.nsAppearance
        resizePopover(to: model.preferredPopoverHeight)
        focusPopover()
        focusSourceTextView()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.resizePopover(to: self.model.preferredPopoverHeight)
            self.focusSourceTextView()
        }
    }

    func hide() {
        window?.orderOut(nil)
    }

    func cancelForMigrationMaintenance() {
        model.cancelForMigrationMaintenance()
        window?.orderOut(nil)
    }

    private func focusPopover() {
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func focusSourceTextView() {
        guard let window,
              let textView = window.contentView?.descendantTextViews.first
        else {
            return
        }

        window.makeFirstResponder(textView)
    }

    private func resizePopover(to height: CGFloat) {
        guard let window else {
            return
        }

        let height = max(1, height)
        var frame = window.frame

        let topY = frame.maxY
        frame.size.width = popoverWidth
        frame.size.height = height
        frame.origin.y = topY - height
        window.setContentSize(NSSize(width: popoverWidth, height: height))
        window.setFrame(frame, display: true, animate: false)
        window.contentView?.frame = NSRect(x: 0, y: 0, width: popoverWidth, height: height)
        window.contentView?.needsLayout = true
        window.contentView?.layoutSubtreeIfNeeded()
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
