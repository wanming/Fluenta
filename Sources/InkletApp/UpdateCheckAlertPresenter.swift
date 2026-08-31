import AppKit
import InkletCore

@MainActor
final class UpdateCheckAlertPresenter: UpdateCheckPresenting {
    struct AlertContent: Equatable {
        let messageText: String
        let informativeText: String
        let primaryButtonTitle: String
        let secondaryButtonTitle: String?
    }

    private let alertRunner: @MainActor (AlertContent) -> NSApplication.ModalResponse
    private let urlOpener: @MainActor (URL) -> Void

    init(
        alertRunner: @escaping @MainActor (AlertContent) -> NSApplication.ModalResponse = defaultAlertRunner,
        urlOpener: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }
    ) {
        self.alertRunner = alertRunner
        self.urlOpener = urlOpener
    }

    func presentUpdate(_ release: InkletRelease, currentVersion: String) {
        var components = [
            L10n.format(
                "update.available.latestVersion",
                release.version.marketingVersion,
                release.version.buildNumber
            ),
            L10n.format("update.available.currentVersion", currentVersion),
        ]

        if let releaseName = usefulReleaseName(for: release) {
            components.append(releaseName)
        }
        components.append(
            release.notes.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                ?? L10n.text("update.available.noNotes")
        )

        let response = alertRunner(
            AlertContent(
                messageText: L10n.text("update.available.title"),
                informativeText: components.joined(separator: "\n\n"),
                primaryButtonTitle: L10n.text("update.action.viewOnGitHub"),
                secondaryButtonTitle: L10n.text("update.action.later")
            )
        )
        if response == .alertFirstButtonReturn {
            urlOpener(release.pageURL)
        }
    }

    func presentUpToDate(currentVersion: String) {
        _ = alertRunner(
            AlertContent(
                messageText: L10n.text("update.upToDate.title"),
                informativeText: L10n.format("update.upToDate.message", currentVersion),
                primaryButtonTitle: L10n.text("update.action.cancel"),
                secondaryButtonTitle: nil
            )
        )
    }

    func presentFailure(retry: @escaping @MainActor () -> Void) {
        let response = alertRunner(
            AlertContent(
                messageText: L10n.text("update.error.title"),
                informativeText: L10n.text("update.error.message"),
                primaryButtonTitle: L10n.text("update.action.retry"),
                secondaryButtonTitle: L10n.text("update.action.cancel")
            )
        )
        if response == .alertFirstButtonReturn {
            retry()
        }
    }

    private static func defaultAlertRunner(_ content: AlertContent) -> NSApplication.ModalResponse {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = content.messageText
        alert.informativeText = content.informativeText
        alert.addButton(withTitle: content.primaryButtonTitle)
        if let secondaryButtonTitle = content.secondaryButtonTitle {
            alert.addButton(withTitle: secondaryButtonTitle)
        }
        return alert.runModal()
    }

    private func usefulReleaseName(for release: InkletRelease) -> String? {
        guard let name = release.name?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
              !isVersionMetadata(name, for: release)
        else {
            return nil
        }
        return name
    }

    private func isVersionMetadata(_ name: String, for release: InkletRelease) -> Bool {
        let marketingVersion = release.version.marketingVersion
        let buildNumber = release.version.buildNumber
        let exactMetadata = [
            release.tagName,
            marketingVersion,
            "v\(marketingVersion)",
            "\(marketingVersion) (\(buildNumber))",
            "\(marketingVersion) (build \(buildNumber))",
            "Inklet \(marketingVersion) (\(buildNumber))",
            "Inklet \(marketingVersion) (build \(buildNumber))",
        ]
        if exactMetadata.contains(where: { $0.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) {
            return true
        }

        let pattern = #"^(?:inklet\s+)?v?\d+(?:\.\d+)*(?:[-\s]*(?:build\s*)?\d+)?(?:\s*\(\s*(?:build\s*)?\d+\s*\))?$"#
        return name.range(of: pattern, options: [.regularExpression, .caseInsensitive, .diacriticInsensitive]) != nil
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
