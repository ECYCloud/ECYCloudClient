import SwiftUI
import ECYCloudKit

struct ProductRefreshAction: Equatable {
    let id: String
    let disabled: Bool
    let run: @MainActor () async -> Void
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id && lhs.disabled == rhs.disabled }
}
struct ProductRefreshKey: PreferenceKey {
    static let defaultValue: ProductRefreshAction? = nil
    static func reduce(value: inout ProductRefreshAction?, nextValue: () -> ProductRefreshAction?) {
        if let next = nextValue() { value = next }
    }
}

@MainActor @Observable
final class FeatureState<Value> {
    var value: Value?
    var loading = false
    var working = false
    var failure: String?
    var message: String?
    private var generation = UUID()

    func load(_ request: () async throws -> Value) async {
        let id = UUID(); generation = id; loading = true; failure = nil
        defer { if generation == id { loading = false } }
        do {
            let result = try await request()
            try Task.checkCancellation()
            if generation == id { value = result }
        } catch is CancellationError { }
        catch { if generation == id { failure = (error as? ClientError)?.localizedDescription ?? (error as? TunnelError)?.localizedDescription ?? L10n.t("加载失败，请重试。") } }
    }
    @discardableResult func perform(_ action: () async throws -> String) async -> Bool {
        guard !working else { return false }
        working = true; message = nil
        defer { working = false }
        do { let result = try await action(); message = result.isEmpty ? nil : result; return true }
        catch is CancellationError { return false }
        catch { message = (error as? ClientError)?.localizedDescription ?? (error as? TunnelError)?.localizedDescription ?? L10n.t("操作未完成，请重试。"); return false }
    }
}

struct FeatureScreen<Value, Content: View>: View {
    let state: FeatureState<Value>
    let reload: @MainActor () async -> Void
    var showsRefresh = true
    var embedded = false
    var topPadding: CGFloat = 16
    @ViewBuilder var content: (Value) -> Content
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Group {
            if embedded { contents }
            else { ScrollView { contents } }
        }
        .background(ProductPalette(scheme: scheme).background)
        .preference(key: ProductRefreshKey.self, value: showsRefresh ? ProductRefreshAction(id: String(describing: Value.self), disabled: state.loading || state.working, run: reload) : nil)
        .refreshable { await reload() }
        .productToast(Binding(get: { state.message }, set: { state.message = $0 }))
    }
    private var contents: some View {
        VStack(alignment: .leading, spacing: 12) {
            if state.value == nil && state.loading { ProgressView().frame(maxWidth: .infinity).padding(.top, 80) }
            if let failure = state.failure {
                ProductNotice(message: failure)
                Button(L10n.t("重试")) { Task { await reload() } }.buttonStyle(ProductButtonStyle())
            }
            if let value = state.value { content(value) }
        }.padding(.leading, embedded ? 0 : 14).padding(.trailing, embedded ? 0 : 16)
            .padding(.top, embedded ? 0 : topPadding).padding(.bottom, embedded ? 0 : 14)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
struct FeatureSheet<Content: View>: View {
    let title: String
    var working = false
    // 对应 Flutter AppBar（AppScaffold.appBar）：高 56，返回键居中于 56 宽的前导区，标题 16 号紧随其后 16
    var appBar = false
    // 对应 PageHeader(showUserAvatar:)：推入的二级页右上角带头像菜单；AppBar 页与弹层不带
    var avatar = true
    var onAccount = false
    var action: AnyView?
    @ViewBuilder var content: Content
    @Environment(AccountMenu.self) private var menu: AccountMenu?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var refresh: ProductRefreshAction?
    var body: some View {
        VStack(spacing: 0) {
            // 非 AppBar 页对应 page_header.dart：返回键左缘按 14 减图标内缩，与标题隔 8，标题 22 号单行省略
            HStack(spacing: appBar ? 0 : 8) {
                Button { dismiss() } label: {
                    Image(systemName: "arrow.left").font(.system(size: 20))
                        .frame(width: appBar ? 32 : ProductMetrics.tapTarget, height: appBar ? 40 : ProductMetrics.tapTarget).productIconHover()
                }
                    .disabled(working).accessibilityLabel(L10n.t("返回")).frame(width: appBar ? 56 : nil)
                Text(verbatim: title).font(.system(size: appBar ? 16 : 22, weight: .semibold)).tracking(appBar ? 0 : -0.66).lineLimit(1).padding(.leading, appBar ? 16 : 0)
                Spacer()
                if let refresh {
                    Button { if !refresh.disabled { Task { await refresh.run() } } } label: {
                        ProductRefreshGlyph(spinning: refresh.disabled).frame(width: ProductMetrics.tapTarget, height: ProductMetrics.tapTarget).contentShape(Rectangle()).productIconHover()
                    }
                        .accessibilityLabel(L10n.t("刷新"))
                }
                if let action { action }
                if avatar && !appBar && menu != nil { AccountAvatarButton(onAccount: onAccount).padding(.leading, 14) }
            }.buttonStyle(.productPlain).padding(appBar ? EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 14) : EdgeInsets(top: 16, leading: 14 - (ProductMetrics.tapTarget - 20) / 2, bottom: 16, trailing: 16))
                .frame(height: appBar ? 56 : nil).productFocusSection()
            content
        }.font(.system(size: 13))
        .foregroundStyle(ProductPalette(scheme: scheme).text)
        .background(ProductPalette(scheme: scheme).background)
        .productMenuHost()
        .interactiveDismissDisabled(working)
        .toolbar(.hidden)
        .onPreferenceChange(ProductRefreshKey.self) { refresh = $0 }
        .onChange(of: menu?.rootRequest) { dismiss() }
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 700, minHeight: 540, idealHeight: 720)
        #endif
    }
}
struct SafeHTML: View {
    let html: String
    let origin: URL
    @State private var document: RichDocument?
    @State private var failed = false
    var body: some View {
        Group {
            if let document { RichDocumentText(document: document).productTextSelection() }
            else if failed { ProductNotice(message: L10n.t("正文格式无效，无法显示。")) }
            else { ProgressView() }
        }.task(id: html) {
            do { document = try RichDocument(html: html, origin: origin); failed = false }
            catch { document = nil; failed = true }
        }
    }
}
struct DetailLine: View {
    let title: String
    let value: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(verbatim: title).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(verbatim: value).multilineTextAlignment(.trailing).productTextSelection()
        }.padding(.vertical, 2.5)
    }
}
struct PageButtons: View {
    let current: Int, last: Int, total: Int
    var disabled = false
    let change: (Int) -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var jump = ""
    private var pageNumbers: [Int] {
        if last <= 7 { return Array(1...max(1, last)) }
        return Set([1, current - 1, current, current + 1, last]).filter { $0 >= 1 && $0 <= last }.sorted()
    }
    var body: some View {
        // 对应 list_toolbar.dart 的 Wrap(alignment: end)：统计、页码、跳页依次靠右排列，放不下时逐段换行
        ProductFlow(spacing: 14, trailing: true, runSpacing: 8) { stats; controls; jumpControls }.padding(.vertical, 12)
    }
    private var stats: some View { Text(L10n.t("共 {0} 条 · 第 {1}/{2} 页", [String(describing: total), String(describing: current), String(describing: max(1, last))])).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize() }
    private var controls: some View {
        HStack(spacing: 4) {
            pageButton(L10n.t("上页"), enabled: current > 1) { change(current - 1) }
            ForEach(Array(pageNumbers.enumerated()), id: \.element) { index, number in
                if index > 0 && number - pageNumbers[index - 1] > 1 { Text("…") }
                pageButton(String(number), selected: number == current) { change(number) }
            }
            pageButton(L10n.t("下页"), enabled: current < last) { change(current + 1) }
        }
    }
    private var jumpControls: some View {
        HStack(spacing: 4) {
            TextField(L10n.t("跳页"), text: $jump).textFieldStyle(.plain).font(.system(size: 12))
                .productTextFieldFit()
                .padding(.horizontal, 10 - ProductMetrics.textFieldInset).frame(width: 80, height: 32).productTextFieldClip()
                .overlay(Capsule().strokeBorder(ProductPalette(scheme: scheme).outline, lineWidth: 1))
                .onSubmit(jumpToPage)
            pageButton(L10n.t("确定"), action: jumpToPage)
        }.fixedSize()
    }
    private func jumpToPage() { if let number = Int(jump) { change(min(max(number, 1), max(last, 1))) } }
    private func pageButton(_ title: String, selected: Bool = false, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        let colors = ProductPalette(scheme: scheme)
        return Button(action: action) {
            Text(verbatim: title).font(.system(size: 12, weight: .semibold)).padding(.horizontal, title.count > 1 ? 10 : 4)
                .frame(minWidth: 32, minHeight: 32).foregroundStyle(selected ? colors.surface : colors.text)
                .background(selected ? colors.text : colors.background, in: Capsule())
                .overlay(Capsule().strokeBorder(selected ? colors.text : colors.outline, lineWidth: 1))
        }.buttonStyle(.productPlain).disabled(disabled || !enabled).opacity(enabled ? 1 : 0.4)
    }
}

struct ProductTable: View {
    let columns: [String]
    // 对应 simple_data_table.dart 的 _mobileValue：宽表靠左的操作按钮，窄屏卡片里翻到行末
    var actionColumn: Int?
    let rows: [[AnyView]]
    var empty = L10n.t("暂无数据")
    var minimumWidth: CGFloat?
    var sortColumn: Int?
    var ascending = true
    var sort: ((Int) -> Void)?
    var selectedRow: Int?
    var select: ((Int) -> Void)?
    var expanded: AnyView?
    var footer: [AnyView]?
    @Environment(\.colorScheme) private var scheme
    private var colors: ProductPalette { ProductPalette(scheme: scheme) }
    var body: some View {
        Group {
            if rows.isEmpty { Text(verbatim: empty).foregroundStyle(colors.secondary).padding(.vertical, 32).frame(maxWidth: .infinity) }
            else {
                ViewThatFits(in: .horizontal) {
                    table(wide: true).frame(minWidth: minimumWidth ?? min(1600, max(360, CGFloat(columns.count) * 140)))
                    table(wide: false)
                }
            }
        }.font(.system(size: 12)).background(colors.surface).clipShape(RoundedRectangle(cornerRadius: 20))
    }
    private func table(wide: Bool) -> some View {
        VStack(spacing: 0) {
            if wide {
                HStack(spacing: 0) {
                    ForEach(columns.indices, id: \.self) { column in
                        header(column).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 12)
                    }
                }
            }
            ForEach(rows.indices, id: \.self) { row in
                if wide || row > 0 { Divider().overlay(colors.segment) }
                Group {
                    if let select { Button { select(row) } label: { cells(rows[row], wide: wide) }.buttonStyle(.productPlain) }
                    else { cells(rows[row], wide: wide) }
                }
                .background(selectedRow == row ? colors.accent.opacity(scheme == .dark ? 0.18 : 0.08) : Color.clear)
                .overlay(alignment: .leading) { if selectedRow == row { Rectangle().fill(colors.accent).frame(width: 3) } }
                if selectedRow == row, let expanded { expanded }
            }
            if let footer { Divider().overlay(colors.segment); cells(footer, wide: wide).fontWeight(.semibold) }
        }
    }
    @ViewBuilder private func header(_ column: Int) -> some View {
        if let sort {
            Button { sort(column) } label: {
                HStack(spacing: 4) {
                    Text(verbatim: columns[column])
                    Image(systemName: sortColumn == column ? (ascending ? "arrow.up" : "arrow.down") : "arrow.up.arrow.down").font(.system(size: 10))
                }
            }.buttonStyle(.productPlain).fontWeight(.semibold).foregroundStyle(colors.secondary)
        } else { Text(verbatim: columns[column]).fontWeight(.semibold).foregroundStyle(colors.secondary) }
    }
    @ViewBuilder private func cells(_ values: [AnyView], wide: Bool) -> some View {
        if wide {
            HStack(spacing: 0) {
                ForEach(columns.indices, id: \.self) { column in
                    values[column].frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 12)
                }
            }.contentShape(Rectangle())
        } else {
            VStack(spacing: 6) {
                ForEach(columns.indices, id: \.self) { column in
                    HStack(alignment: .top, spacing: 8) {
                        Text(verbatim: columns[column]).foregroundStyle(colors.secondary).frame(width: 96, alignment: .leading)
                        values[column].frame(maxWidth: .infinity, alignment: column == actionColumn ? .trailing : .leading)
                    }
                }
            }.padding(.horizontal, 12).padding(.vertical, 13).contentShape(Rectangle())
        }
    }
}
