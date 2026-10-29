import SwiftUI
import OSLog
import ECYCloudKit

struct RuntimeConnectionsView: View {
    let session: ClientSession
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var scheme
    @State private var state = FeatureState<TunnelSnapshot>()
    @State private var search = ""
    @State private var scope = "all"
    @State private var connections: [TunnelSnapshot.Connection] = []
    @State private var revision = 0
    @State private var detail: TunnelSnapshot.Connection?
    private var connected: Bool { session.connection?.state == .connected }
    var body: some View {
        Group {
            if connected {
                GeometryReader { geometry in
                    VStack(spacing: 0) {
                        filterBar(wide: geometry.size.width >= 640)
                        ScrollView {
                            FeatureScreen(state: state, reload: load, showsRefresh: false, embedded: true) { _ in
                                if visibleConnections.isEmpty {
                                    Text(L10n.t("没有符合条件的连接")).frame(maxWidth: .infinity)
                                        .containerRelativeFrame(.vertical) { length, _ in max(0, length - 12) }
                                } else {
                                    LazyVStack(spacing: 10) {
                                        ForEach(visibleConnections) { connection in
                                            Button { detail = connection } label: { connectionRow(connection) }.buttonStyle(.productPlain)
                                        }
                                    }
                                }
                            }.padding(.leading, 14).padding(.trailing, 16).padding(.vertical, 6)
                            // tvOS 首个可聚焦项紧贴滚动区顶边时，上移键会被滚动吞掉
                            #if os(tvOS)
                            .padding(.top, 10)
                            #endif
                        }
                    }
                }
            } else { Text(L10n.t("连接后可查看连接明细")).frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .task(id: "\(connected)|\(scenePhase)|\(search)") {
            guard connected, scenePhase == .active else {
                state.value = nil; connections = []
                if !connected { revision += 1 }
                return
            }
            while !Task.isCancelled && connected {
                await load()
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
            }
        }
        .productDialog(item: $detail) { row in
            ConnectionDetailDialog(session: session, row: row, live: connections.first { $0.id == row.id }, revision: revision) { detail = nil }
        }
    }
    private var visibleConnections: [TunnelSnapshot.Connection] {
        connections.filter { scope == "all" || (scope == "active" ? $0.closedAt == nil : $0.closedAt != nil) }
    }
    private func filterBar(wide: Bool) -> some View {
        Group {
            if wide { HStack(spacing: 10) { scopeFilter.fixedSize(horizontal: true, vertical: false); connectionSearch } }
            else { VStack(spacing: 8) { scopeFilter; connectionSearch } }
        }.padding(.leading, 14).padding(.trailing, 16).padding(.top, 26).padding(.bottom, 10)
    }
    private var scopeFilter: some View {
        let active = connections.filter { $0.closedAt == nil }.count
        let closed = connections.count - active
        return ProductSegments(values: ["all", "active", "closed"], selection: $scope) { value in
            switch value {
            case "active": L10n.t("活跃中 {0}", [String(active)])
            case "closed": L10n.t("已关闭 {0}", [String(closed)])
            default: L10n.t("全部 {0}", [String(active + closed)])
            }
        }
    }
    private var connectionSearch: some View {
        ProductSearchField(hint: L10n.t("搜索域名、IP、进程、规则"), text: $search)
    }
    private func connectionRow(_ connection: TunnelSnapshot.Connection) -> some View {
        let colors = ProductPalette(scheme: scheme)
        let active = connection.closedAt == nil
        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    ProductGlyph(name: active ? "circle" : "remove_circle_outline", size: active ? 8 : 12)
                        .foregroundStyle(active ? colors.success : colors.secondary).frame(width: 12, height: 12)
                    Text(verbatim: connection.destination).lineLimit(1)
                }
                ProductFlow(spacing: 5) {
                    if !connection.inbound.isEmpty { ProductTag(text: connection.inbound) }
                    if !connection.network.isEmpty { ProductTag(text: connection.network.uppercased()) }
                    if connection.chains.first?.isEmpty == false {
                        ProductTag(text: chainLabel(connection, session: session), icon: "call_made")
                    }
                    if !connection.process.isEmpty { ProductTag(text: connection.process, icon: "memory") }
                    if !connection.rule.isEmpty { Text(verbatim: connection.rule).font(.system(size: 12)).foregroundStyle(colors.secondary) }
                }.padding(.leading, 20)
            }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 3) {
                Text("↑ " + bytes(connection.upload) + "　↓ " + bytes(connection.download)).monospacedDigit()
                Text(active ? lifetime(connection) : L10n.t("已关闭 · {0}", [lifetime(connection)]))
            }.font(.system(size: 12)).foregroundStyle(colors.secondary)
        }.padding(.horizontal, 14).padding(.vertical, 12).contentShape(RoundedRectangle(cornerRadius: 16))
            .productHoverLayer(RoundedRectangle(cornerRadius: 16))
            .background(colors.surface, in: RoundedRectangle(cornerRadius: 16)).opacity(active ? 1 : 0.65)
    }
    private func lifetime(_ connection: TunnelSnapshot.Connection) -> String {
        let start = ProductFormat.timestamp(connection.start)
        let end = connection.closedAt.flatMap(ProductFormat.timestamp) ?? .now
        guard let start else { return "" }
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        return seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) : String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
    private func load() async {
        guard !state.loading, !state.working else { return }
        await state.load {
            let first = try await session.tunnelSnapshot(page: 1, scope: "all", query: search)
            var rows = first.connections
            if first.total > 25 {
                for next in 2...((first.total + 24) / 25) {
                    try Task.checkCancellation()
                    rows += try await session.tunnelSnapshot(page: next, scope: "all", query: search).connections
                }
            }
            try Task.checkCancellation()
            var seen: Set<String> = []
            connections = rows.filter { seen.insert($0.id).inserted }
            revision += 1
            return first
        }
    }
    private func bytes(_ n: Int64) -> String { ProductFormat.bytes(n) }

}
private func chainLabel(_ connection: TunnelSnapshot.Connection, session: ClientSession) -> String {
    connection.chains.reversed().map { session.catalog?.displayName($0) ?? $0 }.joined(separator: " → ")
}
// 对应 connections_page.dart 的 _ConnectionDetailDialog：速率按相邻两次连接快照的计数差分
private struct ConnectionDetailDialog: View {
    let session: ClientSession
    let live: TunnelSnapshot.Connection?
    let revision: Int
    let close: () -> Void
    @State private var row: TunnelSnapshot.Connection
    @State private var sampledAt: Date?
    @State private var uploadSpeed: Int64 = 0
    @State private var downloadSpeed: Int64 = 0
    @State private var active: Bool
    @State private var closing = false
    @State private var closeError: String?
    @Environment(\.colorScheme) private var scheme
    init(session: ClientSession, row: TunnelSnapshot.Connection, live: TunnelSnapshot.Connection?, revision: Int, close: @escaping () -> Void) {
        self.session = session; self.live = live; self.revision = revision; self.close = close
        _row = State(initialValue: row); _active = State(initialValue: row.closedAt == nil)
    }
    var body: some View {
        let colors = ProductPalette(scheme: scheme)
        let start = ProductFormat.timestamp(row.start).map { Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: $0) }
        let fields: [(String, String)] = [
            (L10n.t("主机"), row.destination),
            (L10n.t("下载量"), ProductFormat.bytes(row.download)),
            (L10n.t("上传量"), ProductFormat.bytes(row.upload)),
            (L10n.t("下载速度"), ProductFormat.bytes(downloadSpeed) + "/s"),
            (L10n.t("上传速度"), ProductFormat.bytes(uploadSpeed) + "/s"),
            (L10n.t("链路"), chainLabel(row, session: session)),
            (L10n.t("规则"), row.rulePayload.isEmpty ? row.rule : row.rule + "(" + row.rulePayload + ")"),
            (L10n.t("进程"), row.processPath.isEmpty || row.processPath == row.process ? row.process : row.process + " (" + row.processPath + ")"),
            (L10n.t("连接时间"), start.map { String(format: "%04d-%02d-%02d %02d:%02d:%02d", $0.year ?? 0, $0.month ?? 0, $0.day ?? 0, $0.hour ?? 0, $0.minute ?? 0, $0.second ?? 0) } ?? ""),
            (L10n.t("源地址"), row.source),
            (L10n.t("目标地址"), row.remoteDestination.isEmpty ? row.ip : row.remoteDestination),
            (L10n.t("目标端口"), row.port),
            (L10n.t("类型"), row.network.isEmpty ? row.inbound : row.inbound + "(" + row.network + ")"),
        ]
        ProductDialog(title: L10n.t("连接详情")) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(fields, id: \.0) { label, value in
                    Text(verbatim: label + ": ").foregroundStyle(colors.secondary) + Text(verbatim: value.isEmpty ? "—" : value)
                }
                if let closeError { Text(verbatim: closeError).foregroundStyle(colors.danger) }
            }
        } actions: {
            if active {
                Button(L10n.t("关闭连接")) { Task { await closeConnection() } }
                    .buttonStyle(ProductButtonStyle(filled: true)).disabled(closing)
            }
            Button(L10n.t("关闭"), action: close).buttonStyle(ProductButtonStyle())
        }
        .onChange(of: revision) { update() }
    }
    // 连接从活跃列表消失即视为已关闭；已关闭列表里找不到时沿用最后一次的数据
    private func update() {
        guard active else { return }
        let now = Date.now, last = sampledAt
        sampledAt = now
        guard let live, live.closedAt == nil else {
            if let live { row = live }
            active = false; uploadSpeed = 0; downloadSpeed = 0
            return
        }
        if let last, now > last {
            let seconds = now.timeIntervalSince(last)
            uploadSpeed = Int64((Double(max(0, live.upload - row.upload)) / seconds).rounded())
            downloadSpeed = Int64((Double(max(0, live.download - row.download)) / seconds).rounded())
        }
        row = live
    }
    private func closeConnection() async {
        closing = true; closeError = nil
        do {
            try await session.closeConnection(row.id)
            close()
        } catch {
            Logger(subsystem: Bundle.main.bundleIdentifier ?? "ECYCloud", category: "Connections").warning("关闭连接失败: \(error.localizedDescription, privacy: .public)")
            closing = false
            closeError = L10n.t("关闭连接失败：{0}", [error.localizedDescription])
        }
    }
}
struct RuntimeLogsView: View {
    let session: ClientSession
    @Environment(\.scenePhase) private var scenePhase
    @State private var state = FeatureState<TunnelLogs>()
    @State private var level = ""
    @State private var search = ""
    @State private var entries: [TunnelLogs.Entry] = []
    @Environment(\.colorScheme) private var scheme
    private var connected: Bool { session.connection?.controlPlaneReady == true }
    var body: some View {
        let colors = ProductPalette(scheme: scheme)
        GeometryReader { geometry in
            VStack(spacing: 0) {
                filterBar(wide: geometry.size.width >= 640)
                ScrollView {
                    VStack(spacing: 12) {
                        if let failure = state.failure { ProductNotice(message: failure) }
                        LazyVStack(spacing: 2) {
                            if entries.isEmpty {
                                Text(L10n.t("没有符合条件的日志")).frame(maxWidth: .infinity)
                                    .containerRelativeFrame(.vertical) { length, _ in max(0, length - 4) }
                            }
                            ForEach(entries) { entry in
                                let tone = color(entry.level, colors)
                                HStack(alignment: .top, spacing: 0) {
                                    Text(verbatim: entry.level).fontWeight(.semibold).foregroundStyle(tone)
                                        .frame(width: 72, alignment: .leading).padding(.trailing, 6)
                                    Text(verbatim: clock(entry.time)).foregroundStyle(colors.secondary).frame(width: 62, alignment: .leading)
                                    Text(verbatim: "mihomo").lineLimit(1).foregroundStyle(colors.secondary).frame(width: 82, alignment: .leading)
                                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                                        if let inbound = entry.inbound, !inbound.isEmpty { ProductTag(text: inbound) }
                                        Text(verbatim: entry.message).foregroundStyle(tone).productTextSelection()
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }.font(.system(size: 13)).padding(.horizontal, 14).padding(.vertical, 7).productScrollStop()
                            }
                        }.background(colors.surface, in: RoundedRectangle(cornerRadius: 20))
                    }.padding(.leading, 14).padding(.trailing, 16).padding(.vertical, 2)
                    #if os(tvOS)
                    .padding(.top, 14)
                    #endif
                }
            }
        }

        .task(id: "\(connected)|\(scenePhase)|\(level)|\(search)") {
            guard connected, scenePhase == .active else { state.value = nil; entries = []; return }
            while !Task.isCancelled && connected {
                await load()
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
            }
        }
    }
    private func color(_ level: String, _ colors: ProductPalette) -> Color {
        switch level {
        case "error": colors.danger
        case "warning": colors.warning
        case "info": colors.text
        default: colors.secondary
        }
    }
    private func clock(_ time: String) -> String {
        guard let date = ProductFormat.timestamp(time) else { return "" }
        let parts = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
        return String(format: "%02d:%02d:%02d", parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
    }
    private func filterBar(wide: Bool) -> some View {
        Group {
            if wide { HStack(spacing: 10) { levelFilter(compact: false).fixedSize(horizontal: true, vertical: false); searchActions } }
            else { VStack(spacing: 8) { levelFilter(compact: true); searchActions } }
        }.padding(.leading, 14).padding(.trailing, 16).padding(.top, 26).padding(.bottom, 10)
    }
    private func levelFilter(compact: Bool) -> some View {
        ProductSegments(values: ["", "debug", "info", "warning", "error"], selection: $level, compact: compact) { $0.isEmpty ? L10n.t("全部") : $0 }
    }
    private var searchActions: some View {
        HStack(spacing: 10) {
            Text(L10n.t("{0} 条", [String(entries.count)])).font(.system(size: 12))
                .foregroundStyle(ProductPalette(scheme: scheme).secondary).fixedSize()
            ProductSearchField(hint: L10n.t("搜索日志内容"), text: $search)
        }
    }
    private func load() async {
        guard !state.loading else { return }
        await state.load {
            let first = try await session.tunnelLogs(page: 1, level: level, query: search)
            var rows = first.entries
            if first.total > 20 {
                for next in 2...((min(first.total, 2000) + 19) / 20) {
                    try Task.checkCancellation()
                    rows += try await session.tunnelLogs(page: next, level: level, query: search).entries
                }
            }
            try Task.checkCancellation()
            var seen: Set<Int64> = []
            entries = rows.filter { seen.insert($0.id).inserted }
            return first
        }
    }
}
