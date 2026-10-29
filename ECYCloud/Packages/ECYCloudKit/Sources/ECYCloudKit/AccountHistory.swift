import Foundation

public enum AccountHistoryKind: String, CaseIterable, Identifiable, Sendable {
    case devices, loginLogs, operationLogs, purchases, balance, unlock
    public var id: Self { self }
    public var title: String {
        switch self {
        case .devices: L10n.t("在线客户端")
        case .loginLogs: L10n.t("登录记录")
        case .operationLogs: L10n.t("操作记录")
        case .purchases: L10n.t("购买记录")
        case .balance: L10n.t("余额记录")
        case .unlock: L10n.t("解锁")
        }
    }
    var path: String {
        switch self {
        case .devices: "/user/devices"
        case .loginLogs: "/user/login-logs"
        case .operationLogs: "/user/operation-logs"
        case .purchases: "/user/purchases"
        case .balance: "/user/balance-transactions"
        case .unlock: "/user/unlock"
        }
    }
}

public struct AccountHistory: Sendable {
    public struct Row: Sendable {
        public struct Field: Sendable {
            private let sourceLabel: String
            public var label: String { L10n.t(sourceLabel) }
            public let value: String
            init(label: String, value: String) { sourceLabel = label; self.value = value }
        }
        public let fields: [Field]
        public let deviceID: String?
        public let online: Bool?
        public let currentDevice: Bool
        public var content: String? = nil
        public var renewal: Renewal? = nil
        public var thirdPartyDevice = false
        public struct Renewal: Sendable { public let id: Int; public let enabled: Bool }
    }
    public let rows: [Row]
    public let currentPage: Int
    public let lastPage: Int
    public let total: Int
    public let keepDays: Int
    public var checkInterval = 0
}

struct HistoryPage<Record: Decodable & Sendable>: Decodable, Sendable {
    let items: [Record]
    let logKeepDays: Int
    let currentPage: Int
    let lastPage: Int
    let total: Int
    let perPage: Int

    func history(_ map: (Record) -> AccountHistory.Row) throws -> AccountHistory {
        guard currentPage > 0, lastPage > 0,
              total >= 0, logKeepDays > 0, [10, 25, 50, 100].contains(perPage), items.count <= perPage else {
            throw ClientError.invalidResponse
        }
        return AccountHistory(rows: items.map(map), currentPage: currentPage, lastPage: lastPage, total: total, keepDays: logKeepDays)
    }
}

struct DeviceRecord: Decodable, Sendable {
    let ip: String, location: String, datetime: String, device: String, appVersion: String, deviceId: String
    let online: Bool
    func row(currentID: String) -> AccountHistory.Row {
        let kickable = !device.isEmpty && !deviceId.isEmpty
        return .init(fields: [.init(label: "IP", value: ip), .init(label: "归属地", value: location),
                              .init(label: "最后使用时间", value: datetime), .init(label: "在线设备", value: device.isEmpty ? L10n.t("第三方客户端") : device),
                              .init(label: "客户端版本", value: appVersion)],
                     deviceID: kickable ? deviceId : nil, online: online, currentDevice: kickable && deviceId == currentID,
                     thirdPartyDevice: device.isEmpty)
    }
}

struct LoginRecord: Decodable, Sendable {
    let ip: String, location: String, datetime: String, device: String, type: String, method: String
    var row: AccountHistory.Row {
        .init(fields: [.init(label: "登录IP", value: ip), .init(label: "归属地", value: location),
                       .init(label: "设备", value: device), .init(label: "状态", value: type),
                       .init(label: "登录方式", value: method), .init(label: "登录时间", value: datetime)],
              deviceID: nil, online: nil, currentDevice: false)
    }
}

struct OperationRecord: Decodable, Sendable {
    let datetime: String, operationDescription: String, oldValue: String, newValue: String
    let ipAddress: String, location: String, requestMethod: String, requestUrl: String, userAgent: String
    var row: AccountHistory.Row {
        .init(fields: [.init(label: "操作时间", value: datetime), .init(label: "操作描述", value: operationDescription),
                       .init(label: "操作前", value: oldValue), .init(label: "操作后", value: newValue),
                       .init(label: "IP地址", value: ipAddress), .init(label: "归属地", value: location),
                       .init(label: "请求方法", value: requestMethod), .init(label: "请求URL", value: requestUrl), .init(label: "User-Agent", value: userAgent)],
              deviceID: nil, online: nil, currentDevice: false)
    }
}

struct BusinessHistoryPage: Decodable, Sendable {
    let items: [BalanceRecord]?, purchases: [PurchaseRecord]?, results: [UnlockRecord]?
    let currentPage: Int, lastPage: Int, total: Int, perPage: Int
    let unlockCheckInterval: Int?
    func history(kind: AccountHistoryKind) throws -> AccountHistory {
        let rows: [AccountHistory.Row]
        switch kind {
        case .balance: guard let items else { throw ClientError.invalidResponse }; rows = items.map(\.row)
        case .purchases: guard let purchases else { throw ClientError.invalidResponse }; rows = purchases.map(\.row)
        case .unlock: guard let results else { throw ClientError.invalidResponse }; rows = results.map(\.row)
        default: throw ClientError.invalidResponse
        }
        try validatePage(currentPage, lastPage, total, perPage, rows.count)
        return AccountHistory(rows: rows, currentPage: currentPage, lastPage: lastPage, total: total, keepDays: 0,
                              checkInterval: max(0, unlockCheckInterval ?? 0))
    }
}
struct BalanceRecord: Decodable, Sendable {
    let orderNo: String, typeText: String, createdAt: String
    let amount: Double
    var row: AccountHistory.Row {
        .init(fields: [.init(label: "订单号", value: orderNo), .init(label: "类型", value: typeText),
                       .init(label: "金额", value: String(format: "¥ %.2f", amount)), .init(label: "时间", value: createdAt)],
              deviceID: nil, online: nil, currentDevice: false)
    }
}
struct PurchaseRecord: Decodable, Sendable {
    let id: Int
    let orderNo: String, shopName: String, content: String, datetime: String, expTime: String
    let name: String?
    let price: Double
    let autoRenew: Bool, canToggle: Bool
    let renew: String?
    var row: AccountHistory.Row {
        .init(fields: [.init(label: "订单号", value: orderNo), .init(label: "商品名称", value: shopName.isEmpty ? name ?? "" : shopName),
                       .init(label: "购买价格", value: String(format: "¥ %.2f", price)), .init(label: "购买时间", value: datetime),
                       .init(label: "套餐过期时间", value: expTime.isEmpty ? "-" : expTime),
                       .init(label: "自动续费时间", value: autoRenew && renew?.isEmpty == false ? renew ?? "-" : "-")],
              deviceID: nil, online: nil, currentDevice: false, content: content,
              renewal: canToggle ? .init(id: id, enabled: autoRenew) : nil)
    }
}
struct UnlockRecord: Decodable, Sendable {
    let nodeName: String, createdAt: String
    let unlockItem: [String: String]
    var row: AccountHistory.Row {
        .init(fields: [.init(label: "节点", value: nodeName)]
              + [("YouTube Premium", "YouTube_Premium"), ("Netflix", "Netflix"), ("Prime Video", "AmazonPrime"),
                 ("Disney Plus", "DisneyPlus"), ("TikTok", "TikTok"), ("HBO Max", "HBOMax"),
                 ("OpenAI", "OpenAI"), ("Gemini", "Gemini"), ("Claude", "Claude")].map { .init(label: $0.0, value: unlockItem[$0.1] ?? "") }
              + [.init(label: "更新时间", value: createdAt)],
              deviceID: nil, online: nil, currentDevice: false)
    }
}

public struct OnlineDevice: Decodable, Sendable, Identifiable {
    public let ip: String, deviceId: String, device: String, location: String, datetime: String
    public var id: String { deviceId + "|" + ip }
}
