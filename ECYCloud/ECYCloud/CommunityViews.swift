import SwiftUI
import ECYCloudKit

// 对应 auto_refresh_mixin.dart：面板下发该页版本号时只在版本变化后静默重取，未下发时每 60 秒静默刷新；切换语言后立即重取
private struct ProductAutoRefresh: ViewModifier {
    let revision: String?
    let refresh: @MainActor () async -> Void
    @Environment(\.locale) private var locale
    func body(content: Content) -> some View {
        content
            .task(id: revision == nil) {
                guard revision == nil else { return }
                while true {
                    do { try await Task.sleep(for: .seconds(60)) } catch { return }
                    await refresh()
                }
            }
            .onChange(of: revision) { old, new in if old != nil && new != nil { Task { await refresh() } } }
            .onChange(of: locale) { Task { await refresh() } }
    }
}

struct ProductTableText: View {
    let text: String
    var bold = false
    var color: Color?
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let colors = ProductPalette(scheme: scheme)
        Text(verbatim: text.isEmpty ? "—" : text).font(.system(size: bold ? 13 : 12, weight: bold ? .semibold : .regular)).monospacedDigit()
            .foregroundStyle(color ?? (bold ? colors.text : colors.secondary))
    }
}

extension View {
    func productAutoRefresh(revision: String? = nil, _ refresh: @escaping @MainActor () async -> Void) -> some View {
        modifier(ProductAutoRefresh(revision: revision, refresh: refresh))
    }
    func productDialog<Dialog: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Dialog) -> some View {
        #if os(tvOS)
        // tvOS 焦点引擎不受遮罩阻挡，叠加层里的按钮拿不到焦点；改为全屏呈现，焦点限定在弹窗内
        fullScreenCover(isPresented: isPresented) {
            ProductDialogBarrier(dismiss: { isPresented.wrappedValue = false }, content: content).presentationBackground(.clear)
        }
        #else
        overlay { if isPresented.wrappedValue { ProductDialogBarrier(dismiss: { isPresented.wrappedValue = false }, content: content) } }
        #endif
    }
    func productDialog<Item: Identifiable, Dialog: View>(item: Binding<Item?>, onDismiss: (() -> Void)? = nil,
                                                         @ViewBuilder content: @escaping (Item) -> Dialog) -> some View {
        #if os(tvOS)
        fullScreenCover(item: item, onDismiss: onDismiss) { value in
            ProductDialogBarrier(dismiss: { item.wrappedValue = nil }) { content(value) }.presentationBackground(.clear)
        }
        #else
        overlay { if let value = item.wrappedValue { ProductDialogBarrier(dismiss: { item.wrappedValue = nil }) { content(value) } } }
            .onChange(of: item.wrappedValue == nil) { _, closed in if closed { onDismiss?() } }
        #endif
    }
}

private struct ProductDialogBarrier<Content: View>: View {
    let dismiss: () -> Void
    @ViewBuilder var content: () -> Content
    var body: some View {
        ZStack {
            Color.black.opacity(0.54).ignoresSafeArea().contentShape(Rectangle()).onTapGesture(perform: dismiss).accessibilityHidden(true)
            content().padding(.horizontal, 40).padding(.vertical, 24)
        }
        #if os(tvOS) || os(macOS)
        .onExitCommand(perform: dismiss)
        #endif
    }
}

struct ProductDialog<Content: View, Actions: View>: View {
    let title: String
    // 对应 AppAlertDialog：标题默认左对齐，只有公告弹窗（announcement_dialog.dart）居中
    var centeredTitle = false
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions
    @Environment(\.colorScheme) private var scheme
    @State private var contentHeight: CGFloat = 0
    var body: some View {
        let colors = ProductPalette(scheme: scheme)
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: title).font(.system(size: 18)).multilineTextAlignment(centeredTitle ? .center : .leading)
                .frame(maxWidth: .infinity, alignment: centeredTitle ? .center : .leading)
            // 对应 AlertDialog(scrollable: true) 始终只有一个滚动容器：在两种容器间切换会重建内容，输入框随之失焦；
            // 标题下的间距放在滚动区内，跨在描边上的浮动标签才不会被裁掉
            ScrollView {
                wrapped(content).padding(.top, 16)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .frame(maxHeight: contentHeight)
            .scrollBounceBehavior(.basedOnSize)
            HStack(spacing: 8) { actions }.frame(maxWidth: .infinity, alignment: .trailing).padding(.top, 24)
        }
        .font(.system(size: 13)).foregroundStyle(colors.text)
        .padding(24).frame(minWidth: 280, maxWidth: 560)
        .background(colors.surface, in: RoundedRectangle(cornerRadius: 20))
    }
    private func wrapped(_ content: Content) -> some View {
        content.frame(maxWidth: .infinity, alignment: .leading).productTextSelection()
    }
}

struct AnnouncementBody: View {
    let session: ClientSession
    let item: Announcement
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(spacing: 0) {
            if item.id != 1 && !item.date.isEmpty {
                Text(verbatim: item.date).font(.system(size: 12)).foregroundStyle(ProductPalette(scheme: scheme).secondary)
                    .multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.bottom, 12)
            }
            SafeHTML(html: item.content, origin: session.endpoints.site).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct AnnouncementPopup: View {
    let session: ClientSession
    let item: Announcement
    let close: () -> Void
    var body: some View {
        ProductDialog(title: item.title, centeredTitle: true) { AnnouncementBody(session: session, item: item) } actions: {
            Button(L10n.t("我知道了")) { session.announcementState.dismissPopup(item); close() }.buttonStyle(ProductButtonStyle(filled: true))
        }
    }
}

struct AnnouncementsView: View {
    let session: ClientSession
    var close: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var state = FeatureState<AnnouncementBundle>()
    @State private var index: Int?
    @State private var browsed = false
    var body: some View {
        Group {
            if let items = state.value?.announcements, !items.isEmpty {
                let current = min(max(index ?? 0, 0), items.count - 1)
                ProductDialog(title: items[current].title, centeredTitle: true) { AnnouncementBody(session: session, item: items[current]) } actions: {
                    VStack(alignment: .trailing, spacing: 0) {
                        if items.count > 1 {
                            HStack(spacing: 8) {
                                Button(L10n.t("上一条")) { browsed = true; index = (current - 1 + items.count) % items.count }.buttonStyle(ProductButtonStyle())
                                Spacer(minLength: 0)
                                Text(verbatim: "\(current + 1) / \(items.count)").font(.system(size: 12)).foregroundStyle(ProductPalette(scheme: scheme).secondary)
                                Spacer(minLength: 0)
                                Button(L10n.t("下一条")) { browsed = true; index = (current + 1) % items.count }.buttonStyle(ProductButtonStyle())
                            }.padding(.bottom, 24)
                        }
                        Button(L10n.t("关闭"), action: finish).buttonStyle(ProductButtonStyle())
                    }
                }
            } else {
                ProductDialog(title: L10n.t("网站公告")) {
                    if state.value == nil && state.failure == nil { ProgressView().frame(maxWidth: .infinity, minHeight: 96) }
                    else { Text(verbatim: state.failure ?? (state.value != nil ? L10n.t("暂无公告") : L10n.t("暂时无法获取公告，请稍后重试"))) }
                } actions: {
                    Button(L10n.t("关闭"), action: finish).buttonStyle(ProductButtonStyle())
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            if state.value == nil { state.value = session.announcementState.bundle }
            if let items = state.value?.announcements { index = session.announcementState.openIndex(items) }
            await state.load { try await session.announcements() }
            if !browsed, let items = state.value?.announcements { index = session.announcementState.openIndex(items) }
        }
        .onDisappear { session.announcementState.markAllSeen() }
    }
    private func finish() { if let close { close() } else { dismiss() } }
}

struct TrafficHistoryView: View {
    let session: ClientSession
    var openShop: (() -> Void)?
    @State private var state = FeatureState<TrafficHistory>()
    @State private var expandedDay: String?
    @State private var daySort: Int?
    @State private var dayAscending = true
    @State private var nodeSort: Int?
    @State private var nodeAscending = true
    @State private var showInfo = false
    @State private var showStrategy = false
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        FeatureScreen(state: state, reload: load, topPadding: 0) { history in
            VStack(alignment: .leading, spacing: 10) {
                ProductCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.t("此处只展示最近 {0} 天的每日流量记录。", [String(describing: history.logKeepDays)]))
                        Text(L10n.t("当天的流量数据为实时统计，历史数据为每日汇总记录。点击日期可查看节点使用详情。")).fontWeight(.semibold)
                        ProductFlow(spacing: 0) {
                            Text(L10n.t("我没有使用某些节点，为什么这些节点也会消耗流量？"))
                            Button(L10n.t("查看说明")) { showInfo = true }.buttonStyle(ProductButtonStyle())
                        }.productFocusSection()
                        if let openShop {
                            ProductFlow(spacing: 0) {
                                Text(L10n.t("流量不够用？前往 "))
                                Button(L10n.t("商店") + " ›", action: openShop).buttonStyle(ProductButtonStyle())
                                Text(L10n.t(" 选购流量包"))
                            }.productFocusSection()
                        }
                    }.font(.system(size: 14)).foregroundStyle(ProductPalette(scheme: scheme).secondary)
                }
                TrafficDayTable(history: history, days: sortedDays(history), expandedDay: $expandedDay,
                                daySort: daySort, dayAscending: dayAscending, nodeSort: nodeSort, nodeAscending: nodeAscending,
                                sortDays: { column in dayAscending = daySort == column ? !dayAscending : true; daySort = column },
                                sortNodes: { column in nodeAscending = nodeSort == column ? !nodeAscending : true; nodeSort = column },
                                nodes: sortedNodes)
            }
        }.task { await load() }
        .productAutoRefresh { if !state.loading, let value = try? await session.trafficHistory(), !state.loading { state.value = value } }
        .alert(L10n.t("流量记录说明"), isPresented: $showInfo) {
            Button(L10n.t("分组策略") + " ›") { showStrategy = true }
            Button(L10n.t("我知道了"), role: .cancel) { }
        } message: {
            Text(L10n.t("如果您手动测试了一些节点的延迟或者您使用了包含自动选择和故障转移策略的订阅，如：Clash / Stash、Surge等自带分流策略的订阅链接，以及Quantumult X、Shadowrocket、Loon等带自动测试的分流规则，会每隔一段时间测试一次延迟(通常是每5分钟左右)，以检查最低延迟的节点以及节点存活性，这部分测试也会被计入流量，通常每个节点在一小时内自动测试延迟所消耗的流量在1-5KB左右。")
                 + "\n\n" + L10n.t("如需关闭自动测试可在本客户端的 ") + L10n.t("分组策略") + L10n.t(" 关闭 自动选择 和 故障转移 策略组。"))
        }
        .navigationDestination(isPresented: $showStrategy) { SubscriptionStrategyView(session: session) }
    }
    private func sortedNodes(_ history: TrafficHistory, _ day: String) -> [TrafficHistory.Node] {
        (history.nodeTraffic[day] ?? []).sorted { left, right in
            guard let column = nodeSort else { return false }
            if column == 0 { return nodeAscending ? left.nodeName.lowercased() < right.nodeName.lowercased() : left.nodeName.lowercased() > right.nodeName.lowercased() }
            let a = [Double(left.dailyUpload), Double(left.dailyDownload), left.nodeTrafficRate, Double(left.dailyUsage)][column - 1]
            let b = [Double(right.dailyUpload), Double(right.dailyDownload), right.nodeTrafficRate, Double(right.dailyUsage)][column - 1]
            return nodeAscending ? a < b : a > b
        }
    }
    private func sortedDays(_ history: TrafficHistory) -> [String] {
        history.traffic.keys.sorted { left, right in
            guard let column = daySort else { return left > right }
            if column == 0 { return dayAscending ? left < right : left > right }
            let a = history.traffic[left]!, b = history.traffic[right]!
            let av = [a.totalUpload, a.totalDownload, a.rateInfo, a.totalUsage][column - 1]
            let bv = [b.totalUpload, b.totalDownload, b.rateInfo, b.totalUsage][column - 1]
            return dayAscending ? number(av, traffic: column != 3) < number(bv, traffic: column != 3) : number(av, traffic: column != 3) > number(bv, traffic: column != 3)
        }
    }
    private func number(_ value: String, traffic: Bool) -> Double {
        let raw = value.replacingOccurrences(of: " ", with: "")
        guard let range = raw.range(of: "-?[0-9]+(?:\\.[0-9]+)?", options: .regularExpression), let number = Double(raw[range]) else { return 0 }
        guard traffic else { return number }
        let unit = String(raw[range.upperBound...]).uppercased()
        let power = ["B", "KB", "MB", "GB", "TB", "PB", "EB", "ZB", "YB"].firstIndex(of: unit) ?? 0
        return number * pow(1024, Double(power))
    }
    private func load() async { await state.load { try await session.trafficHistory() } }
}

private struct TrafficDayTable: View {
    let history: TrafficHistory
    let days: [String]
    @Binding var expandedDay: String?
    let daySort: Int?
    let dayAscending: Bool
    let nodeSort: Int?
    let nodeAscending: Bool
    let sortDays: (Int) -> Void
    let sortNodes: (Int) -> Void
    let nodes: (TrafficHistory, String) -> [TrafficHistory.Node]
    @Environment(\.colorScheme) private var scheme
    private var colors: ProductPalette { ProductPalette(scheme: scheme) }
    private let dayColumns = ["日期", "实际上传流量", "实际下载流量", "倍率", "结算流量"]
    private let nodeColumns = ["节点名称", "实际上传流量", "实际下载流量", "倍率", "结算流量"]
    private var expandedFill: Color {
        scheme == .dark ? Color(.sRGB, red: 0x1E / 255, green: 0x3A / 255, blue: 0x5F / 255, opacity: 0x8C / 255)
            : Color(.sRGB, red: 0xEA / 255, green: 0xF3 / 255, blue: 1, opacity: 1)
    }
    private var expandedBar: Color {
        scheme == .dark ? Color(.sRGB, red: 0x64 / 255, green: 0xB5 / 255, blue: 0xF6 / 255, opacity: 1)
            : Color(.sRGB, red: 0x19 / 255, green: 0x76 / 255, blue: 0xD2 / 255, opacity: 1)
    }
    var body: some View {
        Group {
            if days.isEmpty {
                Text(L10n.t("您最近 {0} 天内还没有流量使用记录", [String(describing: history.logKeepDays)])).font(.system(size: 13))
                    .foregroundStyle(colors.secondary).padding(.vertical, 32).frame(maxWidth: .infinity)
            } else {
                ViewThatFits(in: .horizontal) {
                    wide.frame(minWidth: 800)
                    narrow
                }
            }
        }.background(colors.surface).clipShape(RoundedRectangle(cornerRadius: 20))
    }
    private var line: some View { Rectangle().fill(colors.segment).frame(height: 0.5) }
    private func row(_ cells: [AnyView]) -> some View {
        HStack(spacing: 0) {
            ForEach(cells.indices, id: \.self) { index in
                cells[index].frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 12)
            }
        }.contentShape(Rectangle())
    }
    private func sortLabel(_ title: String, column: Int, active: Int?, ascending: Bool, sort: @escaping (Int) -> Void) -> AnyView {
        let selected = active == column
        func arrow(_ text: String, _ highlight: Bool) -> some View {
            Text(verbatim: text).font(.system(size: 10, weight: .semibold)).foregroundStyle(colors.secondary.opacity(highlight ? 1 : selected ? 0.45 : 0.65))
        }
        return AnyView(Button { sort(column) } label: {
            HStack(spacing: 0) {
                Text(L10n.t(title)).font(.system(size: 12, weight: .semibold)).foregroundStyle(colors.secondary).padding(.trailing, 4)
                arrow("↑", selected && ascending)
                arrow("↓", selected && !ascending)
            }.padding(2).contentShape(Rectangle())
        }.buttonStyle(.productPlain))
    }
    private func dayCell(_ day: String, bold: Bool) -> some View {
        HStack(spacing: 0) {
            ProductGlyph(name: expandedDay == day ? "expand_more" : "chevron_right", size: 18).foregroundStyle(colors.text)
            ProductTableText(text: day, bold: bold)
        }
    }
    private func toggle(_ day: String) { expandedDay = expandedDay == day ? nil : day }
    private func expandedStyle<Content: View>(_ day: String, _ content: Content) -> some View {
        content.background(expandedDay == day ? expandedFill : Color.clear)
            .overlay(alignment: .leading) { if expandedDay == day { Rectangle().fill(expandedBar).frame(width: 3) } }
    }
    private var wide: some View {
        VStack(spacing: 0) {
            row(dayColumns.indices.map { sortLabel(dayColumns[$0], column: $0, active: daySort, ascending: dayAscending, sort: sortDays) })
            ForEach(days, id: \.self) { day in
                let total = history.traffic[day]!
                line
                expandedStyle(day, Button { toggle(day) } label: {
                    row([AnyView(dayCell(day, bold: false)), AnyView(ProductTableText(text: total.totalUpload)), AnyView(ProductTableText(text: total.totalDownload)),
                         AnyView(ProductTableText(text: L10n.t(total.rateInfo))), AnyView(ProductTableText(text: total.totalUsage, bold: true))])
                }.buttonStyle(.productPlain))
                if expandedDay == day { wideNodes(day) }
            }
            line
            row([L10n.t("累计使用流量"), history.totalUpload, history.totalDownload, L10n.t(history.totalRateInfo), history.totalUsage]
                .map { AnyView(ProductTableText(text: $0, bold: true)) })
        }
    }
    private func wideNodes(_ day: String) -> some View {
        let items = nodes(history, day)
        return VStack(spacing: 0) {
            line
            row(nodeColumns.indices.map { sortLabel(nodeColumns[$0], column: $0, active: nodeSort, ascending: nodeAscending, sort: sortNodes) })
                .background(colors.segment.opacity(0.35))
            if items.isEmpty {
                row([AnyView(Text(L10n.t("该日期没有节点使用数据")).font(.system(size: 12)).foregroundStyle(colors.secondary))] + Array(repeating: AnyView(EmptyView()), count: 4))
            }
            ForEach(items.indices, id: \.self) { index in
                let node = items[index]
                row([AnyView(ProductTableText(text: node.nodeName, bold: true)), AnyView(ProductTableText(text: ProductFormat.bytes(node.dailyUpload))),
                     AnyView(ProductTableText(text: ProductFormat.bytes(node.dailyDownload))), AnyView(ProductTableText(text: node.nodeRateStr)),
                     AnyView(ProductTableText(text: ProductFormat.bytes(node.dailyUsage), bold: true))])
            }
        }.background(colors.segment.opacity(0.28))
    }
    private func pair<Value: View>(_ label: String, _ value: Value) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(L10n.t(label)).font(.system(size: 12)).foregroundStyle(colors.secondary).frame(width: 96, alignment: .leading)
            value.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.vertical, 3)
    }
    private var narrow: some View {
        VStack(spacing: 0) {
            ForEach(Array(days.enumerated()), id: \.element) { index, day in
                let total = history.traffic[day]!
                if index > 0 { line }
                expandedStyle(day, Button { toggle(day) } label: {
                    VStack(spacing: 0) {
                        pair("日期", dayCell(day, bold: true))
                        pair("实际上传流量", ProductTableText(text: total.totalUpload))
                        pair("实际下载流量", ProductTableText(text: total.totalDownload))
                        pair("倍率", ProductTableText(text: L10n.t(total.rateInfo)))
                        pair("结算流量", ProductTableText(text: total.totalUsage, bold: true))
                    }.padding(.horizontal, 12).padding(.vertical, 10).contentShape(Rectangle())
                }.buttonStyle(.productPlain))
                if expandedDay == day { narrowNodes(day) }
            }
            line
            VStack(spacing: 0) {
                pair("日期", ProductTableText(text: L10n.t("累计使用流量"), bold: true))
                pair("实际上传流量", ProductTableText(text: history.totalUpload, bold: true))
                pair("实际下载流量", ProductTableText(text: history.totalDownload, bold: true))
                pair("倍率", ProductTableText(text: L10n.t(history.totalRateInfo), bold: true))
                pair("结算流量", ProductTableText(text: history.totalUsage, bold: true))
            }.padding(.horizontal, 12).padding(.vertical, 10)
        }
    }
    private func narrowNodes(_ day: String) -> some View {
        let items = history.nodeTraffic[day] ?? []
        return VStack(spacing: 0) {
            if items.isEmpty { Text(L10n.t("该日期没有节点使用数据")).font(.system(size: 12)).foregroundStyle(colors.secondary).frame(maxWidth: .infinity, alignment: .leading) }
            ForEach(items.indices, id: \.self) { index in
                let node = items[index]
                if index > 0 { line }
                pair("节点名称", ProductTableText(text: node.nodeName, bold: true))
                pair("实际上传流量", ProductTableText(text: ProductFormat.bytes(node.dailyUpload)))
                pair("实际下载流量", ProductTableText(text: ProductFormat.bytes(node.dailyDownload)))
                pair("倍率", ProductTableText(text: node.nodeRateStr))
                pair("结算流量", ProductTableText(text: ProductFormat.bytes(node.dailyUsage), bold: true))
            }
        }.padding(.horizontal, 12).padding(.vertical, 10).background(colors.segment.opacity(0.28))
    }
}

private struct TicketRoute: Identifiable, Hashable { let id: Int }

struct TicketsView: View {
    let session: ClientSession
    @State private var state = FeatureState<TicketPage>()
    @State private var search = ""
    @State private var page = 1
    @State private var refresh = 0
    @State private var opened: TicketRoute?
    @State private var composing = false
    @Environment(\.colorScheme) private var scheme
    private var query: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }
    var body: some View {
        let colors = ProductPalette(scheme: scheme)
        FeatureScreen(state: state, reload: load, topPadding: 8) { value in
            ProductSearchField(hint: L10n.t("标题 / 工单号"), text: $search).onChange(of: search) { _, _ in page = 1 }
            if value.banned { Text(L10n.t("您已被禁止发起或回复工单")).font(.system(size: 12)).foregroundStyle(colors.danger) }
            ProductCard(padding: EdgeInsets(top: 20, leading: 12, bottom: 20, trailing: 12)) {
                HStack(spacing: 12) {
                    Text(L10n.t("如需与我们沟通，请点击创建工单按钮。")).font(.system(size: 14)).foregroundStyle(colors.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button { composing = true } label: { Label { Text(L10n.t("创建工单")) } icon: { ProductGlyph(name: "add", size: 16) } }
                        .buttonStyle(ProductButtonStyle(filled: true)).disabled(state.loading || value.banned)
                }
            }
            ProductTable(columns: [L10n.t("操作"), L10n.t("标题"), L10n.t("状态"), L10n.t("创建时间"), L10n.t("最后回复时间")], actionColumn: 0, rows: value.tickets.map { ticket in
                [AnyView(Button(L10n.t("查看")) { opened = TicketRoute(id: ticket.id) }.buttonStyle(ProductButtonStyle(filled: true))),
                 AnyView(ProductTableText(text: "\(ticket.title) (#\(ticket.id))")), AnyView(ProductTableText(text: ticket.statusText)),
                 AnyView(ProductTableText(text: ticket.datetime)),
                 AnyView(ProductTableText(text: ticket.lastReplyTime.isEmpty ? L10n.t("无回复") : ticket.lastReplyTime))]
            }, empty: query.isEmpty ? L10n.t("您目前还没有工单沟通记录") : L10n.t("没有匹配结果"))
            PageButtons(current: value.currentPage, last: value.lastPage, total: value.total) { page = $0 }
        }
        .task(id: "\(page)|\(search)|\(refresh)") {
            do { if !search.isEmpty { try await Task.sleep(for: .milliseconds(300)) }; await load() } catch { }
        }
        .productAutoRefresh(revision: session.profile?.revision(.tickets), silentLoad)
        // 对应 tickets_page.dart：详情以整页推入，创建工单为对话框
        .navigationDestination(item: $opened) { TicketConversationView(session: session, id: $0.id) }
        .onChange(of: opened) { _, route in if route == nil { refresh += 1 } }
        .productDialog(isPresented: $composing) {
            TicketComposerView(session: session, close: { composing = false }) { opened = TicketRoute(id: $0) }
        }
    }
    private func load() async {
        await state.load { try await session.tickets(page: page, search: query) }
        if let value = state.value, value.currentPage > value.lastPage { page = value.lastPage }
    }
    private func silentLoad() async {
        guard !state.loading, !state.working, let value = try? await session.tickets(page: page, search: query), !state.loading else { return }
        state.value = value
    }
}

struct TicketComposerView: View {
    let session: ClientSession
    var replyTo: Int?
    let close: () -> Void
    var finished: (Int) -> Void = { _ in }
    @State private var title = ""
    @State private var text = ""
    @State private var attachments: [TicketAttachment] = []
    @State private var uploading = false
    @State private var working = false
    @State private var toast: String?
    var body: some View {
        ProductDialog(title: replyTo == nil ? L10n.t("创建工单") : L10n.t("回复工单")) {
            VStack(alignment: .leading, spacing: 0) {
                if replyTo == nil { ProductTextField(hint: L10n.t("标题"), text: $title, labeled: true).padding(.bottom, 12) }
                TicketEditor(text: $text)
                TicketAttachmentPicker(session: session, attachments: $attachments, uploading: $uploading, message: $toast).padding(.top, 10)
            }
        } actions: {
            Button(L10n.t("提交")) { Task { await submit() } }.buttonStyle(ProductButtonStyle(filled: true)).disabled(uploading || working)
            Button(L10n.t("取消"), action: close).buttonStyle(ProductButtonStyle()).disabled(uploading || working)
        }
        // 对应 _TicketEditorDialog 的 SizedBox(width: 460) 加 AlertDialog 左右各 24 内边距
        .frame(maxWidth: 508)
        .productToast($toast)
    }
    private func submit() async {
        let blank = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard replyTo != nil || !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !blank || !attachments.isEmpty, !working else { return }
        working = true
        defer { working = false }
        do {
            if let replyTo {
                _ = try await session.replyTicket(replyTo, text: text, attachments: attachments)
                finished(replyTo)
            } else {
                finished(try await session.createTicket(title: title, text: text, attachments: attachments))
            }
            close()
        } catch is CancellationError { }
        catch { toast = (error as? ClientError)?.localizedDescription ?? L10n.t("操作未完成，请重试。") }
    }
}

struct TicketConversationView: View {
    let session: ClientSession
    let id: Int
    @State private var state = FeatureState<TicketDetail>()
    @State private var page = 1
    @State private var confirmClose = false
    @State private var replying = false
    @State private var replied = false
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        FeatureSheet(title: state.value.map { "\($0.title) (#\($0.id))" } ?? L10n.t("工单详情"), working: state.working) {
            FeatureScreen(state: state, reload: load, showsRefresh: false, topPadding: 14) { detail in conversation(detail) }
        }
        .task(id: id) { await load() }
        .productAutoRefresh(revision: session.profile?.revision(.tickets), silentLoad)
        .alert(L10n.t("关闭工单"), isPresented: $confirmClose) {
            Button(L10n.t("关闭工单"), role: .destructive) { Task { if await state.perform({ _ = try await session.closeTicket(id); return "" }) { await load() } } }
            Button(L10n.t("取消"), role: .cancel) { }
        } message: { Text(L10n.t("确定关闭此工单？")) }
        .productDialog(isPresented: $replying) {
            TicketComposerView(session: session, replyTo: id, close: { replying = false }) { _ in replied = true }
        }
        .onChange(of: replying) { _, open in if !open && replied { replied = false; Task { await load() } } }
    }
    @ViewBuilder private func conversation(_ detail: TicketDetail) -> some View {
        let colors = ProductPalette(scheme: scheme)
        let last = max(1, (detail.messages.count + 9) / 10)
        let current = min(max(page, 1), last)
        let shown = Array(detail.messages.dropFirst((current - 1) * 10).prefix(10))
        if !detail.banned {
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                if detail.status != 0 {
                    Button(L10n.t("关闭工单")) { confirmClose = true }
                        .buttonStyle(ProductButtonStyle(filled: true, color: ProductPalette(scheme: .light).danger)).disabled(state.working)
                }
                Button { replying = true } label: { Label { Text(L10n.t("回复工单")) } icon: { ProductGlyph(name: "reply", size: 16) } }
                    .buttonStyle(ProductButtonStyle(filled: true))
            }
        }
        VStack(spacing: 8) {
            ProductFlow(spacing: 8, centered: true, runSpacing: 6) {
                ProductTag(text: detail.statusText)
                Text(L10n.t("创建 {0}", [detail.datetime])).font(.system(size: 12)).foregroundStyle(colors.secondary)
                Text(L10n.t("共 {0} 条消息", [String(describing: detail.messageCount)])).font(.system(size: 12)).foregroundStyle(colors.secondary)
            }
            if detail.banned { Text(L10n.t("您已被禁止回复工单")).font(.system(size: 12)).foregroundStyle(colors.danger) }
        }
        if shown.isEmpty {
            Text(L10n.t("暂无消息")).frame(maxWidth: .infinity).padding(.top, 40)
        } else {
            VStack(spacing: 10) {
                ForEach(shown) { message in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top, spacing: 8) {
                            Text(verbatim: message.userName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                .foregroundStyle(message.isAdmin ? colors.warning : colors.accent)
                            Spacer(minLength: 0)
                            Text(verbatim: message.datetime).font(.system(size: 12)).foregroundStyle(colors.secondary).multilineTextAlignment(.trailing)
                        }
                        SafeHTML(html: message.content, origin: session.endpoints.site)
                    }
                    .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    .background(message.isAdmin ? colors.segment : colors.surface, in: RoundedRectangle(cornerRadius: 20))
                }
            }
        }
        PageButtons(current: current, last: last, total: detail.messages.count) { page = $0 }
    }
    private func load() async {
        await state.load { try await session.ticket(id) }
        if state.failure == nil { page = 1 }
    }
    private func silentLoad() async {
        guard !state.loading, !state.working, let value = try? await session.ticket(id), !state.loading else { return }
        state.value = value
    }
}

struct TicketEditor: View {
    @Binding var text: String
    #if os(tvOS)
    @FocusState private var focused: Bool
    private let inset = EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 16)
    #else
    @State private var focused = false
    @State private var scroll = ProductScrollMetrics()
    // multiline_content_field.dart 的 contentPadding (12, 8, 16, 8)：左右各加 gapPadding 4，上下各扣 visualDensity(-2) 的 4
    private let inset = EdgeInsets(top: 4, leading: ProductMetrics.labelInset, bottom: 4, trailing: 20)
    #endif
    @Environment(\.colorScheme) private var scheme
    @ViewBuilder private var editor: some View {
        #if os(tvOS)
        ProductTextEditor(text: $text).font(.system(size: 13)).focused($focused)
            .padding(.leading, inset.leading).padding(.trailing, inset.trailing)
        #else
        ProductTextView(text: $text, focused: $focused, leading: inset.leading, trailing: inset.trailing, metrics: scroll)
        #endif
    }
    var body: some View {
        let colors = ProductPalette(scheme: scheme)
        // 对应 multiline_content_field.dart 的 minLines 4 / maxLines 8：由隐藏的同字号、同行高文本撑出高度，随内容在 4～8 行之间增长
        Text(verbatim: text + " ").font(.system(size: 13)).lineSpacing(ProductMetrics.editorLineSpacing).hidden()
            .padding(.vertical, ProductMetrics.editorLineSpacing / 2)
            .frame(maxWidth: .infinity, minHeight: 13 * 1.5 * 4, maxHeight: 13 * 1.5 * 8, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, inset.leading).padding(.trailing, inset.trailing)
            .overlay { editor }
            .padding(.vertical, inset.top)
            .background(colors.surface, in: RoundedRectangle(cornerRadius: 16))
            #if os(tvOS)
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(focused ? colors.accent : colors.segment, lineWidth: 1))
            .overlay(alignment: .topLeading) {
                Text(L10n.t("内容")).font(.system(size: 11)).foregroundStyle(focused ? colors.accent : colors.secondary)
                    .padding(.horizontal, 4).background(colors.surface).offset(x: 10, y: -7).allowsHitTesting(false)
            }
            #else
            .overlay { ProductScrollbar(metrics: scroll, cornerRadius: 16) }
            .productFieldOutline(RoundedRectangle(cornerRadius: 16), color: focused ? colors.accent : colors.segment,
                                 label: L10n.t("内容"), floating: focused || !text.isEmpty, focused: focused,
                                 restingTop: inset.top + ProductMetrics.editorLineSpacing / 2)
            #endif
    }
}
