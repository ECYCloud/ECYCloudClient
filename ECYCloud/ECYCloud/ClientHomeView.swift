import SwiftUI
import ECYCloudKit

struct ClientHomeView: View {
    let session: ClientSession
    @Environment(\.colorScheme) private var scheme
    @Environment(\.productVerticalBarTop) private var verticalBarTop
    @State private var selection: Page = .home
    @State private var shopCategory: ShopProduct.Kind = .plan
    @State private var popup: Announcement?
    @Environment(AccountMenu.self) private var menu
    @State private var showTraffic = false
    @State private var showAnnouncements = false
    @State private var moreOpen = false
    @State private var nodeSnapshot: TunnelSnapshot?
    @State private var nodeActionError: String?
    @State private var refreshAction: ProductRefreshAction?
    @State private var toast: String?
    @State private var hovered: Page?
    @State private var restrictedTickets = false
    @State private var confirmCancelDeletion = false
    @State private var cancellingDeletion = false
    @State private var kickNotice = false
    @State private var slotDevices: [OnlineDevice]?
    @State private var slotSelection = ""
    private enum Page: String, CaseIterable {
        case home = "首页", nodes = "节点", shop = "商店", tickets = "工单", invite = "邀请", unlock = "解锁", connections = "连接", logs = "日志", settings = "设置"
        // 对应 app/lib/ui/shell.dart 的 _destinations（icon / selectedIcon）与 nav_glyph.dart 的解锁字形
        func icon(filled: Bool) -> String {
            switch self {
            case .home: filled ? "home" : "home_outlined"
            case .nodes: filled ? "dns" : "dns_outlined"
            case .shop: filled ? "shopping_bag" : "shopping_bag_outlined"
            case .tickets: filled ? "confirmation_number" : "confirmation_number_outlined"
            case .invite: filled ? "group_add" : "group_add_outlined"
            case .unlock: filled ? "lock_open_right_filled" : "lock_open_right"
            case .connections: filled ? "swap_horizontal_circle" : "swap_horiz_outlined"
            case .logs: filled ? "article" : "article_outlined"
            case .settings: filled ? "settings" : "settings_outlined"
            }
        }
    }
    private var colors: ProductPalette { ProductPalette(scheme: scheme) }
    private var restricted: Bool { session.phase == .restricted }
    private let pages = Page.allCases

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 640
            let insets = geometry.safeAreaInsets
            // iPhone Duo 等设备的系统状态放在竖向栏里，导航随之放进竖向栏、排在状态区下方
            let bar: HorizontalEdge? = restricted || verticalBarTop == nil ? nil
                : insets.trailing > insets.leading ? .trailing : insets.leading > insets.trailing ? .leading : nil
            HStack(spacing: 0) {
                if bar == .leading { verticalBarNavigation(.leading, width: insets.leading) }
                if wide && !restricted && bar == nil { sidebar }
                VStack(spacing: 0) {
                    header
                    Group {
                        if restricted { restrictedAccount }
                        else {
                            // 对应 shell.dart 的 IndexedStack：各页常驻，切回时沿用已加载的数据与滚动位置
                            ZStack {
                                ForEach(pages, id: \.self) { page in
                                    let active = selection == page
                                    // tvOS 隐藏页切走后其中的控件仍能获得焦点，只保留当前页
                                    #if os(tvOS)
                                    if active { pageView(page, wide: wide) }
                                    #else
                                    pageView(page, wide: wide)
                                        .opacity(active ? 1 : 0).allowsHitTesting(active).disabled(!active).accessibilityHidden(!active)
                                        .transformPreference(ProductRefreshKey.self) { if !active { $0 = nil } }
                                    #endif
                                }
                            }.productFocusSection()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .bottomTrailing) {
                        if !wide && moreOpen && !restricted { moreNavigation.padding(.trailing, 16).padding(.bottom, 8) }
                    }
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        if !wide && !restricted && bar == nil { bottomNavigation.padding(.bottom, insets.bottom > 0 ? 0 : 8) }
                    }
                }
                if bar == .trailing { verticalBarNavigation(.trailing, width: insets.trailing) }
            }
            .ignoresSafeArea(.container, edges: bar == .leading ? .leading : bar == .trailing ? .trailing : [])
        }
        .font(.system(size: 13)).foregroundStyle(colors.text)
        .background(colors.background)
        .productMenuHost()
        .productToast($toast)
        .onPreferenceChange(ProductRefreshKey.self) { refreshAction = $0 }
        .onChange(of: selection) { _, page in
            moreOpen = false
            if page == .tickets { session.markTicketsSeen() }
        }
        .onChange(of: session.phase) { _, phase in
            if phase == .restricted { showTraffic = false; menu.rootRequest += 1 }
        }
        .task(id: session.phase == .signedIn ? session.profile?.id : nil) {
            guard session.phase == .signedIn else { popup = nil; return }
            // 对应 home_page.dart：公告与账号同为 60 秒轮询，每次拉取后都检查待弹出的公告
            while true {
                if (try? await session.announcements(silently: true)) != nil, !Task.isCancelled, popup == nil {
                    popup = session.announcementState.takePopup()
                }
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            }
        }
        .task(id: "\(session.profile?.deviceKickNotice == true)|\(session.profile?.deviceKickReason ?? "")") {
            guard session.phase == .signedIn, session.profile?.deviceKickNotice == true else { return }
            if session.profile?.deviceKickReason == "limit_denied" { await loadSlotDevices() } else { kickNotice = true }
        }
        .productDialog(item: $popup) { item in AnnouncementPopup(session: session, item: item) { popup = nil } }
        .onChange(of: menu.shopTrafficRequest) {
            showTraffic = false; restrictedTickets = false; menu.rootRequest += 1
            shopCategory = .trafficPackage; selection = .shop
        }
        .navigationDestination(isPresented: $showTraffic) { TrafficPage(session: session) }
        .navigationDestination(isPresented: $restrictedTickets) { FeatureSheet(title: L10n.t("工单")) { TicketsView(session: session) } }
        .productDialog(isPresented: $showAnnouncements) { AnnouncementsView(session: session) { showAnnouncements = false } }
        .alert(L10n.t("退出登录"), isPresented: Bindable(menu).confirmLogout) {
            Button(L10n.t("退出")) { Task { await session.logout() } }
            Button(L10n.t("取消"), role: .cancel) {}
        } message: {
            Text(L10n.t("退出后将断开连接并清除本机保存的登录凭据。"))
        }
        .alert(L10n.t("设备已下线"), isPresented: $kickNotice) {
            Button(L10n.t("知道了")) { Task { try? await session.acknowledgeDeviceKick() } }
        } message: {
            Text(session.profile?.deviceKickReason == "remove" ? L10n.t("该设备已被下线。") : L10n.t("由于超出在线客户端数量限制，有新客户端请求连接，已将您的设备踢下线。"))
        }
        .productDialog(isPresented: Binding(get: { slotDevices != nil }, set: { if !$0 { cancelSlot() } })) { deviceSlotDialog }
    }

    @ViewBuilder private func pageView(_ page: Page, wide: Bool) -> some View {
        switch page {
        case .home: DashboardView(session: session, wide: wide, openNodes: { selection = .nodes }, openTraffic: { showTraffic = true }, openShop: { selection = .shop }, requestDeviceSlot: { Task { await loadSlotDevices() } })
        case .nodes: nodeList(wide: wide)
        case .shop: ShopView(session: session, category: $shopCategory)
        case .tickets: TicketsView(session: session)
        case .invite: InviteView(session: session)
        case .unlock: AccountHistoryView(session: session, kind: .unlock, embedded: true)
        case .connections: RuntimeConnectionsView(session: session)
        case .logs: RuntimeLogsView(session: session)
        case .settings: ClientSettingsView(session: session)
        }
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Image("ProductLogo").resizable().scaledToFit().frame(width: 24, height: 24)
                        .accessibilityHidden(true)
                    Text("ECY Cloud").font(.system(size: 22, weight: .semibold)).tracking(-0.66).lineLimit(1)
                }
                .padding(.horizontal, 12).frame(height: 48).padding(.bottom, 8)
                ForEach(pages, id: \.self) { page in
                    let filled = selection == page || hovered == page
                    Button { selection = page } label: {
                        HStack(spacing: 10) {
                            ProductGlyph(name: page.icon(filled: filled), size: 16)
                            Text(verbatim: L10n.t(page.rawValue)).font(.system(size: 15)).lineLimit(1)
                            if page == .tickets && session.hasUnreadTicketReply { unreadDot.padding(.leading, -4) }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(filled ? colors.segment : Color.clear, in: RoundedRectangle(cornerRadius: 16))
                        .contentShape(Rectangle())
                        .productHover { hovered = $0 ? page : (hovered == page ? nil : hovered) }
                        .productFocusRing(RoundedRectangle(cornerRadius: 16))
                    }
                    .buttonStyle(.productPlain).padding(.leading, 8).padding(.trailing, 24)
                    .accessibilityAddTraits(selection == page ? [.isSelected] : [])
                }
            }
        }
        .frame(width: 192).frame(maxHeight: .infinity)
        .background(colors.surface)
        .productFocusSection()
    }

    private var unreadDot: some View {
        Circle().fill(Color(red: 0xE5 / 255, green: 0x39 / 255, blue: 0x35 / 255)).frame(width: 8, height: 8)
    }

    private var bottomNavigation: some View {
        HStack(spacing: 0) {
            ForEach(Array(pages.prefix(5)), id: \.self) { page in
                Button { selection = page } label: {
                    navigationItem(page).frame(maxWidth: .infinity, minHeight: 80).contentShape(Rectangle())
                }
                .buttonStyle(.productPlain).accessibilityAddTraits(selection == page ? [.isSelected] : [])
            }
            let overflow = pages.dropFirst(5).contains(selection)
            Button { moreOpen.toggle() } label: {
                VStack(spacing: 5) {
                    ProductGlyph(name: "more_horiz", size: 24).frame(width: 64, height: 32)
                        .background(overflow ? colors.segment : Color.clear, in: Capsule())
                        .foregroundStyle(overflow ? colors.text : colors.secondary)
                    Text(L10n.t("更多")).font(.system(size: 12, weight: overflow ? .semibold : .medium))
                        .foregroundStyle(overflow ? colors.text : colors.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 80).contentShape(Rectangle())
            }.buttonStyle(.productPlain).accessibilityAddTraits(overflow ? [.isSelected] : [])
        }
        .productGlass(colors.surface, in: Capsule())
        .padding(.horizontal, 16)
    }

    private func navigationItem(_ page: Page) -> some View {
        let selected = selection == page
        return VStack(spacing: 5) {
            ProductGlyph(name: page.icon(filled: selected), size: 24)
                .overlay(alignment: .topTrailing) {
                    if page == .tickets && session.hasUnreadTicketReply { unreadDot.offset(x: 4, y: -2) }
                }
                .frame(width: 64, height: 32)
                .background(selected ? colors.segment : Color.clear, in: Capsule())
                .foregroundStyle(selected ? colors.text : colors.secondary)
            Text(verbatim: L10n.t(page.rawValue)).font(.system(size: 12, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? colors.text : colors.secondary)
        }
    }

    private func verticalBarNavigation(_ edge: HorizontalEdge, width: CGFloat) -> some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(pages, id: \.self) { page in
                    Button { selection = page } label: {
                        navigationItem(page).frame(maxWidth: .infinity, minHeight: 52).contentShape(Rectangle())
                    }
                    .buttonStyle(.productPlain).accessibilityAddTraits(selection == page ? [.isSelected] : [])
                }
            }
            .padding(.top, verticalBarTop ?? 0)
        }
        .scrollBounceBehavior(.basedOnSize)
        .productVerticalBarMargin(edge, width: width)
        .frame(width: width)
        // 右侧页头与页面背景会延伸进竖向栏所在的安全区，前导侧的导航列须叠在其上
        .zIndex(1)
    }

    private var moreNavigation: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(pages.dropFirst(5)), id: \.self) { page in
                let selected = selection == page
                Button { selection = page; moreOpen = false } label: {
                    HStack(spacing: 16) {
                        ProductGlyph(name: page.icon(filled: selected), size: 24)
                        Text(verbatim: L10n.t(page.rawValue)).font(.system(size: 15))
                        Spacer(minLength: 0)
                    }.padding(.horizontal, 16).frame(minHeight: 48).contentShape(Rectangle())
                        .foregroundStyle(selected ? colors.accent : colors.text)
                        .background(selected ? colors.segment : Color.clear)
                }.buttonStyle(.productPlain)
            }
        }.fixedSize().clipShape(RoundedRectangle(cornerRadius: 20))
            .productGlass(colors.surface, in: RoundedRectangle(cornerRadius: 20))
    }

    private var header: some View {
        HStack(spacing: 0) {
            Text(verbatim: restricted ? L10n.t("账户状态") : selection == .unlock ? L10n.t("解锁检测") : L10n.t(selection.rawValue))
                .font(.system(size: 22, weight: .semibold)).tracking(-0.66).lineLimit(1)
            Spacer(minLength: 0)
            if !restricted && selection == .home {
                Button { showAnnouncements = true } label: {
                    ProductGlyph(name: "notifications_outlined", size: 20).frame(width: 32, height: 32)
                        .overlay(alignment: .topTrailing) { if session.announcementState.hasUnread { unreadDot } }
                        .frame(width: ProductMetrics.tapTarget, height: ProductMetrics.tapTarget).contentShape(Rectangle()).productIconHover()
                }.buttonStyle(.productPlain).help(L10n.t("公告")).accessibilityLabel(L10n.t("公告"))
            }
            if !restricted && selection == .nodes {
                refreshButton(L10n.t("刷新节点"), spinning: session.nodesLoading) { await session.loadNodes() }
            } else if !restricted, let refreshAction {
                refreshButton(L10n.t("刷新"), spinning: refreshAction.disabled) { await refreshAction.run() }
            }
            AccountAvatarButton().padding(.leading, 14)
        }
        .padding(.leading, 14).padding(.trailing, 16).frame(height: 48)
        .background(scheme == .dark ? Color(red: 22 / 255, green: 22 / 255, blue: 23 / 255).opacity(0.72) : Color.white.opacity(0.72))
        .productFocusSection()
    }

    // 对应 widgets/refresh_button.dart：刷新时旋转、不置灰，重复点击忽略
    private func refreshButton(_ tooltip: String, spinning: Bool, run: @escaping @MainActor () async -> Void) -> some View {
        Button { if !spinning { Task { await run() } } } label: {
            ProductRefreshGlyph(spinning: spinning).frame(width: ProductMetrics.tapTarget, height: ProductMetrics.tapTarget).contentShape(Rectangle()).productIconHover()
        }.buttonStyle(.productPlain).help(tooltip).accessibilityLabel(tooltip)
    }

    private func nodeList(wide: Bool) -> some View {
        ScrollViewReader { scroll in
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                if let message = session.message { ProductNotice(message: message) }
                if let error = session.nodesError {
                    ProductNotice(message: error)
                    if session.catalog != nil {
                        Text(L10n.t("以下为上次获取的节点。")).foregroundStyle(colors.secondary)
                    }
                    Button(L10n.t("重新获取节点")) { Task { await session.loadNodes() } }
                        .buttonStyle(ProductButtonStyle()).disabled(session.nodesLoading)
                }
                if session.nodesLoading { ProgressView(L10n.t("正在获取节点…")).padding(12) }
                if let error = nodeActionError { ProductNotice(message: error) }
                if let catalog = session.catalog {
                    let groups = catalog.groups(for: session.preferences.mode, runtime: nodeSnapshot?.groups ?? [])
                    if groups.isEmpty {
                        VStack(spacing: 10) {
                            ProductGlyph(name: session.preferences.mode == .direct ? "public" : "inbox_outlined", size: 34).foregroundStyle(colors.outline)
                            Text(verbatim: session.preferences.mode == .direct ? L10n.t("直连") : L10n.t("面板未下发节点分组"))
                                .font(.system(size: 15)).foregroundStyle(colors.secondary)
                        }.frame(maxWidth: .infinity, minHeight: 320)
                    }
                    ForEach(groups) { group in
                        NodeGroupCard(session: session, group: group, catalog: catalog, selections: nodeSnapshot?.selections ?? [:],
                                      live: session.connection?.controlPlaneReady == true, wide: wide,
                                      initiallyExpanded: session.preferences.mode == .global,
                                      locate: { node in withAnimation { scroll.scrollTo([group.id, node], anchor: .center) } }) { node in
                            do {
                                try await session.selectActiveNode(group: group.id, node: node)
                                nodeSnapshot = try await session.tunnelSnapshot()
                                nodeActionError = nil
                            } catch is CancellationError { }
                            catch { nodeActionError = (error as? TunnelError)?.localizedDescription ?? (error as? ClientError)?.localizedDescription ?? L10n.t("节点切换失败，请重试。") }
                        }
                    }
                } else if !session.nodesLoading && session.nodesError == nil {
                    ProductNotice(message: L10n.t("尚未获取节点"))
                }
            }
            .padding(.leading, 14).padding(.trailing, 16).padding(.top, 20).padding(.bottom, 14)
        }
        .task(id: session.connection?.controlPlaneReady) {
            guard session.connection?.controlPlaneReady == true else { nodeSnapshot = nil; return }
            while !Task.isCancelled && session.connection?.controlPlaneReady == true {
                do { nodeSnapshot = try await session.tunnelSnapshot(); nodeActionError = nil }
                catch is CancellationError { break }
                catch { nodeActionError = (error as? TunnelError)?.localizedDescription ?? L10n.t("无法读取当前节点。") }
                do { try await Task.sleep(for: .seconds(5)) } catch { break }
            }
        }
        .refreshable { await session.loadNodes() }
        }
    }

    private var restrictedAccount: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let status = session.accountStatus, status.enable == -1 {
                    ProductCard(title: L10n.t("您的账户已提交删除请求"), icon: "delete_outline") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(L10n.t("提交删除时间：{0}", [status.submitAccountDeletionTime ?? L10n.t("未知")]))
                            Text(L10n.t("预计删除时间：{0}", [status.deletionTime ?? L10n.t("未知")]))
                            Text(L10n.t("状态说明：您的账户将在30天后被彻底删除。在此期间，您可以取消删除请求以恢复账户。"))
                                .font(.system(size: 14)).foregroundStyle(colors.secondary)
                            Button { confirmCancelDeletion = true } label: {
                                HStack(spacing: 8) { ProductGlyph(name: "history", size: 18); Text(L10n.t("取消删除")) }
                            }.buttonStyle(ProductButtonStyle(filled: true)).disabled(cancellingDeletion).padding(.top, 6)
                        }
                    }
                } else if let status = session.accountStatus, status.enable == 0 {
                    ProductCard(title: L10n.t("你的账户已被封禁"), icon: "block") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(L10n.t("封禁原因：{0}", [status.banReason ?? L10n.t("特殊原因被封禁")]))
                            if status.banPermanent == true || (status.banTimeText ?? "").isEmpty {
                                Text(L10n.t("封禁期限：永久封禁"))
                            } else {
                                Text(L10n.t("封禁时长：{0}", [status.banTimeText ?? ""]))
                                Text(L10n.t("封禁开始时间：{0}", [status.banStartTime ?? L10n.t("未知")]))
                                Text(L10n.t("封禁结束时间：{0}", [status.banEndTime ?? L10n.t("未知")]))
                            }
                            if status.ticketEnabled == true {
                                ProductFlow(spacing: 0) {
                                    Text(L10n.t("如果我们错误地禁用了您的账户，请 ")).font(.system(size: 14)).foregroundStyle(colors.secondary)
                                    Button(L10n.t("发送工单") + " ›") { restrictedTickets = true }.buttonStyle(ProductButtonStyle())
                                    Text(L10n.t(" 与我们联系。")).font(.system(size: 14)).foregroundStyle(colors.secondary)
                                }.padding(.top, 6)
                            } else if !status.supportEmail.isEmpty, let mail = URL(string: "mailto:" + status.supportEmail) {
                                ProductFlow(spacing: 0) {
                                    Text(L10n.t("如果我们错误地禁用了您的账户，请通过邮箱：")).font(.system(size: 14)).foregroundStyle(colors.secondary)
                                    Link(destination: mail) { Text(verbatim: status.supportEmail) }.buttonStyle(ProductButtonStyle())
                                    Text(L10n.t(" 与我们联系。")).font(.system(size: 14)).foregroundStyle(colors.secondary)
                                }.padding(.top, 6)
                            }
                        }
                    }
                } else {
                    ProductCard(title: L10n.t("账户状态"), icon: "info_outline") {
                        Text(session.accountStatus == nil ? L10n.t("无法获取账户状态") : L10n.t("当前账户状态正常。"))
                    }
                }
                Button { Task { await session.logout() } } label: {
                    HStack(spacing: 16) { ProductGlyph(name: "logout", size: 24); Text(L10n.t("退出登录")); Spacer(minLength: 0) }
                        .foregroundStyle(colors.danger).padding(.horizontal, 16).frame(minHeight: 48)
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(colors.segment, lineWidth: 1)).contentShape(Rectangle())
                }.buttonStyle(.productPlain).disabled(cancellingDeletion)
            }.padding(.leading, 14).padding(.trailing, 16).padding(.bottom, 14).productTextSelection()
        }
        .alert(L10n.t("确认取消删除请求吗？"), isPresented: $confirmCancelDeletion) {
            Button(L10n.t("确定")) {
                Task {
                    cancellingDeletion = true; defer { cancellingDeletion = false }
                    do { toast = try await session.cancelAccountDeletion() }
                    catch { toast = (error as? ClientError)?.localizedDescription ?? L10n.t("操作未完成") }
                }
            }
            Button(L10n.t("取消"), role: .cancel) {}
        } message: { Text(L10n.t("取消后，您的账户将恢复正常状态。")) }
    }

    private var deviceSlotDialog: some View {
        ProductDialog(title: L10n.t("在线客户端数量已达上限")) {
            if let devices = slotDevices, !devices.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.t("在线客户端数量已达上限，请选择一个要下线的客户端："))
                    ForEach(devices) { device in
                        Button { slotSelection = device.deviceId } label: {
                            HStack(spacing: 12) {
                                Circle().strokeBorder(slotSelection == device.deviceId ? colors.accent : colors.secondary, lineWidth: 2)
                                    .overlay { if slotSelection == device.deviceId { Circle().fill(colors.accent).padding(5) } }
                                    .frame(width: 20, height: 20)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: device.device.isEmpty ? device.deviceId : device.device)
                                    Text(verbatim: device.location.isEmpty ? device.ip : device.ip + " · " + device.location)
                                        .font(.system(size: 13)).foregroundStyle(colors.secondary)
                                }
                                Spacer(minLength: 0)
                            }.frame(minHeight: 48).contentShape(Rectangle())
                        }.buttonStyle(.productPlain)
                    }
                }
            } else {
                Text(L10n.t("在线客户端数量已达上限，是否下线其中一个客户端，以挪出位置？"))
            }
        } actions: {
            Button(L10n.t("确定")) {
                let target = slotSelection
                slotDevices = nil
                Task {
                    do { try await session.reclaimDeviceSlot(target) }
                    catch is CancellationError {}
                    catch { toast = (error as? ClientError)?.localizedDescription ?? L10n.t("操作失败，请重试。") }
                }
            }.buttonStyle(ProductButtonStyle(filled: true))
            Button(L10n.t("取消")) { cancelSlot() }.buttonStyle(ProductButtonStyle())
        }
    }

    private func cancelSlot() {
        slotDevices = nil
        if session.profile?.deviceKickNotice == true { Task { try? await session.acknowledgeDeviceKick() } }
    }

    private func loadSlotDevices() async {
        guard slotDevices == nil else { return }
        let devices = (try? await session.onlineDevices()) ?? []
        slotSelection = devices.first?.deviceId ?? ""
        slotDevices = devices
    }
}

struct AccountInfoPage: View {
    let session: ClientSession
    @Environment(\.colorScheme) private var scheme
    @State private var editAccount = false
    @State private var page: AccountPage?
    @State private var history: AccountHistoryKind?
    @State private var renewal: Bool?
    @State private var toast: String?
    @State private var allowDelete = false
    private var colors: ProductPalette { ProductPalette(scheme: scheme) }

    var body: some View {
        FeatureSheet(title: L10n.t("账户信息"), onAccount: true) { account(session.profile) }.toolbar(.hidden)
            .productToast($toast)
            .navigationDestination(item: $page) { page in accountDestination(page) }
            .navigationDestination(isPresented: $editAccount) { AccountEditView(session: session) }
            .navigationDestination(item: $history) { kind in AccountHistoryView(session: session, kind: kind) }
    }

    private enum AccountPage: String, CaseIterable, Identifiable { case traffic = "流量记录", recharge = "余额充值", strategy = "自定义策略", deletion = "删除账号"; var id: Self { self } }

    @ViewBuilder private func accountDestination(_ page: AccountPage) -> some View {
        switch page {
        case .traffic: TrafficPage(session: session)
        case .recharge: FeatureSheet(title: L10n.t(page.rawValue)) { RechargeView(session: session) }
        case .strategy: SubscriptionStrategyView(session: session)
        case .deletion: DeleteAccountView(session: session)
        }
    }

    private func account(_ profile: UserProfile?) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let profile { userCard(profile) }
                else { ProductCard(title: L10n.t("账号"), icon: "person_outline") { Text(verbatim: "—") } }
                ProductSection(title: L10n.t("更多"), icon: "menu") {
                    accountLink(L10n.t("修改信息"), icon: "edit_outlined") { editAccount = true }
                    divider
                    accountLink(L10n.t("自定义策略"), icon: "tune") { page = .strategy }
                    divider
                    accountLink(L10n.t("流量记录"), icon: "data_usage") { page = .traffic }
                    divider
                    accountLink(L10n.t("在线客户端"), icon: "lan_outlined") { history = .devices }
                    divider
                    accountLink(L10n.t("登录记录"), icon: "history") { history = .loginLogs }
                    divider
                    accountLink(L10n.t("操作记录"), icon: "manage_history") { history = .operationLogs }
                    divider
                    accountLink(L10n.t("余额充值"), icon: "currency_yen") { page = .recharge }
                    divider
                    accountLink(L10n.t("余额记录"), icon: "receipt_long_outlined") { history = .balance }
                    divider
                    accountLink(L10n.t("购买记录"), icon: "shopping_bag_outlined") { history = .purchases }
                }
            }
            .padding(.leading, 14).padding(.trailing, 16).padding(.bottom, 14)
            .productTextSelection()
        }
        .task(id: profile?.id) { allowDelete = (try? await session.accountOptions())?.enableKill == true }
        .preference(key: ProductRefreshKey.self, value: ProductRefreshAction(id: "account", disabled: session.busy, run: { await session.refresh() }))
        .alert(renewal == true ? L10n.t("确认开启自动续费？") : L10n.t("确认关闭自动续费？"), isPresented: Binding(get: { renewal != nil }, set: { if !$0 { renewal = nil } }), presenting: renewal) { enable in
            Button(L10n.t("确定")) {
                guard let id = profile?.plan?.id else { return }
                Task {
                    do {
                        let result = try await session.toggleRenewal(id: id, enabled: enable)
                        await session.refresh()
                        toast = result.isEmpty ? (enable ? L10n.t("自动续费开启成功") : L10n.t("自动续费关闭成功")) : result
                    } catch { toast = (error as? ClientError)?.localizedDescription ?? L10n.t("操作未完成") }
                }
            }
            Button(L10n.t("取消"), role: .cancel) {}
        } message: { enable in
            Text(enable ? L10n.t("开启后将在套餐到期时自动续费。") : L10n.t("关闭后，您可以随时重新开启自动续费。"))
        }
    }

    private func userCard(_ profile: UserProfile) -> some View {
        ProductCard(title: L10n.t("账号"), icon: "person_outline") {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    ProductAvatar(session: session, size: 36)
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 6) {
                            Text(verbatim: profile.displayName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                            ProductTag(text: "ID \(profile.id)")
                        }
                        Text(verbatim: profile.email).font(.system(size: 12)).foregroundStyle(colors.secondary)
                    }
                    Spacer(minLength: 0)
                }
                divider.padding(.vertical, 8)
                metric(L10n.t("余额"), "¥ " + String(format: "%.2f", profile.money))
                metric(L10n.t("注册时间"), profile.regDate.flatMap { $0.isEmpty ? nil : $0 } ?? "—")
                metric(L10n.t("套餐"), profile.plan?.name ?? (profile.class > 0 ? "VIP \(profile.class)" : L10n.t("免费用户")))
                if let plan = profile.plan {
                    metric(L10n.t("到期"), plan.expTime)
                    metric(L10n.t("剩余天数"), L10n.t("{0} 天", [String(plan.remainingDays)]))
                    metric(L10n.t("自动续费"), plan.autoRenew == true ? plan.renewAt ?? "—" : "-")
                }
                metric(L10n.t("限速"), profile.nodeSpeedlimit <= 0 ? L10n.t("不限速") : String(format: "%.0f Mbps", profile.nodeSpeedlimit))
                metric(L10n.t("在线客户端"), profile.nodeConnector <= 0 ? L10n.t("{0} / 无限制", [String(profile.onlineClientCount)])
                    : "\(profile.onlineClientCount) / \(profile.nodeConnector)")
                if let plan = profile.plan, plan.canToggleAutoRenew == true, plan.id != nil {
                    Toggle(isOn: Binding(get: { plan.autoRenew == true }, set: { renewal = $0 })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.t("自动续费"))
                            Text(plan.autoRenew == true ? plan.renewAt ?? "—" : L10n.t("已关闭")).font(.system(size: 13)).foregroundStyle(colors.secondary)
                        }
                    }.toggleStyle(ProductToggleStyle()).padding(.top, 4)
                }
            }
        }.headerAction {
            if allowDelete {
                Button { page = .deletion } label: {
                    HStack(spacing: 8) { ProductGlyph(name: "block", size: 16); Text(L10n.t("删除账号")) }
                }.buttonStyle(ProductButtonStyle(color: colors.danger))
            }
        }
    }

    private var divider: some View { Divider().overlay(colors.outline.opacity(0.5)) }

    private func accountLink(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ProductGlyph(name: icon, size: 20).foregroundStyle(colors.secondary)
                Text(verbatim: title)
                Spacer(minLength: 0)
                ProductGlyph(name: "chevron_right", size: 24).foregroundStyle(colors.secondary)
            }.padding(.leading, 16).padding(.trailing, 24).frame(minHeight: 48).contentShape(Rectangle()).productHoverLayer(Rectangle())
        }.buttonStyle(.productPlain)
    }

    private func metric(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(verbatim: title).foregroundStyle(colors.secondary)
            Text(verbatim: value).lineLimit(1).frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.vertical, 2.5)
    }
}

struct TrafficPage: View {
    let session: ClientSession
    @Environment(AccountMenu.self) private var menu
    var body: some View {
        FeatureSheet(title: L10n.t("流量记录")) { TrafficHistoryView(session: session, openShop: { menu.shopTrafficRequest += 1 }) }
    }
}

// 对应 app/lib/ui/widgets/user_avatar.dart：面板 SVG 字母头像取 fill 色，远程头像走受限下载与账户缓存
private struct ProductAvatar: View {
    let session: ClientSession
    let size: CGFloat
    @Environment(\.colorScheme) private var scheme
    private var letter: String { session.profile.map { String($0.displayName.prefix(1)).uppercased() } ?? "?" }
    var body: some View {
        let avatar = session.profile?.avatar ?? ""
        if avatar.hasPrefix("data:image/svg+xml;base64,"), let fill = Self.fill(avatar) {
            letterView(background: fill, weight: .semibold)
        } else if !avatar.isEmpty, !avatar.hasPrefix("data:") {
            ProductGroupIcon(session: session, url: avatar, size: size, placeholder: AnyView(letterView(background: nil, weight: .medium)), inset: false)
                .clipShape(Circle())
        } else {
            letterView(background: nil, weight: .medium)
        }
    }
    private func letterView(background: Color?, weight: Font.Weight) -> some View {
        Text(verbatim: letter).font(.system(size: size * 0.45, weight: weight)).foregroundStyle(.white)
            .frame(width: size, height: size).background(background ?? ProductPalette(scheme: scheme).accent, in: Circle())
    }
    private static func fill(_ uri: String) -> Color? {
        guard let data = Data(base64Encoded: String(uri.split(separator: ",", maxSplits: 1).last ?? "")), data.count <= 65536,
              let svg = String(data: data, encoding: .utf8) else { return nil }
        if let match = svg.firstMatch(of: /fill=["']hsl\((\d+(?:\.\d+)?),\s*([\d.]+)%,\s*([\d.]+)%\)["']/),
           let hue = Double(match.1), let saturation = Double(match.2), let lightness = Double(match.3) {
            let l = lightness / 100, s = saturation / 100
            let chroma = (1 - abs(2 * l - 1)) * s, h = hue.truncatingRemainder(dividingBy: 360) / 60
            let x = chroma * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1)), m = l - chroma / 2
            let (r, g, b): (Double, Double, Double) = switch Int(h) {
                case 0: (chroma, x, 0); case 1: (x, chroma, 0); case 2: (0, chroma, x)
                case 3: (0, x, chroma); case 4: (x, 0, chroma); default: (chroma, 0, x)
            }
            return Color(.sRGB, red: r + m, green: g + m, blue: b + m, opacity: 1)
        }
        if let match = svg.firstMatch(of: /fill=["']#([0-9A-Fa-f]{6})["']/), let value = UInt32(match.1, radix: 16) {
            return Color(.sRGB, red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255, opacity: 1)
        }
        return nil
    }
}

// 主界面页头与各二级页共用；挂在 NavigationStack 上，推入的页面才能取到
// rootRequest 对应 Navigator.popUntil(route.isFirst)：栈内各 FeatureSheet 收到后自行关闭
@MainActor @Observable final class AccountMenu {
    let session: ClientSession
    var confirmLogout = false
    var rootRequest = 0
    var shopTrafficRequest = 0
    init(session: ClientSession) { self.session = session }
}

struct AccountAvatarButton: View {
    var onAccount = false
    @Environment(AccountMenu.self) private var menu
    @Environment(\.colorScheme) private var scheme
    @State private var open = false
    @State private var showAccount = false
    var body: some View {
        let colors = ProductPalette(scheme: scheme)
        Button { open.toggle() } label: {
            // 对应 user_avatar.dart 的圆形 InkWell，悬浮取主题 hoverColor
            ProductAvatar(session: menu.session, size: 36).frame(width: ProductMetrics.tapTarget, height: ProductMetrics.tapTarget).contentShape(Circle())
                .productHoverLayer(Circle())
        }
        .buttonStyle(.productPlain).help(L10n.t("账户信息")).accessibilityLabel(L10n.t("账户信息"))
        .productMenu(isPresented: $open, size: CGSize(width: 136, height: 64), trailing: true) {
            VStack(spacing: 0) {
                AccountMenuRow(title: L10n.t("账户信息"), icon: "badge_outlined", hoverIcon: "badge", color: colors.text) {
                    open = false; if !onAccount { showAccount = true }
                }
                AccountMenuRow(title: L10n.t("退出登录"), icon: "logout_outlined", hoverIcon: "logout", color: colors.danger) {
                    open = false; menu.confirmLogout = true
                }
            }.frame(width: 136)
        }
        // 对应 user_avatar.dart：压在当前页之上；已在账户信息页时不再重复打开
        .navigationDestination(isPresented: $showAccount) { AccountInfoPage(session: menu.session) }
    }
}

private struct AccountMenuRow: View {
    let title: String
    let icon: String
    let hoverIcon: String
    let color: Color
    let action: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                ProductGlyph(name: hovered ? hoverIcon : icon, size: 16)
                Text(verbatim: title).font(.system(size: 15)).lineLimit(1)
            }.foregroundStyle(color).padding(.horizontal, 12).frame(maxWidth: .infinity).frame(height: 32).contentShape(Rectangle())
                .productHoverLayer(Rectangle(), color: color, opacity: 0.08)
                .productHover { hovered = $0 }
        }.buttonStyle(.productPlain)
    }
}

private struct NodeGroupCard: View {
    let session: ClientSession
    let group: NodeSelectionGroup
    let catalog: NodeCatalog
    let selections: [String: String]
    let live: Bool
    let wide: Bool
    let locate: (String) -> Void
    let select: (String) async -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var expanded = false
    @State private var searchOpen = false
    @State private var search = ""
    @State private var working = false
    @State private var sort = 0
    @State private var notice: String?
    init(session: ClientSession, group: NodeSelectionGroup, catalog: NodeCatalog, selections: [String: String],
         live: Bool, wide: Bool, initiallyExpanded: Bool, locate: @escaping (String) -> Void,
         select: @escaping (String) async -> Void) {
        self.session = session; self.group = group; self.catalog = catalog; self.selections = selections
        self.live = live; self.wide = wide; self.locate = locate; self.select = select
        _expanded = State(initialValue: initiallyExpanded)
    }
    private var selected: String? { selections[group.id] }
    private func leaf(_ member: String) -> String {
        NodeProbeState.resolve(member, selections: selections)
    }
    private var sortedMembers: [String] {
        guard sort != 0 else { return group.members }
        let slots = group.members.indices.filter { group.members[$0].range(of: #"^node-[1-9][0-9]*$"#, options: .regularExpression) != nil }
        let nodes = slots.map { group.members[$0] }.sorted { left, right in
            let a = session.nodeProbes.result(leaf(left), kind: sort == 1 ? .delay : .speed)
            let b = session.nodeProbes.result(leaf(right), kind: sort == 1 ? .delay : .speed)
            let x = sort == 1 ? Int64(a?.delay ?? 0) : a?.speed ?? 0
            let y = sort == 1 ? Int64(b?.delay ?? 0) : b?.speed ?? 0
            if (x > 0) != (y > 0) { return x > 0 }
            if x != y { return sort == 1 ? x < y : x > y }
            return catalog.displayName(left).utf8.lexicographicallyPrecedes(catalog.displayName(right).utf8)
        }
        var result = group.members
        for (slot, node) in zip(slots, nodes) { result[slot] = node }
        return result
    }

    var body: some View {
        let colors = ProductPalette(scheme: scheme)
        let radius: CGFloat = wide ? 20 : 16
        Section {
            VStack(alignment: .leading, spacing: 0) {
                if expanded {
                    VStack(alignment: .leading, spacing: 10) {
                        if let notice { ProductNotice(message: notice).padding(.horizontal, 12) }
                        if searchOpen {
                            ProductSearchField(hint: L10n.t("搜索节点名称"), text: $search, autofocus: true).padding(.horizontal, 12)
                        }
                        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
                        let filtered = sortedMembers.filter { !searchOpen || query.isEmpty || catalog.displayName($0).localizedCaseInsensitiveContains(query) }
                        if !group.selectable {
                            HStack(spacing: 6) {
                                ProductGlyph(name: "auto_awesome_outlined", size: 13).foregroundStyle(colors.outline)
                                Text(verbatim: automaticHint).frame(maxWidth: .infinity, alignment: .leading)
                            }.font(.system(size: 12)).foregroundStyle(colors.secondary).padding(.horizontal, 12)
                        }
                        if searchOpen && !query.isEmpty && filtered.isEmpty {
                            Text(L10n.t("没有符合条件的节点")).font(.system(size: 12)).foregroundStyle(colors.secondary).padding(.horizontal, 12)
                        } else {
                            ProductGrid(minimumWidth: 260, maximumColumns: 6, horizontalSpacing: 8, verticalSpacing: 8, includeSpacingInThreshold: true) {
                                ForEach(filtered, id: \.self) { member in tile(member, colors: colors) }
                            }
                        }
                    }.padding(.top, 10).padding(.bottom, 12)
                        .background(colors.background, in: UnevenRoundedRectangle(bottomLeadingRadius: radius, bottomTrailingRadius: radius))
                } else if let notice {
                    ProductNotice(message: notice).padding(.top, 6)
                }
            }.padding(.bottom, 6)
        } header: {
                HStack(spacing: 10) {
                    Button { expanded.toggle() } label: {
                        HStack(spacing: 10) {
                            ProductGroupIcon(session: session, url: catalog.groupIcons[group.id], selectable: group.selectable)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text(verbatim: catalog.displayName(group.id)).fontWeight(.semibold).lineLimit(!wide && expanded ? nil : 1)
                                    ProductTag(text: (group.selectable ? L10n.t("手动") : L10n.t("自动")) + (wide ? "" : " · \(group.members.count)"))
                                }
                                if wide {
                                    Text(verbatim: L10n.t("{0} 个节点{1}", [String(group.members.count), currentLabel]))
                                        .font(.system(size: 12)).foregroundStyle(colors.secondary).lineLimit(1)
                                } else if !currentLabel.isEmpty {
                                    Text(verbatim: String(currentLabel.dropFirst(3)))
                                        .font(.system(size: 12)).foregroundStyle(colors.secondary).lineLimit(expanded ? nil : 1)
                                }
                            }
                            Spacer(minLength: 0)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.productPlain)
                    if wide {
                        HStack(spacing: 0) { groupActions.labelStyle(.iconOnly) }.buttonStyle(.productPlain)
                    } else {
                        Menu { groupActions.labelStyle(.titleAndIcon) } label: {
                            Group {
                                if session.nodeProbes.isTestingGroup(group.id, kind: .delay) || session.nodeProbes.isTestingGroup(group.id, kind: .speed) { ProgressView().controlSize(.small) }
                                else { ProductGlyph(name: "more_horiz", size: 18) }
                            }.frame(width: ProductMetrics.tapTarget, height: ProductMetrics.tapTarget).productIconHover()
                        }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help(L10n.t("更多")).accessibilityLabel(L10n.t("更多"))
                    }
                    Button { expanded.toggle() } label: {
                        ProductGlyph(name: "expand_more", size: 18).foregroundStyle(colors.secondary)
                            .rotationEffect(.degrees(expanded ? 180 : 0)).animation(.easeInOut(duration: 0.18), value: expanded)
                    }.buttonStyle(.productPlain).accessibilityLabel(expanded ? L10n.t("收起分组") : L10n.t("展开分组"))
                }.padding(.horizontal, 12).padding(.vertical, wide ? 0 : 10).frame(minHeight: 54)
                // 对应 nodes_page.dart 分组头的 InkWell：悬浮整行变为 surfaceContainerHighest
                .productHoverLayer(Rectangle(), \.segment).background(colors.surface)
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: radius, bottomLeadingRadius: expanded ? 0 : radius,
                                                bottomTrailingRadius: expanded ? 0 : radius, topTrailingRadius: radius))
                .padding(.top, 4).background(colors.background)
        }
    }
    private func tile(_ member: String, colors: ProductPalette) -> some View {
        let resolved = leaf(member)
        let via = resolved == member ? nil : resolved
        let nested = catalog.groups.first { $0.id == member }
        return HStack(spacing: 4) {
            Button { Task { working = true; await select(member); working = false } } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(verbatim: catalog.displayName(member)).lineLimit(1)
                        if let nested { ProductTag(text: nested.selectable ? L10n.t("手动") : L10n.t("自动")) }
                    }.overlay(alignment: .leading) {
                        if member == selected { ProductGlyph(name: "check_circle", size: 12).foregroundStyle(colors.accent).offset(x: -16) }
                    }
                    if let via {
                        Text(verbatim: catalog.displayName(via)).foregroundStyle(colors.secondary).lineLimit(1)
                    } else if let node = catalog.nodes.first(where: { $0.id == member }) {
                        ProductFlow(spacing: 4) {
                            ForEach([node.protocolName, node.network, node.tls, node.udp].filter { !$0.isEmpty }, id: \.self) { ProductTag(text: $0) }
                        }
                    }
                }.frame(maxWidth: .infinity, minHeight: 64, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.productPlain).disabled(!live || !group.selectable || working)
                .help(catalog.displayName(member) + (via.map { " → " + catalog.displayName($0) } ?? ""))
            VStack(alignment: .trailing, spacing: 0) {
                probeButton(member, kind: .delay)
                probeButton(member, kind: .speed)
            }
        }.padding(.leading, 20).padding(.trailing, 8).padding(.vertical, 4.5)
            .productHoverLayer(RoundedRectangle(cornerRadius: 9), enabled: live && group.selectable)
            .background(member == selected ? colors.accent.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
            .background(colors.surface, in: RoundedRectangle(cornerRadius: 9))
            .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(member == selected ? colors.accent : Color.clear, lineWidth: 1) }
            .id([group.id, member])
    }
    private var currentLabel: String {
        guard let selected, !selected.isEmpty else { return "" }
        let resolved = leaf(selected)
        return resolved == selected ? L10n.t(" · 当前 {0}", [catalog.displayName(selected)])
            : L10n.t(" · 当前 {0} → {1}", [catalog.displayName(selected), catalog.displayName(resolved)])
    }
    private var automaticHint: String {
        if group.type.lowercased() == "fallback" {
            return L10n.t("本组由内核按列表顺序选用第一个可用节点，点击节点不改变选中项；测延迟会刷新可用性并让内核立即重选")
        }
        let fastest = group.members.compactMap { member -> (String, Int)? in
            guard let result = session.nodeProbes.result(leaf(member), kind: .delay), !result.failed, result.delay > 0 else { return nil }
            return (member, result.delay)
        }.min { $0.1 < $1.1 }?.0
        if let fastest, fastest != selected {
            return L10n.t("本组由内核按延迟自动选择，当前最优为 {0}；点上方测延迟可让内核立即切过去", [String(describing: catalog.displayName(fastest))])
        }
        return L10n.t("本组由内核按延迟自动选择，点击节点不改变选中项；测延迟会让内核立即重选")
    }
    @ViewBuilder private var groupActions: some View {
        groupProbeAction(.delay, title: L10n.t("测试本组全部节点延迟"), icon: "bolt_outlined")
        groupProbeAction(.speed, title: L10n.t("测试本组全部节点网速"), icon: "speed")
        Button { sort = (sort + 1) % 3 } label: {
            Label { Text(verbatim: [L10n.t("按最低延迟排序"), L10n.t("按最高网速排序"), L10n.t("按名称排序")][sort]) } icon: { actionIcon(["sort_by_alpha", "timer_outlined", "trending_up"][sort]) }
                .frame(minWidth: ProductMetrics.tapTarget, minHeight: ProductMetrics.tapTarget).productIconHover() }
            .help([L10n.t("目前按名称正序排列，点击切换为最低延迟"), L10n.t("目前按最低延迟排列，点击切换为最高网速"), L10n.t("目前按最高网速排列，点击切换为名称正序")][sort])
        Button { searchOpen.toggle(); if searchOpen { expanded = true } } label: {
            Label { Text(L10n.t("搜索节点名称")) } icon: { actionIcon("search") }.frame(minWidth: ProductMetrics.tapTarget, minHeight: ProductMetrics.tapTarget)
                .background(searchOpen && wide ? ProductPalette(scheme: scheme).secondary.opacity(0.08) : Color.clear, in: Circle()).productIconHover()
        }.help(L10n.t("搜索节点名称"))
        Button {
            if let selected { expanded = true; Task { await Task.yield(); locate(selected) } }
        } label: { Label { Text(L10n.t("定位到当前节点")) } icon: { actionIcon("my_location_outlined") }.frame(minWidth: ProductMetrics.tapTarget, minHeight: ProductMetrics.tapTarget).productIconHover() }
            .disabled(selected == nil || selected?.isEmpty == true).help(L10n.t("定位到当前节点"))
    }
    private func groupProbeAction(_ kind: NodeProbe.Kind, title: String, icon: String) -> some View {
        let testing = session.nodeProbes.isTestingGroup(group.id, kind: kind)
        return Button { Task { await testGroup(kind) } } label: {
            Label { Text(verbatim: title) } icon: {
                if testing { ProgressView().controlSize(.small) }
                else { actionIcon(icon) }
            }.frame(minWidth: ProductMetrics.tapTarget, minHeight: ProductMetrics.tapTarget).productIconHover()
        }.disabled(testing).help(title)
    }
    private func actionIcon(_ name: String) -> some View {
        Image("product_" + name).resizable().scaledToFit().frame(width: 16, height: 16)
    }
    // 与 Flutter 一致：测试按钮不受内核就绪限制（会按需拉起待机内核）；延迟结果只体现在徽标上，
    // 测速仅提示未开始测量的原因，已测出的失败由徽标显示「失败」。
    private func probeButton(_ member: String, kind: NodeProbe.Kind) -> some View {
        let node = leaf(member)
        return ProductProbeBadge(session: session, node: node, kind: kind, height: 32) {
            Task {
                do { _ = try await session.measureNode(node, kind: kind); notice = nil }
                catch is CancellationError { }
                catch { notice = kind == .delay || session.nodeProbes.result(node, kind: kind)?.failed == true ? nil : message(error) }
            }
        }
    }
    private func testGroup(_ kind: NodeProbe.Kind) async {
        notice = nil
        do { let result = try await session.measureGroup(group, selections: selections, kind: kind); notice = kind == .delay ? nil : result }
        catch is CancellationError { }
        catch { notice = kind == .delay ? nil : message(error) }
    }
    private func message(_ error: Error) -> String {
        (error as? ClientError)?.localizedDescription ?? (error as? TunnelError)?.localizedDescription ?? L10n.t("节点测试未完成")
    }
}
