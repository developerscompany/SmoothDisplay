import AppKit

/// Checks GitHub Releases for a newer version. The only network access the app makes.
enum Updates {
    private static let defaults = UserDefaults.standard

    static var automatic: Bool {
        get { defaults.object(forKey: "checkUpdatesAutomatically") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "checkUpdatesAutomatically") }
    }

    /// At most once a day, silent unless there is something new.
    static func checkIfDue() {
        guard automatic else { return }
        let last = defaults.object(forKey: "lastUpdateCheck") as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 24 * 3600 else { return }
        check(userInitiated: false)
    }

    static func check(userInitiated: Bool) {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(AppInfo.repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("SmoothDisplay/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20

        URLSession.shared.dataTask(with: request) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let release = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            DispatchQueue.main.async {
                defaults.set(Date(), forKey: "lastUpdateCheck")
                guard error == nil, status == 200, let release,
                      let tag = release["tag_name"] as? String,
                      let page = (release["html_url"] as? String).flatMap(URL.init(string:)) else {
                    if userInitiated {
                        let reason = error?.localizedDescription ?? (status == 404 ? L("No releases published yet.") : "HTTP \(status)")
                        show(L("Couldn't check for updates"), reason, buttons: [L("OK")])
                    }
                    return
                }
                let latest = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                if isNewer(latest, than: AppInfo.version) {
                    let answer = show(L("SmoothDisplay %@ is available", latest),
                                      L("You have version %@. Download the new version from GitHub?", AppInfo.version),
                                      buttons: [L("Download"), L("Later")])
                    if answer == .alertFirstButtonReturn { NSWorkspace.shared.open(page) }
                } else if userInitiated {
                    show(L("You're up to date"), L("SmoothDisplay %@ is the latest version.", AppInfo.version), buttons: [L("OK")])
                }
            }
        }.resume()
    }

    /// Numeric comparison of dotted versions: 1.10.0 is newer than 1.9.2.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    @discardableResult
    private static func show(_ title: String, _ text: String, buttons: [String]) -> NSApplication.ModalResponse {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        buttons.forEach { alert.addButton(withTitle: $0) }
        return alert.runModal()
    }
}
