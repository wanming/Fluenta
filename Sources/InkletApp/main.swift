import AppKit
import InkletCore

let storagePaths: InkletStoragePaths
do {
    storagePaths = try InkletStoragePaths.current()
} catch {
    preconditionFailure("Unable to resolve Inklet storage paths")
}

switch storagePaths.bundleIdentifier {
case InkletStoragePaths.productionBundleIdentifier,
     InkletStoragePaths.localBundleIdentifier:
    break
default:
    preconditionFailure("Unsupported Inklet bundle identifier")
}

let migrator = LegacySandboxDataMigrator.live(storagePaths: storagePaths)
let migrationOutcome = migrator.migrateAutomatically()

let app = NSApplication.shared
let delegate = AppDelegate(
    migrationOutcome: migrationOutcome,
    migrator: migrator,
    storagePaths: storagePaths
)
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
