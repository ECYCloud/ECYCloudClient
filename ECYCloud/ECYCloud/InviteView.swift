import SwiftUI
import ECYCloudKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct InviteView: View {
    let session: ClientSession
    @State private var state = FeatureState<InviteSummary>()
    @State private var pages = [1, 1]
    @State private var searches = ["", ""]
    @State private var tab = 0
    @State private var resetting = false
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let colors = ProductPalette(scheme: scheme)
        FeatureScreen(state: state, reload: load) { value in
            ProductCard(title: L10n.t("邀请信息"), icon: "link") {
                VStack(alignment: .leading, spacing: 0) {
                    Text(L10n.t("邀请他人注册时，请将以下链接发送给被邀请者")).font(.system(size: 14)).foregroundStyle(colors.secondary).padding(.bottom, 8)
                    copyRow(L10n.t("邀请链接"), value.inviteUrl).padding(.bottom, 8)
                    copyRow(L10n.t("邀请码"), value.code)
                    Divider().padding(.vertical, 10)
                    DetailLine(title: L10n.t("邀请人数"), value: "\(value.invitedUsersCount)")
                    DetailLine(title: L10n.t("返利人数"), value: "\(value.rebateUsersCount)")
                    DetailLine(title: L10n.t("累计返利"), value: money(value.paybacksSum))
                    DetailLine(title: L10n.t("返利比例"), value: String(format: "%.0f%%", value.codePayback * 100))
                    DetailLine(title: L10n.t("每位受邀用户返利次数上限"), value: "\(value.rebateFrequencyLimit)")
                }
            }.headerAction {
                Button(L10n.t("重置链接 / 邀请码")) { resetting = true }.buttonStyle(ProductButtonStyle()).disabled(state.loading || state.working)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 0) { segments(compact: false).fixedSize(); Spacer(minLength: 0) }.frame(minWidth: 640)
                segments(compact: true)
            }.padding(.top, 8)
            ProductSearchField(hint: L10n.t("用户 ID"), text: Binding(get: { searches[tab] }, set: { searches[tab] = $0; pages[tab] = 1 }))
            records(value)
        }
        .task(id: "\(pages)|\(searches)") {
            do { if !searches[tab].isEmpty { try await Task.sleep(for: .milliseconds(300)) }; await load() } catch { }
        }
        .productAutoRefresh(revision: session.profile?.revision(.invite)) { if !state.loading, !state.working, let value = try? await request(), !state.loading { state.value = value } }
        .alert(L10n.t("您确定要重置邀请链接吗？"), isPresented: $resetting) {
            Button(L10n.t("确定")) { Task { await reset() } }
            Button(L10n.t("取消"), role: .cancel) { }
        } message: {
            Text([L10n.t("注意：您点击 ") + L10n.t("确定") + L10n.t(" 按钮之后系统会立即重置您的邀请链接。此操作不可逆！"),
                  L10n.t("重置后旧的邀请链接将失效，新的邀请链接将立即生效。"),
                  L10n.t("通过旧邀请链接注册的被邀请者，返利奖励仍有效，不会因邀请链接变更而受影响。"),
                  L10n.t("重置后请您将新的邀请链接发送给被邀请者。")].joined(separator: "\n\n"))
        }
    }
    private func segments(compact: Bool) -> some View {
        ProductSegments(values: [0, 1], selection: $tab, compact: compact) { [L10n.t("邀请用户"), L10n.t("返利记录")][$0] }
    }
    private func copyRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: label + "：")
                Text(verbatim: value).lineLimit(2).truncationMode(.tail).productTextSelection()
            }.font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading)
            #if os(tvOS)
            PaymentQRCode(text: value, label: label).frame(width: 160, height: 160)
            #else
            Button(L10n.t("复制")) {
                #if os(macOS)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
                #else
                UIPasteboard.general.string = value
                #endif
                state.message = L10n.t("已复制{0}", [label])
            }.buttonStyle(ProductButtonStyle())
            #endif
        }
    }
    @ViewBuilder private func records(_ value: InviteSummary) -> some View {
        if tab == 0 {
            ProductTable(columns: [L10n.t("用户ID"), L10n.t("注册时间")], rows: value.invitedUsers.map {
                [AnyView(ProductTableText(text: String($0.id))), AnyView(ProductTableText(text: $0.regDate))]
            }, empty: L10n.t("暂无邀请用户"), minimumWidth: 360)
            PageButtons(current: value.invitedCurrentPage, last: value.invitedLastPage, total: value.invitedTotal) { pages[0] = $0 }
        } else {
            ProductTable(columns: [L10n.t("返利用户ID"), L10n.t("返利金额"), L10n.t("返利时间")], rows: value.paybacks.map {
                [AnyView(ProductTableText(text: String($0.userid))), AnyView(ProductTableText(text: money($0.refGet), bold: true)), AnyView(ProductTableText(text: $0.datetime))]
            }, empty: L10n.t("暂无返利记录"), minimumWidth: 480)
            PageButtons(current: value.paybackCurrentPage, last: value.paybackLastPage, total: value.paybackTotal) { pages[1] = $0 }
        }
    }
    private func money(_ value: Double) -> String { L10n.t("¥ {0}", [String(format: "%.2f", value)]) }
    private func request() async throws -> InviteSummary {
        let terms = searches.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return try await session.invite(invitedPage: pages[0], invitedSearch: terms[0], paybackPage: pages[1], paybackSearch: terms[1])
    }
    private func load() async {
        await state.load(request)
        if let value = state.value, state.failure == nil {
            let current = [value.invitedCurrentPage, value.paybackCurrentPage]
            if current != pages { pages = current }
        }
    }
    private func reset() async {
        if await state.perform({
            let message = try await session.resetInvite()
            return message.isEmpty ? L10n.t("已重置您的邀请链接，复制您的邀请链接发送给其他人！") : message
        }) { await load() }
    }
}