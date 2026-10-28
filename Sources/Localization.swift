import Foundation

/// Localized UI text. The English text is the key, so a missing translation falls back to English.
/// Translations live in Resources/<language>.lproj/Localizable.strings.
func L(_ key: String) -> String {
    Localization.text(key)
}

func L(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: L(key), arguments: arguments)
}

enum Localization {
    /// Languages the app ships, with their names written in that language.
    static let languages: [(code: String, name: String)] = [("en", "English"), ("uk", "Українська"), ("ru", "Русский")]

    /// The command line speaks English whatever the system language, so its output is predictable in scripts.
    static var englishOnly = false

    /// The language picked in the menu, or nil to follow the system. Takes effect immediately: the menu is
    /// rebuilt every time it opens.
    static var chosen: String? {
        get { UserDefaults.standard.string(forKey: "language") }
        set { UserDefaults.standard.set(newValue, forKey: "language") }
    }

    /// Built once and never mutated, so L() is safe from any thread (the Retina unlock and DDC run off main).
    private static let tables: [String: Bundle] = Dictionary(uniqueKeysWithValues: languages.compactMap { language in
        Bundle.main.path(forResource: language.code, ofType: "lproj").flatMap(Bundle.init(path:)).map { (language.code, $0) }
    })

    static func text(_ key: String) -> String {
        if englishOnly { return key }
        guard let code = chosen, let table = tables[code] else { return NSLocalizedString(key, comment: "") }
        return table.localizedString(forKey: key, value: key, table: nil)
    }
}

enum AppInfo {
    static let repository = "developerscompany/SmoothDisplay"
    static let repositoryURL = URL(string: "https://github.com/\(repository)")!

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }
}
