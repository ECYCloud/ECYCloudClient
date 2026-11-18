import Foundation

public struct InviteSummary: Decodable, Sendable {
    public struct InvitedUser: Decodable, Identifiable, Sendable { public let id: Int; public let regDate: String }
    public struct Payback: Decodable, Identifiable, Sendable { public let id: Int, userid: Int; public let refGet: Double; public let datetime: String }
    public let code: String, inviteUrl: String
    public let invitedUsersCount: Int, rebateUsersCount: Int, rebateFrequencyLimit: Int
    public let paybacksSum: Double, codePayback: Double
    public let invitedUsers: [InvitedUser], paybacks: [Payback]
    public let invitedCurrentPage: Int, invitedLastPage: Int, invitedTotal: Int, invitedPerPage: Int
    public let paybackCurrentPage: Int, paybackLastPage: Int, paybackTotal: Int, paybackPerPage: Int
}
extension ClientSession {
    public func invite(invitedPage: Int, invitedSearch: String, paybackPage: Int, paybackSearch: String) async throws -> InviteSummary {
        var query: [URLQueryItem] = []
        for (name, page, search) in [("invited", invitedPage, invitedSearch), ("payback", paybackPage, paybackSearch)] {
            guard page > 0, search.utf8.count <= 1024 else { throw ClientError.invalidResponse }
            query += [.init(name: name + "_page", value: String(page)), .init(name: name + "_length", value: "10"), .init(name: name + "_search", value: search)]
        }
        let result: InviteSummary = try await authenticated { try await api.request("/user/invite", origin: endpoints.site, token: $0.token, query: query) }
        try validatePage(result.invitedCurrentPage, result.invitedLastPage, result.invitedTotal, result.invitedPerPage, result.invitedUsers.count)
        try validatePage(result.paybackCurrentPage, result.paybackLastPage, result.paybackTotal, result.paybackPerPage, result.paybacks.count)
        return result
    }
    public func resetInvite() async throws -> String {
        try await authenticated { try await api.perform("/user/invite", origin: endpoints.site, token: $0.token, body: [:], method: "PUT").message }
    }
}