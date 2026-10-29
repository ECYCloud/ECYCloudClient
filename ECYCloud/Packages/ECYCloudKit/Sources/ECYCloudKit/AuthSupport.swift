import Foundation

public enum EmailPurpose: Sendable, Hashable {
    case login, registration, passwordReset
    var path: String {
        switch self {
        case .login: "/auth/send-login-verify"
        case .registration: "/auth/send-register-verify"
        case .passwordReset: "/auth/password-reset"
        }
    }
}

public enum LegalDocumentKind: String, Sendable, Identifiable {
    case terms, privacy
    public var id: Self { self }
    public var title: String { self == .terms ? L10n.t("服务条款") : L10n.t("隐私政策") }
    var path: String { self == .terms ? "/auth/tos" : "/auth/privacy" }
}

public enum PasswordResetToken {
    public static func fromInput(_ raw: String) -> String? {
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let token: String
        if input.contains("://") {
            guard let url = URL(string: input), ["http", "https"].contains(url.scheme?.lowercased()),
                  url.user == nil, url.password == nil else { return nil }
            let parts = url.pathComponents
            guard parts.count == 4, parts[1] == "password", parts[2] == "token" else { return nil }
            token = parts[3]
        } else { token = input }
        guard !token.isEmpty, token.utf8.count <= 4096,
              token.utf8.allSatisfy({ (33...126).contains($0) && $0 != 47 }) else { return nil }
        return token
    }
}
