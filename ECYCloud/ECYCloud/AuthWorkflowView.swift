import SwiftUI
import ECYCloudKit

enum AuthWorkflow: String, Identifiable {
    case register, resetPassword, terms, privacy
    var id: Self { self }
    var document: LegalDocumentKind? { self == .terms ? .terms : self == .privacy ? .privacy : nil }
}

enum AuthInput {
    static func otp(_ text: String) -> String {
        let code = String(text.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(6))
        #if os(tvOS)
        // tvOS 键盘输入途中改写大小写会丢掉随后输入的字符；面板比对邮箱验证码不区分大小写
        return code
        #else
        return code.uppercased()
        #endif
    }
    static func ascii(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { (0x20...0x7E).contains($0.value) }))
    }
}

struct AuthErrorBanner: View {
    let message: String
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let danger = ProductPalette(scheme: scheme).danger
        HStack(alignment: .top, spacing: 8) {
            ProductGlyph(name: "error_outline", size: 18)
            Text(verbatim: message).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(danger).frame(maxWidth: .infinity, alignment: .leading)
        .padding(12).background(danger.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct AuthSubmitLabel: View {
    let title: String
    let busy: Bool
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Group {
            if busy { ProgressView().controlSize(.small).tint(ProductPalette(scheme: scheme).surface) }
            else { Text(verbatim: title) }
        }.frame(maxWidth: .infinity)
    }
}

private struct AuthFieldError: ViewModifier {
    let message: String?
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            content
            if let message {
                Text(verbatim: message).font(.system(size: 12)).foregroundStyle(ProductPalette(scheme: scheme).danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

extension View {
    func authError(_ message: String?) -> some View { modifier(AuthFieldError(message: message)) }
}

struct AuthField<Content: View>: View {
    let icon: String
    var isFocused = false
    @ViewBuilder var content: Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let colors = ProductPalette(scheme: scheme)
        Group {
            #if os(tvOS)
            // 图标放进系统文字内缩区；密码显隐按钮须并排放置，叠在输入框上焦点引擎移不过去
            HStack(spacing: 0) { content }
                .overlay(alignment: .leading) { ProductGlyph(name: icon).foregroundStyle(colors.secondary).frame(width: ProductMetrics.textFieldInset) }.frame(height: 48)
            #else
            HStack(spacing: 10) {
                ProductGlyph(name: icon).foregroundStyle(colors.secondary)
                content
            }.padding(.horizontal, 18)
            #endif
        }
        .textFieldStyle(.plain).productTextFieldFit().font(.system(size: 14))
        .frame(minHeight: 48).productTextFieldClip()
        .background(colors.background, in: Capsule())
        .overlay(Capsule().strokeBorder(isFocused ? colors.accent : .clear, lineWidth: 1.5))
    }
}

struct AuthButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, link, subtle }
    var kind: Kind
    func makeBody(configuration: Configuration) -> some View { AuthButtonBody(configuration: configuration, kind: kind) }
}

private struct AuthButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: AuthButtonStyle.Kind
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isFocused) private var focused
    @State private var hovered = false

    var body: some View {
        let colors = ProductPalette(scheme: scheme)
        let block = kind == .primary || kind == .secondary
        let shape = Capsule()
        let foreground = switch kind {
        case .primary: colors.surface
        case .secondary: colors.text
        case .link: colors.accent
        case .subtle: colors.secondary
        }
        configuration.label
            .font(.system(size: 14, weight: block ? .semibold : .medium))
            .padding(.horizontal, block ? 20 : 0).frame(minHeight: block ? 48 : 40)
            .foregroundStyle(foreground)
            .background {
                if kind == .primary { shape.fill(colors.text) }
                if kind == .secondary { shape.strokeBorder(colors.outline, lineWidth: 1) }
                if hovered && enabled && block { shape.fill(foreground.opacity(0.08)) }
            }
            .opacity(!enabled ? 0.38 : configuration.isPressed ? 0.7 : 1)
            .contentShape(shape)
            .productHover { hovered = $0 }
            #if os(tvOS)
            .overlay(shape.inset(by: block ? 0 : -8).strokeBorder(focused ? colors.accent : .clear, lineWidth: 3))
            #endif
    }
}

struct AuthBackBar: View {
    let action: () -> Void
    var body: some View {
        HStack {
            Button(action: action) { Image(systemName: "arrow.left").font(.system(size: 20)).frame(width: 32, height: 40).productIconHover() }
                .buttonStyle(.productPlain).accessibilityLabel(L10n.t("返回"))
            Spacer()
        }
        .padding(16).productFocusSection()
    }
}

struct ProductAuthPanel<Content: View>: View {
    let site: URL
    let title: String
    var subtitle: String?
    var back: (() -> Void)?
    var backDisabled = false
    @ViewBuilder var content: Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width >= 880 {
                HStack(spacing: 0) {
                    AuthBrand(site: site).frame(width: min(max(geometry.size.width * 0.42, 380), 560))
                    ZStack(alignment: .topLeading) {
                        ScrollView {
                            form(split: true)
                                .padding(.horizontal, 48).padding(.vertical, 72)
                                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                        }
                        if let back { AuthBackBar(action: back).disabled(backDisabled) }
                    }
                }
            } else {
                VStack(spacing: 0) {
                    if let back { AuthBackBar(action: back).disabled(backDisabled) }
                    GeometryReader { inner in
                        ScrollView {
                            form(split: false)
                                .padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 40)
                                .frame(maxWidth: .infinity, minHeight: inner.size.height)
                        }
                    }
                }
            }
        }
        .background(ProductPalette(scheme: scheme).surface)
    }

    private func form(split: Bool) -> some View {
        let titleSize: CGFloat = split ? 30 : 28
        return VStack(spacing: 0) {
            if !split {
                HStack(spacing: 10) {
                    Image("ProductLogo").resizable().scaledToFit().frame(width: 28, height: 28).accessibilityHidden(true)
                    Text("ECY Cloud").font(.system(size: 16, weight: .semibold))
                }
                .padding(.bottom, 28)
            }
            Text(verbatim: title).font(.system(size: titleSize, weight: .bold)).tracking(titleSize * -0.03)
                .multilineTextAlignment(.center)
            if let subtitle {
                Text(verbatim: subtitle).font(.system(size: 14)).lineSpacing(3)
                    .foregroundStyle(ProductPalette(scheme: scheme).secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 8)
            }
            content.padding(.top, 32)
        }
        .frame(maxWidth: 400)
    }
}

private struct AuthBrand: View {
    let site: URL

    var body: some View {
        let glow = Color(red: 0x29 / 255, green: 0x97 / 255, blue: 1)
        VStack(spacing: 0) {
            Image("ProductLogo").resizable().scaledToFit().frame(width: 64, height: 64).accessibilityHidden(true)
                .padding(.bottom, 24)
            Text("ECY Cloud").font(.system(size: 44, weight: .bold)).tracking(44 * -0.03)
            Text(verbatim: site.host()!).font(.system(size: 15)).opacity(0.64).padding(.top, 12)
        }
        .multilineTextAlignment(.center).foregroundStyle(.white).padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(alignment: .topTrailing) {
            Circle().fill(RadialGradient(colors: [glow.opacity(0.45), glow.opacity(0)], center: .center, startRadius: 0, endRadius: 240))
                .frame(width: 480, height: 480).offset(x: 160, y: -160)
        }
        .background(LinearGradient(colors: [Color(red: 0x0B / 255, green: 0x10 / 255, blue: 0x20 / 255),
                                             Color(red: 0x0A / 255, green: 0x2A / 255, blue: 0x66 / 255)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing))
        .clipped()
    }
}

struct AuthWorkflowView: View {
    let session: ClientSession
    let page: AuthWorkflow
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var name = ""
    @State private var email = ""
    @State private var password = ""
    @State private var confirmation = ""
    @State private var invite = ""
    @State private var code = ""
    @State private var token = ""
    @State private var agreed = true
    @State private var confirming = false
    @State private var document: LegalDocumentKind?
    @State private var visible: Set<Field> = []
    @State private var errors: [Field: String] = [:]
    @State private var toast: String?
    @FocusState private var focused: Field?
    private enum Field { case name, email, password, confirmation, invite, code, token }
    private var colors: ProductPalette { ProductPalette(scheme: scheme) }

    var body: some View {
        Group {
            if let kind = page.document {
                LegalDocumentView(session: session, kind: kind)
            } else {
                ProductAuthPanel(site: session.endpoints.site, title: heading, subtitle: subheading,
                                 back: { session.dismissMessage(); dismiss() }, backDisabled: session.busy) {
                    VStack(spacing: ProductMetrics.formSpacing) {
                        if page == .register { registration }
                        else { passwordReset }
                    }
                }
            }
        }
        .font(.system(size: 13)).foregroundStyle(colors.text).tint(colors.accent)
        .background(colors.background)
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 520, minHeight: 600, idealHeight: 760)
        #endif
        .interactiveDismissDisabled(session.busy)
        .productToast($toast)
        .productSheet(item: $document) { kind in LegalDocumentView(session: session, kind: kind) }
        .task { if page.document == nil { await session.loadOptions() } }
        .onChange(of: confirming) { errors = [:] }
        .onDisappear { password = ""; confirmation = ""; token = ""; code = "" }
    }

    private var heading: String {
        page == .register ? L10n.t("创建账号") : confirming ? L10n.t("设置新密码") : L10n.t("找回密码")
    }

    private var subheading: String? {
        page == .register ? nil : confirming ? L10n.t("可粘贴邮件中的完整重置链接，或只填 token") : L10n.t("输入注册邮箱，我们会发送重置链接")
    }

    @ViewBuilder private var registration: some View {
        if let options = session.options {
            if options.registrationClosed { AuthErrorBanner(message: L10n.t("当前未开放注册")) }
            else { registrationForm(options) }
        } else if session.busy {
            ProgressView().frame(maxWidth: .infinity).frame(height: 120)
        } else {
            AuthErrorBanner(message: session.message ?? L10n.t("无法加载注册选项"))
            Button { Task { await session.loadOptions() } } label: { Text(L10n.t("重试")).frame(maxWidth: .infinity) }
                .buttonStyle(AuthButtonStyle(kind: .primary))
        }
    }

    @ViewBuilder private func registrationForm(_ options: AuthOptions) -> some View {
        field(L10n.t("用户名(昵称)"), "person_outline", $name, .name)
        field(L10n.t("邮箱(用于登录)"), "mail_outline", $email, .email)
        secretField(L10n.t("密码"), $password, .password)
        secretField(L10n.t("确认密码"), $confirmation, .confirmation)
        field(options.inviteRequired ? L10n.t("邀请码") : L10n.t("邀请码（可选）"), "card_giftcard_outlined", $invite, .invite)
        if options.emailVerify {
            HStack(alignment: .top, spacing: 12) {
                field(L10n.t("邮箱验证码"), "pin_outlined", $code, .code)
                sendButton(.registration)
            }
        }
        if let message = session.message { AuthErrorBanner(message: message).padding(.top, -4) }
        HStack(spacing: 6) {
            Button { agreed.toggle() } label: {
                Image(systemName: agreed ? "checkmark.square.fill" : "square").font(.system(size: 18))
            }
            .buttonStyle(.productPlain).accessibilityLabel(L10n.t("注册即代表同意本站 "))
            .accessibilityAddTraits(agreed ? [.isSelected] : [])
            ProductFlow(spacing: 8) {
                Button(L10n.t("注册即代表同意本站 ")) { agreed.toggle() }.buttonStyle(.productPlain)
                Button(L10n.t("服务条款") + " ›") { document = .terms }.buttonStyle(AuthButtonStyle(kind: .link))
                Button(L10n.t("隐私政策") + " ›") { document = .privacy }.buttonStyle(AuthButtonStyle(kind: .link))
            }
        }
        .padding(.top, -8)
        Button { register(options) } label: { AuthSubmitLabel(title: L10n.t("注册"), busy: session.busy) }
            .buttonStyle(AuthButtonStyle(kind: .primary)).disabled(session.busy).padding(.top, 4)
    }

    @ViewBuilder private var passwordReset: some View {
        if confirming {
            field(L10n.t("重置链接或 Token"), "key_outlined", $token, .token)
            secretField(L10n.t("新密码"), $password, .password)
            secretField(L10n.t("确认密码"), $confirmation, .confirmation)
            if let message = session.message { AuthErrorBanner(message: message).padding(.top, -4) }
            if session.options?.enablePasswordChangeResetSubscription == true {
                Text(L10n.t("修改密码后将重置订阅链接与节点密码，并需重新登录"))
                    .font(.system(size: 12)).foregroundStyle(colors.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, -8)
            }
            Button(action: confirmReset) { AuthSubmitLabel(title: L10n.t("确认重置"), busy: session.busy) }
                .buttonStyle(AuthButtonStyle(kind: .primary)).disabled(session.busy).padding(.top, 4)
            Button { confirming = false } label: { Text(L10n.t("返回上一步")).frame(maxWidth: .infinity) }
                .buttonStyle(AuthButtonStyle(kind: .link)).padding(.top, -8)
        } else {
            field(L10n.t("邮箱"), "mail_outline", $email, .email)
            if let message = session.message { AuthErrorBanner(message: message).padding(.top, -4) }
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let remaining = session.emailCooldown(.passwordReset)
                Button(action: requestReset) {
                    AuthSubmitLabel(title: remaining > 0 ? "\(remaining)s" : L10n.t("发送重置邮件"), busy: session.sendingEmail)
                }
                .buttonStyle(AuthButtonStyle(kind: .primary)).disabled(session.busy || session.sendingEmail || remaining > 0)
            }
            .padding(.top, 4)
            Button { session.dismissMessage(); confirming = true } label: { Text(L10n.t("已有重置 token？")).frame(maxWidth: .infinity) }
                .buttonStyle(AuthButtonStyle(kind: .link)).padding(.top, -8)
        }
    }

    private func field(_ title: String, _ icon: String, _ text: Binding<String>, _ key: Field) -> some View {
        AuthField(icon: icon, isFocused: focused == key) {
            TextField(title, text: text).autocorrectionDisabled()
                #if !os(macOS)
                .textInputAutocapitalization(.never)
                .keyboardType(key == .email ? .emailAddress : key == .name ? .default : .asciiCapable)
                #endif
                .focused($focused, equals: key)
        }
        .onChange(of: text.wrappedValue) { _, value in filter(key, value, text) }
        .authError(errors[key])
    }

    private func secretField(_ title: String, _ text: Binding<String>, _ key: Field) -> some View {
        AuthField(icon: "lock_outline", isFocused: focused == key) {
            Group {
                if visible.contains(key) { TextField(title, text: text) }
                else { SecureField(title, text: text) }
            }
            .textContentType(.newPassword).autocorrectionDisabled()
            #if !os(macOS)
            .textInputAutocapitalization(.never)
            #endif
            .focused($focused, equals: key)
            Button {
                if visible.contains(key) { visible.remove(key) } else { visible.insert(key) }
            } label: {
                ProductGlyph(name: visible.contains(key) ? "visibility_off_outlined" : "visibility_outlined")
                    .foregroundStyle(colors.secondary).frame(width: 28, height: 36).productIconHover()
            }
            .buttonStyle(.productPlain).accessibilityLabel(visible.contains(key) ? L10n.t("隐藏密码") : L10n.t("显示密码"))
        }
        .onChange(of: text.wrappedValue) { _, value in filter(key, value, text) }
        .authError(errors[key])
    }

    private func filter(_ key: Field, _ value: String, _ text: Binding<String>) {
        let filtered: String
        switch key {
        case .code: filtered = AuthInput.otp(value)
        case .password, .confirmation, .invite, .token: filtered = AuthInput.ascii(value)
        case .name, .email: return
        }
        if filtered != value { text.wrappedValue = filtered }
    }

    private func sendButton(_ purpose: EmailPurpose) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let remaining = session.emailCooldown(purpose)
            Button { Task { await sendCode(purpose) } } label: {
                if session.sendingEmail { ProgressView().controlSize(.small).frame(width: 18, height: 18) } else { Text(verbatim: remaining > 0 ? "\(remaining)s" : L10n.t("获取验证码")) }
            }
            .buttonStyle(AuthButtonStyle(kind: .secondary)).fixedSize().disabled(session.busy || session.sendingEmail || remaining > 0)
        }
    }

    private func sendCode(_ purpose: EmailPurpose) async {
        guard !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { toast = L10n.t("请先填写邮箱"); return }
        if await session.sendEmail(email: email, purpose: purpose) {
            session.dismissMessage()
            toast = L10n.t("验证码已发送，请查收邮件")
        }
    }

    private func validate(_ rules: [(Field, String?)]) -> Bool {
        errors = Dictionary(rules.compactMap { key, message in message.map { (key, $0) } }) { first, _ in first }
        return errors.isEmpty
    }

    private func passwordRules() -> [(Field, String?)] {
        [(.password, password.isEmpty ? L10n.t("请填写密码") : password.count < 8 ? L10n.t("密码至少 8 位") : nil),
         (.confirmation, confirmation.isEmpty ? L10n.t("请再次填写密码") : confirmation != password ? L10n.t("两次密码不一致") : nil)]
    }

    private func blank(_ text: String) -> Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func register(_ options: AuthOptions) {
        let valid = validate([
            (.name, blank(name) ? L10n.t("请填写用户名") : nil),
            (.email, blank(email) ? L10n.t("请填写邮箱") : nil),
        ] + passwordRules() + [
            (.invite, options.inviteRequired && blank(invite) ? L10n.t("请填写邀请码") : nil),
            (.code, options.emailVerify && blank(code) ? L10n.t("请填写验证码") : nil),
        ])
        guard valid, !session.busy else { return }
        guard agreed else { toast = L10n.t("请先同意服务条款与隐私政策"); return }
        Task {
            await session.register(name: name, email: email, password: password, confirmation: confirmation,
                                   invite: invite, emailCode: code, agreed: agreed)
        }
    }

    private func requestReset() {
        guard validate([(.email, blank(email) ? L10n.t("请填写邮箱") : nil)]), !session.busy, !session.sendingEmail else { return }
        Task {
            if await session.sendEmail(email: email, purpose: .passwordReset) {
                session.dismissMessage()
                toast = L10n.t("重置邮件已发送，请查收")
                confirming = true
            }
        }
    }

    private func confirmReset() {
        guard validate([(.token, blank(token) ? L10n.t("请填写重置链接或 token") : nil)] + passwordRules()), !session.busy else { return }
        Task { await session.resetPassword(tokenInput: token, password: password, confirmation: confirmation) }
    }
}

struct LegalDocumentView: View {
    let session: ClientSession
    let kind: LegalDocumentKind
    @State private var document: RichDocument?
    @State private var failure: String?
    @State private var loading = false
    @Environment(\.colorScheme) private var scheme

    // 对应 legal_document_page.dart：AppBar 标题，加载、失败与空内容居中，正文四周留 16
    var body: some View {
        let colors = ProductPalette(scheme: scheme)
        FeatureSheet(title: kind.title, appBar: true) {
            Group {
                if let document, !document.runs.isEmpty {
                    ScrollView {
                        RichDocumentText(document: document).productTextSelection().frame(maxWidth: .infinity, alignment: .leading).padding(16)
                    }
                } else if let failure {
                    VStack(spacing: 16) {
                        Text(verbatim: failure).foregroundStyle(colors.danger).multilineTextAlignment(.center)
                        Button(L10n.t("重试")) { Task { await load() } }.buttonStyle(ProductButtonStyle(filled: true))
                    }.padding(24)
                } else if document != nil {
                    Text(kind == .terms ? L10n.t("暂无服务条款") : L10n.t("暂无隐私政策"))
                } else { ProgressView() }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: kind) { await load() }
    }

    private func load() async {
        guard !loading else { return }
        loading = true; failure = nil
        defer { loading = false }
        do { document = try await session.document(kind) }
        catch is CancellationError { }
        catch { failure = (error as? ClientError)?.localizedDescription ?? L10n.t("加载失败，请重试。") }
    }
}

struct RichDocumentText: View {
    let document: RichDocument
    var body: some View {
        #if os(tvOS)
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(chunks.enumerated()), id: \.offset) { _, chunk in
                Text(chunk).font(.system(size: 13)).lineSpacing(5).frame(maxWidth: .infinity, alignment: .leading).padding(6).productScrollStop()
            }
        }.padding(-6)
        #else
        Text(attributed).font(.system(size: 13)).lineSpacing(5)
        #endif
    }
    private func part(_ text: String, _ run: RichDocument.Run) -> AttributedString {
        var part = AttributedString(text)
        var intent: InlinePresentationIntent = []
        if run.bold { intent.insert(.stronglyEmphasized) }
        if run.italic { intent.insert(.emphasized) }
        part.inlinePresentationIntent = intent
        part.link = run.link
        return part
    }
    private var attributed: AttributedString {
        document.runs.reduce(into: AttributedString()) { $0.append(part($1.text, $1)) }
    }
    #if os(tvOS)
    private var chunks: [AttributedString] {
        var chunks: [AttributedString] = []
        var current = AttributedString()
        var length = 0
        for run in document.runs {
            let lines = run.text.components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                if index > 0 {
                    if length >= 300 { chunks.append(current); current = AttributedString(); length = 0 }
                    else { current.append(AttributedString("\n")) }
                }
                current.append(part(line, run))
                length += line.count
            }
        }
        if length > 0 || chunks.isEmpty { chunks.append(current) }
        return chunks
    }
    #endif
}
