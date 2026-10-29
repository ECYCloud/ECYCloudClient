import SwiftUI
import ECYCloudKit

struct SubscriptionStrategyView: View {
    let session: ClientSession
    @State private var state = FeatureState<SubscriptionStrategy>()
    @State private var tab = 0
    @State private var disabled: Set<String> = []
    @State private var hosts = ""
    @State private var rules = ""
    @State private var groups: [CustomProxyGroup] = []
    @State private var providers: [CustomRuleProvider] = []
    @State private var groupDraft = CustomProxyGroup()
    @State private var editingGroup: UUID?
    @State private var deletingGroup: CustomProxyGroup?
    @State private var providerDraft = CustomRuleProvider(policy: "DIRECT")
    @State private var editingProvider: UUID?
    @FocusState private var editorFocus: Int?
    @Environment(\.colorScheme) private var scheme
    init(session: ClientSession, initialTab: Int = 0) {
        self.session = session
        _tab = State(initialValue: initialTab)
    }
    var body: some View {
        FeatureSheet(title: L10n.t("自定义策略"), working: state.working) {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(0..<2) { index in
                        Button { tab = index } label: {
                            Text(index == 0 ? L10n.t("分组策略") : L10n.t("配置策略")).fontWeight(.semibold)
                                .frame(maxWidth: .infinity, minHeight: 48)
                                .foregroundStyle(tab == index ? ProductPalette(scheme: scheme).accent : ProductPalette(scheme: scheme).secondary)
                                .overlay(alignment: .bottom) {
                                    if tab == index { Capsule().fill(ProductPalette(scheme: scheme).accent).frame(width: 60, height: 3) }
                                }
                        }.buttonStyle(.productPlain).accessibilityAddTraits(tab == index ? [.isSelected] : [])
                    }
                }.background(ProductPalette(scheme: scheme).surface)
                FeatureScreen(state: state, reload: { await load() }, showsRefresh: false, topPadding: 14) { config in
                    if tab == 0 { groupSections(config) } else { configSections(config) }
                }.disabled(state.working)
            }
        }.task(id: session.preferences.language.rawValue) { await load(labelsOnly: state.value != nil) }
        .alert(L10n.t("确认删除"), isPresented: Binding(get: { deletingGroup != nil }, set: { if !$0 { deletingGroup = nil } }), presenting: deletingGroup) { group in
            Button(L10n.t("确定")) { remove(group) }
            Button(L10n.t("取消"), role: .cancel) {}
        } message: { group in
            Text(verbatim: L10n.t("确定要删除自定义策略组「{0}」吗？", [String(describing: group.name)]))
        }
    }
    @ViewBuilder private func groupSections(_ config: SubscriptionStrategy) -> some View {
        let base = config.allGroupNames.filter { config.customizableGroups.contains($0) }
        let toggleable = base + (config.allowCustomGroups ? groups.map(\.name).filter { !$0.isEmpty && !base.contains($0) } : [])
        ProductCard(title: L10n.t("策略组开关"), icon: "tune") {
            Text(L10n.t("开启或关闭策略组，保存后刷新配置生效")).font(.system(size: 12)).foregroundStyle(.secondary)
            if toggleable.isEmpty { Text(config.customizableGroups.isEmpty && !config.allowCustomGroups ? L10n.t("管理员未开放分组自定义功能") : L10n.t("暂无可自定义的策略组")) }
            ForEach(toggleable, id: \.self) { name in
                let enabled = Binding(get: { !disabled.contains(name) }, set: { if $0 { disabled.remove(name) } else { disabled.insert(name) } })
                Toggle(isOn: enabled) {
                    HStack(spacing: 10) {
                        ProductGroupIcon(session: session, url: toggleIcon(config, name), size: 20)
                        Text(verbatim: config.groupLabels[name] ?? name)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    .onTapGesture { enabled.wrappedValue.toggle() }
                }.toggleStyle(ProductToggleStyle()).padding(.vertical, 4)
            }
            if !toggleable.isEmpty {
                Button(L10n.t("保存分组配置")) { Task { await save(disabled: disabled.sorted()) } }
                    .buttonStyle(ProductButtonStyle(filled: true)).frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        if config.allowCustomGroups {
            ProductCard(title: L10n.t("自定义策略组"), icon: "add_circle_outline") {
                Text(L10n.t("仅支持手动选择（select）。下方可引用核心策略组与内置出站；图标可填自定义 URL。最多 {0} 个。", [String(describing: config.maxCustomGroups)]))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                if groups.isEmpty { Text(L10n.t("尚未添加自定义策略组")) }
                ForEach(groups) { group in
                    if editingGroup == group.id { groupForm(config) }
                    else {
                        HStack(spacing: 10) {
                            ProductGroupIcon(session: session, url: group.icon, size: 20)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(verbatim: group.name)
                                Text(([group.includeNodes ? L10n.t("全部节点") : nil, group.proxies.isEmpty ? nil : L10n.t("{0} 引用", [String(describing: group.proxies.count)])].compactMap { $0 }).joined(separator: " · "))
                                    .font(.system(size: 12)).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Button(L10n.t("编辑")) { editingGroup = group.id; groupDraft = group }.buttonStyle(ProductButtonStyle())
                            Button(L10n.t("删除")) { deletingGroup = group }.buttonStyle(ProductButtonStyle())
                        }
                    }
                }
                if editingGroup == nil { groupForm(config) }
            }
        }
    }
    private func groupForm(_ config: SubscriptionStrategy) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ProductTextField(hint: L10n.t("策略组名称"), text: $groupDraft.name)
            ProductTextField(hint: L10n.t("图标 URL（可选）"), text: Binding(get: { groupDraft.icon ?? "" }, set: { groupDraft.icon = $0.isEmpty ? nil : $0 }))
            Toggle(L10n.t("包含全部节点"), isOn: $groupDraft.includeNodes).toggleStyle(ProductToggleStyle()).padding(.vertical, 4)
            Text(L10n.t("引用策略组")).font(.system(size: 12)).foregroundStyle(.secondary)
            ProductFlow(spacing: 4) {
                ForEach(config.availableProxyNames, id: \.self) { name in
                    let selected = groupDraft.proxies.contains(name)
                    Button {
                        if selected { groupDraft.proxies.removeAll { $0 == name } }
                        else { groupDraft.proxies.append(name) }
                    } label: {
                        HStack(spacing: 4) {
                            if selected { ProductGlyph(name: "check", size: 16) }
                            Text(verbatim: config.groupLabels[name] ?? name)
                        }
                    }.buttonStyle(StrategyChipStyle(selected: selected)).accessibilityAddTraits(selected ? [.isSelected] : [])
                }
            }
            HStack(spacing: 8) {
                Button(editingGroup == nil ? L10n.t("添加") : L10n.t("保存")) { Task { await commitGroup(config) } }.buttonStyle(ProductButtonStyle(filled: true))
                if editingGroup != nil { Button(L10n.t("取消"), action: clearGroup).buttonStyle(ProductButtonStyle()) }
            }
        }
    }
    @ViewBuilder private func configSections(_ config: SubscriptionStrategy) -> some View {
        if !config.allowCustomHosts && !config.allowCustomRules && !config.allowCustomRuleProviders {
            Text(L10n.t("管理员未开放自定义配置功能")).frame(maxWidth: .infinity).padding(.vertical, 60)
        }
        if config.allowCustomHosts {
            ProductCard(title: L10n.t("自定义 Host"), icon: "dns_outlined") {
                Text(L10n.t("每行一条：domain = ip。最多 {0} 条。", [String(describing: config.maxCustomHosts)])).font(.system(size: 12)).foregroundStyle(.secondary)
                editor($hosts, hint: "example.com = 1.2.3.4", focus: 0)
            }
        }
        if config.allowCustomRules {
            ProductCard(title: L10n.t("自定义分流规则"), icon: "alt_route") {
                Text(L10n.t("每行一条：TYPE,value,POLICY。最多 {0} 条。", [String(describing: config.maxCustomRules)])).font(.system(size: 12)).foregroundStyle(.secondary)
                editor($rules, hint: "DOMAIN-SUFFIX,example.com,DIRECT", focus: 1)
            }
        }
        if config.allowCustomHosts || config.allowCustomRules {
            Button(L10n.t("保存配置策略")) { Task { await save(hosts: config.allowCustomHosts ? hosts : nil, rules: config.allowCustomRules ? rules : nil) } }
                .buttonStyle(ProductButtonStyle(filled: true)).frame(maxWidth: .infinity, alignment: .trailing)
        }
        if config.allowCustomRuleProviders {
            ProductCard(title: L10n.t("远程规则集"), icon: "cloud_download_outlined") {
                Text(L10n.t("填写规则集 URL 并选择策略。需同时在上方设置自定义分流规则。最多 {0} 个。", [String(describing: config.maxCustomRuleProviders)]))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                if providers.isEmpty { Text(L10n.t("尚未添加远程规则集")) }
                ForEach(providers) { provider in
                    if editingProvider == provider.id { providerForm(config) }
                    else {
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(verbatim: provider.url)
                                Text(verbatim: config.groupLabels[provider.policy] ?? provider.policy).font(.system(size: 12)).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Button(L10n.t("编辑")) { beginEdit(provider, config) }.buttonStyle(ProductButtonStyle())
                            Button(L10n.t("删除")) { removeProvider(provider) }.buttonStyle(ProductButtonStyle())
                        }
                    }
                }
                if editingProvider == nil { providerForm(config) }
                HStack(spacing: 8) {
                    if editingProvider == nil {
                        Button(L10n.t("添加")) { Task { await commitProvider(config) } }.buttonStyle(ProductButtonStyle(filled: true))
                    }
                    Button(L10n.t("保存远程规则集")) { Task { await save(providers: providers) } }.buttonStyle(ProductButtonStyle(filled: true))
                }
            }
        }
    }
    private func providerForm(_ config: SubscriptionStrategy) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ProductTextField(hint: L10n.t("规则集 URL"), text: $providerDraft.url)
            HStack(spacing: 12) {
                Text(L10n.t("策略"))
                ProductDropdown(values: policies(config), selection: $providerDraft.policy) { config.groupLabels[$0] ?? $0 }
            }
            if editingProvider != nil {
                HStack(spacing: 8) {
                    Button(L10n.t("保存")) { Task { await commitProvider(config) } }.buttonStyle(ProductButtonStyle(filled: true))
                    Button(L10n.t("取消"), action: clearProvider).buttonStyle(ProductButtonStyle())
                }
            }
        }
    }
    private func policies(_ config: SubscriptionStrategy) -> [String] {
        var seen: Set<String> = []
        return (["DIRECT", "REJECT", "REJECT-TINYGIF"] + config.allGroupNames + config.customGroups.map(\.name)).filter { !$0.isEmpty && seen.insert($0).inserted }
    }
    private func toggleIcon(_ config: SubscriptionStrategy, _ name: String) -> String? {
        if let icon = config.groupIcons?.values[name], !icon.isEmpty { return icon }
        return groups.first { $0.name == name }?.icon
    }
    private func remove(_ group: CustomProxyGroup) {
        groups.removeAll { $0.id == group.id }; disabled.remove(group.name)
        if editingGroup == group.id { clearGroup() }
        Task { await save(groups: groups) }
    }
    private func beginEdit(_ provider: CustomRuleProvider, _ config: SubscriptionStrategy) {
        editingProvider = provider.id; providerDraft = provider
        let options = policies(config)
        if !options.contains(providerDraft.policy) { providerDraft.policy = options.first ?? "" }
    }
    private func removeProvider(_ provider: CustomRuleProvider) {
        providers.removeAll { $0.id == provider.id }
        if editingProvider == provider.id { clearProvider() }
    }
    private func commitGroup(_ config: SubscriptionStrategy) async {
        groupDraft.name = groupDraft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !groupDraft.name.isEmpty else { state.message = L10n.t("请填写策略组名称"); return }
        guard editingGroup != nil || groups.count < config.maxCustomGroups else { state.message = L10n.t("最多添加 {0} 个自定义策略组", [String(describing: config.maxCustomGroups)]); return }
        guard !groups.contains(where: { $0.id != editingGroup && $0.name == groupDraft.name }) else { state.message = L10n.t("策略组名称已存在"); return }
        let icon = groupDraft.icon?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard icon.isEmpty || icon.hasPrefix("/") || webURL(icon) else { state.message = L10n.t("图标须为 http(s) 链接或站点根路径"); return }
        groupDraft.icon = icon.isEmpty ? nil : icon
        groupDraft.proxies = config.availableProxyNames.filter { groupDraft.proxies.contains($0) }
        if let index = groups.firstIndex(where: { $0.id == editingGroup }) { groups[index] = groupDraft } else { groups.append(groupDraft) }
        clearGroup()
        await save(groups: groups)
    }
    private func commitProvider(_ config: SubscriptionStrategy) async {
        providerDraft.url = providerDraft.url.trimmingCharacters(in: .whitespacesAndNewlines)
        let options = policies(config)
        if !options.contains(providerDraft.policy) { providerDraft.policy = options.first ?? "" }
        guard !providerDraft.url.isEmpty else { state.message = L10n.t("请填写规则集 URL"); return }
        guard webURL(providerDraft.url) else { state.message = L10n.t("URL 须为 http(s) 链接"); return }
        guard !providerDraft.policy.isEmpty else { state.message = L10n.t("请选择策略"); return }
        guard editingProvider != nil || providers.count < config.maxCustomRuleProviders else { state.message = L10n.t("最多添加 {0} 个远程规则集", [String(describing: config.maxCustomRuleProviders)]); return }
        let index = providers.firstIndex { $0.id == editingProvider }
        if index.map({ providers[$0].url != providerDraft.url }) ?? true {
            providerDraft.name = ""; providerDraft.behavior = ""; providerDraft.format = ""; providerDraft.interval = 0
        }
        if let index { providers[index] = providerDraft } else { providers.append(providerDraft) }
        clearProvider()
        if index != nil { await save(providers: providers) }
    }
    private func webURL(_ text: String) -> Bool {
        guard let url = ClientLink.external(text) else { return false }
        return url.scheme == "http" || url.scheme == "https"
    }
    private func clearGroup() { groupDraft = CustomProxyGroup(); editingGroup = nil }
    private func clearProvider() { providerDraft = CustomRuleProvider(policy: "DIRECT"); editingProvider = nil }
    private func editor(_ text: Binding<String>, hint: String, focus: Int) -> some View {
        let colors = ProductPalette(scheme: scheme)
        let lines = min(6, max(4, text.wrappedValue.split(separator: "\n", omittingEmptySubsequences: false).count))
        return ProductTextEditor(text: text).font(.system(size: 13))
            #if !os(tvOS)
            .scrollContentBackground(.hidden)
            #endif
            .focused($editorFocus, equals: focus)
            .frame(height: CGFloat(lines) * 17 + 8)
            .padding(.horizontal, 12).padding(.vertical, 8)
            #if !os(tvOS)
            .overlay(alignment: .topLeading) {
                if text.wrappedValue.isEmpty {
                    Text(verbatim: hint).font(.system(size: 12)).foregroundStyle(colors.secondary)
                        .padding(.horizontal, 17).padding(.vertical, 16).allowsHitTesting(false)
                }
            }
            #endif
            .background(colors.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(editorFocus == focus ? colors.accent : colors.segment, lineWidth: 1))
    }
    private func save(disabled: [String]? = nil, hosts: String? = nil, rules: String? = nil, groups: [CustomProxyGroup]? = nil, providers: [CustomRuleProvider]? = nil) async {
        let saved = await state.perform {
            let message = try await session.saveSubscriptionStrategy(disabled: disabled, hosts: hosts, rules: rules, groups: groups, providers: providers)
            return message.isEmpty ? L10n.t("保存成功") : message
        }
        if saved { await load() }
    }
    private func load(labelsOnly: Bool = false) async {
        await state.load { try await session.subscriptionStrategy() }
        guard !labelsOnly, let config = state.value, state.failure == nil, !Task.isCancelled else { return }
        disabled = Set(config.disabledGroups); hosts = config.customHosts; rules = config.customRules
        groups = config.customGroups; providers = config.customRuleProviders
        clearGroup(); clearProvider()
    }
}

private struct StrategyChipStyle: ButtonStyle {
    let selected: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isFocused) private var focused
    func makeBody(configuration: Configuration) -> some View {
        let colors = ProductPalette(scheme: scheme)
        configuration.label
            .font(.system(size: 12, weight: .semibold)).foregroundStyle(colors.text)
            .padding(.horizontal, 12).frame(minHeight: 32)
            .background(selected ? colors.accent.opacity(0.14) : Color.clear, in: Capsule())
            .overlay(Capsule().strokeBorder(colors.outline, lineWidth: 1))
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
            #if os(tvOS)
            .overlay(Capsule().strokeBorder(focused ? colors.accent : .clear, lineWidth: 3))
            #endif
    }
}
