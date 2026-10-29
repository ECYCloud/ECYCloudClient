import Foundation
import Observation

public enum AppLanguage: String, CaseIterable, Sendable {
    case zhCN = "zh-CN", zhTW = "zh-TW", enUS = "en-US"
    public var title: String { switch self { case .zhCN: "简体中文"; case .zhTW: "繁體中文"; case .enUS: "English" } }
    public static func resolve(_ stored: String?, device: String = Locale.preferredLanguages.first ?? "en-US") -> AppLanguage {
        if let stored, let value = AppLanguage(rawValue: stored.replacingOccurrences(of: "_", with: "-")) { return value }
        if stored == "en" { return .enUS }
        let code = device.lowercased()
        guard code.hasPrefix("zh") else { return .enUS }
        return ["hant", "-tw", "-hk", "-mo"].contains(where: code.contains) ? .zhTW : .zhCN
    }
}

public enum L10n {
    private final class Selection: Observable, @unchecked Sendable {
        private let observation = ObservationRegistrar()
        var current: AppLanguage {
            observation.access(self, keyPath: \.current)
            return AppLanguage.resolve(UserDefaults.standard.string(forKey: "apple.language"))
        }
        func set(_ value: AppLanguage) {
            observation.withMutation(of: self, keyPath: \.current) { UserDefaults.standard.set(value.rawValue, forKey: "apple.language") }
        }
    }
    private static let selection = Selection()
    public static var language: AppLanguage { selection.current }
    public static var connectAction: String { language == .enUS ? "Connect" : t("连接") }
    static func setLanguage(_ language: AppLanguage) { selection.set(language) }
    static let translations: [String: [String: String]] = {
        guard let url = Bundle.module.url(forResource: "Translations", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode([String: [String: String]].self, from: data) else { return [:] }
        return value
    }()
    public static func t(_ source: String, _ arguments: [String] = [], language: AppLanguage = L10n.language) -> String {
        let template = translations[language.rawValue]?[source] ?? source
        guard !arguments.isEmpty else { return template }
        return replace(template, values: Dictionary(uniqueKeysWithValues: arguments.enumerated().map { ("{\($0.offset)}", $0.element) }))
    }
    public static func message(_ source: String) -> String {
        let language = language
        guard language != .zhCN, let entries = translations[language.rawValue] else { return source }
        if let value = entries[source] { return value }
        for pattern in patterns {
            let range = NSRange(source.startIndex..., in: source)
            guard let match = pattern.regex.firstMatch(in: source, range: range),
                  let template = entries[pattern.key] else { continue }
            var values: [String: String] = [:]
            for (index, slot) in pattern.slots.enumerated() {
                if let range = Range(match.range(at: index + 1), in: source) { values[slot] = String(source[range]) }
            }
            return replace(template, values: values)
        }
        return source
    }
    private static let token = try! NSRegularExpression(pattern: #"\{\d+\}"#)
    private static let patterns: [(key: String, regex: NSRegularExpression, slots: [String])] = {
        (translations[AppLanguage.enUS.rawValue] ?? [:]).keys.filter { $0.contains("{0}") }.sorted { $0.count > $1.count }.compactMap { key in
            let matches = token.matches(in: key, range: NSRange(key.startIndex..., in: key))
            var pattern = "", end = key.startIndex, slots: [String] = []
            for match in matches {
                let range = Range(match.range, in: key)!
                pattern += NSRegularExpression.escapedPattern(for: String(key[end..<range.lowerBound])) + "([\\s\\S]+?)"
                slots.append(String(key[range])); end = range.upperBound
            }
            pattern += NSRegularExpression.escapedPattern(for: String(key[end...]))
            guard let regex = try? NSRegularExpression(pattern: "^" + pattern + "$") else { return nil }
            return (key, regex, slots)
        }
    }()
    private static func replace(_ template: String, values: [String: String]) -> String {
        var result = template
        for match in token.matches(in: template, range: NSRange(template.startIndex..., in: template)).reversed() {
            let range = Range(match.range, in: template)!
            if let value = values[String(template[range])] { result.replaceSubrange(Range(match.range, in: result)!, with: value) }
        }
        return result
    }
}
