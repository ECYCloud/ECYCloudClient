import SwiftUI
import ECYCloudKit

struct ClientSettingsView: View {
    let session: ClientSession
    @AppStorage("apple.appearance") private var appearance = "system"
    @State private var document: LegalDocumentKind?
    @State private var segments: Bool?
    @State private var port = ""
    @State private var working = false
    @State private var activity: Activity?
    @State private var toast: String?
    @State private var showConfiguration = false
    @State private var showRules = false
    @State private var appStatus: String?
    @State private var appOutdated = false
    @State private var kernelStatus: String?
    @State private var kernelChecked = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.openURL) private var openURL
    #if os(macOS)
    @State private var macSettings = MacApplicationSettings()
    @Environment(\.scenePhase) private var scenePhase
    #endif
    private enum Activity { case apply, panel, geo, app, kernel, other }
    private var colors: ProductPalette { ProductPalette(scheme: scheme) }
    private let rowInsets = EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 24)
    private let dropdownInsets = EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 24)
    private var iconButtonInset: CGFloat { 24 - (ProductMetrics.tapTarget - 24) / 2 }
    // 只有 macOS 提供「打开目录」，其余平台须完整显示路径
    private var logPathLineLimit: Int? {
        #if os(macOS)
        1
        #else
        nil
        #endif
    }
    var body: some View {
        @Bindable var preferences = session.preferences
        ScrollView {
            VStack(spacing: 16) {
                if let connection = session.connection {
                    let proxyLocked = working || ![.disconnected, .connected].contains(connection.state)
                    ProductSection(title: L10n.t("代理"), icon: "vpn_lock_outlined") {
                        #if os(macOS)
                        settingToggle(L10n.t("设置系统代理"), detail: L10n.t("把系统代理指向本机混合端口，只对读取该设置的程序生效，其余程序需要 TUN 模式；退出与崩溃后自动还原"), value: $preferences.systemProxy, edit: false)
                        Divider()
                        settingToggle(L10n.t("TUN 模式"), detail: L10n.t("接管系统全部流量，需要后台服务与虚拟网卡驱动"), value: $preferences.tunEnabled, edit: true)
                        Divider()
                        settingToggle(L10n.t("严格路由"), detail: L10n.t("阻断绕过 TUN 的 DNS 查询防泄露，代价是打断本机回环通信，游戏与虚拟机可能不可用"), value: $preferences.strictRoute).disabled(!preferences.tunEnabled)
                        Divider()
                        settingToggle(L10n.t("允许局域网连接"), detail: L10n.t("混合端口监听全部网卡，供同网段其它设备使用"), value: $preferences.allowLAN)
                        #else
                        Toggle(isOn: .constant(true)) {
                            text(L10n.t("TUN 模式"), L10n.t("接管系统全部流量，需要后台服务与虚拟网卡驱动"), edit: true, editEnabled: !proxyLocked)
                        }.disabled(true).toggleStyle(ProductToggleStyle()).padding(rowInsets)
                        #endif
                        Divider()
                        settingToggle(L10n.t("启用 IPv6"), value: $preferences.ipv6)
                        #if os(macOS)
                        Divider()
                        HStack(spacing: 12) {
                            text(L10n.t("混合代理端口"), L10n.t("HTTP 与 SOCKS 共用，修改后重连生效"))
                            ProductTextField(hint: "", text: $port, alignment: .center, onSubmit: applyPort).frame(width: 116)
                                .onAppear { port = String(preferences.mixedPort) }
                        }.padding(rowInsets)
                        #endif
                    }.disabled(proxyLocked)
                }
                ProductSection(title: L10n.t("应用"), icon: "tune") {
                    HStack {
                        Text(L10n.t("界面配色")); Spacer(minLength: 0)
                        ProductDropdown(values: ["system", "light", "dark"], selection: $appearance) {
                            switch $0 { case "light": L10n.t("浅色"); case "dark": L10n.t("深色"); default: L10n.t("跟随系统") }
                        }.frame(width: 116)
                    }.padding(dropdownInsets)
                    Divider()
                    HStack {
                        Text(L10n.t("语言")); Spacer(minLength: 0)
                        ProductDropdown(values: AppLanguage.allCases, selection: $preferences.language) { $0.title }.frame(width: 116)
                    }.padding(dropdownInsets)
                    #if os(macOS)
                    Divider()
                    Toggle(isOn: Binding(get: { macSettings.launchAtLogin }, set: { enabled in
                        do { try macSettings.setLaunchAtLogin(enabled) }
                        catch { toast = L10n.t("无法更改开机自启设置，请在系统设置中检查登录项。"); macSettings.refresh() }
                    })) { text(L10n.t("开机自启"), macSettings.requiresApproval ? L10n.t("请在系统设置的登录项中允许 ECYCloud。") : nil) }
                        .toggleStyle(ProductToggleStyle()).padding(rowInsets)
                    #endif
                    if session.connection != nil {
                        Divider()
                        Toggle(L10n.t("启动后自动连接"), isOn: $preferences.autoConnect).toggleStyle(ProductToggleStyle()).padding(rowInsets)
                    }
                    #if os(macOS)
                    Divider()
                    Toggle(L10n.t("关闭窗口时最小化到托盘"), isOn: $preferences.closeToTray).toggleStyle(ProductToggleStyle()).padding(rowInsets)
                    #endif
                    if session.connection != nil {
                        Divider()
                        HStack {
                            text(L10n.t("日志落盘级别"), L10n.t("日志页始终显示内核全部日志；此项决定写进日志文件的门槛，调低会显著增加磁盘写入，选 silent 则不写日志文件"))
                            ProductDropdown(values: ["debug", "info", "warning", "error", "silent"], selection: Binding(get: { preferences.logLevel }, set: {
                                preferences.logLevel = $0
                                run(.other) { try await session.applyLogLevel() }
                            })) { $0 }.frame(width: 116)
                        }.padding(rowInsets)
                        if let directory = session.logDirectory {
                            HStack(spacing: 10) {
                                Text(L10n.t("储存路径")).font(.system(size: 12)).foregroundStyle(colors.secondary)
                                Text(directory.path).font(.system(size: 12)).foregroundStyle(colors.secondary).lineLimit(logPathLineLimit).productTextSelection()
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                #if os(macOS)
                                Button {
                                    do {
                                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                                        if !NSWorkspace.shared.open(directory) { toast = status(L10n.t("打开目录"), L10n.t("系统里没有可用的文件管理器")) }
                                    } catch { toast = status(L10n.t("打开目录"), error.localizedDescription) }
                                } label: { ProductGlyph(name: "folder_open_outlined", size: 24).frame(width: ProductMetrics.tapTarget, height: ProductMetrics.tapTarget).contentShape(Rectangle()).productIconHover() }
                                    .buttonStyle(.productPlain).help(L10n.t("打开目录")).accessibilityLabel(L10n.t("打开目录"))
                                #endif
                            }.padding(.leading, 16).padding(.trailing, iconButtonInset).padding(.bottom, 8)
                        }
                    }
                }.disabled(working)
                if session.connection != nil {
                    ProductSection(title: L10n.t("配置"), icon: "description_outlined") {
                        refreshRow(.panel, L10n.t("刷新面板配置"), L10n.t("重新拉取节点与分流规则；节点变更后随账号信息刷新自动更新"), help: L10n.t("刷新面板配置"), progress: true) {
                            await session.loadNodes()
                            if let error = session.nodesError { toast = status(L10n.t("面板配置"), L10n.t("更新失败：{0}", [error])) }
                        }
                        Divider()
                        refreshRow(.geo, L10n.t("更新 GeoData"), L10n.t("按面板 geox-url 重新下载地理位置数据库（需内核运行中）"), help: L10n.t("更新 GeoData"), progress: true) {
                            do { try await session.updateGeoData(); toast = status("GeoData", L10n.t("更新成功")) }
                            catch is CancellationError {}
                            catch { toast = status("GeoData", L10n.t("更新失败：{0}", [error.localizedDescription])) }
                        }
                        Divider()
                        action(L10n.t("查看运行配置"), L10n.t("只读查看内核落盘的 config.json")) { showConfiguration = true }
                        Divider()
                        action(L10n.t("查看分流规则"), L10n.t("只读查看已下载的 rule-providers")) { showRules = true }
                    }.disabled(working)
                }
                ProductSection(title: L10n.t("关于"), icon: "info_outline") {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.t("当前版本"))
                            Link(destination: session.endpoints.site) {
                                HStack(spacing: 4) {
                                    Text(verbatim: session.endpoints.site.host()!)
                                    ProductGlyph(name: "open_in_new", size: 12)
                                }.foregroundStyle(colors.secondary)
                            }.font(.system(size: 12))
                            // tvOS 默认把 Link 绘成系统胶囊按钮
                            #if os(tvOS)
                            .buttonStyle(.productPlain)
                            #endif
                        }
                        Spacer(minLength: 0)
                        Text(ClientRelease.currentVersion)
                    }.padding(rowInsets)
                    Divider()
                    refreshRow(.app, L10n.t("检查更新"), appStatus ?? L10n.t("尚未检查"), help: L10n.t("检查客户端更新"), trailing: appOutdated ? AnyView(
                        Button(L10n.t("打开发布页") + " ›") { openURL(ClientRelease.releasesURL) }.buttonStyle(ProductButtonStyle())
                    ) : nil) {
                        do {
                            let result = try await session.checkClientUpdate()
                            appOutdated = result.outdated
                            appStatus = result.outdated ? L10n.t("发现新版本（{0}），需自行安装", [result.latest]) : L10n.t("已是最新（{0}）", [result.latest])
                        } catch is CancellationError { return }
                        catch { appStatus = L10n.t("检查失败：{0}", [error.localizedDescription]) }
                        toast = status(L10n.t("客户端"), appStatus ?? "")
                    }
                    Divider()
                    refreshRow(.kernel, L10n.t("mihomo 内核"), kernelStatus ?? L10n.t("正在读取版本…"), help: L10n.t("检查内核更新")) {
                        let current = (try? await session.kernelVersion()) ?? ""
                        do {
                            let latest = try await session.latestKernelVersion()
                            kernelChecked = true
                            kernelStatus = current.isEmpty ? L10n.t("本机版本未知，最新（{0}）", [latest])
                                : current != latest ? L10n.t("发现新版本（{0}），将随新版客户端提供，无需单独更新", [latest])
                                : L10n.t("已是最新（{0}）", [current])
                        } catch is CancellationError { return }
                        catch { kernelStatus = L10n.t("检查失败：{0}", [error.localizedDescription]) }
                        toast = status(L10n.t("内核"), kernelStatus ?? "")
                    }
                    Divider()
                    action(L10n.t("服务条款")) { document = .terms }
                    Divider()
                    action(L10n.t("隐私政策")) { document = .privacy }
                }
                if working && activity == .apply { ProgressView(L10n.t("正在应用新设置")) }
            }.padding(.leading, 14).padding(.trailing, 16).padding(.top, 16).padding(.bottom, 14)
        }
        .productToast($toast)
        .task(id: session.connection?.controlPlaneReady) {
            guard !kernelChecked else { return }
            let version = (try? await session.kernelVersion()) ?? ""
            if !kernelChecked { kernelStatus = version.isEmpty ? L10n.t("本机版本未知") : L10n.t("当前（{0}）", [version]) }
        }
        // 对应 settings_page.dart 以 MaterialPageRoute 推入整页
        .navigationDestination(item: $document) { kind in LegalDocumentView(session: session, kind: kind) }
        .navigationDestination(isPresented: $showRules) { RuleProvidersView(session: session) }
        .navigationDestination(isPresented: $showConfiguration) {
            TextViewerSheet(title: L10n.t("运行配置"), subtitle: "config.json") { try session.runtimeConfigurationText() }
        }
        .navigationDestination(isPresented: Binding(get: { segments != nil }, set: { if !$0 { segments = nil } })) {
            NetworkSegmentsEditor(session: session, routes: segments == true) { toast = $0 }
        }
        #if os(macOS)
        .onChange(of: scenePhase) { _, value in if value == .active { macSettings.refresh() } }
        #endif
    }
    private func status(_ name: String, _ text: String) -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : "\(name) · \(text)"
    }
    private func text(_ title: String, _ detail: String? = nil, edit: Bool? = nil, editEnabled: Bool? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 0) {
                Text(verbatim: title)
                if let edit, let editEnabled { editButton(routes: edit).environment(\.isEnabled, editEnabled) }
                else if let edit { editButton(routes: edit) }
            }
            if let detail { Text(verbatim: detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func settingToggle(_ title: String, detail: String? = nil, value: Binding<Bool>, edit: Bool? = nil) -> some View {
        Toggle(isOn: Binding(get: { value.wrappedValue }, set: { next in value.wrappedValue = next; run(.apply) { try await session.applyProxySettings() } })) {
            text(title, detail, edit: edit)
        }.toggleStyle(ProductToggleStyle()).padding(rowInsets)
    }
    private func editButton(routes: Bool) -> some View {
        let label = routes ? L10n.t("TUN 排除自定义网段") : L10n.t("系统代理绕过")
        return Button { segments = routes } label: {
            ProductGlyph(name: "settings_outlined", size: 20).foregroundStyle(colors.secondary)
                .frame(width: ProductMetrics.tapTarget, height: ProductMetrics.tapTarget).contentShape(Rectangle()).productIconHover()
        }.buttonStyle(.productPlain).help(label).accessibilityLabel(label)
    }
    private func action(_ title: String, _ detail: String? = nil, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            HStack(spacing: 12) {
                text(title, detail)
                ProductGlyph(name: "chevron_right", size: 24).foregroundStyle(colors.secondary)
            }.padding(rowInsets).contentShape(Rectangle()).productHoverLayer(Rectangle())
        }.buttonStyle(.productPlain)
    }
    private func refreshRow(_ kind: Activity, _ title: String, _ detail: String, help: String, progress: Bool = false,
                            trailing: AnyView? = nil, perform: @escaping @MainActor () async -> Void) -> some View {
        let busy = working && activity == kind
        let glyph = ProductRefreshGlyph(spinning: busy, size: 24).foregroundStyle(colors.secondary)
            .frame(width: ProductMetrics.tapTarget, height: ProductMetrics.tapTarget)
        // 整行与右侧刷新图标同属一个按钮，与 action 行一致；只有「打开发布页」单独可点
        return VStack(spacing: 0) {
            HStack(spacing: 4) {
                Button { run(kind, perform) } label: {
                    HStack(spacing: 4) {
                        text(title, detail)
                        if trailing == nil { glyph }
                    }.padding(.leading, 16).padding(.trailing, trailing == nil ? iconButtonInset : 0).padding(.vertical, 12)
                        .contentShape(Rectangle()).productHoverLayer(Rectangle())
                }.buttonStyle(.productPlain).help(help).accessibilityLabel(title)
                if let trailing {
                    trailing
                    Button { run(kind, perform) } label: { glyph.contentShape(Rectangle()).productIconHover() }
                        .buttonStyle(.productPlain).help(help).accessibilityLabel(help).padding(.trailing, iconButtonInset)
                }
            }
            if progress && busy { ProgressView().progressViewStyle(.linear).tint(colors.accent).padding(.horizontal, 16).padding(.bottom, 10) }
        }
    }
    private func applyPort() {
        guard let value = Int(port), (1025...65535).contains(value), value != session.preferences.mixedPort else { return }
        session.preferences.mixedPort = value; run(.apply) { try await session.applyProxySettings() }
    }
    private func run(_ kind: Activity, _ operation: @escaping @MainActor () async throws -> Void) {
        guard !working else { return }
        working = true; activity = kind
        Task {
            defer { working = false; activity = nil }
            do { try await operation() } catch is CancellationError {} catch { toast = error.localizedDescription }
        }
    }
}

private struct TextViewerSheet: View {
    let title: String
    let subtitle: String
    let load: @MainActor () async throws -> String
    @State private var lines: [String]?
    @State private var failure: String?
    @Environment(\.colorScheme) private var scheme
    // 对应 text_viewer_page.dart 的「复制全部」：有内容才显示；tvOS 没有剪贴板
    private var copyAction: AnyView? {
        #if os(tvOS)
        nil
        #else
        guard let lines, !lines.isEmpty else { return nil }
        return AnyView(Button {
            let text = lines.joined(separator: "\n")
            #if os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            #else
            UIPasteboard.general.string = text
            #endif
        } label: {
            ProductGlyph(name: "copy_all_outlined", size: 24).foregroundStyle(ProductPalette(scheme: scheme).text)
                .frame(width: 40, height: 40).contentShape(Rectangle()).productIconHover()
        }.help(L10n.t("复制全部")).accessibilityLabel(L10n.t("复制全部")))
        #endif
    }
    var body: some View {
        let colors = ProductPalette(scheme: scheme)
        FeatureSheet(title: title, appBar: true, action: copyAction) {
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: subtitle).font(.system(size: 12)).foregroundStyle(colors.secondary).padding(.horizontal, 16).padding(.vertical, 8)
                Group {
                    if let failure { Text(verbatim: failure).foregroundStyle(colors.danger).multilineTextAlignment(.center).padding(24) }
                    else if let lines, lines.isEmpty { Text(L10n.t("文件为空或不存在")) }
                    else if let lines {
                        // 单个 Text 超过图层纹理尺寸上限时整块空白，大文件须逐行渲染
                        ScrollView {
                            #if os(tvOS)
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(stride(from: 0, to: lines.count, by: 40)), id: \.self) { start in
                                    Text(verbatim: lines[start..<min(start + 40, lines.count)].joined(separator: "\n")).padding(6).productScrollStop()
                                }
                            }.font(.system(size: 12, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                            #else
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(lines.indices, id: \.self) { Text(verbatim: lines[$0]) }
                            }.font(.system(size: 12, design: .monospaced)).productTextSelection()
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.bottom, 16)
                            #endif
                        }
                    } else { ProgressView() }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.task {
            do {
                let text = try await load()
                lines = text.isEmpty ? [] : text.components(separatedBy: "\n")
            } catch is CancellationError {} catch { failure = error.localizedDescription }
        }
    }
}

// 首页代理开关与设置页共用，对应 app/lib/ui/pages/network_segments_page.dart。
struct NetworkSegmentsEditor: View {
    let session: ClientSession
    let routes: Bool
    var finished: (String) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var items: [String] = []
    @State private var input = ""
    @State private var error: String?
    @State private var working = false
    var body: some View {
        let colors = ProductPalette(scheme: scheme)
        FeatureSheet(title: routes ? L10n.t("排除自定义网段") : L10n.t("系统代理绕过"), working: working, appBar: true,
                     action: AnyView(Button(L10n.t("保存"), action: save).buttonStyle(ProductButtonStyle(filled: true)).disabled(working))) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !routes {
                        Text(L10n.t("默认绕过")).font(.system(size: 12)).foregroundStyle(colors.secondary).padding(.bottom, 8)
                        ProductFlow(spacing: 6, runSpacing: 6) { ForEach(NetworkSegments.proxyDefaults, id: \.self) { ProductTag(text: $0) } }
                        Text(L10n.t("自定义")).font(.system(size: 12)).foregroundStyle(colors.secondary).padding(.top, 14).padding(.bottom, 8)
                    }
                    if items.isEmpty {
                        Text(L10n.t("尚未添加")).font(.system(size: 12)).foregroundStyle(colors.secondary)
                    } else {
                        ProductFlow(spacing: 6, runSpacing: 6) {
                            ForEach(items, id: \.self) { item in
                                HStack(spacing: 6) {
                                    Text(verbatim: item).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                    Button { items.removeAll { $0 == item } } label: { ProductGlyph(name: "close", size: 16).foregroundStyle(colors.danger) }
                                        .buttonStyle(.productPlain).disabled(working).accessibilityLabel(L10n.t("删除"))
                                }
                                .foregroundStyle(colors.text).padding(.horizontal, 8).frame(minHeight: 32)
                                .overlay(Capsule().strokeBorder(colors.outline, lineWidth: 1))
                            }
                        }
                    }
                    HStack(alignment: .top, spacing: 8) {
                        ProductTextField(hint: "192.168.56.0/24", text: $input, onSubmit: add)
                        Button(L10n.t("添加"), action: add).buttonStyle(ProductButtonStyle(filled: true)).disabled(working)
                    }.padding(.top, 12)
                    if let error { Text(verbatim: error).font(.system(size: 12)).foregroundStyle(colors.danger).padding(.top, 8) }
                    Text(routes ? L10n.t("仅支持 IPv4/IPv6 CIDR，例如 192.168.56.0/24 或 fd00::/8；局域网与回环已默认排除") : L10n.t("追加到默认列表，例如 192.168.56.0/24 或 *.local"))
                        .font(.system(size: 12)).foregroundStyle(colors.secondary).padding(.top, 8)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 14).padding(.trailing, 16).padding(.vertical, 14)
            }
        }
        .onAppear { items = routes ? session.preferences.excludedRoutes : session.preferences.systemProxyBypass }
    }
    private func add() {
        guard !NetworkSegments.split(input).isEmpty else { error = L10n.t("请输入网段"); return }
        do {
            let candidates = try NetworkSegments.parse(input, routes: routes)
            guard !candidates.contains(where: { items.contains($0) || (!routes && NetworkSegments.proxyDefaults.contains($0)) }) else {
                error = L10n.t("已存在"); return
            }
            items += candidates; error = nil; input = ""
        } catch { self.error = error.localizedDescription }
    }
    private func save() {
        let values: [String]
        do { values = try NetworkSegments.parse(items.joined(separator: "\n"), routes: routes) }
        catch { self.error = error.localizedDescription; return }
        if routes { session.preferences.excludedRoutes = values } else { session.preferences.systemProxyBypass = values }
        working = true; error = nil
        Task {
            defer { working = false }
            do { try await session.applyProxySettings(); finished(L10n.t("保存成功")) }
            catch is CancellationError {} catch { finished(L10n.t("保存失败：{0}", [error.localizedDescription])) }
            dismiss()
        }
    }
}

private struct RuleProvidersView: View {
    let session: ClientSession
    @State private var providers: [RuleProviderInfo] = []
    @State private var selected: RuleProviderInfo?
    @State private var notice: String?
    @State private var working = true
    @Environment(\.colorScheme) private var scheme
    // 对应 rule_providers_page.dart 顶部的规则目录；运行目录由内核侧管理，只显示各规则共用的保存目录
    private var directory: String? {
        let parents = Set(providers.map { ($0.path as NSString).deletingLastPathComponent })
        return parents.count == 1 ? parents.first.flatMap { $0.isEmpty ? nil : $0 } : nil
    }
    var body: some View {
        let colors = ProductPalette(scheme: scheme)
        FeatureSheet(title: L10n.t("分流规则"), working: working, appBar: true) {
            Group {
                if let notice { Text(verbatim: notice).foregroundStyle(colors.danger).multilineTextAlignment(.center).padding(24) }
                else if working { ProgressView() }
                else if providers.isEmpty {
                    Text(L10n.t("暂无分流规则。连接一次后，规则会下载到运行目录。")).multilineTextAlignment(.center).padding(24)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            if let directory {
                                Text(verbatim: directory).font(.system(size: 12)).foregroundStyle(colors.secondary)
                                    .padding(EdgeInsets(top: 8, leading: 16, bottom: 12, trailing: 16))
                                Divider().overlay(colors.segment)
                            }
                            ForEach(Array(providers.enumerated()), id: \.element.id) { index, provider in
                                if index > 0 { Divider().overlay(colors.segment) }
                                Button { selected = provider } label: {
                                    HStack(spacing: 16) {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(verbatim: provider.name)
                                            Text(verbatim: provider.path).font(.system(size: 12)).foregroundStyle(colors.secondary)
                                        }.frame(maxWidth: .infinity, alignment: .leading)
                                        ProductGlyph(name: "chevron_right", size: 24).foregroundStyle(colors.secondary)
                                    }.padding(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 24)).contentShape(Rectangle()).productHoverLayer(Rectangle())
                                }.buttonStyle(.productPlain)
                            }
                        }.padding(.vertical, 8).padding(.trailing, 16)
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.task {
            defer { working = false }
            do { providers = try await session.ruleProviders() } catch { notice = error.localizedDescription }
        }
        .navigationDestination(isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
            if let provider = selected {
                TextViewerSheet(title: provider.name, subtitle: provider.path) { try await session.readRuleProvider(provider.name) }
            }
        }
    }
}
