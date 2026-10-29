import Foundation

public enum PanelSetting: Decodable, Sendable {
    case bool(Bool), text(String), number(Double), null
    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let s = try? c.decode(String.self) { self = .text(s) }
        else { self = .number(try c.decode(Double.self)) }
    }
    var isTrue: Bool { if case .bool(true) = self { return true }; return false }
    var isFalse: Bool { switch self { case .bool(false), .text("false"): true; default: false } }
}
public struct AccountEditOptions: Decodable, Sendable {
    public let gaEnable: Int
    public let gaToken: String, gaUrl: String
    public let enableTelegram: Bool, telegramUnbindKick: Bool
    public let telegramBot: String, imValue: String, bindToken: String
    public let telegramId: Int64
    public let mailNotifySettings: [String: PanelSetting]
    public let mailNotifyPreferences: [String: Bool]
    public struct MailOption: Identifiable, Sendable { public let id: String, title: String }
    public var mailOptions: [MailOption] {
        var result = [MailOption(id: "account_expire", title: L10n.t("账户过期")), .init(id: "vip_expire", title: L10n.t("VIP过期"))]
        if mailNotifySettings["notify_limit_mode"]?.isFalse != true { result.append(.init(id: "traffic_low", title: L10n.t("流量不足"))) }
        for (setting, id, title) in [("notify_exhaust_mode", "traffic_exhausted", L10n.t("流量耗尽")), ("notify_free_user_traffic_reset", "free_traffic_reset", L10n.t("免费用户流量重置")), ("notify_traffic_reset", "vip_traffic_reset", L10n.t("VIP用户流量重置")), ("recharge_send_email", "recharge", L10n.t("充值余额")), ("shop_send_email", "shop_purchase", L10n.t("购买商品")), ("mail_ticket", "ticket_create", L10n.t("管理员创建工单")), ("mail_ticket", "ticket_reply", L10n.t("管理员回复工单"))] {
            if mailNotifySettings[setting]?.isTrue == true { result.append(.init(id: id, title: title)) }
        }
        result += [.init(id: "announcement", title: L10n.t("公告通知")), .init(id: "marketing", title: L10n.t("营销邮件"))]
        return result
    }
}
public struct TwoFactorSecret: Decodable, Sendable { public let gaToken: String, gaUrl: String }
public struct TelegramBinding: Sendable {
    public let bound: Bool, imValue: String, telegramId: Int64, bindToken: String
    public init(bound: Bool, imValue: String, telegramId: Int64, bindToken: String) {
        self.bound = bound; self.imValue = imValue; self.telegramId = telegramId; self.bindToken = bindToken
    }
}
private struct TelegramEnvelope: Decodable {
    struct Payload: Decodable { let imValue: String?, telegramId: Int64?, bindToken: String? }
    let data: Payload?
    let imValue: String?, bindToken: String?
}
public enum AccountEmailPurpose: String, Sendable { case oldEmail, newEmail, deletion }

extension ClientSession {
    public func accountOptions() async throws -> AuthOptions { try await authenticated { _ in try await api.options(endpoints) } }
    public func editOptions() async throws -> AccountEditOptions {
        try await authenticated { try await api.request("/user/edit-options", origin: endpoints.site, token: $0.token) }
    }
    public func accountEmailCooldown(_ purpose: AccountEmailPurpose) -> Int {
        max(0, Int(ceil(accountMailDates[purpose.rawValue]?.timeIntervalSinceNow ?? 0)))
    }
    public func sendAccountEmail(_ purpose: AccountEmailPurpose, newEmail: String = "", oldCode: String = "") async throws -> String {
        guard accountEmailCooldown(purpose) == 0 else { throw ClientError.input(L10n.t("请等待倒计时结束后重试。")) }
        let path: String
        var body: [String: String] = [:]
        switch purpose {
        case .oldEmail: path = "/user/send-old-email-verify"
        case .newEmail:
            path = "/user/send-new-email-verify"; body = ["email": newEmail, "old_emailcode": oldCode]
        case .deletion: path = "/user/send-kill-email-code"
        }
        let result = try await authenticated { try await api.perform(path, origin: endpoints.site, token: $0.token, body: body).message }
        accountMailDates[purpose.rawValue] = Date().addingTimeInterval(60)
        return result
    }
    public func verifyOldEmail(_ code: String) async throws -> String {
        guard !code.isEmpty else { throw ClientError.input(L10n.t("请输入原邮箱验证码。")) }
        return try await authenticated { try await api.perform("/user/verify-old-email", origin: endpoints.site, token: $0.token, body: ["old_emailcode": code]).message }
    }
    public func updateEmail(_ email: String, oldCode: String, newCode: String) async throws {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty, email.utf8.count <= 254 else { throw ClientError.input(L10n.t("请输入有效的新邮箱。")) }
        let result = try await authenticated { try await api.perform("/user/email", origin: endpoints.site, token: $0.token,
            body: ["newemail": email, "old_emailcode": oldCode, "new_emailcode": newCode]).message }
        finishCredentialChange(result)
    }
    public func enableTwoFactor(code: String) async throws -> String {
        guard code.utf8.count == 6, code.utf8.allSatisfy({ (48...57).contains($0) }) else { throw ClientError.input(L10n.t("请输入验证器中的 6 位验证码。")) }
        _ = try await authenticated { try await api.perform("/user/ga-check", origin: endpoints.site, token: $0.token, body: ["code": code]).message }
        return try await authenticated { try await api.perform("/user/ga-set", origin: endpoints.site, token: $0.token, body: ["enable": "1"]).message }
    }
    public func testTwoFactor(code: String) async throws -> String {
        guard code.utf8.count == 6, code.utf8.allSatisfy({ (48...57).contains($0) }) else { throw ClientError.input(L10n.t("请输入验证器中的 6 位验证码。")) }
        return try await authenticated { try await api.perform("/user/ga-check", origin: endpoints.site, token: $0.token, body: ["code": code]).message }
    }
    public func keepTwoFactorSetting(enabled: Bool) async throws -> String {
        try await authenticated { try await api.perform("/user/ga-set", origin: endpoints.site, token: $0.token, body: ["enable": enabled ? "1" : "0"]).message }
    }
    public func disableTwoFactor(password: String) async throws -> String {
        guard !password.isEmpty else { throw ClientError.input(L10n.t("请输入当前登录密码。")) }
        return try await authenticated { try await api.perform("/user/ga-set", origin: endpoints.site, token: $0.token, body: ["enable": "0", "passwd": password]).message }
    }
    public func resetTwoFactor(password: String) async throws -> TwoFactorSecret {
        try await authenticated { try await api.request("/user/ga-reset", origin: endpoints.site, token: $0.token, body: ["passwd": password]) }
    }
    public func resetTelegram() async throws -> (message: String, binding: TelegramBinding) {
        let result = try await authenticated { try await api.perform("/user/telegram-reset", origin: endpoints.site, token: $0.token, body: [:]) }
        let body = try? Self.snakeDecoder.decode(TelegramEnvelope.self, from: result.data)
        return (result.message, TelegramBinding(bound: false, imValue: "", telegramId: 0, bindToken: body?.data?.bindToken ?? body?.bindToken ?? ""))
    }
    public func checkTelegramBinding() async throws -> TelegramBinding {
        let data: Data? = try await authenticated { session in
            do { return try await api.perform("/user/telegram-bind-check", origin: endpoints.site, token: session.token).data }
            catch ClientError.server(status: 200, code: 0, message: _, retryAfter: _) { return nil }
        }
        guard let data else { return TelegramBinding(bound: false, imValue: "", telegramId: 0, bindToken: "") }
        let body = try? Self.snakeDecoder.decode(TelegramEnvelope.self, from: data)
        return TelegramBinding(bound: true, imValue: body?.data?.imValue ?? body?.imValue ?? "", telegramId: body?.data?.telegramId ?? 0, bindToken: "")
    }
    private static var snakeDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
    public func updateMailPreferences(_ preferences: [String: Bool]) async throws -> String {
        let encoded = String(decoding: try JSONEncoder().encode(preferences), as: UTF8.self)
        return try await authenticated { try await api.perform("/user/mail-notify", origin: endpoints.site, token: $0.token, body: ["preferences": encoded]).message }
    }
    public func deleteAccount(emailCode: String) async throws -> String {
        let result = try await authenticated { try await api.perform("/user/kill", origin: endpoints.site, token: $0.token, body: ["email_code": emailCode]).message }
        connection?.disconnect()
        await refresh()
        return result
    }
    public func cancelAccountDeletion() async throws -> String {
        let result = try await authenticated(allowRestricted: true) { try await api.perform("/user/cancel-account-deletion", origin: endpoints.site, token: $0.token, body: [:]).message }
        await refresh()
        return result
    }
}
