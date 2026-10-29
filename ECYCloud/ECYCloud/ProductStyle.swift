import SwiftUI
import ECYCloudKit

extension View {
    @ViewBuilder func productTextSelection() -> some View {
        #if os(tvOS)
        self
        #else
        textSelection(.enabled)
        #endif
    }

    // tvOS 的 isFocused 取最近的可聚焦祖先，须挂在按钮标签或按钮样式内部才对应该按钮
    @ViewBuilder func productHover(_ action: @escaping (Bool) -> Void) -> some View {
        #if os(tvOS)
        modifier(ProductFocusHover(action: action))
        #else
        onHover(perform: action)
        #endif
    }

    @ViewBuilder func productFocusRing(_ shape: some InsettableShape) -> some View {
        #if os(tvOS)
        modifier(ProductFocusRing(shape: shape))
        #else
        self
        #endif
    }

    // tvOS 文本框自带系统底板（未聚焦深色、聚焦白色），去掉后才露出与其它平台一致的胶囊
    @ViewBuilder func productTextFieldFit() -> some View {
        #if os(tvOS)
        focusEffectDisabled().background(ProductTextFieldPlate().frame(width: 0, height: 0))
        #else
        self
        #endif
    }

    // tvOS 文本框固定 72 高，由外层胶囊裁掉溢出的系统底板
    @ViewBuilder func productTextFieldClip() -> some View {
        #if os(tvOS)
        clipShape(Capsule().inset(by: 1))
        #else
        self
        #endif
    }

    // tvOS 只随焦点滚动，纯文本的行或段落须可聚焦才能用遥控器翻阅
    @ViewBuilder func productScrollStop() -> some View {
        #if os(tvOS)
        Button {} label: { self }.buttonStyle(.productPlain)
        #else
        self
        #endif
    }

    @ViewBuilder func productFocusWrap() -> some View {
        #if os(tvOS)
        background(ProductFocusWrap().frame(width: 0, height: 0))
        #else
        self
        #endif
    }

    @ViewBuilder func productFocusSection() -> some View {
        #if os(tvOS)
        focusSection()
        #else
        self
        #endif
    }

    func productHoverLayer(_ shape: some InsettableShape, _ tone: KeyPath<ProductPalette, Color> = \.hover, opacity: Double = 1, enabled: Bool = true) -> some View {
        modifier(ProductHoverLayer(shape: shape, tone: tone, color: nil, opacity: opacity, enabled: enabled))
    }

    func productHoverLayer(_ shape: some InsettableShape, color: Color, opacity: Double) -> some View {
        modifier(ProductHoverLayer(shape: shape, tone: nil, color: color, opacity: opacity, enabled: true))
    }

    // 对应 M3 IconButton：悬浮叠 onSurfaceVariant 8% 圆形状态层
    func productIconHover() -> some View { productHoverLayer(Circle(), \.secondary, opacity: 0.08) }

    // 对应 Tooltip：由 productMenuHost 画在锚点右侧并垂直居中，右侧放不下时改到锚点下方（再不够则上方）
    @ViewBuilder func productTooltip<Content: View>(isPresented: Binding<Bool>,
                                                   @ViewBuilder content: @escaping () -> Content) -> some View {
        #if os(tvOS)
        sheet(isPresented: isPresented) { content().fixedSize(horizontal: false, vertical: true).frame(maxWidth: 320).padding(50) }
        #else
        modifier(ProductTooltip(isPresented: isPresented, bubble: content))
        #endif
    }

    // tvOS 的 sheet 按内容理想尺寸排版，含 GeometryReader 的整页会被压成零宽，整页弹层在 tvOS 改为全屏覆盖
    @ViewBuilder func productSheet<Content: View>(isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil,
                                                 @ViewBuilder content: @escaping () -> Content) -> some View {
        #if os(tvOS)
        fullScreenCover(isPresented: isPresented, onDismiss: onDismiss, content: content)
        #else
        sheet(isPresented: isPresented, onDismiss: onDismiss, content: content)
        #endif
    }

    @ViewBuilder func productSheet<Item: Identifiable, Content: View>(item: Binding<Item?>, onDismiss: (() -> Void)? = nil,
                                                                     @ViewBuilder content: @escaping (Item) -> Content) -> some View {
        #if os(tvOS)
        fullScreenCover(item: item, onDismiss: onDismiss, content: content)
        #else
        sheet(item: item, onDismiss: onDismiss, content: content)
        #endif
    }

    // 对应 MenuAnchor：锚点下方 4、圆角 16、elevation 8，左缘对齐锚点（trailing 时右缘对齐），下方放不下时翻到锚点上方。
    // 菜单由祖先视图的 productMenuHost 绘制；所在页面（含 sheet / 导航目标的根视图）缺少它时菜单不会出现。
    @ViewBuilder func productMenu<Content: View>(isPresented: Binding<Bool>, size: CGSize, trailing: Bool = false,
                                                @ViewBuilder content: @escaping () -> Content) -> some View {
        #if os(tvOS)
        modifier(ProductTVMenu(isPresented: isPresented, size: size, trailing: trailing, menu: content))
        #else
        anchorPreference(key: ProductMenuKey.self, value: .bounds) { anchor in
            isPresented.wrappedValue ? [ProductMenuRequest(anchor: anchor, size: size, trailing: trailing,
                                                           content: AnyView(content()), dismiss: { isPresented.wrappedValue = false })] : []
        }
        #endif
    }

    @ViewBuilder func productMenuHost() -> some View {
        #if os(tvOS)
        self
        #else
        modifier(ProductMenuHost())
        #endif
    }

    @ViewBuilder func productGlass(_ fallback: Color, in shape: some Shape) -> some View {
        #if os(visionOS)
        background(fallback, in: shape)
        #else
        if #available(iOS 26.0, macOS 26.0, tvOS 26.0, *) { glassEffect(.regular, in: shape) } else { background(fallback, in: shape) }
        #endif
    }

    // 屏幕或窗口圆角未计入安全区时（iPhone Duo 状态栏移入竖向栏、visionOS 窗口圆角）补足边距，避免四角内容被裁切；
    // 竖向栏状态区的高度须在 NavigationStack 之外读取，经环境传给页面
    @ViewBuilder func productCornerPadding() -> some View {
        #if os(visionOS)
        padding(16)
        #elseif os(iOS)
        GeometryReader { proxy in
            let top = ProductMetrics.cornerTop(proxy)
            padding(.top, top).environment(\.productVerticalBarTop, ProductMetrics.verticalBarTop(proxy).map { max(0, $0 - top) })
        }
        #else
        self
        #endif
    }

    @ViewBuilder func productVerticalBarMargin(_ edge: HorizontalEdge, width: CGFloat) -> some View {
        #if os(iOS)
        HStack(spacing: 0) {
            if edge == .leading { VerticalBarMargin(edge: edge, width: width) }
            self
            if edge == .trailing { VerticalBarMargin(edge: edge, width: width) }
        }
        #else
        self
        #endif
    }
}

extension EnvironmentValues {
    @Entry var productVerticalBarTop: CGFloat? = nil
}

#if os(iOS)
// 系统竖向栏的状态图标排在 edgeInsets(for: .bar) 给出的区域中线上，该区域与屏幕边缘另有间距、不在安全区中线；
// 系统可能放宽请求的宽度，按返回区域的实际中线计算外侧留白，使导航与状态图标同一中线
private struct VerticalBarMargin: UIViewRepresentable {
    let edge: HorizontalEdge
    let width: CGFloat
    func makeUIView(context: Context) -> MarginView {
        let view = MarginView()
        view.setContentHuggingPriority(.required, for: .horizontal)
        return view
    }
    func updateUIView(_ view: MarginView, context: Context) {
        view.right = (edge == .trailing) == (context.environment.layoutDirection == .leftToRight)
        view.width = width
        view.invalidateIntrinsicContentSize()
    }
    final class MarginView: UIView {
        var right = true
        var width: CGFloat = 0
        override var intrinsicContentSize: CGSize {
            guard #available(iOS 27.1, *), let window else { return CGSize(width: 0, height: UIView.noIntrinsicMetric) }
            let insets = window.edgeInsets(for: .bar(onEdge: right ? .right : .left, extent: ProductMetrics.tapTarget))
            let center = (right ? insets.right : insets.left) + (window.bounds.width - insets.left - insets.right) / 2
            return CGSize(width: max(0, 2 * center - width), height: UIView.noIntrinsicMetric)
        }
        override func didMoveToWindow() { invalidateIntrinsicContentSize() }
    }
}
#endif

#if !os(tvOS)
struct ProductMenuRequest {
    let anchor: Anchor<CGRect>
    let size: CGSize
    let trailing: Bool
    let content: AnyView
    let dismiss: () -> Void
    var tooltip = false
    var hover: ((Bool) -> Void)?
}

// 对应 Tooltip 的鼠标规则：移入锚点或气泡即显示，两者都移出 100ms 后收起；点击显示且未悬浮时 8 秒后收起
private struct ProductTooltip<Bubble: View>: ViewModifier {
    @Binding var isPresented: Bool
    let bubble: () -> Bubble
    @State private var hovering = Set<Int>()
    @State private var dismissal: Task<Void, Never>?
    func body(content: Content) -> some View {
        content
            .onHover { hover(0, $0) }
            .anchorPreference(key: ProductMenuKey.self, value: .bounds) { anchor in
                isPresented ? [ProductMenuRequest(anchor: anchor, size: .zero, trailing: false, content: AnyView(bubble()),
                                                  dismiss: { isPresented = false }, tooltip: true, hover: { hover(1, $0) })] : []
            }
            .onChange(of: isPresented) { _, shown in
                dismissal?.cancel()
                if shown && hovering.isEmpty { dismiss(after: .seconds(8)) }
            }
    }
    private func hover(_ part: Int, _ inside: Bool) {
        if inside { hovering.insert(part) } else { hovering.remove(part) }
        dismissal?.cancel()
        if inside { isPresented = true } else if hovering.isEmpty { dismiss(after: .milliseconds(100)) }
    }
    private func dismiss(after delay: Duration) {
        dismissal = Task { @MainActor in
            try? await Task.sleep(for: delay)
            if !Task.isCancelled { isPresented = false }
        }
    }
}
struct ProductMenuKey: PreferenceKey {
    static let defaultValue: [ProductMenuRequest] = []
    static func reduce(value: inout [ProductMenuRequest], nextValue: () -> [ProductMenuRequest]) { value += nextValue() }
}

private struct ProductMenuHost: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content
            .overlayPreferenceValue(ProductMenuKey.self) { menus in
                if let menu = menus.last {
                    GeometryReader { proxy in
                        let anchor = proxy[menu.anchor]
                        let x = menu.trailing ? anchor.maxX - menu.size.width : anchor.minX
                        let below = anchor.maxY + 4 + menu.size.height <= proxy.size.height
                        ZStack(alignment: .topLeading) {
                            if menu.tooltip {
                                // 点击层须让出锚点，否则锚点收不到悬浮与点击
                                Color.clear.contentShape(Path { $0.addRect(CGRect(origin: .zero, size: proxy.size)); $0.addRect(anchor) }, eoFill: true)
                                    .onTapGesture(perform: menu.dismiss)
                                ProductTooltipBubble(anchor: anchor, bounds: proxy.size, content: menu.content).onHover { menu.hover?($0) }
                            } else {
                            Color.clear.contentShape(Rectangle()).onTapGesture(perform: menu.dismiss)
                            menu.content
                                .frame(width: menu.size.width, height: menu.size.height)
                                .background(ProductPalette(scheme: scheme).surface)
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                                .shadow(color: .black.opacity(0.24), radius: 8, y: 4)
                                .offset(x: min(max(0, x), max(0, proxy.size.width - menu.size.width)),
                                        y: below ? anchor.maxY + 4 : max(0, anchor.minY - 4 - menu.size.height))
                                #if os(macOS)
                                .onExitCommand(perform: menu.dismiss)
                                #endif
                            }
                        }
                    }
                }
            }
            .transformPreference(ProductMenuKey.self) { $0 = [] }
    }
}

// 对应 M3 Tooltip：inverseSurface 底、圆角 4、最大宽 320、距屏幕边 10；触控端内边距 16×4、最小高 32，桌面 8×0、最小高 24
private struct ProductTooltipBubble: View {
    let anchor: CGRect
    let bounds: CGSize
    let content: AnyView
    @State private var size: CGSize?
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let colors = ProductPalette(scheme: scheme)
        let room = bounds.width - 10 - anchor.maxX - 8
        let right = room >= 160
        let measured = size ?? .zero
        let below = anchor.midY + 24 + measured.height <= bounds.height - 10
        content
            .font(.system(size: 12)).foregroundStyle(colors.surface)
            .fixedSize(horizontal: false, vertical: true)
            #if os(macOS)
            .padding(.horizontal, 8).frame(minHeight: 24)
            #else
            .padding(.horizontal, 16).padding(.vertical, 4).frame(minHeight: 32)
            #endif
            .background(colors.text, in: RoundedRectangle(cornerRadius: 4))
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .frame(maxWidth: min(320, right ? room : bounds.width - 20), alignment: .leading)
            .opacity(size == nil ? 0 : 1)
            .offset(x: right ? anchor.maxX + 8 : min(max(10, anchor.midX - measured.width / 2), bounds.width - measured.width - 10),
                    y: right ? min(max(10, anchor.midY - measured.height / 2), bounds.height - measured.height - 10)
                        : below ? anchor.midY + 24 : anchor.midY - 24 - measured.height)
    }
}
#endif

private struct ProductHoverLayer<S: InsettableShape>: ViewModifier {
    let shape: S
    let tone: KeyPath<ProductPalette, Color>?
    let color: Color?
    let opacity: Double
    let enabled: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var environmentEnabled
    @State private var hovered = false
    func body(content: Content) -> some View {
        let fill = color ?? tone.map { ProductPalette(scheme: scheme)[keyPath: $0] } ?? .clear
        content
            .background { if hovered && enabled && environmentEnabled { shape.fill(fill.opacity(opacity)) } }
            .productHover { hovered = $0 }
            .productFocusRing(shape)
    }
}

#if os(tvOS)
// 上下键在最顶 / 最底端移不动时，绕到同一列的另一端（对应 television_navigation.dart 的循环切换）
private struct ProductFocusWrap: UIViewRepresentable {
    func makeUIView(context: Context) -> WrapView { WrapView() }
    func updateUIView(_ view: WrapView, context: Context) {}

    // SwiftUI 不接受 UIKit 的程序化聚焦，只能在窗口顶 / 底边放引导，由焦点引擎移入后重定向
    final class WrapView: UIView {
        private var observer: NSObjectProtocol?
        private let top = UIFocusGuide()
        private let bottom = UIFocusGuide()

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { return }
            for (guide, edge) in [(top, window.topAnchor), (bottom, window.bottomAnchor)] {
                guide.owningView?.removeLayoutGuide(guide)
                window.addLayoutGuide(guide)
                guide.isEnabled = false
                NSLayoutConstraint.activate([
                    guide.leadingAnchor.constraint(equalTo: window.leadingAnchor),
                    guide.trailingAnchor.constraint(equalTo: window.trailingAnchor),
                    guide.heightAnchor.constraint(equalToConstant: 1),
                    guide === top ? guide.topAnchor.constraint(equalTo: edge) : guide.bottomAnchor.constraint(equalTo: edge)
                ])
            }
            observer = NotificationCenter.default.addObserver(forName: UIFocusSystem.didUpdateNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            }
        }

        private func update() {
            top.isEnabled = false
            bottom.isEnabled = false
            guard let window, let current = UIFocusSystem.focusSystem(for: window)?.focusedItem, var root = window.rootViewController else { return }
            while let presented = root.presentedViewController, !presented.isBeingDismissed { root = presented }
            var items: [(item: UIFocusItem, frame: CGRect)] = []
            var seen: Set<ObjectIdentifier> = []
            collect(root.view, into: &items, seen: &seen, depth: 0)
            guard let origin = items.first(where: { $0.item === current }) else { return }
            let others = items.filter { $0.item !== current }
            let overlapping = others.filter { $0.frame.maxX > origin.frame.minX && $0.frame.minX < origin.frame.maxX }
            let column = overlapping.isEmpty ? others : overlapping
            // 坐标按未滚动的整页布局换算，滚动区里尚未显示的按钮也在其中；整列没有其它控件时（如左上角返回键）先去斜向最近的，再绕到另一端
            let diagonal = overlapping.isEmpty
            if !overlapping.contains(where: { $0.frame.midY < origin.frame.minY }),
               let target = (diagonal ? nearest(others.filter { $0.frame.maxY <= origin.frame.minY + 1 }, to: origin.frame) : nil) ?? pick(column, origin: origin.frame, top: false) {
                top.preferredFocusEnvironments = [target]; top.isEnabled = true
            }
            if !overlapping.contains(where: { $0.frame.midY > origin.frame.maxY }),
               let target = (diagonal ? nearest(others.filter { $0.frame.minY >= origin.frame.maxY - 1 }, to: origin.frame) : nil) ?? pick(column, origin: origin.frame, top: true) {
                bottom.preferredFocusEnvironments = [target]; bottom.isEnabled = true
            }
        }

        private func nearest(_ candidates: [(item: UIFocusItem, frame: CGRect)], to origin: CGRect) -> UIFocusItem? {
            candidates.min { hypot($0.frame.midX - origin.midX, $0.frame.midY - origin.midY) < hypot($1.frame.midX - origin.midX, $1.frame.midY - origin.midY) }?.item
        }

        private func pick(_ column: [(item: UIFocusItem, frame: CGRect)], origin: CGRect, top: Bool) -> UIFocusItem? {
            guard let edge = top ? column.map(\.frame.minY).min() : column.map(\.frame.maxY).max() else { return nil }
            return column.filter { abs((top ? $0.frame.minY : $0.frame.maxY) - edge) < 8 }
                .min { abs($0.frame.midX - origin.midX) < abs($1.frame.midX - origin.midX) }?.item
        }

        private func collect(_ environment: UIFocusEnvironment, into items: inout [(item: UIFocusItem, frame: CGRect)],
                             seen: inout Set<ObjectIdentifier>, depth: Int) {
            guard depth < 12, let container = environment.focusItemContainer, let window else { return }
            let space = container.coordinateSpace
            for item in container.focusItems(in: CGRect(x: -1e5, y: -1e5, width: 2e5, height: 2e5)) where seen.insert(ObjectIdentifier(item)).inserted {
                if item.canBecomeFocused { items.append((item, space.convert(item.frame, to: window))) }
                collect(item, into: &items, seen: &seen, depth: depth + 1)
            }
        }
    }
}

// 与其它平台的 MenuAnchor 同样定位在锚点下方；以透明全屏呈现承载，焦点才会限定在菜单内
private struct ProductTVMenu<Menu: View>: ViewModifier {
    @Binding var isPresented: Bool
    let size: CGSize
    let trailing: Bool
    @ViewBuilder let menu: () -> Menu
    @State private var anchor: CGRect = .zero
    @State private var shown = false
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content
            .background { GeometryReader { proxy in Color.clear.onAppear { anchor = proxy.frame(in: .global) }.onChange(of: proxy.frame(in: .global)) { _, value in anchor = value } } }
            .onChange(of: isPresented, initial: true) { _, value in
                var transaction = Transaction(); transaction.disablesAnimations = true
                withTransaction(transaction) { shown = value }
            }
            .fullScreenCover(isPresented: Binding(get: { shown }, set: { if !$0 { isPresented = false } })) {
                GeometryReader { proxy in
                    let screen = proxy.frame(in: .global)
                    let x = trailing ? anchor.maxX - size.width : anchor.minX
                    let below = anchor.maxY + 4 + size.height <= screen.maxY
                    menu()
                        .frame(width: size.width, height: size.height)
                        .background(ProductPalette(scheme: scheme).surface)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .shadow(color: .black.opacity(0.24), radius: 8, y: 4)
                        .offset(x: min(max(0, x), max(0, screen.width - size.width)) - screen.minX,
                                y: (below ? anchor.maxY + 4 : max(0, anchor.minY - 4 - size.height)) - screen.minY)
                }
                .ignoresSafeArea()
                .presentationBackground(.clear)
                .onExitCommand { isPresented = false }
            }
    }
}

private struct ProductTextFieldPlate: UIViewRepresentable {
    func makeUIView(context: Context) -> PlateView { PlateView() }
    func updateUIView(_ view: PlateView, context: Context) { view.schedule() }

    // 系统文本框的文字也画在底板的视觉效果视图里，只能清掉效果与背景，不能隐藏整块
    final class PlateView: UIView {
        private var observer: NSObjectProtocol?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard window != nil else { return }
            observer = NotificationCenter.default.addObserver(forName: UIFocusSystem.didUpdateNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.schedule() }
            }
            schedule()
        }
        func schedule() { DispatchQueue.main.async { [weak self] in self?.clear() } }
        private func clear() {
            guard let window else { return }
            var stack: [UIView] = [window]
            while let view = stack.popLast() {
                if let field = view as? UITextField { recolor(field); strip(field) } else { stack += view.subviews }
            }
        }
        // 聚焦时系统按白色底板改用深色文字，底板去掉后须改回调色板的正文 / 次要色
        private func recolor(_ field: UITextField) {
            let colors = ProductPalette(scheme: field.traitCollection.userInterfaceStyle == .dark ? .dark : .light)
            field.textColor = UIColor(colors.text)
            var stack = field.subviews
            while let view = stack.popLast() {
                if let label = view as? UILabel { label.textColor = UIColor(colors.secondary) } else { stack += view.subviews }
            }
        }
        private func strip(_ view: UIView) {
            for sub in view.subviews where !(sub is UILabel) {
                if let effect = sub as? UIVisualEffectView {
                    effect.effect = nil
                    effect.subviews.filter { $0 !== effect.contentView }.forEach { $0.isHidden = true }
                }
                sub.backgroundColor = .clear
                sub.layer.shadowOpacity = 0
                strip(sub)
            }
        }
    }
}

private struct ProductFocusHover: ViewModifier {
    let action: (Bool) -> Void
    @Environment(\.isFocused) private var focused
    func body(content: Content) -> some View {
        content.onChange(of: focused, initial: true) { _, value in action(value) }
    }
}

private struct ProductFocusRing<S: InsettableShape>: ViewModifier {
    let shape: S
    @Environment(\.isFocused) private var focused
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content
            .overlay(shape.strokeBorder(focused ? ProductPalette(scheme: scheme).accent : .clear, lineWidth: 3))
            .preference(key: ProductFocusRingKey.self, value: true)
    }
}

private struct ProductFocusRingKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

struct ProductPlainButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var focused
    @Environment(\.colorScheme) private var scheme
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
            .overlayPreferenceValue(ProductFocusRingKey.self) { ringed in
                RoundedRectangle(cornerRadius: 6).strokeBorder(
                    focused && !ringed ? ProductPalette(scheme: scheme).accent : .clear, lineWidth: 3)
            }
    }
}
extension ButtonStyle where Self == ProductPlainButtonStyle {
    static var productPlain: ProductPlainButtonStyle { ProductPlainButtonStyle() }
}
#else
extension PrimitiveButtonStyle where Self == PlainButtonStyle {
    static var productPlain: PlainButtonStyle { .plain }
}
#endif

struct ProductTextEditor: View {
    @Binding var text: String
    var body: some View {
        #if os(tvOS)
        TextField(L10n.t("输入内容"), text: $text, axis: .vertical).lineLimit(3...8)
        #else
        TextEditor(text: $text)
        #endif
    }
}

#if !os(tvOS)
// TextEditor 不接受文字内缩与 lineFragmentPadding，也收不回系统滚动条，只能直接配置系统文本视图
@MainActor @Observable final class ProductScrollMetrics {
    var offset: CGFloat = 0
    var viewport: CGFloat = 0
    var content: CGFloat = 0
    @ObservationIgnored var scrollTo: (CGFloat) -> Void = { _ in }
}

// 对应 theme.dart 的 scrollbarTheme 与 multiline_content_field.dart：拇指宽 7、离右缘 2，两端各让出圆角半径减半宽，最短 48；
// 平时隐藏，滚动后显示、停 600ms 再 300ms 淡出，悬停或拖动时常显并换成 outline 0.6；点轨道按视口 0.8 翻页
struct ProductScrollbar: View {
    let metrics: ProductScrollMetrics
    let cornerRadius: CGFloat
    static let gutter: CGFloat = 16
    // 触屏没有悬停，隐藏的拇指不接收触摸，免得右缘这一列吞掉文本滚动
    #if os(macOS)
    private static let hoverReveals = true
    #else
    private static let hoverReveals = false
    #endif
    private let thickness: CGFloat = 7
    @State private var shown = false
    @State private var hovering = false
    @State private var dragOrigin: CGFloat?
    @State private var fade: Task<Void, Never>?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { proxy in
            let scrollable = metrics.content - metrics.viewport
            if scrollable > 0 {
                let margin = cornerRadius - thickness / 2
                let track = max(0, proxy.size.height - margin * 2)
                let length = min(track, max(48, track * metrics.viewport / metrics.content))
                let travel = track - length
                let top = margin + travel * min(max(metrics.offset / scrollable, 0), 1)
                let active = hovering || dragOrigin != nil
                ZStack(alignment: .topTrailing) {
                    #if os(macOS)
                    Color.clear.frame(width: Self.gutter).contentShape(Rectangle())
                        .onHover { inside in hovering = inside; if !inside { flash() } }
                        .onTapGesture { point in
                            let page = metrics.viewport * 0.8 * (point.y < top ? -1 : 1)
                            metrics.scrollTo(min(max(metrics.offset + page, 0), scrollable))
                        }
                    #endif
                    Capsule().fill(active ? (scheme == .dark ? Color.white : Color.black).opacity(0.6) : ProductPalette(scheme: scheme).segment)
                        .frame(width: thickness, height: length)
                        .contentShape(Capsule())
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let origin = dragOrigin ?? metrics.offset
                                dragOrigin = origin
                                guard travel > 0 else { return }
                                metrics.scrollTo(min(max(origin + value.translation.height * scrollable / travel, 0), scrollable))
                            }
                            .onEnded { _ in dragOrigin = nil; flash() })
                        .padding(.top, top).padding(.trailing, 2)
                        .opacity(shown || active ? 1 : 0)
                        .allowsHitTesting(shown || active || Self.hoverReveals)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .animation(.linear(duration: 0.3), value: shown || active)
            }
        }
        .onChange(of: metrics.offset) { flash() }
    }

    private func flash() {
        shown = true
        fade?.cancel()
        fade = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            if !Task.isCancelled { shown = false }
        }
    }
}

#if os(macOS)
struct ProductTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    let leading: CGFloat
    let trailing: CGFloat
    let metrics: ProductScrollMetrics

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = FocusTextView.scrollableTextView()
        let view = scroll.documentView as! FocusTextView
        view.coordinator = context.coordinator
        view.delegate = context.coordinator
        view.drawsBackground = false
        view.isRichText = false
        view.allowsUndo = true
        view.font = .systemFont(ofSize: 13)
        let style = NSMutableParagraphStyle()
        style.lineSpacing = ProductMetrics.editorLineSpacing
        view.defaultParagraphStyle = style
        view.typingAttributes[.paragraphStyle] = style
        view.textContainer?.lineFragmentPadding = 0
        view.leading = leading
        view.textContainerInset = NSSize(width: (leading + trailing) / 2, height: ProductMetrics.editorLineSpacing / 2)
        view.string = text
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        context.coordinator.observe(scroll)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? NSTextView else { return }
        let color = NSColor(ProductPalette(scheme: context.environment.colorScheme).text)
        view.textColor = color
        view.insertionPointColor = color
        if view.string != text { view.string = text }
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ProductTextView
        private weak var scroll: NSScrollView?
        private var observers: [NSObjectProtocol] = []
        init(_ parent: ProductTextView) { self.parent = parent }
        func observe(_ scroll: NSScrollView) {
            self.scroll = scroll
            scroll.contentView.postsBoundsChangedNotifications = true
            scroll.documentView?.postsFrameChangedNotifications = true
            observers = [(NSView.boundsDidChangeNotification, scroll.contentView), (NSView.frameDidChangeNotification, scroll.documentView)].map { name, object in
                NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.publish() }
                }
            }
            parent.metrics.scrollTo = { [weak scroll] offset in
                guard let scroll else { return }
                scroll.contentView.scroll(to: NSPoint(x: 0, y: offset))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            publish()
        }
        private func publish() {
            guard let scroll, let document = scroll.documentView else { return }
            let bounds = scroll.contentView.bounds
            parent.metrics.offset = bounds.minY
            parent.metrics.viewport = bounds.height
            parent.metrics.content = document.frame.height
        }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
        }
        isolated deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }

    final class FocusTextView: NSTextView {
        weak var coordinator: Coordinator?
        var leading: CGFloat = 0
        // textContainerInset 只能左右对称，起点另移到 leading，右侧余下的即 trailing
        override var textContainerOrigin: NSPoint { NSPoint(x: leading, y: super.textContainerOrigin.y) }
        override func becomeFirstResponder() -> Bool {
            let became = super.becomeFirstResponder()
            if became { coordinator?.parent.focused = true }
            return became
        }
        override func resignFirstResponder() -> Bool {
            let resigned = super.resignFirstResponder()
            if resigned { coordinator?.parent.focused = false }
            return resigned
        }
        // 文本视图的 I 形光标区域盖着右侧滚动条那一列，对应 Flutter 在该列改回箭头
        override func cursorUpdate(with event: NSEvent) {
            if inGutter(event) { NSCursor.arrow.set() } else { super.cursorUpdate(with: event) }
        }
        override func mouseMoved(with event: NSEvent) {
            super.mouseMoved(with: event)
            if inGutter(event) { NSCursor.arrow.set() }
        }
        private func inGutter(_ event: NSEvent) -> Bool {
            guard let scroll = enclosingScrollView else { return false }
            return scroll.convert(event.locationInWindow, from: nil).x >= scroll.bounds.width - ProductScrollbar.gutter
        }
    }
}
#else
struct ProductTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    let leading: CGFloat
    let trailing: CGFloat
    let metrics: ProductScrollMetrics

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> LayoutTextView {
        let view = LayoutTextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.font = .systemFont(ofSize: 13)
        let style = NSMutableParagraphStyle()
        style.lineSpacing = ProductMetrics.editorLineSpacing
        view.typingAttributes[.paragraphStyle] = style
        view.showsVerticalScrollIndicator = false
        view.textContainer.lineFragmentPadding = 0
        view.textContainerInset = UIEdgeInsets(top: ProductMetrics.editorLineSpacing / 2, left: leading,
                                               bottom: ProductMetrics.editorLineSpacing / 2, right: trailing)
        view.text = text
        view.onLayout = { [weak coordinator = context.coordinator] view in coordinator?.publish(view) }
        metrics.scrollTo = { [weak view] offset in view?.setContentOffset(CGPoint(x: 0, y: offset), animated: false) }
        return view
    }

    func updateUIView(_ view: LayoutTextView, context: Context) {
        context.coordinator.parent = self
        view.textColor = UIColor(ProductPalette(scheme: context.environment.colorScheme).text)
        if view.text != text { view.text = text }
    }

    final class LayoutTextView: UITextView {
        var onLayout: (UIScrollView) -> Void = { _ in }
        override func layoutSubviews() {
            super.layoutSubviews()
            onLayout(self)
        }
    }

    @MainActor final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ProductTextView
        init(_ parent: ProductTextView) { self.parent = parent }
        func publish(_ view: UIScrollView) {
            parent.metrics.offset = view.contentOffset.y
            parent.metrics.viewport = view.bounds.height
            parent.metrics.content = view.contentSize.height
        }
        func scrollViewDidScroll(_ view: UIScrollView) { publish(view) }
        func textViewDidChange(_ view: UITextView) { parent.text = view.text }
        func textViewDidBeginEditing(_ view: UITextView) { parent.focused = true }
        func textViewDidEndEditing(_ view: UITextView) { parent.focused = false }
    }
}
#endif
#endif

struct ProductDisclosureGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    @State private var expanded = false
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title; self.content = content()
    }
    var body: some View {
        #if os(tvOS)
        VStack(alignment: .leading, spacing: 8) {
            Button { expanded.toggle() } label: {
                Label(title, systemImage: expanded ? "chevron.down" : "chevron.right")
            }.buttonStyle(.productPlain)
            if expanded { content }
        }
        #else
        DisclosureGroup(title) { content }
        #endif
    }
}

enum ProductMetrics {
    // 各平台统一使用 theme.dart 桌面端的 minTapTarget 32
    static let tapTarget: CGFloat = 32
    // multiline_content_field.dart 的正文为 13 号字、1.5 倍行高
    #if os(macOS)
    static let editorLineSpacing = 13 * 1.5 - NSLayoutManager().defaultLineHeight(for: .systemFont(ofSize: 13))
    #else
    static let editorLineSpacing = 13 * 1.5 - UIFont.systemFont(ofSize: 13).lineHeight
    #endif
    #if os(iOS)
    static func cornerTop(_ proxy: GeometryProxy) -> CGFloat {
        guard #available(iOS 26.0, *), proxy.safeAreaInsets.top == 0 else { return 0 }
        let corners = proxy.containerCornerInsets
        let corner = corners.topLeading.height <= corners.topTrailing.height ? corners.topLeading : corners.topTrailing
        guard min(proxy.safeAreaInsets.leading, proxy.safeAreaInsets.trailing) < corner.width else { return 0 }
        return (corner.height * (1 - 1 / 2.squareRoot())).rounded(.up)
    }
    static func verticalBarTop(_ proxy: GeometryProxy) -> CGFloat? {
        guard #available(iOS 26.0, *) else { return nil }
        let insets = proxy.safeAreaInsets, corners = proxy.containerCornerInsets
        if insets.trailing > insets.leading { return corners.topTrailing.height }
        if insets.leading > insets.trailing { return corners.topLeading.height }
        return nil
    }
    #endif
    // tvOS 的 TextField 焦点区域固定 72 高，上下相邻的输入框须隔开 24 以上，否则焦点区域重叠、方向键会跳错
    static var formSpacing: CGFloat {
        #if os(tvOS)
        24
        #else
        16
        #endif
    }
    // tvOS 系统文本框的文字左右各内缩 30，布局里扣除，使文字位置与其它平台一致
    static var textFieldInset: CGFloat {
        #if os(tvOS)
        30
        #else
        0
        #endif
    }
    // InputDecorator 带描边时正文与 labelText 的起点：contentPadding 12 加 OutlineInputBorder.gapPadding 4
    static let labelInset: CGFloat = 16
    // 对应 Material 的 padded tapTargetSize：触控平台按钮与分段的可点盒子 48 经 visualDensity(-2) 收到 40，桌面不留
    static var buttonTarget: CGFloat {
        #if os(macOS)
        0
        #else
        40
        #endif
    }
}

// 与 app/lib/ui/theme.dart、auth_store_panel.dart、section_card.dart 保持一致。
struct ProductPalette {
    let scheme: ColorScheme
    private var dark: Bool { scheme == .dark }
    var background: Color { color(0xF5F5F7, 0x161617) }
    var surface: Color { color(0xFFFFFF, 0x1D1D1F) }
    var text: Color { color(0x1D1D1F, 0xF5F5F7) }
    var secondary: Color { color(0x6E6E73, 0xA1A1A6) }
    var segment: Color { color(0xE8E8ED, 0x2C2C2E) }
    var accent: Color { color(0x0071E3, 0x2997FF) }
    var success: Color { color(0x2FBF71, 0x2FBF71) }
    var warning: Color { color(0xE0A800, 0xE0A800) }
    var danger: Color { color(0xD70015, 0xFF453A) }
    var outline: Color { (dark ? Color.white : Color.black).opacity(dark ? 0.28 : 0.22) }
    // theme.dart 未覆写 hoverColor，取 ThemeData 默认：InkWell / ListTile 悬浮时黑 / 白 4%
    var hover: Color { (dark ? Color.white : Color.black).opacity(0.04) }

    private func color(_ light: UInt32, _ dark: UInt32) -> Color {
        let value = self.dark ? dark : light
        return Color(.sRGB, red: Double((value >> 16) & 255) / 255,
                     green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255, opacity: 1)
    }
}

struct ProductGlyph: View {
    let name: String
    var size: CGFloat = 20

    var body: some View {
        Image("product_\(name)").resizable().scaledToFit().frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

// 对应 widgets/refresh_button.dart：每 700ms 一圈，结束时转完当前这圈再归位
struct ProductRefreshGlyph: View {
    let spinning: Bool
    var size: CGFloat = 20
    @State private var start: Date?
    @State private var end: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(paused: start == nil || reduceMotion)) { context in
            ProductGlyph(name: "refresh", size: size).rotationEffect(.degrees(reduceMotion ? 0 : angle(at: context.date)))
        }
        .onChange(of: spinning, initial: true) { _, value in
            if value { start = start ?? .now; end = nil }
            else if let start { end = start.addingTimeInterval((Date.now.timeIntervalSince(start) / 0.7).rounded(.up) * 0.7) }
        }
        .task(id: end) {
            guard let end else { return }
            try? await Task.sleep(for: .seconds(max(0, end.timeIntervalSinceNow)))
            if self.end == end { start = nil; self.end = nil }
        }
    }
    private func angle(at date: Date) -> Double {
        guard let start else { return 0 }
        return min(date, end ?? date).timeIntervalSince(start).truncatingRemainder(dividingBy: 0.7) / 0.7 * 360
    }
}

// 对应 section_card.dart 的 matchedSectionIcon：24 网格字形放大 24/20 后裁进 18 的方框
struct ProductSectionIcon: View {
    let name: String
    var body: some View {
        ProductGlyph(name: name, size: 21.6).frame(width: 18, height: 18).clipped()
    }
}

// 对应 theme.dart 的 inputDecorationTheme 与 controlDecoration：胶囊、surface 填充、outline 描边，聚焦为主色
struct ProductTextField: View {
    let hint: String
    @Binding var text: String
    var alignment: TextAlignment = .leading
    var onSubmit: () -> Void = {}
    // 对应 InputDecoration 的 labelText；tvOS 由系统文本框显示占位，仍按 hintText
    var labeled = false
    @FocusState private var focused: Bool
    @Environment(\.colorScheme) private var scheme
    private var floatsLabel: Bool {
        #if os(tvOS)
        false
        #else
        labeled
        #endif
    }
    var body: some View {
        let colors = ProductPalette(scheme: scheme)
        TextField(text: $text) { Text(verbatim: floatsLabel ? "" : hint).font(.system(size: 12)).foregroundStyle(colors.secondary) }
            .font(.system(size: 13)).multilineTextAlignment(alignment)
            .autocorrectionDisabled().focused($focused).onSubmit(onSubmit)
            .textFieldStyle(.plain).productTextFieldFit()
            .padding(.horizontal, (floatsLabel ? ProductMetrics.labelInset : 12) - ProductMetrics.textFieldInset).frame(height: 36).productTextFieldClip()
            .background(colors.surface, in: Capsule())
            .productFieldOutline(Capsule(), color: focused ? colors.accent : colors.outline,
                                 label: floatsLabel ? hint : nil, floating: focused || !text.isEmpty, focused: focused)
    }
}

extension View {
    // 对应 InputDecorator 的描边与 labelText：标签为空且未聚焦时与正文同字号同起点（restingTop 为空时竖直居中），
    // 否则按 0.75 缩小、居中压在上描边，描边在标签两侧各留 gapPadding 4 断开；overlay 不认 alignmentGuide，靠零高度框居中
    func productFieldOutline(_ shape: some InsettableShape, color: Color, label: String? = nil, floating: Bool = false,
                             focused: Bool = false, restingTop: CGFloat? = nil) -> some View {
        modifier(ProductFieldOutline(shape: shape, color: color, label: label, floating: floating, focused: focused, restingTop: restingTop))
    }
}

private struct ProductFieldOutline<S: InsettableShape>: ViewModifier {
    let shape: S
    let color: Color
    let label: String?
    let floating: Bool
    let focused: Bool
    let restingTop: CGFloat?
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        let colors = ProductPalette(scheme: scheme)
        content
            .overlay {
                shape.strokeBorder(color, lineWidth: 1).mask {
                    Rectangle().overlay(alignment: .topLeading) {
                        if floating, let label { floated(label, color: .clear).background(Color.black).padding(.leading, ProductMetrics.labelInset - 4).frame(height: 0).offset(y: 0.5).blendMode(.destinationOut) }
                    }.compositingGroup()
                }
            }
            .overlay(alignment: floating || restingTop != nil ? .topLeading : .leading) {
                if let label {
                    Group {
                        if floating {
                            floated(label, color: focused ? colors.accent : colors.secondary)
                                .padding(.leading, ProductMetrics.labelInset - 4).frame(height: 0).offset(y: 0.5)
                        } else {
                            Text(verbatim: label).font(.system(size: 13)).foregroundStyle(colors.secondary)
                                .padding(.leading, ProductMetrics.labelInset).padding(.top, restingTop ?? 0)
                        }
                    }.allowsHitTesting(false)
                }
            }
    }
    private func floated(_ label: String, color: Color) -> some View {
        Text(verbatim: label).font(.system(size: 13 * 0.75)).foregroundStyle(color).padding(.horizontal, 4)
    }
}

struct ProductButtonStyle: ButtonStyle {
    var filled = false
    var color: Color?
    // 默认 32 对应 theme.dart 按钮 40 经 visualDensity(-2)；登录类页面的 authControlStyle 传 40
    var height: CGFloat = 32

    func makeBody(configuration: Configuration) -> some View {
        ProductButtonBody(configuration: configuration, filled: filled, color: color, height: height)
    }
}

private struct ProductButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let filled: Bool
    let color: Color?
    let height: CGFloat
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isFocused) private var focused
    @State private var hovered = false

    var body: some View {
        let colors = ProductPalette(scheme: scheme)
        let foreground = filled ? colors.surface : color ?? colors.text
        let hovering = hovered && enabled
        // 对应 app/lib/ui/theme.dart：Filled 为实心；Text/Outlined 的 _tonalPill 为透明底、正文色描边，color 只改文字。
        // 悬浮态按 M3：叠前景色 8% 状态层，Filled 另抬升到 elevation 1 的阴影
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 20).frame(minHeight: height)
            .foregroundStyle(foreground)
            .opacity(!enabled ? 0.38 : 1)
            .background {
                if filled {
                    Capsule().fill(color ?? colors.text).opacity(enabled ? 1 : 0.38)
                        .shadow(color: .black.opacity(hovering ? 0.3 : 0), radius: 1.5, y: 1)
                } else { Capsule().strokeBorder(colors.text.opacity(enabled ? 1 : 0.12), lineWidth: 1) }
                if hovering { Capsule().fill(foreground.opacity(0.08)) }
            }
            .contentShape(Capsule())
            .compositingGroup()
            .opacity(configuration.isPressed ? 0.7 : 1)
            .productHover { hovered = $0 }
            #if os(tvOS)
            .overlay(Capsule().strokeBorder(focused ? colors.accent : .clear, lineWidth: 3))
            #endif
            .padding(.vertical, max(0, ProductMetrics.buttonTarget - height) / 2)
            .contentShape(Rectangle())
    }
}

struct ProductField<Content: View>: View {
    let title: String
    let icon: String
    let hasValue: Bool
    var isFocused = false
    @ViewBuilder var content: Content
    @FocusState private var editing: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let colors = ProductPalette(scheme: scheme)
        #if os(tvOS)
        let isFocused = self.isFocused || editing
        #endif
        Group {
            #if os(tvOS)
            // 系统底板铺满胶囊，图标放进系统的文字内缩区
            content.focused($editing)
                .overlay(alignment: .leading) { ProductGlyph(name: icon).foregroundStyle(colors.secondary).frame(width: ProductMetrics.textFieldInset) }.frame(height: 40)
            #else
            HStack(spacing: 10) {
                ProductGlyph(name: icon).foregroundStyle(colors.secondary)
                content
            }.padding(.horizontal, 14)
            #endif
        }
        .textFieldStyle(.plain).productTextFieldFit().font(.system(size: 13))
        .frame(minHeight: 40).productTextFieldClip()
        .background {
            Capsule().fill(isFocused ? colors.accent : colors.outline)
            Capsule().fill(colors.surface).padding(1)
        }
        .overlay(alignment: .topLeading) {
            if isFocused || hasValue {
                Text(verbatim: title).font(.system(size: 11))
                    .foregroundStyle(isFocused ? colors.accent : colors.secondary)
                    .padding(.horizontal, 4).background(colors.surface)
                    .offset(x: ProductMetrics.textFieldInset > 0 ? ProductMetrics.textFieldInset - 4 : 38, y: -7)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
    }
}

struct ProductCard<Content: View>: View {
    var title = ""
    var icon = ""
    var padding = EdgeInsets(top: 20, leading: 24, bottom: 20, trailing: 24)
    @ViewBuilder var content: Content
    var action: AnyView?
    var accessory: AnyView?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let colors = ProductPalette(scheme: scheme)
        VStack(alignment: .leading, spacing: 12) {
            if !title.isEmpty {
                HStack(spacing: 7) {
                    if !icon.isEmpty { ProductSectionIcon(name: icon).foregroundStyle(colors.secondary) }
                    // 标题后的图标按钮悬浮圆铺满 32 的点击区，留 4 才不压到文字
                    HStack(spacing: 4) {
                        Text(verbatim: title).font(.system(size: 18, weight: .semibold))
                        accessory
                    }
                    Spacer(minLength: 8)
                    // 对应 section_card.dart：操作区按内容宽度排版，标题让出空间
                    action.layoutPriority(1)
                }.frame(minHeight: 22).productFocusSection()
            }
            #if os(tvOS)
            // 焦点引擎只在正上 / 正下方寻找目标，逐行设为焦点区才能上下切到错位的控件
            if #available(tvOS 18.0, *) { ForEach(subviews: content) { $0.frame(maxWidth: .infinity, alignment: .leading).focusSection() } } else { content }
            #else
            content
            #endif
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(padding)
        .background(colors.surface, in: RoundedRectangle(cornerRadius: 20))
        .productFocusSection()
    }

    func headerAction<Action: View>(@ViewBuilder _ content: () -> Action) -> Self {
        var card = self
        card.action = AnyView(content())
        return card
    }

    func titleAccessory<Accessory: View>(@ViewBuilder _ content: () -> Accessory) -> Self {
        var card = self
        card.accessory = AnyView(content())
        return card
    }
}

struct ProductSearchField: View {
    let hint: String
    @Binding var text: String
    var autofocus = false
    @FocusState private var focused: Bool
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let colors = ProductPalette(scheme: scheme)
        HStack(spacing: 0) {
            TextField(hint, text: $text)
                .textFieldStyle(.plain).productTextFieldFit()
                .font(.system(size: 12)).autocorrectionDisabled().focused($focused)
                .padding(.trailing, -ProductMetrics.textFieldInset)
            if !text.isEmpty {
                Button { text = "" } label: { ProductGlyph(name: "close", size: 14).frame(width: 26, height: 26).productIconHover() }
                    .buttonStyle(.productPlain).accessibilityLabel(L10n.t("清除搜索"))
            }
        }
        .padding(.leading, 30 - ProductMetrics.textFieldInset)
        .overlay(alignment: .leading) { ProductGlyph(name: "search", size: 15).foregroundStyle(colors.outline).frame(width: 30) }
        .padding(.trailing, text.isEmpty ? 12 : 2).frame(height: 30).productTextFieldClip()
        .background(colors.surface, in: Capsule()).overlay(Capsule().strokeBorder(focused ? colors.accent : colors.outline, lineWidth: 1))
        .onAppear { if autofocus { focused = true } }
    }
}

struct ProductPair<Left: View, Right: View>: View {
    var stackedDivider = false
    @ViewBuilder var left: Left
    @ViewBuilder var right: Right
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 10) { left.frame(minWidth: 325); right.frame(minWidth: 325) }
            VStack(spacing: stackedDivider ? 20 : 10) {
                left
                if stackedDivider { Divider() }
                right
            }
        }
    }
}

struct ProductGrid: Layout {
    var minimumWidth: CGFloat = 320
    var minimumColumns = 1
    var maximumColumns = 3
    var horizontalSpacing: CGFloat = 10
    var verticalSpacing: CGFloat = 10
    var includeSpacingInThreshold = false

    private func metrics(_ width: CGFloat, _ subviews: Subviews) -> (Int, CGFloat, [CGFloat]) {
        let columns = max(minimumColumns, min(maximumColumns, Int(includeSpacingInThreshold ? (width + horizontalSpacing) / (minimumWidth + horizontalSpacing) : width / minimumWidth)))
        let cell = max(0, (width - CGFloat(columns - 1) * horizontalSpacing) / CGFloat(columns))
        var heights: [CGFloat] = []
        for index in subviews.indices {
            let height = subviews[index].sizeThatFits(ProposedViewSize(width: cell, height: nil)).height
            if index % columns == 0 { heights.append(height) }
            else { heights[heights.count - 1] = max(heights.last!, height) }
        }
        return (columns, cell, heights)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? minimumWidth
        let (_, _, heights) = metrics(width, subviews)
        return CGSize(width: width, height: heights.reduce(0, +) + CGFloat(max(0, heights.count - 1)) * verticalSpacing)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (columns, cell, heights) = metrics(bounds.width, subviews)
        var y = bounds.minY
        for index in subviews.indices {
            let row = index / columns
            if index > 0 && index % columns == 0 { y += heights[row - 1] + verticalSpacing }
            subviews[index].place(at: CGPoint(x: bounds.minX + CGFloat(index % columns) * (cell + horizontalSpacing), y: y),
                                  proposal: ProposedViewSize(width: cell, height: heights[row]))
        }
    }
}

enum ProductFormat {
    static func timestamp(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
    static func bytes(_ value: Int64) -> String {
        var amount = abs(Double(value))
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var unit = 0
        while amount >= 1024 && unit < units.count - 1 { amount /= 1024; unit += 1 }
        return (value < 0 ? "-" : "") + String(format: unit == 0 ? "%.0f %@" : "%.2f %@", amount, units[unit])
    }
    // 与 app/lib/ui/format.dart 的 Format.elapsed 一致
    static func elapsed(_ interval: TimeInterval) -> String {
        var seconds = max(0, Int(interval))
        var parts: [String] = []
        for (unit, key) in [(365 * 24 * 3600, "{0}年"), (30 * 24 * 3600, "{0}个月"), (24 * 3600, "{0}天"), (3600, "{0}小时"), (60, "{0}分钟")] {
            if seconds >= unit { parts.append(L10n.t(key, [String(seconds / unit)])) }
            seconds %= unit
        }
        if seconds > 0 || parts.isEmpty { parts.append(L10n.t("{0}秒", [String(seconds)])) }
        return parts.joined(separator: " ")
    }
}

struct ProductFlow: Layout {
    var spacing: CGFloat = 4
    var centered = false
    var trailing = false
    var runSpacing: CGFloat?
    private func rows(width: CGFloat, subviews: Subviews) -> [[(Int, CGSize)]] {
        var rows: [[(Int, CGSize)]] = [[]]
        var used: CGFloat = 0
        for index in subviews.indices {
            let ideal = subviews[index].sizeThatFits(.unspecified)
            let size = subviews[index].sizeThatFits(ProposedViewSize(width: min(width, ideal.width), height: nil))
            if used > 0 && used + spacing + size.width > width { rows.append([]); used = 0 }
            rows[rows.count - 1].append((index, size))
            used += (used == 0 ? 0 : spacing) + size.width
        }
        return rows
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? subviews.reduce(0) { $0 + $1.sizeThatFits(.unspecified).width + spacing }
        let rows = rows(width: width, subviews: subviews)
        return CGSize(width: width, height: rows.reduce(0) { $0 + ($1.map { $0.1.height }.max() ?? 0) } + CGFloat(max(0, rows.count - 1)) * (runSpacing ?? spacing))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(width: bounds.width, subviews: subviews) {
            let height = row.map { $0.1.height }.max() ?? 0
            let width = row.reduce(0) { $0 + $1.1.width } + CGFloat(max(0, row.count - 1)) * spacing
            var x = bounds.minX + max(0, bounds.width - width) * (centered ? 0.5 : trailing ? 1 : 0)
            for (index, size) in row {
                subviews[index].place(at: CGPoint(x: x, y: y + (height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += height + (runSpacing ?? spacing)
        }
    }
}

struct ProductSegments<Value: Hashable>: View {
    let values: [Value]
    @Binding var selection: Value
    // 对应 logs_page.dart 窄屏的紧凑内边距（左右 6）
    var compact = false
    let title: (Value) -> String
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var enabled
    @State private var hovered: Value?
    var body: some View {
        let colors = ProductPalette(scheme: scheme)
        HStack(spacing: 0) {
            ForEach(Array(values.enumerated()), id: \.element) { index, value in
                if index > 0 { Rectangle().fill(colors.text).frame(width: 1) }
                let selected = selection == value
                Button { selection = value } label: {
                    Text(verbatim: title(value)).font(.system(size: 12, weight: .semibold))
                        .lineLimit(1).padding(.horizontal, compact ? 6 : 14)
                        .frame(maxWidth: .infinity, minHeight: 32)
                        .foregroundStyle(selected ? colors.surface : colors.text)
                        .background {
                            selected ? colors.text : Color.clear
                            if hovered == value && enabled { (selected ? colors.surface : colors.text).opacity(0.08) }
                        }
                        .contentShape(Rectangle())
                        .productHover { hovered = $0 ? value : (hovered == value ? nil : hovered) }
                        .productFocusRing(Rectangle())
                }.buttonStyle(.productPlain).accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }.fixedSize(horizontal: false, vertical: true).clipShape(Capsule())
            .overlay(Capsule().strokeBorder(colors.text, lineWidth: 1))
            .opacity(enabled ? 1 : 0.38)
            .padding(.vertical, max(0, ProductMetrics.buttonTarget - 32) / 2)
    }
}

struct ProductDropdown<Value: Hashable>: View {
    let label: String
    let values: [Value]
    @Binding var selection: Value
    let title: (Value) -> String
    var leading: ((Value) -> AnyView?)?
    var trailing: ((Value) -> AnyView?)?
    @State private var open = false
    @State private var width: CGFloat = 160
    @FocusState private var focused: Value?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var enabled
    private var rowHeight: CGFloat {
        #if os(tvOS)
        48
        #else
        36
        #endif
    }
    private var menuHeight: CGFloat { min(320, CGFloat(values.count) * rowHeight) }

    init(label: String = "", values: [Value], selection: Binding<Value>,
         leading: ((Value) -> AnyView?)? = nil, trailing: ((Value) -> AnyView?)? = nil,
         title: @escaping (Value) -> String) {
        self.label = label; self.values = values; _selection = selection
        self.leading = leading; self.trailing = trailing; self.title = title
    }

    var body: some View {
        let colors = ProductPalette(scheme: scheme)
        VStack(alignment: .leading, spacing: 6) {
            if !label.isEmpty { Text(verbatim: label).font(.system(size: 12)).foregroundStyle(colors.secondary) }
            Button { open.toggle() } label: {
                HStack(spacing: 8) {
                    row(selection).foregroundStyle(values.contains(selection) ? colors.text : colors.secondary)
                    ProductGlyph(name: "expand_more", size: 16)
                        .rotationEffect(.degrees(open ? 180 : 0)).animation(.easeInOut(duration: 0.18), value: open)
                        .foregroundStyle(open ? colors.accent : colors.outline)
                }.font(.system(size: 13))
                    .padding(.leading, 12).padding(.trailing, 6).frame(height: rowHeight)
                    .background(colors.surface, in: Capsule())
                    .overlay(Capsule().strokeBorder(open ? colors.accent : colors.outline, lineWidth: 1))
                    .opacity(enabled ? 1 : 0.38).contentShape(Capsule()).productFocusRing(Capsule())
            }.buttonStyle(.productPlain).disabled(values.isEmpty)
                .accessibilityLabel(label.isEmpty ? title(selection) : label)
                .background { GeometryReader { geometry in Color.clear.onAppear { width = geometry.size.width }.onChange(of: geometry.size.width) { _, value in width = value } } }
                .productMenu(isPresented: $open, size: CGSize(width: width, height: menuHeight)) {
                    ScrollViewReader { scroll in
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(values, id: \.self) { value in
                                    Button { selection = value; open = false } label: {
                                        row(value).padding(.horizontal, 12).frame(height: rowHeight)
                                            .foregroundStyle(selection == value ? colors.accent : colors.text)
                                            .background(selection == value ? colors.accent.opacity(0.08) : Color.clear)
                                            .contentShape(Rectangle())
                                    }.buttonStyle(.productPlain).focused($focused, equals: value).id(value)
                                        .accessibilityAddTraits(selection == value ? [.isSelected] : [])
                                }
                            }
                        }.frame(width: width, height: menuHeight)
                            .onAppear {
                                let value = values.contains(selection) ? selection : values.first
                                if let value { scroll.scrollTo(value, anchor: .center); focused = value }
                            }
                    }.font(.system(size: 13)).background(colors.surface)

                }
        }
    }
    private func row(_ value: Value) -> some View {
        HStack(spacing: 6) {
            leading?(value)
            Text(verbatim: title(value)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            trailing?(value)
        }
    }
}

struct ProductProbeBadge: View {
    let session: ClientSession
    let node: String
    let kind: NodeProbe.Kind
    var height: CGFloat = ProductMetrics.tapTarget
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme
    private var result: NodeProbe? { session.nodeProbes.result(node, kind: kind) }
    private var testing: Bool { session.nodeProbes.isTesting(node, kind: kind) }
    static func delayColor(_ delay: Int, scheme: ColorScheme) -> Color {
        let colors = ProductPalette(scheme: scheme)
        return delay < 200 ? colors.success : delay < 500 ? colors.warning : colors.danger
    }
    var body: some View {
        let colors = ProductPalette(scheme: scheme)
        Button(action: action) {
            Group {
                if testing { ProgressView().controlSize(.small).scaleEffect(0.65) }
                else if let result, result.failed {
                    Text(kind == .delay ? L10n.t("超时") : L10n.t("失败")).foregroundStyle(colors.danger)
                } else if let result {
                    Text(kind == .delay ? String(result.delay) : String(format: "%.1f MB/s", Double(result.speed) / 1_000_000))
                        .foregroundStyle(kind == .delay ? Self.delayColor(result.delay, scheme: scheme) :
                            result.speed >= 5 * 1024 * 1024 ? colors.success : result.speed >= 1024 * 1024 ? colors.warning : colors.danger)
                } else {
                    ProductGlyph(name: kind == .delay ? "bolt_outlined" : "speed", size: 16).foregroundStyle(colors.secondary)
                }
            }.font(.system(size: 11, weight: .semibold)).monospacedDigit()
                .padding(.horizontal, 4).frame(minWidth: ProductMetrics.tapTarget, minHeight: height).contentShape(Capsule())
                // 对应 delay_badge.dart / speed_badge.dart 的 InkWell：悬浮为主色 12% 胶囊
                .productHoverLayer(Capsule(), \.accent, opacity: 0.12)
        }.buttonStyle(.productPlain).disabled(testing)
            .help(kind == .delay ? L10n.t("测试该节点延迟") : L10n.t("测试该节点网速"))
            .accessibilityLabel(kind == .delay ? L10n.t("测试该节点延迟") : L10n.t("测试该节点网速"))
    }
}

struct ProductSection<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder var content: Content
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                ProductSectionIcon(name: icon)
                Text(verbatim: title).font(.system(size: 18, weight: .semibold))
            }.padding(.leading, 4)
            VStack(spacing: 0) { content }
                .frame(maxWidth: .infinity)
                .background(ProductPalette(scheme: scheme).surface, in: RoundedRectangle(cornerRadius: 20))
                .clipShape(RoundedRectangle(cornerRadius: 20))
        }.productFocusSection()
    }
}

// 对应 widgets/tag_chip.dart：默认次要色 12% 底；capsule 为高 20、18% 底与 30% 描边
struct ProductTag: View {
    let text: String
    var color: Color?
    var icon = ""
    var capsule = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let tone = color ?? ProductPalette(scheme: scheme).secondary
        HStack(spacing: capsule ? 4 : 3) {
            if !icon.isEmpty { ProductGlyph(name: icon, size: 11) }
            Text(verbatim: text).font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(tone).padding(.leading, capsule ? 8 : icon.isEmpty ? 6 : 4).padding(.trailing, capsule ? 8 : 6)
        .padding(.vertical, capsule ? 0 : 2).frame(minHeight: capsule ? 20 : nil)
        .background(tone.opacity(capsule ? 0.18 : 0.12), in: Capsule())
        .overlay { if capsule { Capsule().strokeBorder(tone.opacity(0.3), lineWidth: 1) } }
    }
}

struct ProductToggleStyle: ToggleStyle {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        let colors = ProductPalette(scheme: scheme)
        HStack(spacing: 10) {
            configuration.label.frame(maxWidth: .infinity, alignment: .leading)
            Button { configuration.isOn.toggle() } label: {
                // 对应 theme.dart 的 switchTheme：M3 开关按 0.8 缩放，轨道无描边，未选中滑块为 outline 色
                Capsule().fill(configuration.isOn ? colors.text : colors.segment)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle().fill(configuration.isOn ? colors.surface : colors.outline)
                            .frame(width: configuration.isOn ? 19 : 13, height: configuration.isOn ? 19 : 13)
                            .padding(.horizontal, configuration.isOn ? 3.5 : 6.5)
                    }.frame(width: 42, height: 26).opacity(enabled ? 1 : 0.38).productFocusRing(Capsule())
            }.buttonStyle(.productPlain).accessibilityLabel(configuration.isOn ? L10n.t("已开启") : L10n.t("已关闭"))
        }
    }
}

// 对应 Flutter 的浮动 SnackBar（snackBarTheme）：正文色底、surface 色 13 号字，距边 15，4 秒后消失
struct ProductToast: ViewModifier {
    @Binding var message: String?
    var duration: Double = 4
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        let colors = ProductPalette(scheme: scheme)
        content.overlay(alignment: .bottom) {
            if let message, !message.isEmpty {
                Text(verbatim: message).font(.system(size: 13)).foregroundStyle(colors.surface)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 14)
                    .background(colors.text, in: RoundedRectangle(cornerRadius: 4))
                    .padding(15).transition(.opacity).accessibilityAddTraits(.isStaticText)
                    .onTapGesture { self.message = nil }
                    .task(id: message) {
                        try? await Task.sleep(for: .seconds(duration))
                        if self.message == message { self.message = nil }
                    }
            }
        }.animation(.easeOut(duration: 0.2), value: message)
    }
}
extension View {
    func productToast(_ message: Binding<String?>, duration: Double = 4) -> some View { modifier(ProductToast(message: message, duration: duration)) }
}

struct ProductNotice: View {
    let message: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let colors = ProductPalette(scheme: scheme)
        HStack(alignment: .top, spacing: 8) {
            ProductGlyph(name: "info_outline", size: 16)
            Text(verbatim: message).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 13)).foregroundStyle(colors.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12).background(colors.segment.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
}
