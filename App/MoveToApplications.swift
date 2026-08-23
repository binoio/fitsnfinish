#if os(macOS)
import AppKit

/// Offers to move the app into an Applications folder when launched from
/// anywhere else (Downloads, a disk image, or a Gatekeeper-translocated
/// path) — Sparkle cannot install updates over a copy running from those
/// locations.
enum MoveToApplications {
    private static let suppressKey = "FFSuppressMoveToApplicationsPrompt"

    static func offerIfNeeded() {
        let bundle = Bundle.main.bundleURL
        // Bare `swift run` / test binaries have no .app bundle; dev launches
        // opt out via the environment (Scripts/run.sh sets it).
        guard bundle.pathExtension == "app",
              ProcessInfo.processInfo.environment["FF_SKIP_MOVE_PROMPT"] == nil,
              !bundle.path.contains("/Applications/"),
              !UserDefaults.standard.bool(forKey: suppressKey)
        else { return }

        let alert = NSAlert()
        alert.messageText = "Move FITS n' Finish to the Applications folder?"
        alert.informativeText = """
        FITS n' Finish is running from \
        \(displayLocation(of: bundle)). Keeping it outside the Applications \
        folder prevents automatic updates from installing.
        """
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"

        let response = alert.runModal()
        if alert.suppressionButton?.state == .on {
            UserDefaults.standard.set(true, forKey: suppressKey)
        }
        guard response == .alertFirstButtonReturn else { return }
        move(from: bundle)
    }

    private static func displayLocation(of bundle: URL) -> String {
        if bundle.path.contains("/AppTranslocation/") {
            return "a temporary location (it was launched straight from a download)"
        }
        return "“\(bundle.deletingLastPathComponent().path)”"
    }

    private static func move(from source: URL) {
        let fileManager = FileManager.default
        var applications = URL(fileURLWithPath: "/Applications", isDirectory: true)
        if !fileManager.isWritableFile(atPath: applications.path) {
            applications = fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications", isDirectory: true)
            try? fileManager.createDirectory(
                at: applications, withIntermediateDirectories: true
            )
        }
        let destination = applications.appendingPathComponent(source.lastPathComponent)

        do {
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.trashItem(at: destination, resultingItemURL: nil)
            }
            try fileManager.copyItem(at: source, to: destination)
            stripQuarantine(destination)
            // Tidy up the original unless it is the read-only translocated
            // mirror (the true original is unknown in that case).
            if !source.path.contains("/AppTranslocation/") {
                try? fileManager.trashItem(at: source, resultingItemURL: nil)
            }
            relaunch(at: destination)
        } catch {
            let failure = NSAlert(error: error)
            failure.messageText = "Couldn't move FITS n' Finish"
            failure.runModal()
        }
    }

    /// The copy inherits the download's quarantine attribute; removing it
    /// stops Gatekeeper from translocating the moved app all over again.
    /// (The app is notarized, so this drops no protection the first launch
    /// hasn't already applied.)
    private static func stripQuarantine(_ url: URL) {
        let xattr = Process()
        xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        xattr.arguments = ["-dr", "com.apple.quarantine", url.path]
        try? xattr.run()
        xattr.waitUntilExit()
    }

    private static func relaunch(at url: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
    }
}

final class MacAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MoveToApplications.offerIfNeeded()
    }
}
#endif
