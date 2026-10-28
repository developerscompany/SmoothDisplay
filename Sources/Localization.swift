import Foundation

/// Localized UI text. The English text is the key, so a missing translation falls back to English.
/// Translations live in Resources/<language>.lproj/Localizable.strings.
func L(_ key: String) -> String {
    Localization.englishOnly ? key : NSLocalizedString(key, comment: "")
}

func L(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: L(key), arguments: arguments)
}

enum Localization {
    /// The command line speaks English whatever the system language, so its output is predictable in scripts.
    static var englishOnly = false
}

enum AppInfo {
    static let repository = "developerscompany/SmoothDisplay"
    static let repositoryURL = URL(string: "https://github.com/\(repository)")!

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }
}
