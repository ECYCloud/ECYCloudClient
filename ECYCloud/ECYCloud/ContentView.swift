import SwiftUI
import ECYCloudKit

struct ContentView: View {
    let session: ClientSession
    @State private var accountMenu: AccountMenu
    init(session: ClientSession) {
        self.session = session
        _accountMenu = State(initialValue: AccountMenu(session: session))
    }
    @AppStorage("apple.appearance") private var appearance = "system"
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var scheme
    @State private var entered: String?
    @State private var resetMessage: String?

    var body: some View {
        Group {
            switch session.phase {
            case .starting, .restoring:
                VStack(spacing: 20) {
                    ProgressView(L10n.t("正在恢复登录…"))
                    Button(L10n.t("退出登录")) { Task { await session.logout() } }
                }
            case .signedOut:
                LoginView(session: session)
            case .cleanupFailed:
                ContentUnavailableView {
                    Label(L10n.t("登录信息尚未清除"), systemImage: "exclamationmark.triangle")
                } description: {
                    Text(verbatim: session.message ?? L10n.t("请稍后重试。"))
                } actions: {
                    Button(L10n.t("重试")) { Task { await session.logout() } }
                        .disabled(session.busy)
                }
            case .signedIn, .restricted:
                NavigationStack { ClientHomeView(session: session).toolbar(.hidden) }.environment(accountMenu)
            }
        }
        .preferredColorScheme(appearance == "light" ? .light : appearance == "dark" ? .dark : nil)
        .environment(\.locale, Locale(identifier: session.preferences.language.rawValue))
        .font(.system(size: 13))
        .foregroundStyle(ProductPalette(scheme: scheme).text)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .productCornerPadding()
        .background(ProductPalette(scheme: scheme).background)
        .tint(ProductPalette(scheme: scheme).accent)
        #if os(tvOS)
        .padding(40)
        #endif
        .productFocusWrap()
        .productToast($entered, duration: 0.9)
        .onChange(of: session.phase) { old, new in
            guard old == .signedOut, new == .signedIn || new == .restricted, let kind = session.authentication else { return }
            if kind == .reset { resetMessage = session.message ?? "" }
            else { entered = kind == .login ? L10n.t("登录成功") : L10n.t("注册成功") }
            session.dismissMessage()
        }
        .alert(L10n.t("重置成功"), isPresented: Binding(get: { resetMessage != nil }, set: { if !$0 { resetMessage = nil } })) {
            Button(L10n.t("我知道了")) { resetMessage = nil }
        } message: { Text(L10n.message(resetMessage ?? "")) }
        .task { await session.start() }
        .task(id: scenePhase) { await session.setRuntimeActive(scenePhase != .background) }
        .task(id: "\(scenePhase)|\(session.connection?.state.rawValue ?? "none")") {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await session.refresh(silently: true)
                do { try await Task.sleep(for: .seconds(session.refreshInterval)) } catch { break }
            }
        }
    }
}

struct LoginView: View {
    let session: ClientSession
    @Environment(\.colorScheme) private var scheme
    @State private var email = ""
    @State private var password = ""
    @State private var code = ""
    @State private var emailCode = false
    @State private var showPassword = false
    @State private var rememberPassword = false
    @State private var restoredLogin: RememberedLogin?
    @State private var workflow: AuthWorkflow?
    @State private var errors: [Field: String] = [:]
    @State private var toast: String?
    @State private var twoFactor = false
    @State private var twoFactorPrompt: String?
    @FocusState private var focus: Field?
    private enum Field { case email, password, code }
    private var colors: ProductPalette { ProductPalette(scheme: scheme) }

    var body: some View {
        ProductAuthPanel(site: session.endpoints.site, title: L10n.t("登录"),
                         subtitle: L10n.t("使用 {0} 账号登录，登录后自动获取可用节点", [String(describing: session.endpoints.site.host()!)])) {
            form
        }
        .productToast($toast)
        .task {
            do {
                if let login = try session.loadRememberedLogin() {
                    restoredLogin = login; email = login.email; password = login.password; rememberPassword = true
                }
            } catch { toast = L10n.t("记住账号密码：") + ((error as? ClientError)?.localizedDescription ?? L10n.t("无法读取记住的账号密码")) }
        }
        .productSheet(item: $workflow) { page in AuthWorkflowView(session: session, page: page) }
        .productSheet(isPresented: $twoFactor) { TwoFactorSheet(verify: verifyTwoFactor) }
        .onChange(of: email) { _, value in
            if let restoredLogin, value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != restoredLogin.email {
                if password == restoredLogin.password { password = "" }
                self.restoredLogin = nil
            }
        }
        .onChange(of: password) { _, value in
            guard value != restoredLogin?.password else { return }
            let filtered = AuthInput.ascii(value)
            if filtered != value { password = filtered }
        }
        .onChange(of: code) { _, value in
            let filtered = AuthInput.otp(value)
            if filtered != value { code = filtered }
        }
        .onChange(of: session.needsTwoFactor) { _, needed in
            twoFactorPrompt = needed ? session.message : nil
            if needed && !emailCode { twoFactor = true }
        }
        .onChange(of: session.phase) { _, phase in
            if phase != .signedOut { password = ""; code = ""; restoredLogin = nil; twoFactor = false }
        }
    }

    private var form: some View {
        VStack(spacing: ProductMetrics.formSpacing) {
            AuthField(icon: "mail_outline", isFocused: focus == .email) {
                TextField(L10n.t("邮箱"), text: $email)
                    .textContentType(.username).autocorrectionDisabled()
                    #if !os(macOS)
                    .textInputAutocapitalization(.never).keyboardType(.emailAddress)
                    #endif
                    .focused($focus, equals: .email)
                    .onSubmit { focus = emailCode ? .code : .password }
            }
            .authError(errors[.email])
            if emailCode {
                HStack(alignment: .top, spacing: 12) { codeField; sendCodeButton.fixedSize() }
            } else {
                AuthField(icon: "lock_outline", isFocused: focus == .password) {
                    Group {
                        if showPassword { TextField(L10n.t("密码"), text: $password) }
                        else { SecureField(L10n.t("密码"), text: $password) }
                    }
                    .textContentType(.password).autocorrectionDisabled()
                    #if !os(macOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .focused($focus, equals: .password).onSubmit { submit() }
                    Button { showPassword.toggle() } label: {
                        ProductGlyph(name: showPassword ? "visibility_off_outlined" : "visibility_outlined")
                            .foregroundStyle(colors.secondary).frame(width: 28, height: 36).productIconHover()
                    }
                    .buttonStyle(.productPlain).accessibilityLabel(showPassword ? L10n.t("隐藏密码") : L10n.t("显示密码"))
                }
                .authError(errors[.password])
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    if !emailCode { rememberButton }
                    Spacer(minLength: 0)
                    forgotButton
                }
                VStack(alignment: .leading, spacing: 0) {
                    if !emailCode { rememberButton }
                    forgotButton
                }
            }.padding(.top, -8)
            if let message = session.message, !(session.needsTwoFactor && message == twoFactorPrompt) {
                AuthErrorBanner(message: message).padding(.top, -8).accessibilityIdentifier("loginMessage")
            }
            Button(action: submit) { AuthSubmitLabel(title: L10n.t("登录"), busy: session.busy) }
                .buttonStyle(AuthButtonStyle(kind: .primary)).disabled(session.busy).padding(.top, 4)
            Button {
                emailCode.toggle(); code = ""; errors = [:]
                focus = emailCode ? .code : .password
            } label: { Text(emailCode ? L10n.t("密码登录") : L10n.t("邮箱验证码登录")).frame(maxWidth: .infinity) }
                .buttonStyle(AuthButtonStyle(kind: .secondary)).padding(.top, -4)
            Divider().padding(.top, 12)
            ViewThatFits(in: .horizontal) {
                HStack { registerButton; Spacer(minLength: 8); legalButtons }
                VStack(alignment: .leading, spacing: 0) { registerButton; legalButtons }
            }
            .padding(.top, -4)
        }
    }

    private var rememberButton: some View {
        Button {
            do {
                if rememberPassword { try session.clearRememberedLogin() }
                rememberPassword.toggle()
            } catch { toast = L10n.t("记住账号密码：") + ((error as? ClientError)?.localizedDescription ?? L10n.t("无法清除记住的账号密码")) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: rememberPassword ? "checkmark.square.fill" : "square").font(.system(size: 18))
                Text(L10n.t("记住账号密码"))
            }
        }.buttonStyle(.productPlain).accessibilityAddTraits(rememberPassword ? [.isSelected] : [])
    }

    private var registerButton: some View {
        Button(L10n.t("注册账号 ›")) { open(.register) }.buttonStyle(AuthButtonStyle(kind: .link))
    }

    private var legalButtons: some View {
        HStack(spacing: 16) {
            Button(L10n.t("服务条款")) { open(.terms) }
            Button(L10n.t("隐私政策")) { open(.privacy) }
        }
        .buttonStyle(AuthButtonStyle(kind: .subtle))
    }

    private var forgotButton: some View {
        Button(L10n.t("忘记密码？")) { open(.resetPassword) }.buttonStyle(AuthButtonStyle(kind: .link))
    }

    private var codeField: some View {
        AuthField(icon: "pin_outlined", isFocused: focus == .code) {
            TextField(L10n.t("验证码"), text: $code)
                .textContentType(.oneTimeCode).autocorrectionDisabled()
                #if !os(macOS)
                .textInputAutocapitalization(.never).keyboardType(.asciiCapable)
                #endif
                .focused($focus, equals: .code).onSubmit { submit() }
        }
        .authError(errors[.code])
        .frame(minWidth: 100)
    }

    private var sendCodeButton: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let remaining = session.emailCooldown(.login)
            Button { Task { await sendCode() } } label: {
                if session.sendingEmail { ProgressView().controlSize(.small).frame(width: 18, height: 18) } else { Text(verbatim: remaining > 0 ? "\(remaining)s" : L10n.t("获取验证码")) }
            }
            .buttonStyle(AuthButtonStyle(kind: .secondary))
            .disabled(session.busy || session.sendingEmail || remaining > 0)
        }
    }

    private func sendCode() async {
        guard !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { toast = L10n.t("请先填写邮箱"); return }
        if await session.sendEmail(email: email, purpose: .login) {
            session.dismissMessage()
            toast = L10n.t("验证码已发送，请查收邮件")
        }
    }

    private func open(_ page: AuthWorkflow) {
        session.dismissMessage()
        workflow = page
    }

    private func submit() {
        var invalid: [Field: String] = [:]
        if email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { invalid[.email] = L10n.t("请填写邮箱") }
        if emailCode {
            if code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { invalid[.code] = L10n.t("请填写验证码") }
        } else if password.isEmpty { invalid[.password] = L10n.t("请填写密码") }
        errors = invalid
        guard invalid.isEmpty, !session.busy else { return }
        let inputEmail = email, inputPassword = password, inputCode = code, useCode = emailCode, remember = rememberPassword
        Task {
            await session.login(email: inputEmail, password: inputPassword, code: useCode ? inputCode : "", emailCode: useCode, rememberPassword: remember)
            if !useCode, session.phase == .signedOut, session.needsTwoFactor, session.message == twoFactorPrompt { twoFactor = true }
        }
    }

    private func verifyTwoFactor(_ value: String) async -> String? {
        await session.login(email: email, password: password, code: value, emailCode: false, rememberPassword: rememberPassword)
        return session.phase == .signedOut ? session.message ?? "" : nil
    }
}

private struct TwoFactorSheet: View {
    let verify: (String) async -> String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var code = ""
    @State private var error: String?
    @State private var busy = false
    @FocusState private var focused: Bool

    var body: some View {
        let colors = ProductPalette(scheme: scheme)
        VStack(spacing: 0) {
            Text(L10n.t("两步验证")).font(.system(size: 18, weight: .semibold)).multilineTextAlignment(.center)
            Text(L10n.t("请输入您的两步验证码")).font(.system(size: 12)).foregroundStyle(colors.secondary)
                .multilineTextAlignment(.center).padding(.top, 16)
            TextField("", text: $code)
                .font(.system(size: 17, weight: .semibold)).tracking(8)
                .multilineTextAlignment(.center).textContentType(.oneTimeCode)
                #if !os(macOS)
                .keyboardType(.numberPad)
                #endif
                .focused($focused).disabled(busy)
                .textFieldStyle(.plain).productTextFieldFit()
                .padding(.horizontal, 12 - ProductMetrics.textFieldInset).frame(height: 40).productTextFieldClip()
                .background(colors.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(focused ? colors.accent : colors.outline, lineWidth: 1))
                .padding(.top, 16)
            if busy { ProgressView().controlSize(.small).padding(.top, 16) }
            if let error, !error.isEmpty {
                Text(verbatim: error).font(.system(size: 13)).foregroundStyle(colors.danger)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true).padding(.top, 12)
            }
            HStack {
                Spacer()
                Button(L10n.t("取消")) { dismiss() }.buttonStyle(ProductButtonStyle()).disabled(busy)
            }
            .padding(.top, 24)
        }
        .padding(24).frame(minWidth: 280, maxWidth: 400)
        .font(.system(size: 13)).foregroundStyle(colors.text)
        .background(colors.surface)
        .interactiveDismissDisabled(busy)
        #if os(iOS)
        .presentationDetents([.medium])
        #endif
        .onAppear { focused = true }
        .onChange(of: code) { _, value in
            let digits = String(value.filter { $0.isASCII && $0.isNumber }.prefix(6))
            if digits != value { code = digits; return }
            if digits.count == 6 { Task { await submit(digits) } }
        }
    }

    private func submit(_ value: String) async {
        guard !busy else { return }
        busy = true; error = nil
        if let failure = await verify(value) { code = ""; error = failure }
        busy = false
    }
}

#Preview {
    ContentView(session: try! AppSessionFactory.make())
}