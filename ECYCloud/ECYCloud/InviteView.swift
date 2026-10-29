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
    @State private var pages = [1, 1, 1]
    @State private var searches = ["", "", ""]
    @State private var tab = 0
    @State private var resetting = false
    @State private var withdrawing = false
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
            ProductCard(title: L10n.t("提现"), icon: "account_balance_wallet_outlined") {
                VStack(spacing: 0) {
                    DetailLine(title: L10n.t("可提现"), value: money(value.withdrawBalance))
                    if value.enableWithdraw { DetailLine(title: L10n.t("提现中"), value: money(value.pendingWithdraw)) }
                    DetailLine(title: L10n.t("账户余额"), value: money(value.money))
                }
            }.headerAction {
                Button(value.withdrawChannels.isEmpty ? L10n.t("提现到余额") : L10n.t("申请提现")) { withdrawing = true }.buttonStyle(ProductButtonStyle())
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 0) { segments(compact: false).fixedSize(); Spacer(minLength: 0) }.frame(minWidth: 640)
                segments(compact: true)
            }.padding(.top, 8)
            ProductSearchField(hint: tab == 2 ? L10n.t("渠道 / 金额") : L10n.t("用户 ID"), text: Binding(get: { searches[tab] }, set: { searches[tab] = $0; pages[tab] = 1 }))
            records(value)
        }
        .task(id: "\(pages)|\(searches)") {
            do { if !searches[tab].isEmpty { try await Task.sleep(for: .milliseconds(300)) }; await load() } catch { }
        }
        .productAutoRefresh(revision: session.profile?.revision(.invite)) { if !state.loading, !state.working, let value = try? await request(), !state.loading { state.value = value } }
        .productSheet(isPresented: $withdrawing) {
            if let value = state.value {
                WithdrawalView(session: session, summary: value) { message in
                    state.message = message.isEmpty ? L10n.t("提现成功") : message
                    Task { await session.refresh(); await load() }
                }
            }
        }
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
        ProductSegments(values: [0, 1, 2], selection: $tab, compact: compact) { [L10n.t("邀请用户"), L10n.t("返利记录"), L10n.t("提现记录")][$0] }
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
        } else if tab == 1 {
            ProductTable(columns: [L10n.t("返利用户ID"), L10n.t("返利金额"), L10n.t("返利时间")], rows: value.paybacks.map {
                [AnyView(ProductTableText(text: String($0.userid))), AnyView(ProductTableText(text: money($0.refGet), bold: true)), AnyView(ProductTableText(text: $0.datetime))]
            }, empty: L10n.t("暂无返利记录"), minimumWidth: 480)
            PageButtons(current: value.paybackCurrentPage, last: value.paybackLastPage, total: value.paybackTotal) { pages[1] = $0 }
        } else {
            ProductTable(columns: [L10n.t("金额"), L10n.t("提现方式"), L10n.t("状态"), L10n.t("申请时间"), L10n.t("操作")], rows: value.withdrawRecords.map { row in
                [AnyView(ProductTableText(text: money(row.amount), bold: true)), AnyView(ProductTableText(text: row.channel)), AnyView(ProductTableText(text: L10n.t(row.statusText))),
                 AnyView(ProductTableText(text: row.createdAt)),
                 row.status == 0 ? AnyView(Button(L10n.t("取消")) { Task { await cancel(row.id) } }.buttonStyle(ProductButtonStyle()).disabled(state.working))
                    : AnyView(ProductTableText(text: "-"))]
            }, empty: L10n.t("暂无提现记录"), minimumWidth: 640)
            PageButtons(current: value.withdrawCurrentPage, last: value.withdrawLastPage, total: value.withdrawTotal) { pages[2] = $0 }
        }
    }
    private func money(_ value: Double) -> String { String(format: "¥ %.2f", value) }
    private func request() async throws -> InviteSummary {
        let terms = searches.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return try await session.invite(invitedPage: pages[0], invitedSearch: terms[0], paybackPage: pages[1], paybackSearch: terms[1],
                                        withdrawPage: pages[2], withdrawSearch: terms[2])
    }
    private func load() async {
        await state.load(request)
        if let value = state.value, state.failure == nil {
            let current = [value.invitedCurrentPage, value.paybackCurrentPage, value.withdrawCurrentPage]
            if current != pages { pages = current }
        }
    }
    private func reset() async {
        if await state.perform({
            let message = try await session.resetInvite()
            return message.isEmpty ? L10n.t("已重置您的邀请链接，复制您的邀请链接发送给其他人！") : message
        }) { await load() }
    }
    private func cancel(_ id: Int) async {
        if await state.perform({
            let message = try await session.cancelWithdrawal(id)
            return message.isEmpty ? L10n.t("已取消") : message
        }) { await load() }
    }
}

struct WithdrawalView: View {
    let session: ClientSession
    let summary: InviteSummary
    let finished: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var state = FeatureState<WithdrawalFields>()
    @State private var amount = ""
    @State private var amountError: String?
    @State private var channel = "balance"
    @State private var savedID = ""
    @State private var account: [String: String] = [:]
    @State private var save = false
    @State private var deleteID: Int?
    @State private var confirmingDelete = false
    private var toBalance: Bool { channel == "balance" }
    private var fieldsBusy: Bool { !toBalance && state.loading }
    private var fieldsError: String? { toBalance ? nil : state.failure }
    var body: some View {
        let colors = ProductPalette(scheme: scheme)
        FeatureSheet(title: summary.withdrawChannels.isEmpty ? L10n.t("提现到余额") : L10n.t("申请提现"), working: state.working, avatar: false) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ProductTextField(hint: L10n.t("金额"), text: Binding(get: { amount }, set: { amount = $0; amountError = nil }))
                    Text(verbatim: amountError ?? helper).font(.system(size: 12)).foregroundStyle(amountError == nil ? colors.secondary : colors.danger).padding(.top, 4)
                    if !summary.withdrawChannels.isEmpty {
                        ProductDropdown(label: L10n.t("提现方式"), values: ["balance"] + summary.withdrawChannels.map { String($0.id) }, selection: $channel) { value in
                            value == "balance" ? L10n.t("提现到账户余额（无需审批）")
                                : L10n.t("{0}（需审批）", [summary.withdrawChannels.first { String($0.id) == value }?.name ?? ""])
                        }.padding(.top, 12)
                    }
                    if !toBalance { channelFields(colors) }
                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        Button(L10n.t("申请")) { Task { await submit() } }.buttonStyle(ProductButtonStyle(filled: true))
                            .disabled(fieldsBusy || fieldsError != nil || state.working)
                        Button(L10n.t("取消")) { dismiss() }.buttonStyle(ProductButtonStyle()).disabled(state.working)
                    }.padding(.top, 24)
                }.padding(16)
            }.disabled(state.working)
        }
        .productToast(Binding(get: { state.message }, set: { state.message = $0 }))
        .task(id: channel) {
            account = [:]; savedID = ""; save = false; state.value = nil; state.failure = nil
            if let id = Int(channel) { await state.load { try await session.withdrawalFields(id) } }
        }
        .alert(L10n.t("删除已保存的收款账户？"), isPresented: $confirmingDelete) {
            Button(L10n.t("删除"), role: .destructive) { Task {
                if let id = deleteID, await state.perform({ try await session.deleteWithdrawalAccount(id) }), let channelID = Int(channel) {
                    savedID = ""; await state.load { try await session.withdrawalFields(channelID) }
                }
                deleteID = nil
            } }
            Button(L10n.t("取消"), role: .cancel) { deleteID = nil }
        }
    }
    @ViewBuilder private func channelFields(_ colors: ProductPalette) -> some View {
        if fieldsBusy {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.top, 16)
        } else if let fieldsError {
            Text(verbatim: fieldsError).font(.system(size: 12)).foregroundStyle(colors.danger).padding(.top, 12)
        } else if let fields = state.value, String(fields.channel.id) == channel {
            if !fields.savedAccounts.isEmpty {
                HStack(alignment: .bottom, spacing: 8) {
                    ProductDropdown(label: L10n.t("已保存的账户"), values: [""] + fields.savedAccounts.map { String($0.id) },
                                    selection: Binding(get: { savedID }, set: { fill($0, fields) })) { value in
                        guard let saved = fields.savedAccounts.first(where: { String($0.id) == value }) else { return L10n.t("手动输入") }
                        return saved.isDefault == true ? L10n.t("{0}（默认）", [saved.summary]) : saved.summary
                    }
                    if let id = Int(savedID) {
                        Button(L10n.t("删除")) { deleteID = id; confirmingDelete = true }.buttonStyle(ProductButtonStyle(color: colors.danger))
                    }
                }.padding(.top, 12)
            }
            ForEach(fields.channel.fields) { field in
                ProductTextField(hint: field.required ? field.name + " *" : field.name,
                                 text: Binding(get: { account[field.name] ?? "" }, set: { account[field.name] = $0 })).padding(.top, 12)
            }
            Toggle(L10n.t("保存此收款账户"), isOn: $save).toggleStyle(ProductToggleStyle()).padding(.top, 8)
        }
    }
    private var helper: String {
        let minimum = toBalance && !summary.balanceWithdrawRequireMin ? "" : L10n.t("，最低 ¥ {0}", [String(format: "%.2f", summary.minWithdrawAmount)])
        return L10n.t("可提现 ¥ {0}{1}", [String(format: "%.2f", summary.withdrawBalance), minimum])
    }
    private func fill(_ id: String, _ fields: WithdrawalFields) {
        savedID = id
        let saved = fields.savedAccounts.first { String($0.id) == id }
        account = Dictionary(uniqueKeysWithValues: fields.channel.fields.map { ($0.name, saved?.accountInfo[$0.name] ?? "") })
    }
    private func submit() async {
        guard let value = MoneyInput.amount(amount.trimmingCharacters(in: .whitespacesAndNewlines)), value > 0 else {
            amountError = L10n.t("请输入有效的提现金额"); return
        }
        guard toBalance || (!fieldsBusy && fieldsError == nil) else { return }
        var result = ""
        let values = account.mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if await state.perform({ result = try await session.withdraw(amount: amount.trimmingCharacters(in: .whitespacesAndNewlines), channel: channel, account: values, save: save); return "" }) {
            finished(result)
            dismiss()
        }
    }
}
