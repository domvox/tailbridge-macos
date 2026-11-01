import Foundation

/// Tests only: a strings table used instead of the app bundle, to check fully formatted text. nil in the app.
var stringsTableOverride: [String: String]?

/// Looks up a UI string in Localizable.strings (en.lproj for now). A missing key shows up as the raw key.
func L(_ key: String, _ args: CVarArg...) -> String {
    let format = stringsTableOverride?[key] ?? Bundle.main.localizedString(forKey: key, value: nil, table: nil)
    return args.isEmpty ? format : String(format: format, locale: .current, arguments: args)
}
