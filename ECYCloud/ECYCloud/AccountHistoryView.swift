import SwiftUI
import ECYCloudKit

struct AccountHistoryView: View {
    let session: ClientSession
    let kind: AccountHistoryKind
    var embedded = false
    @Environment(\.colorScheme) private var scheme
    @State private var history: AccountHistory?
    @State private var search = ""
    @State private var page = 1
    @State private var refresh = 0
    @State private var loading = false
    @State private var kicking = false
    @State private var failure: String?
    @State private var toast: String?
    @State private var kickTarget: AccountHistory.Row?
    @State private var confirmingKick = false
    @State private var operation = UUID()
    @State private var renewal: AccountHistory.Row.Renewal?
    @State private var confirmingRenewal = false
    private var colors: ProductPalette { ProductPalette(scheme: scheme) }
    private struct RequestKey: Equatable { let page: Int; let search: String; let refresh: Int }

    var body: some View {
        Group {
            if embedded { content }
            else { FeatureSheet(title: title, working: kicking) { content } }
        }
        .task(id: RequestKey(page: page, search: search, refresh: refresh)) {
            await load(silent: false)
        }
        .productAutoRefresh(revision: kind == .unlock ? session.profile?.revision(.unlock) : nil) { await load(silent: true) }
        .alert(renewal?.enabled == false ? L10n.t("确认开启自动续费？") : L10n.t("确认关闭自动续费？"), isPresented: $confirmingRenewal, presenting: renewal) { item in
            Button(L10n.t("确定")) { Task { await toggleRenewal(item) } }
            Button(L10n.t("取消"), role: .cancel) { }
        } message: { item in
            Text(item.enabled ? L10n.t("关闭后，您可以随时重新开启自动续费。") : L10n.t("开启后将在套餐到期时自动续费。"))
        }
        .alert(L10n.t("确认将该设备下线？"), isPresented: $confirmingKick, presenting: kickTarget) { row in
            Button(L10n.t("确定")) { Task { await kick(row) } }
            Button(L10n.t("取消"), role: .cancel) { kickTarget = nil }
        } message: { row in
            Text(L10n.t("将通知 {0} 上的客户端下线。", [value(row, "在线设备")]))
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let hint {
                    Text(verbatim: hint).font(.system(size: 14)).foregroundStyle(colors.secondary)
                        .fixedSize(horizontal: false, vertical: true).padding(.top, 8)
                }
                ProductSearchField(hint: searchHint, text: $search).onChange(of: search) { _, _ in page = 1 }
                    .padding(.top, 8).padding(.bottom, 12)
                let rows = history?.rows ?? []
                if loading && rows.isEmpty {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 80)
                } else if let failure, rows.isEmpty {
                    Text(verbatim: failure).frame(maxWidth: .infinity).multilineTextAlignment(.center).padding(.top, 80)
                } else if let history {
                    if kind == .unlock { unlockNotice(history.checkInterval).padding(.bottom, 12) }
                    ProductTable(columns: columns, rows: history.rows.map(tableRow), empty: emptyText, minimumWidth: minimumWidth)
                    PageButtons(current: history.currentPage, last: history.lastPage, total: history.total, disabled: loading || kicking) { page = $0 }
                }
            }
            .padding(.leading, 14).padding(.trailing, 16).padding(.top, embedded ? 16 : 0).padding(.bottom, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .refreshable { refresh += 1 }
        .productToast($toast)
        .preference(key: ProductRefreshKey.self, value: ProductRefreshAction(id: kind.rawValue, disabled: false, run: { refresh += 1 }))
    }

    private var title: String {
        kind == .devices ? L10n.t("最近 {0} 天的在线客户端", [String(describing: history?.keepDays ?? 1)]) : kind.title
    }
    private var hint: String? {
        let days = String(describing: history?.keepDays ?? (kind == .devices ? 1 : 30))
        switch kind {
        case .loginLogs: return L10n.t("最近 {0} 天网站登录记录，请确认均为本人 IP，异常请及时修改登录密码。", [days])
        case .operationLogs: return L10n.t("以下显示您最近 {0} 天的操作记录。", [days])
        case .devices: return L10n.t("请确认均为本人 IP，如有异常请及时修改密码。")
        default: return nil
        }
    }
    private var searchHint: String {
        switch kind {
        case .devices: L10n.t("IP / 归属地 / 设备 / 版本")
        case .loginLogs: L10n.t("IP / 归属地 / 设备")
        case .operationLogs: L10n.t("描述 / IP / 归属地")
        case .purchases: L10n.t("订单号 / 商品名")
        case .balance: L10n.t("订单号")
        case .unlock: L10n.t("搜索节点")
        }
    }
    private var emptyText: String {
        let days = String(describing: history?.keepDays ?? 1)
        switch kind {
        case .devices: return L10n.t("最近 {0} 天没有在线客户端记录", [days])
        case .loginLogs: return L10n.t("最近 {0} 天内还没有登录记录", [days])
        case .operationLogs: return L10n.t("最近 {0} 天内还没有操作记录", [days])
        case .purchases: return L10n.t("暂无购买记录")
        case .balance: return L10n.t("暂无余额记录")
        case .unlock: return search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? L10n.t("暂无解锁检测结果") : L10n.t("没有匹配结果")
        }
    }
    private var minimumWidth: CGFloat? {
        switch kind {
        case .devices: 1080
        case .purchases, .unlock: 1280
        default: nil
        }
    }
    private var columns: [String] {
        switch kind {
        case .devices: ["IP", L10n.t("归属地"), L10n.t("最后使用时间"), L10n.t("在线设备"), L10n.t("客户端版本"), L10n.t("操作")]
        case .loginLogs: [L10n.t("登录IP"), L10n.t("归属地"), L10n.t("设备"), L10n.t("状态"), L10n.t("登录方式"), L10n.t("登录时间")]
        case .operationLogs: [L10n.t("操作时间"), L10n.t("操作描述"), L10n.t("操作前"), L10n.t("操作后"), L10n.t("IP地址"), L10n.t("归属地"), L10n.t("请求方法"), L10n.t("请求URL"), "User-Agent"]
        case .balance: [L10n.t("订单号"), L10n.t("类型"), L10n.t("金额"), L10n.t("时间")]
        case .purchases: [L10n.t("操作"), L10n.t("订单号"), L10n.t("商品名称"), L10n.t("购买价格"), L10n.t("商品详情"), L10n.t("购买时间"), L10n.t("套餐过期时间"), L10n.t("自动续费时间")]
        case .unlock: [L10n.t("节点"), "YouTube Premium", "Netflix", "Prime Video", "Disney Plus", "TikTok", "HBO Max", "OpenAI", "Gemini", "Claude", L10n.t("更新时间")]
        }
    }
    private var mutedColumns: Set<String> {
        switch kind {
        case .devices: [L10n.t("最后使用时间"), L10n.t("客户端版本")]
        case .loginLogs: [L10n.t("登录时间")]
        case .operationLogs: [L10n.t("操作时间")]
        case .balance: [L10n.t("时间")]
        case .purchases: [L10n.t("购买时间"), L10n.t("套餐过期时间"), L10n.t("自动续费时间")]
        case .unlock: [L10n.t("更新时间")]
        }
    }
    private var boldColumns: Set<String> {
        switch kind {
        case .balance: [L10n.t("金额")]
        case .purchases: [L10n.t("商品名称"), L10n.t("购买价格")]
        case .unlock: [L10n.t("节点")]
        default: []
        }
    }

    private func unlockNotice(_ interval: Int) -> some View {
        ProductCard {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.t("您可以在这里查看节点的流媒体和各大AI平台解锁情况。"))
                if interval > 0 { Text(L10n.t("每 {0} 小时更新一次，测试结果仅供参考，请以实际使用情况为准。", [String(describing: interval)])) }
                Text(L10n.t("(YouTube Premium 检测结果如果显示：No，可能无法正常使用Google服务，如需使用Google Play、YouTube Music等请切换到其他节点)"))
            }.font(.system(size: 14)).foregroundStyle(colors.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func value(_ row: AccountHistory.Row, _ label: String) -> String {
        row.fields.first(where: { $0.label == L10n.t(label) })?.value ?? ""
    }

    private func tableRow(_ row: AccountHistory.Row) -> [AnyView] {
        columns.map { column in
            if column == L10n.t("操作") { return actionCell(row) }
            if column == L10n.t("商品详情") {
                guard let content = row.content, !content.isEmpty else { return AnyView(cell("-", muted: true)) }
                return AnyView(PurchaseDetail(html: content, origin: session.endpoints.site))
            }
            let text = row.fields.first(where: { $0.label == column })?.value ?? ""
            if kind == .devices && column == L10n.t("在线设备") && !row.thirdPartyDevice {
                return AnyView(ProductFlow(spacing: 6) {
                    cell(text)
                    if row.currentDevice { ProductTag(text: L10n.t("当前设备"), color: colors.accent) }
                })
            }
            if kind == .unlock && column != L10n.t("节点") && column != L10n.t("更新时间") {
                return AnyView(cell(text, color: statusColor(text)))
            }
            return AnyView(cell(text, muted: mutedColumns.contains(column), bold: boldColumns.contains(column)))
        }
    }

    private func actionCell(_ row: AccountHistory.Row) -> AnyView {
        if kind == .devices {
            if row.online == true, row.deviceID != nil {
                return AnyView(Button(L10n.t("下线")) { kickTarget = row; confirmingKick = true }
                    .buttonStyle(ProductButtonStyle(filled: true, color: colors.danger)).disabled(kicking))
            }
            return AnyView(cell(row.thirdPartyDevice ? L10n.t("不支持") : "", muted: true))
        }
        if let renewal = row.renewal {
            return AnyView(Button(renewal.enabled ? L10n.t("关闭自动续费") : L10n.t("开启自动续费")) {
                self.renewal = renewal; confirmingRenewal = true
            }.buttonStyle(ProductButtonStyle()).disabled(kicking))
        }
        return AnyView(cell("-", muted: true))
    }

    private func cell(_ text: String, muted: Bool = false, bold: Bool = false, color: Color? = nil) -> some View {
        Text(verbatim: text.isEmpty ? "—" : text)
            .font(.system(size: bold ? 13 : 12, weight: bold ? .semibold : .regular)).monospacedDigit()
            .foregroundStyle(color ?? (muted ? colors.secondary : colors.text))
            .productTextSelection()
    }

    private func statusColor(_ status: String) -> Color? {
        let lower = status.lowercased()
        if status.hasPrefix("Yes") || status.contains("解锁") || lower.contains("yes") || lower.contains("unlock") { return colors.success }
        if lower.hasPrefix("unknow") { return colors.warning }
        if status.hasPrefix("No") || status.contains("失败") || status.contains("屏蔽") || lower.hasPrefix("no") { return colors.danger }
        if ["仅限自制", "仅限网页", "仅限App"].contains(where: { status.hasPrefix($0) || status.hasPrefix(L10n.t($0)) }) {
            return Color(.sRGB, red: 0x9C / 255, green: 0x27 / 255, blue: 0xB0 / 255, opacity: 1)
        }
        return nil
    }

    private func load(silent: Bool) async {
        if silent && loading { return }
        let id = UUID()
        operation = id
        if !silent { loading = true; failure = nil }
        defer { if operation == id { loading = false } }
        do {
            if !silent && !search.isEmpty { try await Task.sleep(for: .milliseconds(300)) }
            let result = try await session.history(kind, page: page, search: search.trimmingCharacters(in: .whitespacesAndNewlines))
            try Task.checkCancellation()
            guard operation == id else { return }
            if result.currentPage > result.lastPage {
                page = result.lastPage
                return
            }
            history = result
            failure = nil
        } catch is CancellationError { }
        catch {
            if operation == id { failure = (error as? ClientError)?.localizedDescription ?? L10n.t("加载失败，请重试。") }
        }
    }

    private func kick(_ row: AccountHistory.Row) async {
        guard !kicking, let deviceID = row.deviceID, row.online == true else { return }
        kicking = true
        defer { kicking = false; kickTarget = nil }
        do { toast = try await session.kickDevice(deviceID) }
        catch is CancellationError { return }
        catch { toast = (error as? ClientError)?.localizedDescription ?? L10n.t("操作失败，请重试。") }
        refresh += 1
    }

    private func toggleRenewal(_ item: AccountHistory.Row.Renewal) async {
        guard !kicking else { return }
        kicking = true
        defer { kicking = false; renewal = nil }
        do {
            let message = try await session.toggleRenewal(id: item.id, enabled: !item.enabled)
            await session.refresh()
            toast = message.isEmpty ? (item.enabled ? L10n.t("自动续费关闭成功") : L10n.t("自动续费开启成功")) : message
        } catch is CancellationError { return }
        catch { toast = (error as? ClientError)?.localizedDescription ?? L10n.t("操作未完成") }
        refresh += 1
    }
}

private struct PurchaseDetail: View {
    let html: String
    let origin: URL
    @Environment(\.colorScheme) private var scheme
    @State private var expanded = false
    @State private var height: CGFloat = 0
    private let limit: CGFloat = 3 * 1.5 * 13

    var body: some View {
        let colors = ProductPalette(scheme: scheme)
        VStack(alignment: .trailing, spacing: 4) {
            SafeHTML(html: html, origin: origin)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
                .background { GeometryReader { geometry in
                    Color.clear.onAppear { height = geometry.size.height }.onChange(of: geometry.size.height) { _, value in height = value }
                } }
                .frame(maxWidth: .infinity, maxHeight: expanded ? nil : limit, alignment: .topLeading)
                .clipped()
            if height > limit + 1 {
                Button { expanded.toggle() } label: {
                    HStack(spacing: 0) {
                        Text(expanded ? L10n.t("收起详情") : L10n.t("查看详情")).font(.system(size: 12))
                        ProductGlyph(name: "expand_more", size: 12)
                            .rotationEffect(.degrees(expanded ? 180 : 0)).animation(.easeInOut(duration: 0.2), value: expanded)
                    }
                    .foregroundStyle(colors.secondary).padding(.horizontal, 8).padding(.vertical, 4).contentShape(Capsule())
                }.buttonStyle(.productPlain)
            }
        }
    }
}
