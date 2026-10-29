import Foundation

extension PanelAPI {
    func purchase(_ endpoints: PanelEndpoints, token: String, path: String, body: [String: String]) async throws -> PurchaseResult {
        let response = try await perform(path, origin: endpoints.site, token: token, body: body)
        struct Envelope: Decodable {
            let data: PurchasePayload
            enum CodingKeys: String, CodingKey { case data }
            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                if let empty = try? container.decode([String].self, forKey: .data), empty.isEmpty {
                    data = PurchasePayload(cardKey: nil, tradeno: nil, paymentUrl: nil, payQrcode: nil, payScheme: nil)
                } else { data = try container.decode(PurchasePayload.self, forKey: .data) }
            }
        }
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let value = try? decoder.decode(Envelope.self, from: response.data) else { throw ClientError.invalidResponse }
        return value.data.result(message: response.message)
    }
}

extension ClientSession {
    public func announcements(silently: Bool = false) async throws -> AnnouncementBundle {
        let bundle: AnnouncementBundle = try await authenticated(silently: silently) { try await api.request("/announcements", origin: endpoints.site, token: $0.token) }
        announcementState.accept(bundle)
        return bundle
    }
    public func trafficHistory() async throws -> TrafficHistory {
        try await authenticated { try await api.request("/user/traffic-log", origin: endpoints.site, token: $0.token) }
    }
    public func tickets(page: Int, search: String) async throws -> TicketPage {
        let query = try pagination(page, search)
        let result: TicketPage = try await authenticated(allowRestricted: true) {
            try await api.request("/tickets", origin: endpoints.site, token: $0.token, query: query)
        }
        try validatePage(result.currentPage, result.lastPage, result.total, result.perPage, result.tickets.count)
        return result
    }
    public func ticket(_ id: Int) async throws -> TicketDetail {
        guard id > 0 else { throw ClientError.invalidResponse }
        return try await authenticated(allowRestricted: true) { try await api.request("/tickets/\(id)", origin: endpoints.site, token: $0.token) }
    }
    public func createTicket(title: String, text: String, attachments: [TicketAttachment] = []) async throws -> Int {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.utf8.count <= 1024 else { throw ClientError.input(L10n.t("请填写工单标题（最多 1024 字节）。")) }
        let html = try TicketContent.html(text, attachments: attachments)
        struct Created: Decodable, Sendable { let ticketId: Int }
        let result: Created = try await authenticated(allowRestricted: true) {
            try await api.request("/tickets", origin: endpoints.site, token: $0.token, body: ["title": title, "content": html])
        }
        guard result.ticketId > 0 else { throw ClientError.invalidResponse }
        return result.ticketId
    }
    public func replyTicket(_ id: Int, text: String, attachments: [TicketAttachment] = []) async throws -> String {
        guard id > 0 else { throw ClientError.invalidResponse }
        let html = try TicketContent.html(text, attachments: attachments)
        return try await authenticated(allowRestricted: true) {
            try await api.perform("/tickets/\(id)/reply", origin: endpoints.site, token: $0.token, body: ["content": html]).message
        }
    }
    public func closeTicket(_ id: Int) async throws -> String {
        guard id > 0 else { throw ClientError.invalidResponse }
        return try await authenticated(allowRestricted: true) {
            try await api.perform("/tickets/\(id)/close", origin: endpoints.site, token: $0.token, body: [:]).message
        }
    }
    public func shop() async throws -> ShopCatalog {
        try await authenticated { try await api.request("/shop/products", origin: endpoints.site, token: $0.token) }
    }
    public func quote(_ product: ShopProduct, coupon: String) async throws -> ShopQuote {
        try await authenticated {
            try await api.request("/shop/\(product.type.quotePath)", origin: endpoints.site, token: $0.token,
                                  query: [.init(name: "shop", value: String(product.id)), .init(name: "coupon", value: coupon)])
        }
    }
    public func purchase(_ product: ShopProduct, coupon: String, autoRenew: Bool, disableOthers: Bool, payment: String) async throws -> PurchaseResult {
        guard ["", "alipay", "wxpay"].contains(payment), product.id > 0 else { throw ClientError.invalidResponse }
        var body = ["shop": String(product.id)]
        if product.type == .plan {
            body["coupon"] = coupon; body["autorenew"] = autoRenew ? "1" : "0"; body["disableothers"] = disableOthers ? "1" : "0"
        }
        if !payment.isEmpty { body["epay_type"] = payment }
        let path = "/shop/" + product.type.buyPath + (payment.isEmpty ? "" : "-with-epay")
        return try await authenticated { try await api.purchase(endpoints, token: $0.token, path: path, body: body) }
    }
    public func paymentStatus(_ tradeNo: String) async throws -> PaymentStatus {
        guard !tradeNo.isEmpty, tradeNo.utf8.count <= 128, tradeNo.utf8.allSatisfy({ (48...57).contains($0) }) else { throw ClientError.invalidResponse }
        return try await authenticated { try await api.request("/shop/payment-status", origin: endpoints.site, token: $0.token, query: [.init(name: "tradeno", value: tradeNo)]) }
    }
    public func rechargeInfo() async throws -> RechargeInfo {
        try await authenticated { try await api.request("/user/recharge", origin: endpoints.site, token: $0.token) }
    }
    public func redeem(_ code: String) async throws -> String {
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty, code.utf8.count <= 4096 else { throw ClientError.input(L10n.t("请输入有效充值码。")) }
        return try await authenticated { try await api.perform("/user/recharge/code", origin: endpoints.site, token: $0.token, body: ["code": code]).message }
    }
    public func recharge(amount: String, payment: String) async throws -> PurchaseResult {
        guard let price = MoneyInput.amount(amount), price > 0, price <= 1500, ["alipay", "wxpay"].contains(payment) else {
            throw ClientError.input(L10n.t("金额必须大于 0，最多 1500，且小数点后最多两位。"))
        }
        return try await authenticated { try await api.purchase(endpoints, token: $0.token, path: "/user/recharge/epay", body: ["price": NSDecimalNumber(decimal: price).stringValue, "type": payment]) }
    }
    public func toggleRenewal(id: Int, enabled: Bool) async throws -> String {
        guard id > 0 else { throw ClientError.invalidResponse }
        return try await authenticated { try await api.perform("/purchases/toggle", origin: endpoints.site, token: $0.token, body: ["id": String(id), "action": enabled ? "enable" : "disable"]).message }
    }
}

func pagination(_ page: Int, _ search: String) throws -> [URLQueryItem] {
    guard page > 0, search.utf8.count <= 1024 else { throw ClientError.input(L10n.t("搜索内容过长。")) }
    return [.init(name: "page", value: String(page)), .init(name: "length", value: "10"), .init(name: "search", value: search)]
}
func validatePage(_ current: Int, _ last: Int, _ total: Int, _ size: Int, _ count: Int) throws {
    guard current > 0, last > 0, total >= 0, [10, 25, 50, 100].contains(size), count <= size else { throw ClientError.invalidResponse }
}
