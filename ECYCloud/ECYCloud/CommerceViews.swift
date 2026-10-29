import SwiftUI
import CoreImage.CIFilterBuiltins
import ECYCloudKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

private extension Color {
    init(rgb: UInt32) {
        self.init(.sRGB, red: Double(rgb >> 16 & 255) / 255, green: Double(rgb >> 8 & 255) / 255, blue: Double(rgb & 255) / 255, opacity: 1)
    }
}

// 与 app/lib/ui/pages/shop_page.dart 及网页 shop.css 的 .shop-chip / .shop-countdown 同色
private enum ShopTone {
    static let green = Color(rgb: 0x22AD54), orange = Color(rgb: 0xEA580C), gold = Color(rgb: 0xCAA308), red = Color(rgb: 0xDC2626)
    static let teal = Color(rgb: 0x0D9488), blue = Color(rgb: 0x2563EB), purple = Color(rgb: 0x7C3AED), ended = Color(rgb: 0x999999)
}

private func shopAmount(_ text: String?) -> Double { Double((text ?? "").replacingOccurrences(of: ",", with: "")) ?? 0 }
private func shopNumber(_ value: Double) -> String { value == value.rounded() ? String(format: "%.0f", value) : String(value) }
private func shopError(_ error: Error) -> String { (error as? ClientError)?.localizedDescription ?? L10n.t("操作未完成，请重试。") }

struct PendingPayment: Identifiable {
    let id = UUID()
    let result: PurchaseResult
    let methodLabel: String
}
struct PurchaseMessage: Identifiable {
    let id = UUID()
    let message: String
    let cardKey: String
}
enum CheckoutOutcome {
    case order(coupon: String, autoRenew: Bool, payment: String)
    case cooldown(String, Int)
}

struct ShopView: View {
    let session: ClientSession
    @State private var state = FeatureState<ShopCatalog>()
    @Binding var category: ShopProduct.Kind
    @State private var duration: Int?
    @State private var cooldownUntil: Date?
    @State private var quoting = false
    @State private var checkout: Checkout?
    @State private var outcome: CheckoutOutcome?
    @State private var ordering: ShopProduct?
    @State private var pendingPayment: PendingPayment?
    @State private var paid: PaymentStatus?
    @State private var purchaseMessage: PurchaseMessage?
    @State private var notice: String?
    @State private var recharging = false
    @State private var gridWidth: CGFloat = 0
    @Environment(\.colorScheme) private var scheme
    private struct Checkout: Identifiable { let id = UUID(); let product: ShopProduct; let quote: ShopQuote }

    var body: some View {
        FeatureScreen(state: state, reload: load, topPadding: 30) { catalog in content(catalog) }
        .task { await load() }
        .productAutoRefresh(revision: session.profile?.revision(.shop), refreshSilently)
        .productDialog(item: $checkout, onDismiss: checkoutClosed) { item in
            CheckoutView(session: session, product: item.product, quote: item.quote, balance: state.value?.money ?? 0,
                         close: { checkout = nil }) { outcome = $0 }
        }
        .productSheet(item: $pendingPayment, onDismiss: paymentClosed) { item in
            PaymentWaitView(session: session, result: item.result, methodLabel: item.methodLabel,
                            timeoutHint: L10n.t("长时间未收到支付结果，可稍后在购买记录中确认。")) { paid = $0 }
        }
        .productSheet(item: $purchaseMessage, onDismiss: { Task { await refreshAfterPurchase() } }) { item in
            PurchaseMessageView(session: session, message: item.message, cardKey: item.cardKey)
        }
        .productSheet(isPresented: $recharging, onDismiss: { Task { await refreshAfterPurchase() } }) {
            FeatureSheet(title: L10n.t("余额充值"), avatar: false) { RechargeView(session: session) }
        }
        .alert(L10n.t("提示"), isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button(L10n.t("我知道了")) { notice = nil }
        } message: { Text(verbatim: notice ?? "") }
    }
    init(session: ClientSession, category: Binding<ShopProduct.Kind>) {
        self.session = session
        _category = category
    }

    @ViewBuilder private func content(_ catalog: ShopCatalog) -> some View {
        let colors = ProductPalette(scheme: scheme)
        ProductCard(title: L10n.t("账户余额"), icon: "account_balance_wallet_outlined") {
            DetailLine(title: L10n.t("当前余额"), value: String(format: "¥ %.2f", catalog.money))
        }.headerAction {
            Button(L10n.t("余额充值 ›")) { recharging = true }.buttonStyle(ProductButtonStyle()).fontWeight(.semibold)
        }
        if !catalog.notice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ProductCard(title: L10n.t("注意事项"), icon: "info_outline") { SafeHTML(html: catalog.notice, origin: session.endpoints.site) }
        }
        ProductSegments(values: ShopProduct.Kind.allCases, selection: $category) { $0.title }
            .frame(maxWidth: 300).frame(maxWidth: .infinity).padding(.vertical, 2)
        let durations = Array(Set(catalog.products.filter { $0.type == .plan }.compactMap(\.classExpire).filter { $0 > 0 })).sorted()
        let chosen = duration.flatMap { durations.contains($0) ? $0 : nil } ?? (durations.contains(catalog.defaultDuration) ? catalog.defaultDuration : durations.first)
        if category == .plan && durations.count > 1, let chosen {
            ProductSegments(values: durations, selection: Binding(get: { chosen }, set: { duration = $0 })) { L10n.t("{0}天", [String($0)]) }
                .frame(maxWidth: CGFloat(durations.count) * 80).frame(maxWidth: .infinity)
        }
        let products = catalog.products.filter { $0.type == category && (category != .plan || durations.isEmpty || $0.classExpire == chosen) }
        if products.isEmpty {
            Text(L10n.t("暂无商品")).foregroundStyle(colors.text).frame(maxWidth: .infinity).padding(.vertical, 60)
        } else {
            let columns = max(1, min(3, Int(gridWidth / 320)))
            ProductGrid {
                ForEach(Array(products.enumerated()), id: \.element.id) { index, product in
                    let start = index / columns * columns
                    productCard(product, reserveChips: products[start..<min(start + columns, products.count)].contains(where: Self.chipsVisible))
                        .fixedSize(horizontal: false, vertical: category == .cardKey)
                }
            }
            .background { GeometryReader { geometry in Color.clear.onAppear { gridWidth = geometry.size.width }.onChange(of: geometry.size.width) { _, value in gridWidth = value } } }
        }
    }

    private func productCard(_ product: ShopProduct, reserveChips: Bool) -> some View {
        let colors = ProductPalette(scheme: scheme)
        return VStack(spacing: 0) {
            VStack(spacing: 8) {
                Text(verbatim: product.name).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                if Self.chipsVisible(product) { chips(product) }
                else if reserveChips { Color.clear.frame(height: 20) }
            }.padding(.horizontal, 14).padding(.vertical, 12).frame(maxWidth: .infinity)
                .background(colors.accent.opacity(scheme == .dark ? 0.06 : 0.10))
                .overlay(alignment: .bottom) { Rectangle().fill(colors.segment.opacity(0.6)).frame(height: 1) }
            VStack(spacing: 0) {
                Text(verbatim: "¥ " + product.price).font(.system(size: 26, weight: .bold)).foregroundStyle(colors.accent)
                    .frame(maxWidth: .infinity)
                if product.type == .plan, let days = product.classExpire, days > 1 && days != 36500 {
                    Text(L10n.t("≈ {0} 元 / 天", [String(format: "%.2f", shopAmount(product.price) / Double(days))]))
                        .font(.system(size: 12)).foregroundStyle(colors.secondary)
                }
                if product.hasLimitedSale {
                    Text(L10n.t("原价 ¥ {0}", [product.basePrice])).font(.system(size: 12)).strikethrough().foregroundStyle(colors.secondary)
                }
                if !product.countdowns.isEmpty { countdowns(product) }
                if product.type == .plan { planDetails(product) } else { compactDetails(product) }
            }.padding(.horizontal, 14).padding(.top, 14)
            Spacer(minLength: 0)
            Button { Task { await buy(product) } } label: { Text(product.inStock ? L10n.t("购买") : L10n.t("已售罄")).frame(maxWidth: .infinity) }
                .buttonStyle(ProductButtonStyle(filled: true)).disabled(!product.inStock).padding(14)
        }.background(colors.surface).clipShape(RoundedRectangle(cornerRadius: 20))
    }

    private static func showsStock(_ product: ShopProduct) -> Bool { !product.stock.isEmpty && product.stock != "无限" }
    private static func chipsVisible(_ product: ShopProduct) -> Bool {
        showsStock(product) || product.purchaseLimit > 0 || product.newUserDaysLimit > 0 || product.minRegistrationDays > 0
    }
    private static func stockColor(_ product: ShopProduct) -> Color {
        guard product.inStock else { return ShopTone.red }
        switch product.stock {
        case "无限", "充足": return ShopTone.green
        case "少量": return ShopTone.gold
        case "适中": return ShopTone.orange
        default: break
        }
        guard let count = Int(product.stock.filter { ("0"..."9").contains($0) }) else { return ShopTone.green }
        return count <= 0 ? ShopTone.red : count < 10 ? ShopTone.gold : count < 20 ? ShopTone.orange : ShopTone.green
    }
    private func chips(_ product: ShopProduct) -> some View {
        ProductFlow(spacing: 6, centered: true) {
            if Self.showsStock(product) {
                ProductTag(text: L10n.t("库存{0}", [L10n.message(product.stock)]), color: Self.stockColor(product), icon: "inventory_2_outlined", capsule: true)
            }
            if product.purchaseLimit > 0 {
                ProductTag(text: L10n.t("限购{0}次", [String(product.purchaseLimit)]), color: ShopTone.purple, icon: "shopping_cart_outlined", capsule: true)
            }
            if product.newUserDaysLimit > 0 {
                ProductTag(text: L10n.t("需注册未满{0}天", [String(product.newUserDaysLimit)]), color: ShopTone.blue, icon: "person_add_alt", capsule: true)
            } else if product.minRegistrationDays > 0 {
                ProductTag(text: L10n.t("需注册满{0}天", [String(product.minRegistrationDays)]), color: ShopTone.blue, icon: "person_add_alt", capsule: true)
            }
        }
    }
    private func countdowns(_ product: ShopProduct) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            ProductFlow(spacing: 8, centered: true) {
                ForEach(product.countdowns.indices, id: \.self) { index in countdown(product.countdowns[index], now: context.date) }
            }
        }.padding(.top, 6)
    }
    private func countdown(_ item: ShopProduct.Countdown, now: Date) -> some View {
        let remaining = Double(item.end) - now.timeIntervalSince1970
        let ended = remaining < 0
        let dark = scheme == .dark
        let labelColor = ended ? ShopTone.ended : dark ? Color(rgb: 0xFB923C) : ShopTone.orange
        let timeColor = ended ? ShopTone.ended : dark ? Color(rgb: 0xF87171) : ShopTone.red
        let seconds = Int(max(0, remaining))
        let two = { (value: Int) in String(format: "%02d", value) }
        let time = ended ? L10n.t("00天00时00分00秒")
            : L10n.t("{0}天{1}时{2}分{3}秒", [two(seconds / 86400), two(seconds / 3600 % 24), two(seconds / 60 % 60), two(seconds % 60)])
        return HStack(spacing: 0) {
            ProductGlyph(name: "schedule", size: 15).foregroundStyle(labelColor).padding(.trailing, 4)
            Text(verbatim: L10n.t(item.label)).foregroundStyle(labelColor)
            Text(verbatim: time).monospacedDigit().foregroundStyle(timeColor).padding(.leading, 6)
        }.font(.system(size: 12, weight: .semibold))
    }
    private func planDetails(_ product: ShopProduct) -> some View {
        let colors = ProductPalette(scheme: scheme)
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                productMetric(L10n.t("等级"), "VIP \(product.class ?? 0)")
                productMetric(L10n.t("在线客户端数"), product.connector == 0 ? L10n.t("无限制") : L10n.t("{0} 个", [String(product.connector ?? 0)]))
                productMetric(L10n.t("网络速率"), product.speedlimit == 0 ? L10n.t("无限制") : "\(shopNumber(product.speedlimit ?? 0)) Mbps")
            }.padding(.vertical, 14)
            productLine(L10n.t("VIP有效期"), product.classExpire == 36500 ? L10n.t("不限时") : L10n.t("{0} 天", [String(product.classExpire ?? 0)]))
            productLine(product.classExpire == 1 ? L10n.t("试用流量") : L10n.t("每月流量"), product.bandwidth == 10000 ? L10n.t("无限制") : "\(shopNumber(product.bandwidth ?? 0)) GB")
            ForEach(product.contentExtra ?? [], id: \.self) { service in
                HStack(spacing: 6) {
                    ProductGlyph(name: "check_circle_outline", size: 13).foregroundStyle(colors.accent)
                    Text(verbatim: service).font(.system(size: 12)).foregroundStyle(colors.secondary)
                }.frame(maxWidth: .infinity).padding(.top, 6)
            }
        }
    }
    @ViewBuilder private func compactDetails(_ product: ShopProduct) -> some View {
        if product.type == .trafficPackage {
            ProductTag(text: "\(shopNumber(product.bandwidth ?? 0)) GB", color: ShopTone.teal, icon: "data_usage", capsule: true).padding(.top, 14)
        }
        if let html = product.description, !html.isEmpty {
            ProductDescription(html: html, origin: session.endpoints.site).padding(.top, 6)
        }
    }
    private func productMetric(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(verbatim: value).font(.system(size: 14, weight: .semibold)).lineLimit(1)
            Text(verbatim: title).font(.system(size: 12)).foregroundStyle(ProductPalette(scheme: scheme).secondary)
        }.frame(maxWidth: .infinity)
    }
    private func productLine(_ title: String, _ value: String) -> some View {
        HStack(spacing: 0) {
            Text(verbatim: title).font(.system(size: 13)).lineLimit(1).frame(maxWidth: .infinity)
            Spacer(minLength: 0).frame(maxWidth: .infinity)
            Text(verbatim: value).font(.system(size: 14, weight: .semibold)).foregroundStyle(ProductPalette(scheme: scheme).secondary)
                .lineLimit(1).frame(maxWidth: .infinity)
        }.padding(.vertical, 2.5)
    }

    private func buy(_ product: ShopProduct) async {
        guard !quoting else { return }
        if product.type == .plan, let until = cooldownUntil, until > .now {
            notice = L10n.t("您在24小时内已购买过套餐了，请在 {0} 后再购买新套餐。", [Self.cooldownText(Int(until.timeIntervalSinceNow))])
            return
        }
        quoting = true
        defer { quoting = false }
        do {
            let quote = try await session.quote(product, coupon: "")
            if product.type == .plan, quote.planCooldown == true {
                setCooldown(quote.planCooldownRemaining ?? 0)
                if let text = quote.planCooldownMsg, !text.isEmpty { notice = text }
                return
            }
            ordering = product
            checkout = Checkout(product: product, quote: quote)
        } catch is CancellationError {
        } catch { notice = shopError(error) }
    }
    private func checkoutClosed() {
        let outcome = self.outcome, product = ordering
        self.outcome = nil; ordering = nil
        switch outcome {
        case let .order(coupon, autoRenew, payment)?:
            if let product { Task { await submit(product, coupon: coupon, autoRenew: autoRenew, payment: payment) } }
        case let .cooldown(message, remaining)?:
            setCooldown(remaining)
            if !message.isEmpty { notice = message }
        case nil:
            break
        }
    }
    private func submit(_ product: ShopProduct, coupon: String, autoRenew: Bool, payment: String) async {
        do {
            let result = try await session.purchase(product, coupon: coupon, autoRenew: autoRenew && product.autoRenew.map({ $0 != 0 }) == true,
                                                    disableOthers: true, payment: payment)
            if result.needsPayment {
                pendingPayment = PendingPayment(result: result, methodLabel: PaymentPicker.methodLabel(payment))
            } else if !result.message.isEmpty || !result.cardKey.isEmpty {
                purchaseMessage = PurchaseMessage(message: result.message, cardKey: result.cardKey)
            } else {
                await refreshAfterPurchase()
            }
        } catch is CancellationError {
        } catch { notice = shopError(error) }
    }
    private func paymentClosed() {
        if let paid {
            purchaseMessage = PurchaseMessage(message: L10n.t("支付成功，订单已到账。"), cardKey: paid.cardKey)
            self.paid = nil
        } else {
            Task { await refreshAfterPurchase() }
        }
    }
    private func refreshAfterPurchase() async {
        await load()
        await session.refresh()
    }
    private func setCooldown(_ remaining: Int) {
        cooldownUntil = remaining > 0 ? Date().addingTimeInterval(TimeInterval(remaining)) : nil
    }
    private static func cooldownText(_ seconds: Int) -> String {
        var text = ""
        if seconds / 3600 > 0 { text += L10n.t("{0}小时", [String(seconds / 3600)]) }
        if seconds % 3600 / 60 > 0 { text += L10n.t("{0}分钟", [String(seconds % 3600 / 60)]) }
        if seconds % 60 > 0 { text += L10n.t("{0}秒", [String(seconds % 60)]) }
        return text
    }
    private func load() async {
        await state.load { try await session.shop() }
        if state.failure == nil, let value = state.value { setCooldown(value.planCooldownRemaining) }
    }
    private func refreshSilently() async {
        guard !state.loading, !state.working, let value = try? await session.shop() else { return }
        state.value = value
        setCooldown(value.planCooldownRemaining)
    }
}

private struct ProductDescription: View {
    let html: String
    let origin: URL
    @State private var expanded = false
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let colors = ProductPalette(scheme: scheme)
        VStack(alignment: .leading, spacing: 0) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 8) {
                    Text(L10n.t("商品描述")).font(.system(size: 12)).foregroundStyle(colors.secondary)
                    Spacer(minLength: 0)
                    ProductGlyph(name: "expand_more", size: 24).foregroundStyle(colors.secondary).rotationEffect(.degrees(expanded ? 180 : 0))
                }.padding(.horizontal, 10).frame(minHeight: 40).contentShape(Rectangle())
            }.buttonStyle(.productPlain)
            if expanded {
                SafeHTML(html: html, origin: origin).padding(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 16))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }.background(expanded ? colors.accent.opacity(0.06) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
    }
}

struct CheckoutView: View {
    let session: ClientSession
    let product: ShopProduct
    let balance: Double
    let close: () -> Void
    let complete: (CheckoutOutcome) -> Void
    @State private var quote: ShopQuote
    @State private var coupon = ""
    @State private var appliedCoupon = ""
    @State private var couponMessage = ""
    @State private var applying = false
    @State private var autoRenew = true
    @State private var payment: String
    @Environment(\.colorScheme) private var scheme

    init(session: ClientSession, product: ShopProduct, quote: ShopQuote, balance: Double, close: @escaping () -> Void,
         complete: @escaping (CheckoutOutcome) -> Void) {
        self.session = session; self.product = product; self.balance = balance; self.close = close; self.complete = complete
        _quote = State(initialValue: quote)
        _payment = State(initialValue: PaymentPicker.initial(total: shopAmount(quote.total), balance: balance))
    }
    private var title: String {
        switch product.type {
        case .plan: L10n.t("套餐订单确认")
        case .trafficPackage: L10n.t("流量包订单确认")
        case .cardKey: L10n.t("卡密商品订单确认")
        }
    }
    private var applyTitle: String {
        switch L10n.language {
        case .enUS: "Apply"
        case .zhTW: "套用"
        case .zhCN: "应用"
        }
    }
    private var totalText: String {
        let total = quote.total ?? "", base = quote.basePrice ?? ""
        return !base.isEmpty && base != total
            ? L10n.t("总金额：{0} 元（{1}：{2} 元）", [total, quote.hasLimitedSale == true ? L10n.t("限时价格") : L10n.t("原价"), base])
            : L10n.t("总金额：{0} 元", [total])
    }
    var body: some View {
        let colors = ProductPalette(scheme: scheme)
        let total = shopAmount(quote.total)
        // 对应 shop_page.dart 的 AppAlertDialog：内容区宽 460，左右内边距各 24
        ProductDialog(title: title) {
            VStack(alignment: .leading, spacing: 0) {
                if product.type == .trafficPackage {
                    Text(L10n.t("流量包仅限在当前套餐效期内使用")).font(.system(size: 12)).foregroundStyle(colors.secondary).padding(.bottom, 8)
                }
                Text(L10n.t("商品名称：{0}", [quote.name ?? product.name]))
                Text(verbatim: totalText).font(.system(size: 13, weight: .semibold)).padding(.top, 4)
                if product.type == .cardKey || quote.hasStockLimit == true {
                    Text(L10n.t("库存：{0}", [L10n.message(quote.stock ?? "")])).padding(.top, 4)
                }
                if product.type == .plan { planSection }
                PaymentPicker(total: total, balance: balance, selection: $payment).padding(.top, 12)
                if product.type == .plan && product.autoRenew.map({ $0 != 0 }) == true {
                    Toggle(isOn: $autoRenew) {
                        HStack(spacing: 16) {
                            ProductGlyph(name: "autorenew").foregroundStyle(colors.secondary)
                            Text(L10n.t("到期时自动续费"))
                        }
                    }.toggleStyle(ProductToggleStyle()).padding(.top, 8)
                }
            }
        } actions: {
            Button(product.type == .plan ? L10n.t("购买") : L10n.t("确定")) {
                complete(.order(coupon: appliedCoupon, autoRenew: autoRenew, payment: total <= 0 ? "" : payment))
                close()
            }.buttonStyle(ProductButtonStyle(filled: true)).disabled(applying)
            Button(L10n.t("取消"), action: close).buttonStyle(ProductButtonStyle())
        }.frame(maxWidth: 460 + 48)
    }
    @ViewBuilder private var planSection: some View {
        let colors = ProductPalette(scheme: scheme)
        if quote.hasTrafficResetFee == true {
            detailBlock(L10n.t("流量重置费用"), lines: [
                L10n.t("现有套餐：{0} 已使用：{1} / {2}（{3}%）", [quote.trafficCurrentShopName ?? "", ProductFormat.bytes(Int64(quote.trafficUsed ?? 0)),
                                                         ProductFormat.bytes(Int64(quote.trafficTotal ?? 0)), String(format: "%.2f", quote.trafficUsagePercent ?? 0)]),
                L10n.t("新套餐：{0} 计费基准价：{1} 元", [quote.name ?? product.name, quote.trafficBillingBasePrice ?? ""]),
                L10n.t("流量重置费：{0} x {1}%{2} = {3} 元", [quote.trafficBillingBasePrice ?? "", String(format: "%.2f", quote.trafficFeePercent ?? 0),
                                                       quote.trafficFeeIsCapped == true ? L10n.t("（费用上限）") : "", quote.trafficResetFee ?? ""]),
                L10n.t("费用规则：按已用流量比例计算，50% 封顶")
            ]).padding(.top, 10)
        }
        if quote.hasValidOrder == 1, let text = quote.upgradeMsg, !text.isEmpty {
            detailBlock(L10n.t("剩余价值抵扣"), lines: [text]).padding(.top, 10)
        }
        HStack(spacing: 8) {
            ProductTextField(hint: L10n.t("如有优惠码请在此输入"), text: $coupon)
            Button(applyTitle) { Task { await applyCoupon() } }.buttonStyle(ProductButtonStyle()).disabled(applying)
        }.padding(.top, 12)
        if !couponMessage.isEmpty {
            Text(verbatim: couponMessage).font(.system(size: 12)).foregroundStyle(colors.secondary).padding(.top, 6)
        }
    }
    private func detailBlock(_ title: String, lines: [String]) -> some View {
        let colors = ProductPalette(scheme: scheme)
        return VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: title).font(.system(size: 13, weight: .semibold)).padding(.bottom, 4)
            ForEach(lines, id: \.self) { line in
                Text(verbatim: line).font(.system(size: 12)).foregroundStyle(colors.secondary).padding(.vertical, 1)
            }
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(colors.segment, in: RoundedRectangle(cornerRadius: 8))
    }
    private func applyCoupon() async {
        let input = coupon.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { couponMessage = L10n.t("请输入优惠码"); return }
        applying = true
        couponMessage = L10n.t("正在验证优惠码...")
        defer { applying = false }
        do {
            let result = try await session.quote(product, coupon: input)
            if result.planCooldown == true {
                complete(.cooldown(result.planCooldownMsg ?? "", result.planCooldownRemaining ?? 0))
                close()
                return
            }
            quote = result
            let applied = result.couponApplied == true
            appliedCoupon = applied ? input : ""
            if let text = result.couponMsg, !text.isEmpty { couponMessage = text }
            else if applied, let credit = result.credit, credit > 0 { couponMessage = L10n.t("优惠码应用成功，优惠 {0}%", [String(credit)]) }
            else { couponMessage = applied ? L10n.t("优惠码应用成功") : "" }
            payment = PaymentPicker.initial(total: shopAmount(result.total), balance: balance)
        } catch is CancellationError {
        } catch { couponMessage = shopError(error) }
    }
}

struct PaymentPicker: View {
    let total: Double
    let balance: Double
    @Binding var selection: String
    @Environment(\.colorScheme) private var scheme
    @State private var hovered: String?
    private static let methods = ["", "alipay", "wxpay"]
    static func initial(total: Double, balance: Double) -> String { total <= 0 || balance >= total ? "" : "alipay" }
    static func methodLabel(_ method: String) -> String {
        method == "alipay" ? L10n.t("支付宝") : method == "wxpay" ? L10n.t("微信") : L10n.t("余额")
    }
    var body: some View {
        if total > 0 {
            let colors = ProductPalette(scheme: scheme)
            let affordable = balance >= total
            VStack(alignment: .leading, spacing: 0) {
                Text(L10n.t("选择支付方式")).font(.system(size: 13, weight: .semibold))
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 0) {
                        ForEach(Array(Self.methods.enumerated()), id: \.element) { index, method in
                            segment(method, enabled: !method.isEmpty || affordable)
                                .overlay(alignment: .leading) { if index > 0 { Rectangle().fill(colors.text).frame(width: 1) } }
                        }
                    }.fixedSize().clipShape(Capsule()).overlay(Capsule().strokeBorder(colors.text, lineWidth: 1))
                        .padding(.vertical, max(0, ProductMetrics.buttonTarget - 32) / 2)
                    VStack(spacing: 8) {
                        ForEach(Self.methods, id: \.self) { method in
                            Button { selection = method } label: { label(method).frame(maxWidth: .infinity) }
                                .buttonStyle(ProductButtonStyle(filled: selection == method)).disabled(method.isEmpty && !affordable)
                        }
                    }
                }.padding(.top, 8)
                Text(affordable ? L10n.t("当前余额：¥ {0}", [String(format: "%.2f", balance)])
                     : L10n.t("当前余额：¥ {0}，余额不足，请选择在线支付", [String(format: "%.2f", balance)]))
                    .font(.system(size: 12)).foregroundStyle(affordable ? colors.secondary : colors.danger).padding(.top, 6)
            }
        }
    }
    private func segment(_ method: String, enabled: Bool) -> some View {
        let colors = ProductPalette(scheme: scheme)
        let selected = selection == method
        return Button { selection = method } label: {
            label(method).font(.system(size: 12, weight: .semibold)).padding(.horizontal, 14).frame(minHeight: 32)
                .foregroundStyle(selected ? colors.surface : colors.text)
                .background {
                    selected ? colors.text : Color.clear
                    if hovered == method && enabled { (selected ? colors.surface : colors.text).opacity(0.08) }
                }
                .contentShape(Rectangle())
                .productHover { hovered = $0 ? method : (hovered == method ? nil : hovered) }
                .productFocusRing(Rectangle())
        }.buttonStyle(.productPlain).disabled(!enabled).opacity(enabled ? 1 : 0.38)
            .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
    private func label(_ method: String) -> some View {
        HStack(spacing: 8) {
            if method.isEmpty { ProductGlyph(name: "account_balance_wallet_outlined", size: 18) }
            else { Image("payment_" + method).resizable().scaledToFit().frame(width: 18, height: 18) }
            Text(method == "wxpay" ? L10n.t("微信支付") : Self.methodLabel(method))
        }
    }
}

struct RechargeView: View {
    let session: ClientSession
    @State private var state = FeatureState<RechargeInfo>()
    @State private var code = ""
    @State private var amount = ""
    @State private var pendingPayment: PendingPayment?
    @State private var paid = false
    @State private var dialog: Dialog?
    private struct Dialog { let title: String; let message: String }
    var body: some View {
        FeatureScreen(state: state, reload: load, topPadding: 0) { info in
            VStack(spacing: 10) {
                ProductCard(title: L10n.t("账户余额"), icon: "account_balance_wallet_outlined") {
                    DetailLine(title: L10n.t("当前余额"), value: String(format: "¥ %.2f", info.money))
                    DetailLine(title: L10n.t("累计消费"), value: "¥ " + info.totalTopUp)
                }
                ProductCard(title: L10n.t("充值码兑换"), icon: "confirmation_number_outlined") {
                    ProductField(title: L10n.t("充值码"), icon: "vpn_key_outlined", hasValue: !code.isEmpty) {
                        TextField(L10n.t("充值码"), text: $code).autocorrectionDisabled()
                            .onChange(of: code) { _, value in
                                let ascii = String(value.filter(\.isASCII))
                                if ascii != value { code = ascii }
                            }
                    }
                    Button(L10n.t("兑换")) { Task { await redeem() } }.buttonStyle(ProductButtonStyle(filled: true))
                        .disabled(state.working).frame(maxWidth: .infinity, alignment: .trailing)
                }
                if info.hasEpay {
                    ProductCard(title: L10n.t("在线充值"), icon: "currency_yen") {
                        ProductField(title: L10n.t("充值金额"), icon: "currency_yen", hasValue: !amount.isEmpty) {
                            TextField(L10n.t("充值金额"), text: $amount)
                            #if os(iOS) || os(visionOS)
                                .keyboardType(.decimalPad)
                            #endif
                        }
                        HStack(spacing: 10) {
                            ForEach(["alipay", "wxpay"], id: \.self) { method in
                                Button { Task { await pay(method) } } label: {
                                    HStack(spacing: 8) {
                                        Image("payment_" + method).resizable().scaledToFit().frame(width: 18, height: 18)
                                        Text(method == "alipay" ? L10n.t("支付宝") : L10n.t("微信支付"))
                                    }.frame(maxWidth: .infinity)
                                }.buttonStyle(ProductButtonStyle()).disabled(state.working)
                            }
                        }
                    }
                }
            }
        }
        .task { await load() }
        .task { await autoRefresh() }
        .productSheet(item: $pendingPayment, onDismiss: paymentClosed) { item in
            PaymentWaitView(session: session, result: item.result, methodLabel: item.methodLabel,
                            timeoutHint: L10n.t("长时间未收到支付结果，可稍后在余额记录中确认。")) { _ in paid = true }
        }
        .alert(dialog?.title ?? "", isPresented: Binding(get: { dialog != nil }, set: { if !$0 { dialog = nil } })) {
            Button(L10n.t("确定")) { dialog = nil }
        } message: { Text(verbatim: dialog?.message ?? "") }
    }
    private func redeem() async {
        let value = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !state.working else { return }
        var message = ""
        guard await state.perform({ message = try await session.redeem(value); return "" }) else { return }
        code = ""
        dialog = Dialog(title: L10n.t("兑换成功"), message: message.isEmpty ? L10n.t("兑换码已使用，余额已到账。") : message)
        await session.refresh()
        await load()
    }
    private func pay(_ method: String) async {
        guard !state.working else { return }
        let value = amount.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let price = Double(value), price > 0 else { state.message = L10n.t("请输入有效金额"); return }
        var online: PurchaseResult?
        guard await state.perform({
            let result = try await session.recharge(amount: value, payment: method)
            if result.needsPayment { online = result; return "" }
            return result.message.isEmpty ? L10n.t("充值已提交") : result.message
        }) else { return }
        if let online {
            pendingPayment = PendingPayment(result: online, methodLabel: method == "wxpay" ? L10n.t("微信") : L10n.t("支付宝"))
        } else {
            await session.refresh()
            await load()
        }
    }
    private func paymentClosed() {
        if paid {
            paid = false
            dialog = Dialog(title: L10n.t("支付成功"), message: L10n.t("支付成功，余额已到账"))
        }
        Task { await session.refresh(); await load() }
    }
    private func load() async { await state.load { try await session.rechargeInfo() } }
    private func autoRefresh() async {
        while true {
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
            guard !state.loading, !state.working, let value = try? await session.rechargeInfo(), !Task.isCancelled else { continue }
            state.value = value
        }
    }
}

struct PaymentWaitView: View {
    let session: ClientSession
    let result: PurchaseResult
    let methodLabel: String
    let timeoutHint: String
    let finish: (PaymentStatus) -> Void
    @State private var status = L10n.t("等待支付结果…")
    @State private var browser: Bool
    @State private var deadline = Date().addingTimeInterval(300)
    @State private var round = 0
    @State private var launched = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var scheme
    private struct PollKey: Equatable { let active: Bool; let round: Int }

    init(session: ClientSession, result: PurchaseResult, methodLabel: String, timeoutHint: String, finish: @escaping (PaymentStatus) -> Void) {
        self.session = session; self.result = result; self.methodLabel = methodLabel; self.timeoutHint = timeoutHint; self.finish = finish
        #if os(tvOS)
        _browser = State(initialValue: false)
        #else
        _browser = State(initialValue: result.payQrcode.isEmpty)
        #endif
    }
    private var paymentLink: URL? { ClientLink.external(result.paymentUrl.isEmpty ? result.payScheme : result.paymentUrl) }
    private var qrText: String {
        #if os(tvOS)
        result.payQrcode.isEmpty ? result.paymentUrl : result.payQrcode
        #else
        result.payQrcode
        #endif
    }
    private var hint: String {
        if browser { return L10n.t("已在系统浏览器中打开支付页面，完成支付后订单会自动到账。") }
        #if os(tvOS)
        if result.payQrcode.isEmpty { return L10n.t("请使用手机扫描二维码完成支付") }
        #endif
        return L10n.t("请用{0}扫描下方二维码，完成支付后订单会自动到账。", [methodLabel])
    }
    var body: some View {
        let colors = ProductPalette(scheme: scheme)
        FeatureSheet(title: L10n.t("等待支付"), working: true, avatar: false) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(verbatim: hint)
                    if !browser && !qrText.isEmpty { PaymentQRCode(text: qrText) }
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(verbatim: status).font(.system(size: 12)).foregroundStyle(colors.secondary)
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { Spacer(minLength: 0); actions }
                        VStack(alignment: .trailing, spacing: 8) { actions }.frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }.padding(16)
            }
        }
        .task {
            guard browser, !launched else { return }
            launched = true
            launch()
        }
        .task(id: PollKey(active: scenePhase == .active, round: round)) {
            guard scenePhase == .active else { return }
            if round > 0, await poll() { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                if await poll() { return }
            }
        }
    }
    @ViewBuilder private var actions: some View {
        Button(L10n.t("关闭")) { dismiss() }.buttonStyle(ProductButtonStyle())
        #if !os(tvOS)
        if paymentLink != nil {
            Button(browser ? L10n.t("重新打开支付页") : L10n.t("改用浏览器支付")) { browser = true; launch() }.buttonStyle(ProductButtonStyle())
        }
        #endif
        Button(L10n.t("我已完成支付")) { deadline = Date().addingTimeInterval(300); round += 1 }.buttonStyle(ProductButtonStyle(filled: true))
    }
    private func launch() {
        guard let url = paymentLink else { status = L10n.t("无法打开支付页面，请稍后重试。"); return }
        openURL(url) { accepted in if !accepted { status = L10n.t("无法打开支付页面，请稍后重试。") } }
    }
    private func poll() async -> Bool {
        guard Date() <= deadline else { status = timeoutHint; return true }
        do {
            let value = try await session.paymentStatus(result.tradeno)
            try Task.checkCancellation()
            guard value.paid else { return false }
            finish(value)
            dismiss()
            return true
        } catch is CancellationError {
            return true
        } catch {
            status = (error as? ClientError)?.localizedDescription ?? L10n.t("加载失败，请重试。")
            return false
        }
    }
}

struct PurchaseMessageView: View {
    let session: ClientSession
    let message: String
    let cardKey: String
    @State private var copied: String?
    @Environment(\.dismiss) private var dismiss
    private var html: String {
        guard !cardKey.isEmpty else { return message }
        return message.replacingOccurrences(of: #"<code\b[^>]*>[\s\S]*?</code>"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: cardKey, with: "")
            .replacingOccurrences(of: #"(?:<br\s*/?>\s*)+$"#, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    var body: some View {
        FeatureSheet(title: L10n.t("提示"), avatar: false) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !html.isEmpty { SafeHTML(html: html, origin: session.endpoints.site) }
                    if !cardKey.isEmpty {
                        Text(verbatim: cardKey).font(.system(size: 13, weight: .semibold)).productTextSelection().padding(.top, 8)
                        #if !os(tvOS)
                        Button(action: copy) {
                            HStack(spacing: 8) { ProductGlyph(name: "content_copy", size: 16); Text(L10n.t("复制卡密")) }
                        }.buttonStyle(ProductButtonStyle()).padding(.top, 4)
                        #endif
                    }
                    HStack {
                        Spacer(minLength: 0)
                        Button(L10n.t("我知道了")) { dismiss() }.buttonStyle(ProductButtonStyle(filled: true))
                    }.padding(.top, 20)
                }.padding(16)
            }
        }.productToast($copied)
    }
    #if !os(tvOS)
    private func copy() {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cardKey, forType: .string)
        #else
        UIPasteboard.general.string = cardKey
        #endif
        copied = L10n.t("已复制卡密")
    }
    #endif
}

struct PaymentQRCode: View {
    let text: String
    var label = L10n.t("支付二维码")
    @State private var code: CGImage?
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Group {
            if let code {
                Image(decorative: code, scale: 1).interpolation(.none).resizable().scaledToFit()
                    .frame(maxWidth: 180, maxHeight: 180).padding(12)
                    .background(.white, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(ProductPalette(scheme: scheme).segment, lineWidth: 1))
                    .accessibilityLabel(label)
            } else { ProductNotice(message: L10n.t("无法生成二维码，请使用支付链接。")) }
        }.frame(maxWidth: .infinity).task(id: text) {
            guard text.utf8.count <= 4096 else { code = nil; return }
            let filter = CIFilter.qrCodeGenerator(); filter.message = Data(text.utf8)
            guard let output = filter.outputImage else { return }
            code = CIContext().createCGImage(output, from: output.extent)
        }
    }
}
