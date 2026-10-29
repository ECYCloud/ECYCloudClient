import SwiftUI
import ECYCloudKit

struct AccountSecurityView: View {
    let session: ClientSession
    @Binding var message: String?
    @Binding var working: Bool
    @Environment(\.colorScheme) private var scheme
    @State private var auth: AuthOptions?
    @State private var edit: AccountEditOptions?
    @State private var loaded = false
    @State private var name = ""
    @State private var email = ""
    @State private var oldCode = ""
    @State private var newCode = ""
    @State private var oldVerified = false
    @State private var oldPassword = ""
    @State private var password = ""
    @State private var confirmation = ""
    @State private var twoFactorCode = ""
    @State private var twoFactorDraft = 0
    @State private var freshSecret: TwoFactorSecret?
    @State private var telegram: TelegramBinding?
    @State private var preferences: [String: Bool] = [:]
    @State private var passwordAction: PasswordAction?
    @State private var promptPassword = ""
    @State private var prompting = false
    @State private var confirmingEnable = false
    @State private var confirmingUnbind = false
    @State private var sendingEmail: AccountEmailPurpose?
    private enum PasswordAction { case disable, reset }
    private var colors: ProductPalette { ProductPalette(scheme: scheme) }
    private var busy: Bool { working || session.busy }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !loaded {
                ProgressView().frame(maxWidth: .infinity).padding(.top, 80)
            } else {
                usernameCard
                if let auth, auth.enableChangeEmail { emailCard(auth) }
                passwordCard
                if let edit {
                    twoFactorCard(edit)
                    if edit.enableTelegram { telegramCard(edit) }
                    mailCard(edit)
                }
            }
        }
        .task { await load() }
        .task(id: telegramPolling) { await pollTelegram() }
        .onChange(of: oldCode) { _, value in oldVerified = false; filterCode(value, $oldCode) }
        .onChange(of: newCode) { _, value in filterCode(value, $newCode) }
        .onChange(of: twoFactorCode) { _, value in filterCode(value, $twoFactorCode) }
        .onChange(of: oldPassword) { _, value in filterASCII(value, $oldPassword) }
        .onChange(of: password) { _, value in filterASCII(value, $password) }
        .onChange(of: confirmation) { _, value in filterASCII(value, $confirmation) }
        .onDisappear { clearSecrets() }
        .alert(L10n.t("请验证登录密码"), isPresented: $prompting) {
            SecureField(L10n.t("登录密码"), text: $promptPassword)
            Button(L10n.t("确定")) {
                let value = promptPassword; promptPassword = ""
                guard !value.isEmpty, let action = passwordAction else { return }
                Task { await runPasswordAction(action, password: value) }
            }
            Button(L10n.t("取消"), role: .cancel) { promptPassword = "" }
        } message: { Text(L10n.t("关闭或重置已启用的两步验证属敏感操作，为确认是您本人，请输入当前登录密码。")) }
        .alert(L10n.t("您确定要开启两步验证吗？"), isPresented: $confirmingEnable) {
            Button(L10n.t("确定")) { Task { await enableTwoFactor() } }
            Button(L10n.t("取消"), role: .cancel) { }
        } message: { Text(L10n.t("开启后每次登录都需要输入验证器上的 6 位验证码。请确认已完成测试并通过验证。")) }
        .alert(L10n.t("您确定要解除Telegram绑定吗？"), isPresented: $confirmingUnbind) {
            Button(L10n.t("确定")) { Task { await unbindTelegram() } }
            Button(L10n.t("取消"), role: .cancel) { }
        } message: { Text(verbatim: unbindMessage) }
    }

    private var usernameCard: some View {
        ProductCard(title: L10n.t("修改用户名"), icon: "badge_outlined") {
            Text(L10n.t("当前用户名：")) + Text(verbatim: session.profile?.userName ?? "").foregroundStyle(colors.accent)
            ProductField(title: L10n.t("新用户名"), icon: "person_outline", hasValue: !name.isEmpty) {
                TextField(L10n.t("新用户名"), text: $name).autocorrectionDisabled()
            }
            trailing {
                Button(L10n.t("保存")) { Task { await run { try await session.updateUsername(name) } } }
                    .buttonStyle(ProductButtonStyle(filled: true)).disabled(busy)
            }
        }
    }

    private func emailCard(_ options: AuthOptions) -> some View {
        ProductCard(title: L10n.t("修改邮箱"), icon: "mail_outline") {
            Text(L10n.t("当前邮箱：")) + Text(verbatim: session.profile?.email ?? "").foregroundStyle(colors.accent)
            if options.emailVerify {
                HStack(spacing: 12) {
                    codeField(L10n.t("原邮箱验证码"), text: $oldCode)
                    sendButton(.oldEmail)
                }
                trailing {
                    Button(oldVerified ? L10n.t("原邮箱已验证") : L10n.t("验证原邮箱")) { Task {
                        oldVerified = await run { try await session.verifyOldEmail(oldCode) }
                    } }.buttonStyle(ProductButtonStyle()).disabled(busy || oldVerified)
                }
            }
            ProductField(title: L10n.t("新邮箱"), icon: "mail_outline", hasValue: !email.isEmpty) {
                TextField(L10n.t("新邮箱"), text: $email).textContentType(.emailAddress).autocorrectionDisabled()
            }
            if options.emailVerify {
                HStack(spacing: 12) {
                    codeField(L10n.t("新邮箱验证码"), text: $newCode)
                    sendButton(.newEmail).disabled(!oldVerified)
                }
            }
            trailing {
                Button(L10n.t("换绑邮箱")) { Task {
                    await run { try await session.updateEmail(email, oldCode: oldCode, newCode: newCode); return "" }
                } }.buttonStyle(ProductButtonStyle(filled: true)).disabled(busy)
            }
        }
    }

    private var passwordCard: some View {
        ProductCard(title: L10n.t("修改密码"), icon: "lock_outline") {
            ProductField(title: L10n.t("当前密码"), icon: "lock_outline", hasValue: !oldPassword.isEmpty) {
                SecureField(L10n.t("当前密码"), text: $oldPassword).textContentType(.password)
            }
            ProductField(title: L10n.t("新密码"), icon: "lock_outline", hasValue: !password.isEmpty) {
                SecureField(L10n.t("新密码"), text: $password).textContentType(.newPassword)
            }
            ProductField(title: L10n.t("确认新密码"), icon: "lock_outline", hasValue: !confirmation.isEmpty) {
                SecureField(L10n.t("确认新密码"), text: $confirmation).textContentType(.newPassword)
            }
            Text(auth?.enablePasswordChangeResetSubscription == true ? L10n.t("修改密码后将重置订阅链接与节点密码，并需重新登录") : L10n.t("修改密码后需重新登录"))
                .font(.system(size: 12)).foregroundStyle(colors.secondary)
            trailing {
                Button(L10n.t("修改密码")) { Task { await savePassword() } }
                    .buttonStyle(ProductButtonStyle(filled: true)).disabled(busy)
            }
        }
    }

    private func twoFactorCard(_ options: AccountEditOptions) -> some View {
        let secret = freshSecret.map { (token: $0.gaToken, url: $0.gaUrl) }
            ?? (options.gaEnable == 0 && !options.gaToken.isEmpty ? (token: options.gaToken, url: options.gaUrl) : nil)
        return ProductCard(title: L10n.t("两步验证"), icon: "phonelink_lock_outlined") {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.t("请使用验证器扫描下方二维码。在测试通过前请不要启用。")).font(.system(size: 12)).foregroundStyle(colors.secondary)
                if let secret {
                    if !secret.url.isEmpty { PaymentQRCode(text: secret.url, label: L10n.t("两步验证二维码")).padding(.top, 4) }
                    if !secret.token.isEmpty {
                        Text(L10n.t("密钥：{0}", [secret.token])).font(.system(size: 12)).multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity).productTextSelection()
                    }
                    HStack(spacing: 0) {
                        if secret.url.isEmpty { Spacer(minLength: 0) }
                        else { Text(verbatim: secret.url).font(.system(size: 12)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading) }
                        #if !os(tvOS)
                        if !secret.token.isEmpty { copyButton("key", hint: L10n.t("复制密钥"), label: L10n.t("密钥"), value: secret.token) }
                        if !secret.url.isEmpty { copyButton("link", hint: L10n.t("复制 otpauth"), label: L10n.t("otpauth 链接"), value: secret.url) }
                        #endif
                    }
                }
                codeField(L10n.t("测试验证码"), text: $twoFactorCode)
                Button(L10n.t("测试")) { Task { await run { try await session.testTwoFactor(code: twoFactorCode) } } }
                    .buttonStyle(ProductButtonStyle()).disabled(busy)
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.t("验证设置"))
                        Text(L10n.t("已保存：{0}", [options.gaEnable == 1 ? L10n.t("要求验证") : L10n.t("不要求")]))
                            .font(.system(size: 12)).foregroundStyle(colors.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    ProductDropdown(values: [0, 1], selection: $twoFactorDraft) { $0 == 1 ? L10n.t("要求验证") : L10n.t("不要求") }
                        .frame(width: 120).disabled(busy)
                }.padding(.top, 4)
                Button(L10n.t("保存")) { saveTwoFactor(options) }
                    .buttonStyle(ProductButtonStyle(filled: true)).disabled(busy)
            }
        }.headerAction {
            Button(L10n.t("重置密钥")) { resetTwoFactor(options) }.buttonStyle(ProductButtonStyle()).disabled(busy)
        }
    }

    private func telegramCard(_ options: AccountEditOptions) -> some View {
        let bound = telegram?.bound ?? (options.telegramId > 0)
        let token = telegram?.bindToken ?? options.bindToken
        return ProductCard(title: L10n.t("绑定 Telegram Bot"), icon: "chat_outlined") {
            if bound {
                telegramBoundLine(imValue: telegram?.imValue ?? options.imValue, id: telegram?.telegramId ?? options.telegramId)
                if options.telegramUnbindKick {
                    Text(L10n.t("解绑后将被移出 Telegram 用户群/频道。")).font(.system(size: 12)).foregroundStyle(colors.danger)
                }
                trailing {
                    Button(L10n.t("解除绑定")) { confirmingUnbind = true }
                        .buttonStyle(ProductButtonStyle(filled: true)).disabled(busy)
                }
            } else {
                Text(L10n.t("绑定后可通过 Telegram Bot 签到、查询等。绑定码约 10 分钟有效。")).font(.system(size: 12)).foregroundStyle(colors.secondary)
                Text(L10n.t("绑定码：{0}", [token])).font(.system(size: 12)).productTextSelection()
                ProductFlow(spacing: 8) {
                    #if !os(tvOS)
                    Button { copy(token, label: L10n.t("绑定码")) } label: { iconLabel("content_copy", L10n.t("复制绑定码"), size: 16) }
                        .buttonStyle(ProductButtonStyle())
                    #endif
                    let bot = options.telegramBot.hasPrefix("@") ? String(options.telegramBot.dropFirst()) : options.telegramBot
                    let title = bot.isEmpty ? L10n.t("一键绑定") : L10n.t("一键绑定 @{0}", [bot])
                    if let url = telegramURL(bot: bot, token: token) {
                        Link(destination: url) { iconLabel("open_in_new", title, size: 16) }.buttonStyle(ProductButtonStyle(filled: true))
                    } else {
                        Button { } label: { iconLabel("open_in_new", title, size: 16) }.buttonStyle(ProductButtonStyle(filled: true)).disabled(true)
                    }
                }
            }
        }
    }

    private func mailCard(_ options: AccountEditOptions) -> some View {
        ProductCard(title: L10n.t("邮件通知偏好"), icon: "notifications_outlined") {
            VStack(spacing: 0) {
                ForEach(options.mailOptions) { item in
                    let enabled = Binding(get: { preferences[item.id] ?? true }, set: { preferences[item.id] = $0 })
                    Toggle(isOn: enabled) {
                        Text(verbatim: item.title).frame(maxWidth: .infinity, minHeight: 48, alignment: .leading).contentShape(Rectangle())
                            .onTapGesture { enabled.wrappedValue.toggle() }
                    }.toggleStyle(ProductToggleStyle())
                }
            }
            trailing {
                Button(L10n.t("保存偏好")) { Task { await run { try await session.updateMailPreferences(preferences) } } }
                    .buttonStyle(ProductButtonStyle(filled: true)).disabled(busy)
            }
        }
    }

    private func telegramBoundLine(imValue: String, id: Int64) -> some View {
        let name = imValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let username = !name.isEmpty && name != "未设置用户名" && name != String(id) && name.range(of: #"^[A-Za-z0-9_]+$"#, options: .regularExpression) != nil ? name : nil
        let links: [(String, URL)] = [username.flatMap { value in URL(string: "https://t.me/" + value).map { ("@" + value, $0) } },
                                      id > 0 ? URL(string: "tg://user?id=\(id)").map { (String(id), $0) } : nil].compactMap { $0 }
        return ProductFlow(spacing: 0) {
            Text(L10n.t("当前绑定："))
            ForEach(Array(links.enumerated()), id: \.offset) { index, link in
                if index > 0 { Text(verbatim: " / ") }
                Link(destination: link.1) { Text(verbatim: link.0).foregroundStyle(colors.accent) }.buttonStyle(.productPlain).help(link.1.absoluteString)
            }
            if links.isEmpty { Text(verbatim: name.isEmpty ? String(id) : name) }
        }
    }

    private var unbindMessage: String {
        var parts = [L10n.t("注意：您点击 ") + L10n.t("确定") + L10n.t(" 按钮之后系统会解除你本站账号与Telegram Bot的绑定。"),
                     L10n.t("解绑之后您就不能通过Telegram Bot使用相关功能了。当然您随时可以回来这个页面重新绑定。")]
        if edit?.telegramUnbindKick == true {
            parts.append(L10n.t("注意：如果你加入了 Telegram 用户群或频道，解绑后您将被自动移出用户群和频道，重新绑定后可再次申请加入。"))
        }
        return parts.joined(separator: "\n\n")
    }

    private var telegramPolling: Bool {
        guard loaded, let edit, edit.enableTelegram else { return false }
        return !(telegram?.bound ?? (edit.telegramId > 0))
    }

    private func trailing<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8) { Spacer(minLength: 0); content() }
    }

    private func iconLabel(_ icon: String, _ title: String, size: CGFloat) -> some View {
        HStack(spacing: 8) { ProductGlyph(name: icon, size: size); Text(verbatim: title) }
    }

    private func codeField(_ title: String, text: Binding<String>) -> some View {
        ProductField(title: title, icon: "pin_outlined", hasValue: !text.wrappedValue.isEmpty) {
            TextField(title, text: text).textContentType(.oneTimeCode).autocorrectionDisabled()
        }
    }

    private func sendButton(_ purpose: AccountEmailPurpose) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let seconds = session.accountEmailCooldown(purpose)
            Button { Task {
                sendingEmail = purpose
                await run { try await session.sendAccountEmail(purpose, newEmail: email.trimmingCharacters(in: .whitespacesAndNewlines), oldCode: oldCode) }
                sendingEmail = nil
            } } label: {
                if sendingEmail == purpose { ProgressView().controlSize(.small).frame(width: 18, height: 18) } else { Text(verbatim: seconds > 0 ? "\(seconds)s" : L10n.t("发送")) }
            }.buttonStyle(ProductButtonStyle(height: 40)).fixedSize().disabled(busy || seconds > 0)
        }
    }

    #if !os(tvOS)
    private func copyButton(_ icon: String, hint: String, label: String, value: String) -> some View {
        Button { copy(value, label: label) } label: {
            ProductGlyph(name: icon, size: 18).frame(width: ProductMetrics.tapTarget, height: ProductMetrics.tapTarget).contentShape(Rectangle()).productIconHover()
        }.buttonStyle(.productPlain).help(hint).accessibilityLabel(hint)
    }

    private func copy(_ value: String, label: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        #else
        UIPasteboard.general.string = value
        #endif
        message = L10n.t("已复制{0}", [label])
    }
    #endif

    private func telegramURL(bot: String, token: String) -> URL? {
        guard !bot.isEmpty, bot.range(of: #"^[A-Za-z0-9_]+$"#, options: .regularExpression) != nil else { return nil }
        var url = URLComponents(); url.scheme = "https"; url.host = "t.me"; url.path = "/" + bot
        url.queryItems = [.init(name: "start", value: token)]
        return url.url
    }

    private func filterCode(_ value: String, _ text: Binding<String>) {
        let filtered = AuthInput.otp(value)
        if filtered != value { text.wrappedValue = filtered }
    }

    private func filterASCII(_ value: String, _ text: Binding<String>) {
        let filtered = AuthInput.ascii(value)
        if filtered != value { text.wrappedValue = filtered }
    }

    @discardableResult private func run(_ action: () async throws -> String) async -> Bool {
        guard !working else { return false }
        working = true
        defer { working = false }
        do {
            let result = try await action()
            message = result.isEmpty ? L10n.t("操作成功") : result
            return true
        } catch is CancellationError { return false }
        catch {
            message = (error as? ClientError)?.localizedDescription ?? L10n.t("操作未完成，请重试。")
            return false
        }
    }

    private func savePassword() async {
        await run { try await session.updatePassword(old: oldPassword, password: password, confirmation: confirmation); return "" }
    }

    private func saveTwoFactor(_ options: AccountEditOptions) {
        if twoFactorDraft == 1 { confirmingEnable = true }
        else if options.gaEnable != 0 { passwordAction = .disable; prompting = true }
        else { Task { await run { try await session.keepTwoFactorSetting(enabled: false) } } }
    }

    private func enableTwoFactor() async {
        let enabled = edit?.gaEnable != 0
        let success = await run {
            if enabled { return try await session.keepTwoFactorSetting(enabled: true) }
            return try await session.enableTwoFactor(code: twoFactorCode)
        }
        if success && !enabled { twoFactorCode = ""; freshSecret = nil; await reloadEditOptions() }
    }

    private func resetTwoFactor(_ options: AccountEditOptions) {
        if options.gaEnable != 0 { passwordAction = .reset; prompting = true }
        else { Task { await runPasswordAction(.reset, password: "") } }
    }

    private func runPasswordAction(_ action: PasswordAction, password: String) async {
        switch action {
        case .disable:
            if await run({ try await session.disableTwoFactor(password: password) }) { await reloadEditOptions() }
        case .reset:
            var secret: TwoFactorSecret?
            await run { secret = try await session.resetTwoFactor(password: password); return L10n.t("两步验证密钥已重置") }
            if let secret { freshSecret = secret }
        }
    }

    private func unbindTelegram() async {
        var binding: TelegramBinding?
        await run {
            let result = try await session.resetTelegram()
            binding = result.binding
            return result.message.isEmpty ? L10n.t("已解绑") : result.message
        }
        if let binding { telegram = binding }
    }

    private func pollTelegram() async {
        guard telegramPolling else { return }
        while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            guard let result = try? await session.checkTelegramBinding(), result.bound, !Task.isCancelled else { continue }
            let previous = telegram?.telegramId ?? edit?.telegramId ?? 0
            telegram = TelegramBinding(bound: true, imValue: result.imValue, telegramId: result.telegramId > 0 ? result.telegramId : previous, bindToken: "")
            message = L10n.t("Telegram 绑定成功")
            return
        }
    }

    private func load() async {
        auth = try? await session.accountOptions()
        await reloadEditOptions()
        if let edit { preferences = edit.mailNotifyPreferences }
        loaded = true
    }

    private func reloadEditOptions() async {
        guard let value = try? await session.editOptions() else { if !loaded { edit = nil }; return }
        edit = value
        twoFactorDraft = value.gaEnable
        telegram = nil
    }

    private func clearSecrets() {
        oldPassword = ""; password = ""; confirmation = ""; oldCode = ""; newCode = ""; twoFactorCode = ""
        promptPassword = ""; freshSecret = nil; edit = nil; telegram = nil
    }
}

struct DeleteAccountView: View {
    let session: ClientSession
    @Environment(\.colorScheme) private var scheme
    @State private var options: AuthOptions?
    @State private var loading = true
    @State private var busy = false
    @State private var sendingCode = false
    @State private var code = ""
    @State private var toast: String?
    @State private var confirming = false
    private var colors: ProductPalette { ProductPalette(scheme: scheme) }

    var body: some View {
        FeatureSheet(title: L10n.t("删除账号"), working: busy) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if loading {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 80)
                    } else if let options, options.enableKill {
                        ProductCard(title: L10n.t("注意！"), icon: "warning_amber_outlined") {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(L10n.t("提交删除账号请求后，您的账户将被禁用，并在 30 天后从系统中彻底删除。在此期间，您可以登录并取消删除请求以恢复账户。"))
                                Text(L10n.t("删除后，账号及相关数据（包括余额、有效套餐等）都将被删除，请谨慎操作！"))
                                Text(L10n.t("当然账号删除后如果您还想继续使用本服务，您随时可以回来重新注册账号。"))
                            }.font(.system(size: 14)).foregroundStyle(colors.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        verifyCard(options)
                    } else {
                        ProductCard(title: L10n.t("功能已关闭"), icon: "block") {
                            Text(L10n.t("管理员已关闭账号删除功能。如需删除账号，请联系管理员。")).font(.system(size: 14)).foregroundStyle(colors.secondary)
                        }
                    }
                }
                .padding(.leading, 14).padding(.trailing, 16).padding(.bottom, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .productToast($toast)
        }
        .task { options = try? await session.accountOptions(); loading = false }
        .onChange(of: code) { _, value in
            let filtered = AuthInput.otp(value)
            if filtered != value { code = filtered }
        }
        .onDisappear { code = "" }
        .alert(L10n.t("确认提交删除请求吗？"), isPresented: $confirming) {
            Button(L10n.t("确定")) { Task { await submit() } }
            Button(L10n.t("取消"), role: .cancel) { }
        } message: { Text(L10n.t("提交后，您的账户将被禁用，并在 30 天后彻底删除。在此期间可取消删除。")) }
    }

    private func verifyCard(_ options: AuthOptions) -> some View {
        ProductCard(title: options.emailVerify ? L10n.t("输入邮箱验证码以验证身份") : L10n.t("提交删除请求"), icon: "verified_user_outlined") {
            if options.emailVerify {
                Text(L10n.t("删除账号验证码将发送到 {0} 邮箱", [session.profile?.email ?? ""])).foregroundStyle(colors.secondary)
                ProductTextField(hint: L10n.t("邮箱验证码（必填）"), text: $code).disabled(busy)
            }
            ProductFlow(spacing: 12) {
                if options.emailVerify {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        let seconds = session.accountEmailCooldown(.deletion)
                        Button { Task { await sendCode() } } label: {
                            HStack(spacing: 8) {
                                if sendingCode { ProgressView().controlSize(.small).frame(width: 18, height: 18) } else { ProductGlyph(name: "mail_outline", size: 18) }
                                Text(seconds > 0 ? L10n.t("获取验证码 ({0}s)", [String(describing: seconds)]) : L10n.t("获取验证码"))
                            }
                        }.buttonStyle(ProductButtonStyle()).disabled(busy || seconds > 0)
                    }
                }
                Button { requestSubmit(options) } label: {
                    HStack(spacing: 8) { ProductGlyph(name: "check", size: 18); Text(L10n.t("提交删除请求")) }
                }.buttonStyle(ProductButtonStyle(filled: true)).disabled(busy)
            }
        }
    }

    private func sendCode() async {
        guard !busy else { return }
        busy = true; sendingCode = true
        defer { busy = false; sendingCode = false }
        do { toast = try await session.sendAccountEmail(.deletion) }
        catch is CancellationError { }
        catch { toast = (error as? ClientError)?.localizedDescription ?? L10n.t("操作未完成，请重试。") }
    }

    private func requestSubmit(_ options: AuthOptions) {
        guard !busy else { return }
        if options.emailVerify && code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            toast = L10n.t("请先输入邮箱验证码")
            return
        }
        confirming = true
    }

    private func submit() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do { _ = try await session.deleteAccount(emailCode: code.trimmingCharacters(in: .whitespacesAndNewlines)) }
        catch is CancellationError { }
        catch { toast = (error as? ClientError)?.localizedDescription ?? L10n.t("操作未完成，请重试。") }
    }
}
