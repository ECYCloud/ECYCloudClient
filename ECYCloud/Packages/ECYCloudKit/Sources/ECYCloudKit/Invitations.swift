import Foundation

public struct InviteSummary: Decodable, Sendable {
    public struct InvitedUser: Decodable, Identifiable, Sendable { public let id: Int; public let userName: String, email: String, regDate: String }
    public struct Payback: Decodable, Identifiable, Sendable { public let id: Int, userid: Int; public let total: Double, refGet: Double; public let datetime: String }
    public struct Withdrawal: Decodable, Identifiable, Sendable {
        public let id: Int, status: Int
        public let amount: Double
        public let statusText: String, channel: String, createdAt: String, processedAt: String
    }
    public struct Channel: Decodable, Identifiable, Sendable { public let id: Int; public let name: String }
    public let code: String, inviteUrl: String
    public let invitedUsersCount: Int, rebateUsersCount: Int, rebateFrequencyLimit: Int
    public let paybacksSum: Double, codePayback: Double, withdrawBalance: Double, pendingWithdraw: Double, minWithdrawAmount: Double, money: Double
    public let enableWithdraw: Bool, balanceWithdrawRequireMin: Bool
    public let withdrawChannels: [Channel]
    public let invitedUsers: [InvitedUser], paybacks: [Payback], withdrawRecords: [Withdrawal]
    public let invitedCurrentPage: Int, invitedLastPage: Int, invitedTotal: Int, invitedPerPage: Int
    public let paybackCurrentPage: Int, paybackLastPage: Int, paybackTotal: Int, paybackPerPage: Int
    public let withdrawCurrentPage: Int, withdrawLastPage: Int, withdrawTotal: Int, withdrawPerPage: Int
}
public struct WithdrawalFields: Decodable, Sendable {
    public struct Field: Decodable, Identifiable, Sendable { public let name: String; public let required: Bool; public var id: String { name } }
    public struct Channel: Decodable, Sendable { public let id: Int; public let name: String; public let fields: [Field] }
    public struct Account: Decodable, Identifiable, Sendable { public let id: Int; public let accountInfo: [String: String]; public let summary: String; public let isDefault: Bool? }
    public let channel: Channel
    public let savedAccounts: [Account]
}
extension ClientSession {
    public func invite(invitedPage: Int, invitedSearch: String, paybackPage: Int, paybackSearch: String,
                       withdrawPage: Int, withdrawSearch: String) async throws -> InviteSummary {
        var query: [URLQueryItem] = []
        for (name, page, search) in [("invited", invitedPage, invitedSearch), ("payback", paybackPage, paybackSearch), ("withdraw", withdrawPage, withdrawSearch)] {
            guard page > 0, search.utf8.count <= 1024 else { throw ClientError.invalidResponse }
            query += [.init(name: name + "_page", value: String(page)), .init(name: name + "_length", value: "10"), .init(name: name + "_search", value: search)]
        }
        let result: InviteSummary = try await authenticated { try await api.request("/user/invite", origin: endpoints.site, token: $0.token, query: query) }
        try validatePage(result.invitedCurrentPage, result.invitedLastPage, result.invitedTotal, result.invitedPerPage, result.invitedUsers.count)
        try validatePage(result.paybackCurrentPage, result.paybackLastPage, result.paybackTotal, result.paybackPerPage, result.paybacks.count)
        try validatePage(result.withdrawCurrentPage, result.withdrawLastPage, result.withdrawTotal, result.withdrawPerPage, result.withdrawRecords.count)
        return result
    }
    public func resetInvite() async throws -> String {
        try await authenticated { try await api.perform("/user/invite", origin: endpoints.site, token: $0.token, body: [:], method: "PUT").message }
    }
    public func withdrawalFields(_ channel: Int) async throws -> WithdrawalFields {
        guard channel > 0 else { throw ClientError.invalidResponse }
        return try await authenticated {
            let result = try await api.perform("/user/withdraw/channel/\(channel)/fields", origin: endpoints.site, token: $0.token)
            let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
            guard let value = try? decoder.decode(WithdrawalFields.self, from: result.data), value.channel.id == channel else { throw ClientError.invalidResponse }
            return value
        }
    }
    public func withdraw(amount: String, channel: String, account: [String: String], save: Bool) async throws -> String {
        guard let value = MoneyInput.amount(amount), value > 0 else { throw ClientError.input(L10n.t("请输入有效的提现金额，最多两位小数。")) }
        guard channel == "balance" || Int(channel).map({ $0 > 0 }) == true else { throw ClientError.invalidResponse }
        struct Body: Encodable { let amount: String, channel_id: String; let account_info: [String: String]; let save_account: Bool }
        let data = try JSONEncoder().encode(Body(amount: NSDecimalNumber(decimal: value).stringValue, channel_id: channel, account_info: account, save_account: save))
        return try await authenticated { try await api.perform("/user/withdraw/apply", origin: endpoints.site, token: $0.token, jsonBody: data).message }
    }
    public func cancelWithdrawal(_ id: Int) async throws -> String {
        guard id > 0 else { throw ClientError.invalidResponse }
        return try await authenticated { try await api.perform("/user/withdraw/cancel", origin: endpoints.site, token: $0.token, body: ["record_id": String(id)]).message }
    }
    public func deleteWithdrawalAccount(_ id: Int) async throws -> String {
        guard id > 0 else { throw ClientError.invalidResponse }
        return try await authenticated { try await api.perform("/user/withdraw/account/delete", origin: endpoints.site, token: $0.token, body: ["account_id": String(id)]).message }
    }
}
