import SwiftUI
import ECYCloudKit

struct ClientHomeView: View {
    let session: ClientSession
    @Environment(\.colorScheme) private var scheme
    @Environment(\.productVerticalBarTop) private var verticalBarTop
    @State private var selection: Page = .home
    @State private var popup: Announcement?
    @Environment(AccountMenu.self) private var menu
    @State private var showTraffic = false
    @State private var showAnnouncements = false
    @State private var moreOpen = false
    // iPhone 系统底栏的「更多」标签：显示自己的列表页还是从列表进入的页面
    @State private var moreList = false
    @State private var nodeSnapshot: TunnelSnapshot?
    @State private var nodeActionError: String?
    @State private var nodeListWidth: CGFloat = 0
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
        case home = "首页", nodes = "节点", tickets = "工单", invite = "邀请", unlock = "解锁", connections = "连接", logs = "日志", settings = "设置"
        // 对应 app/lib/ui/shell.dart 的 _destinations（icon / selectedIcon）与 nav_glyph.dart 的解锁字形
        func icon(filled: Bool) -> String {
            switch self {
            case .home: filled ? "home" : "home_outlined"
            case .nodes: filled ? "dns" : "dns_outlined"
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
                if Self.systemTabs && !wide && !restricted && bar == nil { systemTabBar } else {
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
                                        pageView(page, wide: wide).environment(\.productPageActive, active)
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
        .task(id: "\(session.profile?.deviceKickNotice == true)|\(session.profile?.deviceKickReason ?? "")|\(session.updatedAt?.timeIntervalSince1970 ?? 0)") {
            guard session.phase == .signedIn, session.profile?.deviceKickNotice == true else { return }
            if session.profile?.deviceKickReason == "limit_denied" { await loadSlotDevices() } else { kickNotice = true }
        }
        .productDialog(item: $popup) { item in AnnouncementsView(session: session, popup: item) { popup = nil } }
        .navigationDestination(isPresented: $showTraffic) { TrafficPage(session: session) }
        .navigationDestination(isPresented: $restrictedTickets) { FeatureSheet(title: L10n.t("工单")) { TicketsView(session: session) } }
        .productDialog(isPresented: $showAnnouncements) { AnnouncementsView(session: session) { showAnnouncements = false } }
        .alert(L10n.t("退出登录"), isPresented: Bindable(menu).confirmLogout) {
            Button(L10n.t("退出登录")) { Task { await session.logout() } }
            Button(L10n.t("取消"), role: .cancel) {}
        } message: {
            Text(L10n.t("退出后将断开连接并清除本机保存的登录凭据。"))
        }
        .alert(L10n.t("面板配置不规范"), isPresented: Binding(get: { session.configAlert != nil }, set: { if !$0 { session.configAlert = nil } })) {
            Button(L10n.t("知道了")) {}
        } message: {
            Text(verbatim: session.configAlert ?? "")
        }
        .alert(L10n.t("设备已下线"), isPresented: $kickNotice) {
            Button(L10n.t("知道了")) { Task { try? await session.acknowledgeDeviceKick() } }
        } message: {
            Text(session.profile?.deviceKickReason == "remove" ? L10n.t("该设备已被下线。") : L10n.t("由于超出在线客户端数量限制，有新客户端请求连接，已将您的设备踢下线。"))
        }
        .productDialog(isPresented: Binding(get: { slotDevices != nil }, set: { if !$0 { cancelSlot() } })) { deviceSlotDialog }
    }

    // iPhone 竖屏用系统 TabView 底栏：首页、节点、工单、邀请加「更多」，选中胶囊、切换动画与液态玻璃由系统负责。
    // 「更多」标签放自己的列表页而不是系统列表：页头与其它页一致带头像、分割线铺满整行（与 Android 一致），
    // 从列表进入的页面页头带返回键回到列表。iPad 与宽窗口走侧栏，iPhone Duo 走竖向栏，macOS / visionOS 窄窗口仍是自绘底栏
    #if os(iOS)
    private static let systemTabs = true
    #else
    private static let systemTabs = false
    #endif
    private static let barPages = 4

    @ViewBuilder private var systemTabBar: some View {
        #if os(iOS)
        let pinned = Array(pages.prefix(Self.barPages))
        let slot = Binding<Int>(
            get: { moreList ? Self.barPages : pinned.firstIndex(of: selection) ?? Self.barPages },
            set: { index in
                if index < Self.barPages { moreList = false; selection = pinned[index] } else { moreList = true }
            })
        TabView(selection: slot) {
            ForEach(Array(pinned.enumerated()), id: \.element) { index, page in
                let active = slot.wrappedValue == index
                VStack(spacing: 0) {
                    header
                    pageView(page, wide: false).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                // 系统 TabView 给每个标签铺系统背景（纯白 / 纯黑），盖住了外层的页面底色，须在标签内重设
                .background(colors.background)
                .environment(\.productPageActive, active)
                .transformPreference(ProductRefreshKey.self) { if !active { $0 = nil } }
                .tabItem {
                    Label { Text(verbatim: L10n.t(page.rawValue)) } icon: {
                        Self.tabIcon(page.icon(filled: active), unread: page == .tickets && !active && session.hasUnreadTicketReply, dark: scheme == .dark)
                    }
                }
                .tag(index)
                // 页面内的控件仍用主题色；只让底栏选中项与侧栏一致，不染主题蓝
                .tint(colors.accent)
            }
            let inMore = slot.wrappedValue == Self.barPages
            Group {
                if moreList || pinned.contains(selection) {
                    VStack(spacing: 0) {
                        pageHeader(title: L10n.t("更多"), back: nil)
                        ScrollView {
                            VStack(spacing: 0) {
                                ForEach(Array(pages.dropFirst(Self.barPages).enumerated()), id: \.element) { index, page in
                                    if index > 0 { Divider().overlay(colors.outline.opacity(0.5)) }
                                    ProductLinkRow(title: L10n.t(page.rawValue), icon: page.icon(filled: false)) { selection = page; moreList = false }
                                }
                            }
                            .background(colors.surface, in: RoundedRectangle(cornerRadius: 20)).clipShape(RoundedRectangle(cornerRadius: 20))
                            .padding(.leading, 14).padding(.trailing, 16).padding(.top, 16)
                        }
                    }
                    .background(colors.background)
                } else {
                    VStack(spacing: 0) {
                        pageHeader(title: nil, back: { moreList = true })
                        pageView(selection, wide: false).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .background(colors.background)
                    .environment(\.productPageActive, inMore)
                    .transformPreference(ProductRefreshKey.self) { if !inMore { $0 = nil } }
                }
            }
            .tabItem { Label { Text(verbatim: L10n.t("更多")) } icon: { Self.tabIcon("more_horiz") } }
            .tag(Self.barPages)
            .tint(colors.accent)
        }
        .tint(colors.text)
        #endif
    }

    // 部分图标资源原尺寸是 960，交给系统底栏前统一缩成 24 点模板图。
    // 工单未读不用系统角标（空角标固定约 18 点，调字号也缩不小），在图标右上角画 8 点红点、周围挖一圈空隙；
    // 带红点的图按原色交给系统，否则模板着色会把红点一起染掉，图标颜色取系统底栏未选中项用的 label 色
    #if os(iOS)
    private static var tabIcons: [String: Image] = [:]
    private static func tabIcon(_ name: String, unread: Bool = false, dark: Bool = false) -> Image {
        let key = unread ? "\(name)|unread|\(dark)" : name
        if let cached = tabIcons[key] { return cached }
        guard let source = UIImage(named: "product_" + name) else { return Image("product_" + name) }
        let size = CGSize(width: 24, height: 24)
        let drawn = UIGraphicsImageRenderer(size: size).image { context in
            let rect = CGRect(origin: .zero, size: size)
            guard unread else { source.draw(in: rect); return }
            let label = UIColor.label.resolvedColor(with: UITraitCollection(userInterfaceStyle: dark ? .dark : .light))
            source.withTintColor(label, renderingMode: .alwaysOriginal).draw(in: rect)
            context.cgContext.setBlendMode(.clear)
            context.cgContext.fillEllipse(in: CGRect(x: 14, y: -2, width: 12, height: 12))
            context.cgContext.setBlendMode(.normal)
            UIColor(red: 0xE5 / 255, green: 0x39 / 255, blue: 0x35 / 255, alpha: 1).setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 16, y: 0, width: 8, height: 8))
        }
        let image = Image(uiImage: drawn.withRenderingMode(unread ? .alwaysOriginal : .alwaysTemplate))
        tabIcons[key] = image
        return image
    }
    #endif

    @ViewBuilder private func pageView(_ page: Page, wide: Bool) -> some View {
        switch page {
        case .home: DashboardView(session: session, wide: wide, openNodes: { selection = .nodes }, openTraffic: { showTraffic = true }, requestDeviceSlot: { Task { await loadSlotDevices() } })
        case .nodes: nodeList(wide: wide)
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
                    ProductGlyph(name: "more_horiz", size: 24).frame(maxWidth: 64).frame(height: 32)
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
                // 指示条最宽 64，窄屏六项平分不够时随格宽收窄，不撑出屏幕
                .frame(maxWidth: 64).frame(height: 32)
                .background(selected ? colors.segment : Color.clear, in: Capsule())
                .foregroundStyle(selected ? colors.text : colors.secondary)
            // iPhone Duo 竖向栏每项仅 72 宽，放不下英文 Connections 时缩字，不断词换行
            Text(verbatim: L10n.t(page.rawValue)).font(.system(size: 12, weight: selected ? .semibold : .medium))
                .lineLimit(1).minimumScaleFactor(0.8)
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
                        // 与底栏、侧栏一致：选中只换底色，图标文字不变主题蓝
                        .foregroundStyle(colors.text)
                        .background(selected ? colors.segment : Color.clear)
                }.buttonStyle(.productPlain)
            }
        }.fixedSize().clipShape(RoundedRectangle(cornerRadius: 20))
            .productGlass(colors.surface, in: RoundedRectangle(cornerRadius: 20))
    }

    // title 与 back 只给 iPhone「更多」列表页及其进入的页面用：列表页只留头像，进入的页面左侧带返回键（对应 page_header.dart）
    private var header: some View { pageHeader(title: nil, back: nil) }

    private func pageHeader(title: String?, back: (() -> Void)?) -> some View {
        HStack(spacing: 0) {
            if let back {
                Button(action: back) {
                    Image(systemName: "arrow.left").font(.system(size: 20))
                        .frame(width: ProductMetrics.tapTarget, height: ProductMetrics.tapTarget).contentShape(Rectangle()).productIconHover()
                }.buttonStyle(.productPlain).accessibilityLabel(L10n.t("返回"))
                    .padding(.leading, -(ProductMetrics.tapTarget - 20) / 2).padding(.trailing, 8)
            }
            Text(verbatim: title ?? (restricted ? L10n.t("账户状态") : selection == .unlock ? L10n.t("解锁检测") : L10n.t(selection.rawValue)))
                .font(.system(size: 22, weight: .semibold)).tracking(-0.66).lineLimit(1)
            Spacer(minLength: 0)
            if title == nil && !restricted && selection == .home {
                Button { showAnnouncements = true } label: {
                    ProductGlyph(name: "notifications_outlined", size: 20).frame(width: 32, height: 32)
                        .overlay(alignment: .topTrailing) { if session.announcementState.hasUnread { unreadDot } }
                        .frame(width: ProductMetrics.tapTarget, height: ProductMetrics.tapTarget).contentShape(Rectangle()).productIconHover()
                }.buttonStyle(.productPlain).help(L10n.t("公告")).accessibilityLabel(L10n.t("公告"))
            }
            if title != nil {
            } else if !restricted && selection == .nodes {
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
                                      columns: max(1, min(6, Int((nodeListWidth + 8) / 268))),
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
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { nodeListWidth = $0 }
            .padding(.leading, 14).padding(.trailing, 16).padding(.top, 20).padding(.bottom, 14)
        }
        .task(id: "\(session.connection?.controlPlaneReady == true)|\(selection == .nodes)") {
            guard session.connection?.controlPlaneReady == true else { nodeSnapshot = nil; return }
            guard selection == .nodes else { return }
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

// 账户页「更多」区块与 iPhone「更多」列表共用的一行：图标、名称、右箭头
private struct ProductLinkRow: View {
    let title: String
    let icon: String
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let colors = ProductPalette(scheme: scheme)
        Button(action: action) {
            HStack(spacing: 10) {
                ProductGlyph(name: icon, size: 20).foregroundStyle(colors.secondary)
                Text(verbatim: title)
                Spacer(minLength: 0)
                ProductGlyph(name: "chevron_right", size: 24).foregroundStyle(colors.secondary)
            }.padding(.leading, 16).padding(.trailing, 24).frame(minHeight: 48).contentShape(Rectangle()).productHoverLayer(Rectangle())
        }.buttonStyle(.productPlain)
    }
}

struct AccountInfoPage: View {
    let session: ClientSession
    @Environment(\.colorScheme) private var scheme
    @State private var editAccount = false
    @State private var page: AccountPage?
    @State private var history: AccountHistoryKind?
    @State private var allowDelete = false
    private var colors: ProductPalette { ProductPalette(scheme: scheme) }

    var body: some View {
        FeatureSheet(title: L10n.t("账户信息"), onAccount: true) { account(session.profile) }.toolbar(.hidden)
            .navigationDestination(item: $page) { page in accountDestination(page) }
            .navigationDestination(isPresented: $editAccount) { AccountEditView(session: session) }
            .navigationDestination(item: $history) { kind in AccountHistoryView(session: session, kind: kind) }
    }

    private enum AccountPage: String, CaseIterable, Identifiable { case traffic = "流量记录", strategy = "自定义策略", deletion = "删除账号"; var id: Self { self } }

    @ViewBuilder private func accountDestination(_ page: AccountPage) -> some View {
        switch page {
        case .traffic: TrafficPage(session: session)
        case .strategy: SubscriptionStrategyView(session: session)
        case .deletion: DeleteAccountView(session: session)
        }
    }

    private func account(_ profile: UserProfile?) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let profile { userCard(profile); planCard(profile) }
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
                infoGrid(accountItems(profile))
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
        ProductLinkRow(title: title, icon: icon, action: action)
    }

    private func planCard(_ profile: UserProfile) -> some View {
        ProductCard(title: L10n.t("套餐"), icon: "inventory_2_outlined") {
            infoGrid(planItems(profile))
        }
    }

    private func accountItems(_ profile: UserProfile) -> [(String, String)] {
        [
            (L10n.t("余额"), L10n.t("¥ {0}", [String(format: "%.2f", profile.money)])),
            (L10n.t("注册时间"), profile.regDate.flatMap { $0.isEmpty ? nil : $0 } ?? "—"),
            (L10n.t("限速"), profile.nodeSpeedlimit <= 0 ? L10n.t("不限速") : String(format: "%.0f Mbps", profile.nodeSpeedlimit)),
            (L10n.t("在线客户端"), profile.nodeConnector <= 0 ? L10n.t("{0} / 无限制", [String(profile.onlineClientCount)])
                : "\(profile.onlineClientCount) / \(profile.nodeConnector)"),
        ]
    }

    private func planItems(_ profile: UserProfile) -> [(String, String)] {
        var items = [(L10n.t("套餐"), profile.plan?.name ?? (profile.class > 0 ? "VIP \(profile.class)" : L10n.t("免费用户")))]
        if let plan = profile.plan {
            items += [
                (L10n.t("到期"), plan.expTime),
                (L10n.t("剩余天数"), L10n.t("{0} 天", [String(plan.remainingDays)])),
                (L10n.t("自动续费"), plan.autoRenew == true ? plan.renewAt ?? "—" : "-"),
            ]
        }
        return items
    }

    // 宽屏排成标签在上、取值在下的小块，取值紧挨标签；放不下三栏时仍是逐行的标签与取值
    private func infoGrid(_ items: [(String, String)]) -> some View {
        ViewThatFits(in: .horizontal) {
            ProductGrid(minimumWidth: 180, maximumColumns: items.count, horizontalSpacing: 24, verticalSpacing: 12,
                        includeSpacingInThreshold: true, balanceRows: true) {
                ForEach(items, id: \.0) { infoTile($0.0, $0.1) }
            }.frame(minWidth: 3 * 180 + 2 * 24).padding(.vertical, 4)
            VStack(spacing: 0) { ForEach(items, id: \.0) { metric($0.0, $0.1) } }
        }
    }

    // 与首页内核状态的小块同字号，但标签与取值都靠左：逐项阅读时居中会让各项左缘参差
    private func infoTile(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: title).font(.system(size: 12)).foregroundStyle(colors.secondary)
            Text(verbatim: value).fontWeight(.semibold).monospacedDigit().lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading)
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
        FeatureSheet(title: L10n.t("流量记录")) { TrafficHistoryView(session: session) }
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
    let columns: Int
    let locate: (String) -> Void
    let select: (String) async -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var expanded = false
    @State private var searchOpen = false
    @State private var search = ""
    @State private var working = false
    @State private var sort = 0
    @State private var notice: String?
    // 面板只下发了一部分节点时，其余成员按页、按搜索词向面板取（ClientSession 的 NodeBrowsing）
    @State private var pageError: String?
    @State private var searching = false
    // 搜索下一页的偏移，没有更多时为 nil
    @State private var searchNext: Int?
    init(session: ClientSession, group: NodeSelectionGroup, catalog: NodeCatalog, selections: [String: String],
         live: Bool, wide: Bool, columns: Int, initiallyExpanded: Bool, locate: @escaping (String) -> Void,
         select: @escaping (String) async -> Void) {
        self.session = session; self.group = group; self.catalog = catalog; self.selections = selections
        self.live = live; self.wide = wide; self.columns = columns; self.locate = locate; self.select = select
        _expanded = State(initialValue: initiallyExpanded)
    }
    private var selected: String? { selections[group.id] }
    private func leaf(_ member: String) -> String {
        NodeProbeState.resolve(member, selections: selections)
    }
    private var sortedMembers: [String] {
        let members = session.members(of: group)
        guard sort != 0 else { return members }
        let slots = members.indices.filter { members[$0].range(of: #"^node-[1-9][0-9]*$"#, options: .regularExpression) != nil }
        let nodes = slots.map { members[$0] }.sorted { left, right in
            let a = session.nodeProbes.result(leaf(left), kind: sort == 1 ? .delay : .speed)
            let b = session.nodeProbes.result(leaf(right), kind: sort == 1 ? .delay : .speed)
            let x = sort == 1 ? Int64(a?.delay ?? 0) : a?.speed ?? 0
            let y = sort == 1 ? Int64(b?.delay ?? 0) : b?.speed ?? 0
            if (x > 0) != (y > 0) { return x > 0 }
            if x != y { return sort == 1 ? x < y : x > y }
            return session.displayName(left).utf8.lexicographicallyPrecedes(session.displayName(right).utf8)
        }
        var result = members
        for (slot, node) in zip(slots, nodes) { result[slot] = node }
        return result
    }

    private var query: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var filteredMembers: [String] {
        let query = query
        return sortedMembers.filter { !searchOpen || query.isEmpty || session.displayName($0).localizedCaseInsensitiveContains(query) }
    }
    private var remoteQuery: String { searchOpen && session.hasUnlistedNodes(group) ? query : "" }
    private var paging: Bool { remoteQuery.isEmpty ? session.hasMoreNodes(group) : searching || searchNext != nil }
    private func loadPage() async {
        do {
            if remoteQuery.isEmpty { try await session.loadMoreNodes(group) }
            else if let offset = searchNext { searchNext = try await session.searchNodes(group, query: remoteQuery, offset: offset) }
        } catch is CancellationError {
        } catch { pageError = message(error) }
    }
    // 搜索词停下 400 毫秒后才问面板
    private func searchPanel() async {
        searchNext = nil; pageError = nil
        guard !remoteQuery.isEmpty else { return }
        searching = true
        defer { searching = false }
        do {
            try await Task.sleep(for: .milliseconds(400))
            searchNext = try await session.searchNodes(group, query: remoteQuery, offset: 0)
        } catch is CancellationError {
        } catch { pageError = message(error) }
    }
    private struct Row: Identifiable {
        let id: [String]
        let members: ArraySlice<String>
        let top: CGFloat
    }

    var body: some View {
        let colors = ProductPalette(scheme: scheme)
        let radius: CGFloat = wide ? 20 : 16
        Section {
            if expanded {
                let filtered = filteredMembers
                let unmatched = searchOpen && !query.isEmpty && filtered.isEmpty && !paging && pageError == nil
                let leading = notice != nil || searchOpen || !group.selectable
                VStack(alignment: .leading, spacing: 10) {
                    if let notice { ProductNotice(message: notice).padding(.horizontal, 12) }
                    if searchOpen {
                        ProductSearchField(hint: L10n.t("搜索节点名称"), text: $search, autofocus: true).padding(.horizontal, 12)
                    }
                    if !group.selectable {
                        HStack(spacing: 6) {
                            ProductGlyph(name: "auto_awesome_outlined", size: 13).foregroundStyle(colors.outline)
                            Text(verbatim: automaticHint).frame(maxWidth: .infinity, alignment: .leading)
                        }.font(.system(size: 12)).foregroundStyle(colors.secondary).padding(.horizontal, 12)
                    }
                    if unmatched {
                        Text(L10n.t("没有符合条件的节点")).font(.system(size: 12)).foregroundStyle(colors.secondary).padding(.horizontal, 12)
                    }
                }.padding(.top, 10)
                // 成员一行一行交给外层的懒加载列表：一次建出全部成员，几千个节点就会让界面卡住。行的标识同时供「定位到当前节点」滚动用
                ForEach(stride(from: 0, to: filtered.count, by: columns).map { start in
                    Row(id: [group.id, filtered[start]], members: filtered[start..<min(start + columns, filtered.count)], top: start > 0 ? 8 : leading ? 10 : 0)
                }) { row in
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(row.members, id: \.self) { member in tile(member, colors: colors).frame(maxWidth: .infinity) }
                        ForEach(row.members.count..<columns, id: \.self) { _ in Color.clear.frame(maxWidth: .infinity, maxHeight: 0) }
                    }.padding(.top, row.top)
                }
                if let pageError {
                    VStack(spacing: 8) {
                        ProductNotice(message: pageError)
                        Button(L10n.t("重试")) { self.pageError = nil }.buttonStyle(ProductButtonStyle())
                    }.frame(maxWidth: .infinity).padding(.top, 10).padding(.horizontal, 12)
                } else if paging {
                    // 成员数或搜索位置一变就重新判断：这一行可能一直留在屏幕里，不会再次出现
                    ProgressView(L10n.t("正在获取节点…")).frame(maxWidth: .infinity).padding(12)
                        .task(id: [remoteQuery, String(filtered.count), String(searchNext ?? -1), String(searching)]) { if !searching { await loadPage() } }
                }
                Color.clear.frame(height: 18)
            } else {
                if let notice { ProductNotice(message: notice).padding(.top, 6) }
                Color.clear.frame(height: 6)
            }
        } header: {
                HStack(spacing: 10) {
                    Button { expanded.toggle() } label: {
                        HStack(spacing: 10) {
                            ProductGroupIcon(session: session, url: catalog.groupIcons[group.id], selectable: group.selectable)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text(verbatim: catalog.displayName(group.id)).fontWeight(.semibold).lineLimit(!wide && expanded ? nil : 1)
                                    ProductTag(text: (group.selectable ? L10n.t("手动") : L10n.t("自动")) + (wide ? "" : " · \(session.memberCount(of: group))"))
                                }
                                if wide {
                                    Text(verbatim: L10n.t("{0} 个节点{1}", [String(session.memberCount(of: group)), currentLabel]))
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
                .task(id: remoteQuery) { await searchPanel() }
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
                        Text(verbatim: session.displayName(member)).lineLimit(1)
                        if let nested { ProductTag(text: nested.selectable ? L10n.t("手动") : L10n.t("自动")) }
                    }.overlay(alignment: .leading) {
                        if member == selected { ProductGlyph(name: "check_circle", size: 12).foregroundStyle(colors.accent).offset(x: -16) }
                    }
                    if let via {
                        Text(verbatim: catalog.displayName(via)).foregroundStyle(colors.secondary).lineLimit(1)
                    } else if let node = session.node(member) {
                        ProductFlow(spacing: 4) {
                            ForEach([node.protocolName, node.network, node.tls, node.udp].filter { !$0.isEmpty }, id: \.self) { ProductTag(text: $0) }
                        }
                    }
                }.frame(maxWidth: .infinity, minHeight: 64, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.productPlain).disabled(!live || !group.selectable || working)
                .help(session.displayName(member) + (via.map { " → " + catalog.displayName($0) } ?? ""))
            VStack(alignment: .trailing, spacing: 0) {
                probeButton(member, kind: .delay)
                probeButton(member, kind: .speed)
            }
        }.padding(.leading, 20).padding(.trailing, 8).padding(.vertical, 4.5)
            .productHoverLayer(RoundedRectangle(cornerRadius: 9), enabled: live && group.selectable)
            .background(member == selected ? colors.accent.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
            .background(colors.surface, in: RoundedRectangle(cornerRadius: 9))
            .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(member == selected ? colors.accent : Color.clear, lineWidth: 1) }
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
            if let selected {
                expanded = true
                // 成员按行懒加载，滚动只能落到行上：取当前节点所在行的行首成员
                let members = filteredMembers
                let anchor = members.firstIndex(of: selected).map { members[$0 - $0 % columns] }
                Task { await Task.yield(); if let anchor { locate(anchor) } }
            }
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
