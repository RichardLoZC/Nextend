import Foundation

enum AppLanguage {
    static var english: Bool {
        let saved = UserDefaults.standard.string(forKey: "language")
        return saved.map { $0 == "en" } ?? !(Locale.preferredLanguages.first ?? "en").hasPrefix("zh")
    }
    static func select(english: Bool) { UserDefaults.standard.set(english ? "en" : "zh", forKey: "language") }
}

func L(_ chinese: String, _ english: String) -> String { AppLanguage.english ? english : chinese }

/// Keeps a message and its arguments separate until it reaches the UI, so an
/// in-flight connection or error can be translated without restarting capture.
struct AppMessage: Codable, ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
    let key: String
    let arguments: [AppMessage]
    private let literal: Bool
    init(stringLiteral value: String) { key = value; arguments = []; literal = false }
    init(raw value: String) { key = value; arguments = []; literal = true }
    init(stringInterpolation value: StringInterpolation) { key = value.key; arguments = value.arguments; literal = false }
    struct StringInterpolation: StringInterpolationProtocol {
        var key = ""
        var arguments: [AppMessage] = []
        init(literalCapacity: Int, interpolationCount: Int) { key.reserveCapacity(literalCapacity) }
        mutating func appendLiteral(_ value: String) { key += value }
        mutating func appendInterpolation<T>(_ value: T) {
            key += "{\(arguments.count)}"
            arguments.append((value as? AppMessage) ?? (value as? Error)?.appMessage ?? AppMessage(raw: String(describing: value)))
        }
    }
    static let translations: [String: String] = {
        guard let url = Bundle.main.url(forResource: "Messages", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let values = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return values
    }()
    func render(english: Bool) -> String {
        if literal { return key }
        let template = english ? Self.translations[key] ?? key : key
        // Build from template tokens once; arguments can contain braces themselves.
        let expression = try! NSRegularExpression(pattern: #"\{(\d+)\}"#)
        let source = template as NSString
        var result = "", start = 0
        for match in expression.matches(in: template, range: NSRange(location: 0, length: source.length)) {
            result += source.substring(with: NSRange(location: start, length: match.range.location - start))
            if let index = Int(source.substring(with: match.range(at: 1))), arguments.indices.contains(index) {
                result += arguments[index].render(english: english)
            } else { result += source.substring(with: match.range) }
            start = NSMaxRange(match.range)
        }
        return result + source.substring(from: start)
    }
    var text: String { render(english: AppLanguage.english) }
}

extension Error {
    var appMessage: AppMessage { (self as? BridgeError)?.text ?? AppMessage(raw: localizedDescription) }
}
