import Foundation
import AppKit
import WhirCore

/// Bridges App Sandbox file access. Outside the sandbox (direct/notarized build)
/// every method is a no-op and the app reads the real `~/.claude` / `~/.codex`
/// directly. Inside the MAS sandbox, the user grants those hidden folders once
/// via an open panel; we persist security-scoped bookmarks and bracket each scan
/// with start/stop access.
enum FolderAccess {
    static let claudeID = "claude"   // user grants ~/.claude
    static let codexID  = "codex"    // user grants ~/.codex

    static var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    private static func key(_ id: String) -> String { "folderBookmark.\(id)" }
    static func hasBookmark(_ id: String) -> Bool { UserDefaults.standard.data(forKey: key(id)) != nil }

    /// One granted folder is enough to start — not everyone uses both tools.
    /// The popover offers the missing grant afterwards.
    static var needsOnboarding: Bool {
        isSandboxed && !hasBookmark(claudeID) && !hasBookmark(codexID)
    }

    struct Roots { let claudeProjects: String; let codexSessions: String? }

    /// Real on-disk roots to scan. Outside the sandbox: default home paths
    /// (codexSessions nil → engine honors $CODEX_HOME). Inside: from the grants.
    static func currentRoots() -> Roots {
        if !isSandboxed {
            return Roots(claudeProjects: homePath(".claude/projects"), codexSessions: nil)
        }
        let claude = resolve(claudeID)?.appendingPathComponent("projects").path
            ?? homePath(".claude/projects")
        let codex = resolve(codexID)?.appendingPathComponent("sessions").path
        return Roots(claudeProjects: claude, codexSessions: codex)
    }

    /// Run `body` with security-scoped access to the granted folders active.
    static func withAccess<T>(_ body: () -> T) -> T {
        guard isSandboxed else { return body() }
        let urls = [resolve(claudeID), resolve(codexID)].compactMap { $0 }
        // Only stop the scopes whose start actually succeeded — an unbalanced
        // stop corrupts the per-resource access count (Apple's contract).
        let started = urls.filter { $0.startAccessingSecurityScopedResource() }
        defer { started.forEach { $0.stopAccessingSecurityScopedResource() } }
        return body()
    }

    private static func resolve(_ id: String) -> URL? {
        guard let data = UserDefaults.standard.data(forKey: key(id)) else { return nil }
        var stale = false
        let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                           relativeTo: nil, bookmarkDataIsStale: &stale)
        if stale, let url {
            // Re-creating a security-scoped bookmark requires the scope to be
            // active; doing it cold yields a scope-less bookmark that would
            // overwrite the good one. Bracket the re-save with start/stop.
            let ok = url.startAccessingSecurityScopedResource()
            defer { if ok { url.stopAccessingSecurityScopedResource() } }
            if let fresh = try? url.bookmarkData(options: .withSecurityScope,
                                                 includingResourceValuesForKeys: nil, relativeTo: nil) {
                UserDefaults.standard.set(fresh, forKey: key(id))
            }
        }
        return url
    }

    private static func save(url: URL, id: String) {
        guard let data = try? url.bookmarkData(options: .withSecurityScope,
                                               includingResourceValuesForKeys: nil, relativeTo: nil)
        else { NSLog("Whir: bookmark save failed for \(id)"); return }
        UserDefaults.standard.set(data, forKey: key(id))
    }

    /// Show a folder picker pre-navigated to the target hidden folder and
    /// persist the grant. Returns whether a grant was saved.
    @MainActor @discardableResult static func grant(id: String) -> Bool {
        let name = id == claudeID ? ".claude" : ".codex"
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        // Open inside the target folder — the default "Grant" click selects it,
        // no hidden-folder hunting.
        panel.directoryURL = URL(fileURLWithPath: homePath(name), isDirectory: true)
        panel.prompt = "Grant"
        panel.message = "Grant read-only access to ~/\(name) — it's already open here, just click Grant."
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        // A wrong folder is invisible later (everything just reads $0), so
        // sanity-check the pick and offer a redo.
        if url.lastPathComponent != name {
            let alert = NSAlert()
            alert.messageText = "That doesn't look like ~/\(name)"
            alert.informativeText = "Whir would find no usage in \u{201C}\(url.lastPathComponent)\u{201D}. Use it anyway?"
            alert.addButton(withTitle: "Choose again")
            alert.addButton(withTitle: "Use this folder")
            if alert.runModal() == .alertFirstButtonReturn { return grant(id: id) }
        }
        save(url: url, id: id)
        return true
    }
}
