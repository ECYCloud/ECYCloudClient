import SwiftUI
import ECYCloudKit

struct DashboardView: View {
    let session: ClientSession
    let wide: Bool
    let openNodes: () -> Void
    let openTraffic: () -> Void
    let openShop: () -> Void
    let requestDeviceSlot: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var snapshot: TunnelSnapshot?
    @State private var samples: [RateSample] = []
    @State private var failure: String?
    @State private var selectedGroup = ""
    @State private var working = false
    @State private var checkingIn = false
    @State private var checkinMessage: String?
    @State private var segments: Bool?
    @State private var rankDay = TrafficRankDay.today
    @State private var rankHint = false
    @State private var toast: String?
    private var state: ConnectionState { session.connection?.state ?? .disconnected }
    private var connected: Bool { state == .connected }
    private var ready: Bool { session.connection?.controlPlaneReady == true }
    private var colors: ProductPalette { ProductPalette(scheme: scheme) }
    var body: some View {
        @Bindable var preferences = session.preferences
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let message = session.message { ProductNotice(message: message) }
                if let failure { ProductNotice(message: failure) }
                ProductCard(padding: EdgeInsets(top: 14, leading: 24, bottom: 14, trailing: 24)) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) { connectionStatus; Spacer(minLength: 0); connectionActions }.frame(minWidth: 560)
                        VStack(alignment: .leading, spacing: 12) { connectionStatus; connectionActions.frame(maxWidth: .infinity) }
                    }
                }
                if session.preferences.mode == .direct {
                    ProductCard(title: L10n.t("当前节点"), icon: "cell_tower_outlined") { Text(L10n.t("直连")) }
                } else if let catalog = session.catalog {
                    let groups = catalog.groups(for: session.preferences.mode, runtime: snapshot?.groups ?? [])
                    if !groups.isEmpty {
                        ProductCard(title: L10n.t("当前节点"), icon: "cell_tower_outlined") {
                            let group = currentGroup(groups, catalog: catalog)
                            let now = snapshot?.selections[group.id] ?? ""
                            let leaf = resolvedNode(now)
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(verbatim: leaf.isEmpty ? (ready ? L10n.t("未选择节点") : L10n.t("正在准备内核")) : catalog.displayName(leaf))
                                        .font(.system(size: 13, weight: .semibold)).lineLimit(wide ? 1 : 3)
                                    if let node = catalog.nodes.first(where: { $0.id == leaf }) {
                                        HStack(spacing: 4) {
                                            ForEach([node.protocolName, node.network, node.tls, node.udp].filter { !$0.isEmpty }, id: \.self) { ProductTag(text: $0) }
                                        }
                                    }
                                }
                                Spacer(minLength: 0)
                                if !leaf.isEmpty {
                                    // 与 Flutter 一致：延迟失败只在徽标上显示「超时」
                                    ProductProbeBadge(session: session, node: leaf, kind: .delay) {
                                        Task { _ = try? await session.measureNode(leaf, kind: .delay) }
                                    }
                                }
                            }.padding(.horizontal, 14).padding(.vertical, 10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(colors.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 9))
                                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(colors.outline, lineWidth: 1))
                            ProductPair {
                                ProductDropdown(label: L10n.t("策略组"), values: groups.map(\.id), selection: Binding(get: { group.id }, set: { selectedGroup = $0 }),
                                                leading: { name in AnyView(ProductGroupIcon(session: session, url: catalog.groupIcons[name], selectable: groups.first { $0.id == name }?.selectable ?? true, size: 16)) }) { catalog.displayName($0) }
                                    .disabled(session.preferences.mode == .global)
                            } right: {
                                ProductDropdown(label: L10n.t("节点"), values: group.members, selection: Binding(get: { now }, set: { node in
                                    Task { await perform { try await session.selectActiveNode(group: group.id, node: node) } }
                                }), trailing: { member in
                                    let delay = session.nodeProbes.result(resolvedNode(member), kind: .delay)
                                    if let delay, !delay.failed, delay.delay > 0 {
                                        return AnyView(Text(String(delay.delay)).font(.system(size: 11, weight: .semibold)).monospacedDigit().foregroundStyle(ProductProbeBadge.delayColor(delay.delay, scheme: scheme)))
                                    }
                                    return nil
                                }) { $0.isEmpty ? (ready ? L10n.t("未选择") : L10n.t("内核尚未就绪")) : catalog.displayName($0) }
                                    .disabled(!ready || !group.selectable || group.members.isEmpty || working)
                            }
                        }.headerAction {
                            HStack(spacing: 4) {
                                let testing = session.nodeProbes.isTestingGroup(currentGroup(groups, catalog: catalog).id, kind: .delay)
                                Button {
                                    let group = currentGroup(groups, catalog: catalog)
                                    Task { await testGroup(group) }
                                } label: {
                                    Group {
                                        if testing { ProgressView().controlSize(.small) }
                                        else { ProductGlyph(name: "bolt_outlined", size: 16) }
                                    }.frame(width: ProductMetrics.tapTarget, height: ProductMetrics.tapTarget).contentShape(Rectangle()).productIconHover()
                                }
                                    .disabled(testing)
                                    .help(L10n.t("测试本组全部节点延迟")).accessibilityLabel(L10n.t("测试本组全部节点延迟"))
                                Button(L10n.t("节点") + " ›", action: openNodes).buttonStyle(ProductButtonStyle())
                            }.buttonStyle(.productPlain).font(.system(size: 13, weight: .semibold))
                        }
                    }
                }
                if session.connection != nil {
                    ProductCard(padding: EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)) {
                        #if os(macOS)
                        HStack(spacing: 12) {
                            switchTile(L10n.t("系统代理"), connected ? L10n.t("本机 {0} 端口", [String(preferences.mixedPort)]) : L10n.t("仅连接后占用，当前未生效"),
                                       isOn: Binding(get: { preferences.systemProxy }, set: { value in
                                           Task { await perform { preferences.systemProxy = value; try await session.applyProxySettings() } }
                                       }), routes: false) { ProductGlyph(name: "public", size: 18) }
                            Divider().frame(height: 34)
                            switchTile(L10n.t("TUN 模式"), connected ? L10n.t("接管系统全部流量") : L10n.t("仅连接后占用，当前未生效"),
                                       isOn: Binding(get: { preferences.tunEnabled }, set: { value in
                                           Task { await perform { preferences.tunEnabled = value; try await session.applyProxySettings() } }
                                       }), routes: true) { ProductGlyph(name: "lan_outlined", size: 18) }
                        }
                        #else
                        switchTile(L10n.t("TUN 模式"), L10n.t("由系统 VPN 接管，始终开启"), isOn: .constant(true), locked: true, routes: true) {
                            ProductGlyph(name: "lan_outlined", size: 18)
                        }
                        #endif
                    }
                }
                ProductPair {
                    traffic(upload: true)
                } right: {
                    traffic(upload: false)
                }
                ProductCard(title: L10n.t("内核状态"), icon: "developer_board") {
                    // 与 Flutter 一致：仅接管连接后展示内核数值，待机时显示「—」
                    let live = connected ? snapshot : nil
                    ProductGrid(minimumWidth: 153.34, minimumColumns: 2, maximumColumns: 3, horizontalSpacing: 16) {
                        kernelMetric(L10n.t("内存占用"), live.map { bytes($0.memory) } ?? "—", icon: "memory")
                        kernelMetric(L10n.t("活跃连接"), live.map { String($0.active) } ?? "—", icon: "swap_vert", color: (live?.active ?? 0) > 0 ? colors.success : nil)
                        kernelMetric(L10n.t("已关闭连接"), live.map { String($0.closed) } ?? "—", icon: "history")
                    }
                }
                trafficRank
                if let profile = session.profile {
                    let remaining = profile.transferEnable - profile.used
                    ProductCard(title: L10n.t("流量使用情况"), icon: "pie_chart_outline") {
                        trafficUsage(L10n.t("今日已使用"), value: profile.todayUsed, total: profile.transferEnable, color: colors.danger)
                        trafficUsage(L10n.t("之前已使用"), value: profile.lastDayT, total: profile.transferEnable, color: colors.warning)
                        trafficUsage(L10n.t("剩余流量"), value: remaining, total: profile.transferEnable,
                                     color: remaining < 0 ? colors.danger : colors.success)
                        Divider().padding(.vertical, 2)
                        HStack { Text(L10n.t("账户总流量")); Spacer(); Text(compactBytes(profile.transferEnable)).fontWeight(.semibold).monospacedDigit().foregroundStyle(colors.accent) }
                        HStack(spacing: 0) {
                            Text(L10n.t("流量不够用？前往 ")).foregroundStyle(colors.secondary)
                            Button(L10n.t("商店") + " ›", action: openShop).buttonStyle(ProductButtonStyle())
                            Text(L10n.t(" 选购流量包")).foregroundStyle(colors.secondary)
                        }
                        VStack(spacing: 0) {
                            trafficMeta("today_outlined", L10n.t("下次重置已使用流量日期"), profile.trafficReset.isEmpty ? "—" : L10n.t(profile.trafficReset))
                            trafficMeta("schedule_outlined", L10n.t("上次使用时间"), L10n.t(profile.lastSsTime ?? "从未使用喵"))
                            if profile.enableCheckin != false {
                                trafficMeta("calendar_month_outlined", L10n.t("上次签到时间"), L10n.t(profile.lastCheckInTime.flatMap { $0.isEmpty ? nil : $0 } ?? "从未签到"))
                            }
                        }
                        if profile.enableCheckin != false {
                            Text(L10n.t("签到可随机获得 {0}~{1} MB 流量", [String(profile.checkinMin ?? 1), String(profile.checkinMax ?? 300)]))
                                .font(.system(size: 12)).foregroundStyle(colors.secondary).frame(maxWidth: .infinity).padding(.top, 2)
                            Button {
                                Task {
                                    checkingIn = true; defer { checkingIn = false }
                                    do { checkinMessage = try await session.checkin() }
                                    catch { checkinMessage = (error as? ClientError)?.localizedDescription ?? L10n.t("签到未完成，请重试。") }
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    if checkingIn { ProgressView().controlSize(.small) }
                                    else { ProductGlyph(name: "check_circle_outline", size: 18) }
                                    Text(profile.ableToCheckin == true ? L10n.t("点我签到") : L10n.t("今日已签到"))
                                }.frame(maxWidth: .infinity)
                            }.buttonStyle(ProductButtonStyle(filled: true)).disabled(checkingIn || profile.ableToCheckin != true)
                        }
                    }.headerAction {
                        HStack(spacing: 0) {
                            Button { if !session.busy { Task { await session.refresh() } } } label: {
                                ProductRefreshGlyph(spinning: session.busy).frame(width: ProductMetrics.tapTarget, height: 22).contentShape(Rectangle()).productIconHover()
                            }.help(L10n.t("刷新流量")).accessibilityLabel(L10n.t("刷新流量"))
                            Button(L10n.t("流量明细") + " ›", action: openTraffic).buttonStyle(ProductButtonStyle())
                        }.buttonStyle(.productPlain).font(.system(size: 13, weight: .semibold))
                    }
                }
            }.padding(.leading, 14).padding(.trailing, 16).padding(.top, 16).padding(.bottom, 14)
        }
        .background(colors.background)
        .navigationDestination(isPresented: Binding(get: { segments != nil }, set: { if !$0 { segments = nil } })) {
            NetworkSegmentsEditor(session: session, routes: segments == true) { toast = $0 }
        }
        .productToast($toast)
        .alert(L10n.t("提示"), isPresented: Binding(get: { checkinMessage != nil }, set: { if !$0 { checkinMessage = nil } })) {
            Button(L10n.t("我知道了")) { checkinMessage = nil }
        } message: {
            Text(verbatim: checkinMessage ?? "")
        }
        .task(id: "\(ready)|\(connected)|\(scenePhase)") {
            guard ready else { samples = []; snapshot = nil; failure = nil; return }
            guard scenePhase == .active else { return }
            while !Task.isCancelled && ready {
                do {
                    let value = try await session.tunnelSnapshot()
                    try Task.checkCancellation()
                    snapshot = value; failure = nil
                    if connected { samples.append(RateSample(date: .now, upload: value.upload, download: value.download)) }
                    else { samples = [] }
                    samples.removeAll { $0.date < .now.addingTimeInterval(-60) }
                } catch is CancellationError { break }
                catch { failure = (error as? ClientError)?.localizedDescription ?? (error as? TunnelError)?.localizedDescription ?? L10n.t("无法读取实时流量。") }
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
            }
        }
    }
    private var connectionStatus: some View {
        let busy = [.preparing, .connecting, .reconnecting, .disconnecting].contains(state)
        let failed = state == .disconnected && session.connection?.message != nil
        let color = connected ? colors.success : busy ? colors.warning : failed ? colors.danger : colors.outline
        let label = connected ? L10n.t("已连接") : state == .disconnecting ? L10n.t("正在断开连接") : busy ? L10n.t("正在连接")
            : failed ? L10n.t("连接失败") : L10n.t("未连接")
        return HStack(spacing: 12) {
            ZStack {
                Circle().fill(color.opacity(0.12))
                Circle().strokeBorder(color.opacity(0.22), lineWidth: 1)
                if busy {
                    TimelineView(.animation(paused: reduceMotion)) { context in
                        Circle().trim(from: 0, to: 0.75).stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.2) / 1.2 * 360))
                            .padding(3)
                    }.accessibilityHidden(true)
                }
                ProductGlyph(name: connected ? "shield" : "shield_outlined", size: 24).foregroundStyle(color)
            }
            .frame(width: 50, height: 50)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: label).font(.system(size: 17, weight: .semibold))
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(verbatim: connectionDetail(failed: failed, now: context.date))
                        .font(.system(size: 12)).foregroundStyle(failed || (state == .disconnecting && session.connection?.message != nil) ? colors.danger : colors.secondary)
                        .lineLimit(2)
                }
            }
        }
    }
    private func connectionDetail(failed: Bool, now: Date) -> String {
        let message = session.connection?.message
        switch state {
        case .connected:
            if session.panelOffline { return L10n.t("已连接，面板暂不可达，正在使用有效的本地配置") }
            guard let since = session.connection?.connectedAt else { return L10n.t("已连接") }
            return L10n.t("已连接 {0}", [ProductFormat.elapsed(now.timeIntervalSince(since))])
        case .preparing, .reconnecting: return message ?? state.title
        case .connecting: return message ?? L10n.t("正在启动内核，请稍候")
        case .disconnecting: return message ?? L10n.t("正在断开连接，请稍候")
        case .disconnected: return failed ? message! : L10n.t("点击右侧按钮开始连接")
        }
    }
    private var connectionActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { modeSelector; connectButton }
            VStack(spacing: 10) { modeSelector; connectButton }
        }
    }
    private var modeSelector: some View {
        ProductSegments(values: ClientPreferences.Mode.allCases, selection: Binding(get: { session.preferences.mode }, set: { mode in
                Task { await perform { try await session.setMode(mode) } }
            })) { $0.title }.fixedSize(horizontal: true, vertical: false).disabled(working)
    }
    private var connectButton: some View {
        let stopping = state == .disconnecting
        let spinning = [.preparing, .connecting, .reconnecting].contains(state) || (stopping && session.connection?.message == nil)
        return Button {
                if state == .disconnected {
                    if session.needsDeviceSlot && session.profile?.deviceKickNotice != true { requestDeviceSlot() }
                    else { Task { await session.connect() } }
                }
                else if connected { Task { await session.disconnectToStandby() } }
                else { session.connection?.disconnect() }
            } label: {
                HStack(spacing: 8) {
                    Group {
                        if spinning { ProgressView().controlSize(.small) }
                        else { ProductGlyph(name: connected || stopping ? "stop" : "play_arrow", size: 16) }
                    }.frame(width: 16, height: 16)
                    Text(verbatim: connectionButtonTitle)
                }
            }.buttonStyle(ProductButtonStyle(filled: true, color: connected || stopping ? colors.danger : nil))
                .disabled(session.connection == nil || (stopping && session.connection?.message == nil) || session.busy)
    }
    private var connectionButtonTitle: String {
        switch state {
        case .connected: L10n.t("断开")
        case .preparing, .connecting, .reconnecting: L10n.t("取消")
        case .disconnecting: session.connection?.message == nil ? L10n.t("断开中") : L10n.t("重试断开")
        default: L10n.connectAction
        }
    }
    private func perform(_ operation: () async throws -> Void) async {
        guard !working else { return }
        working = true; defer { working = false }
        do {
            try await operation()
            if ready { snapshot = try await session.tunnelSnapshot() }
            failure = nil
        } catch is CancellationError { }
        catch { failure = (error as? ClientError)?.localizedDescription ?? (error as? TunnelError)?.localizedDescription ?? L10n.t("操作未完成，请重试。") }
    }
    private func switchTile<Icon: View>(_ title: String, _ subtitle: String, isOn: Binding<Bool>, locked: Bool = false, routes: Bool,
                                        @ViewBuilder icon: () -> Icon) -> some View {
        let settings = routes ? L10n.t("TUN 排除自定义网段") : L10n.t("系统代理绕过")
        return HStack(spacing: 10) {
            icon().foregroundStyle(isOn.wrappedValue ? colors.text : colors.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    Text(verbatim: title).lineLimit(1)
                    Button { segments = routes } label: {
                        ProductGlyph(name: "settings_outlined", size: 20).foregroundStyle(colors.secondary)
                            .frame(width: ProductMetrics.tapTarget, height: ProductMetrics.tapTarget).contentShape(Rectangle()).productIconHover()
                    }.buttonStyle(.productPlain).help(settings).accessibilityLabel(settings)
                }
                Text(verbatim: subtitle).font(.system(size: 12)).foregroundStyle(colors.secondary)
            }
            Spacer(minLength: 0)
            Toggle(isOn: isOn) { EmptyView() }.toggleStyle(ProductToggleStyle()).fixedSize()
                .disabled(locked || working || ![.disconnected, .connected].contains(state))
        }.frame(maxWidth: .infinity)
    }
    private func kernelMetric(_ label: String, _ value: String, icon: String, color: Color? = nil) -> some View {
        VStack(spacing: 3) {
            HStack(spacing: 4) {
                ProductGlyph(name: icon, size: 14.4).frame(width: 12, height: 12).clipped().foregroundStyle(color ?? colors.secondary)
                Text(verbatim: label).foregroundStyle(colors.secondary)
            }.font(.system(size: 12))
            Text(verbatim: value).fontWeight(.semibold).monospacedDigit().foregroundStyle(color ?? colors.text)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func trafficUsage(_ label: String, value: Int64, total: Int64, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack { Text(verbatim: label).lineLimit(1); Spacer(); Text(compactBytes(value)).fontWeight(.semibold).monospacedDigit().foregroundStyle(color) }
            GeometryReader { geometry in
                Capsule().fill(colors.segment)
                Capsule().fill(color).frame(width: geometry.size.width * (total > 0 ? min(1, max(0, Double(value) / Double(total))) : 0))
            }.frame(height: 6)
        }
    }
    private func trafficMeta(_ icon: String, _ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            ProductGlyph(name: icon, size: 16).foregroundStyle(colors.secondary)
            Text(verbatim: label).foregroundStyle(colors.secondary).frame(maxWidth: .infinity, alignment: .leading)
            Text(verbatim: value).productTextSelection()
        }.font(.system(size: 12)).padding(.top, 6)
    }
    private func traffic(upload: Bool) -> some View {
        ProductCard(title: upload ? L10n.t("上传") : L10n.t("下载"), icon: upload ? "north" : "south", padding: EdgeInsets(top: 14, leading: 14, bottom: 10, trailing: 14)) {
            VStack(alignment: .leading, spacing: 1) {
                Text(bytes(connected ? (snapshot.map { upload ? $0.upload : $0.download } ?? 0) : 0) + "/s")
                    .font(.system(size: 18, weight: .bold)).monospacedDigit()
                Text(L10n.t("累计 {0}", [bytes(connected ? (snapshot.map { upload ? $0.uploadTotal : $0.downloadTotal } ?? 0) : 0)]))
                    .font(.system(size: 12)).foregroundStyle(colors.secondary)
                RateGraph(samples: samples, upload: upload, color: upload ? colors.warning : colors.accent)
                    .frame(height: 108).padding(.top, 8)
                    .accessibilityLabel(upload ? L10n.t("上传速率曲线") : L10n.t("下载速率曲线"))
            }
        }
    }
    private var trafficRank: some View {
        ProductCard(title: L10n.t("流量排行"), icon: "leaderboard_outlined") {
            ProductSegments(values: [TrafficRankDay.today, .yesterday], selection: $rankDay) { $0 == .today ? L10n.t("今日") : L10n.t("昨日") }
                .fixedSize(horizontal: true, vertical: false)
            ProductPair(stackedDivider: true) {
                rankList(L10n.t("策略组"), icon: "tune_outlined", rows: session.trafficRank.top(rankDay, hosts: false))
            } right: {
                rankList(L10n.t("域名/IP"), icon: "language", rows: session.trafficRank.top(rankDay, hosts: true))
            }
        }.titleAccessory {
            Button { rankHint.toggle() } label: {
                ProductGlyph(name: "error_outline", size: 14).foregroundStyle(colors.secondary)
                    .frame(width: ProductMetrics.tapTarget, height: ProductMetrics.tapTarget).contentShape(Rectangle()).productIconHover()
            }.buttonStyle(.productPlain).offset(y: -2)
                .accessibilityLabel(L10n.t("统计数据仅储存于本地，只保留最近两天的数据，只统计当前设备的流量使用，不同设备之间的流量数据不同步。"))
                .productTooltip(isPresented: $rankHint) {
                    Text(L10n.t("统计数据仅储存于本地，只保留最近两天的数据，只统计当前设备的流量使用，不同设备之间的流量数据不同步。"))
                        .font(.system(size: 12)).productTextSelection()
                }
        }
    }
    private func rankList(_ title: String, icon: String, rows: [TrafficRankRow]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                ProductGlyph(name: icon, size: 16)
                Text(verbatim: title).font(.system(size: 13, weight: .semibold))
            }.padding(.bottom, 8)
            if rows.isEmpty {
                Text(L10n.t("暂无排行数据")).font(.system(size: 12)).foregroundStyle(colors.secondary)
            } else {
                VStack(spacing: 10) {
                    ForEach(rows) { row in trafficUsage(row.name, value: row.bytes, total: rows[0].bytes, color: colors.accent) }
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func bytes(_ n: Int64) -> String { ProductFormat.bytes(n) }
    private func compactBytes(_ n: Int64) -> String { ProductFormat.bytes(n).replacingOccurrences(of: " ", with: "") }
    private func resolvedNode(_ name: String) -> String {
        NodeProbeState.resolve(name, selections: snapshot?.selections ?? [:])
    }
    private func currentGroup(_ groups: [NodeSelectionGroup], catalog: NodeCatalog) -> NodeSelectionGroup {
        groups.first { $0.id == selectedGroup } ?? groups.first { $0.id == catalog.mainGroupID } ?? groups[0]
    }
    private func testGroup(_ group: NodeSelectionGroup) async {
        // 与 Flutter testGroup 一致：结果只体现在延迟徽标上，不弹提示
        _ = try? await session.measureGroup(group, selections: snapshot?.selections ?? [:], kind: .delay)
        if ready, let value = try? await session.tunnelSnapshot() { snapshot = value }
    }
}
private struct RateSample { let date: Date; let upload: Int64, download: Int64 }
private struct RateGraph: View {
    let samples: [RateSample]
    let upload: Bool
    let color: Color
    @Environment(\.colorScheme) private var scheme
    @State private var inspectX: CGFloat?
    #if os(tvOS)
    @State private var graphWidth: CGFloat = 0
    #endif
    var body: some View {
        Canvas { context, size in
            let colors = ProductPalette(scheme: scheme)
            let now = samples.last?.date ?? .now
            let points = samples.filter { $0.date >= now.addingTimeInterval(-60) }
            let peak = points.map { upload ? $0.upload : $0.download }.max() ?? 0
            let font = Font.system(size: 10).monospacedDigit()
            let labels = [peak, peak / 2, 0].map { ProductFormat.bytes($0) + "/s" }
            let yWidth = labels.map { context.resolve(Text($0).font(font)).measure(in: size).width }.max() ?? 0
            let plot = CGRect(x: yWidth + 6, y: 10, width: max(1, size.width - yWidth - 10), height: max(1, size.height - 26))
            for (index, label) in labels.enumerated() {
                let y = plot.minY + plot.height * Double(index) / 2
                let path = Path { $0.move(to: CGPoint(x: plot.minX, y: y)); $0.addLine(to: CGPoint(x: plot.maxX, y: y)) }
                context.stroke(path, with: .color(colors.segment.opacity(0.55)), lineWidth: 1)
                context.draw(Text(label).font(font).foregroundStyle(colors.secondary), at: CGPoint(x: plot.minX - 5, y: y), anchor: .trailing)
            }
            var axes = Path()
            axes.move(to: CGPoint(x: plot.minX, y: plot.minY)); axes.addLine(to: CGPoint(x: plot.minX, y: plot.maxY)); axes.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
            context.stroke(axes, with: .color(colors.segment), lineWidth: 1)
            for index in 0...2 {
                let date = now.addingTimeInterval(Double(index - 2) * 30)
                let text = date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
                context.draw(Text(text).font(font).foregroundStyle(colors.secondary), at: CGPoint(x: plot.minX + plot.width * Double(index) / 2, y: plot.maxY + 4), anchor: index == 0 ? .topLeading : index == 1 ? .top : .topTrailing)
            }
            func position(_ sample: RateSample) -> CGPoint {
                let value = upload ? sample.upload : sample.download
                return CGPoint(x: plot.maxX + plot.width * sample.date.timeIntervalSince(now) / 60,
                               y: plot.maxY - plot.height * (peak > 0 ? Double(value) / Double(peak) : 0))
            }
            var line = Path()
            if points.isEmpty {
                line.move(to: CGPoint(x: plot.minX, y: plot.maxY)); line.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
            } else {
                for (index, point) in points.enumerated() {
                    if index == 0 { line.move(to: position(point)) } else { line.addLine(to: position(point)) }
                }
                var fill = line
                fill.addLine(to: CGPoint(x: position(points.last!).x, y: plot.maxY))
                fill.addLine(to: CGPoint(x: position(points.first!).x, y: plot.maxY)); fill.closeSubpath()
                context.fill(fill, with: .linearGradient(Gradient(colors: [color.opacity(0.28), color.opacity(0.02)]), startPoint: CGPoint(x: 0, y: plot.minY), endPoint: CGPoint(x: 0, y: plot.maxY)))
            }
            context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            if let inspectX, let point = points.min(by: { abs(position($0).x - inspectX) < abs(position($1).x - inspectX) }) {
                let p = position(point)
                let cursor = Path { $0.move(to: CGPoint(x: p.x, y: plot.minY)); $0.addLine(to: CGPoint(x: p.x, y: plot.maxY)) }
                context.stroke(cursor, with: .color(color.opacity(0.7)), lineWidth: 1)
                context.fill(Path(ellipseIn: CGRect(x: p.x - 3.2, y: p.y - 3.2, width: 6.4, height: 6.4)), with: .color(color))
                let text = ProductFormat.bytes(upload ? point.upload : point.download) + "/s"
                context.draw(Text(text).font(.system(size: 12)).foregroundStyle(colors.text), at: CGPoint(x: min(max(p.x, 50), size.width - 50), y: 0), anchor: .top)
            }
        }
        #if os(tvOS)
        .background { GeometryReader { geometry in Color.clear.onAppear { graphWidth = geometry.size.width } } }
        .focusable()
        .onMoveCommand { direction in
            if direction == .left { inspectX = max(0, (inspectX ?? graphWidth) - graphWidth / 60) }
            if direction == .right { inspectX = min(graphWidth, (inspectX ?? 0) + graphWidth / 60) }
        }
        #else
        .onContinuousHover { phase in
            switch phase { case .active(let point): inspectX = point.x; case .ended: inspectX = nil }
        }
        // 拖动手势会抢走所在 ScrollView 的滑动，触屏按 Flutter 的按下即查看改用点按
        .gesture(SpatialTapGesture().onEnded { inspectX = $0.location.x })
        #endif
    }
}
