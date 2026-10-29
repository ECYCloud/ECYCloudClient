import SwiftUI
import Foundation

public struct SVGIcon: View {
    private let document: SVGDocument
    public init?(data: Data) {
        guard data.count <= RemoteIconStore.maximumBytes, let document = SVGDocument(data: data) else { return nil }
        self.document = document
    }
    public var body: some View {
        Canvas { context, size in
            let bounds = document.bounds
            let scale = min(size.width / bounds.width, size.height / bounds.height)
            context.translateBy(x: (size.width - bounds.width * scale) / 2, y: (size.height - bounds.height * scale) / 2)
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -bounds.minX, y: -bounds.minY)
            for shape in document.shapes {
                var layer = context
                layer.concatenate(shape.transform)
                if let fill = shape.fill { layer.fill(shape.path, with: .color(fill), style: FillStyle(eoFill: shape.evenOdd)) }
                if let stroke = shape.stroke { layer.stroke(shape.path, with: .color(stroke), lineWidth: shape.width) }
            }
        }
    }
}

private final class SVGDocument: NSObject, XMLParserDelegate {
    struct Shape {
        let path: Path, fill: Color?, stroke: Color?, width: Double, evenOdd: Bool, transform: CGAffineTransform
    }
    var shapes: [Shape] = []
    var bounds = CGRect(x: 0, y: 0, width: 24, height: 24)
    private var styles: [[String: String]] = []
    private var transforms: [CGAffineTransform] = []
    private var suppressed = 0
    private var nodes = 0
    private var valid = true
    init?(data: Data) {
        super.init()
        guard let text = String(data: data, encoding: .utf8), !text.localizedCaseInsensitiveContains("<!DOCTYPE"), !text.localizedCaseInsensitiveContains("<!ENTITY") else { return nil }
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = self
        guard parser.parse(), valid, shapes.contains(where: { $0.fill != nil || $0.stroke != nil }),
              bounds.width > 0, bounds.height > 0, bounds.width.isFinite, bounds.height.isFinite else { return nil }
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        nodes += 1
        guard nodes <= 2048, styles.count < 64 else { valid = false; parser.abortParsing(); return }
        guard nodes != 1 || name == "svg" else { valid = false; parser.abortParsing(); return }
        var style = styles.last ?? [:]
        style.merge(attributes) { _, new in new }
        for declaration in (attributes["style"] ?? "").split(separator: ";") {
            let parts = declaration.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 { style[parts[0]] = parts[1] }
        }
        let numeric = ["x", "y", "x1", "x2", "y1", "y2", "cx", "cy", "rx", "ry", "r", "width", "height", "stroke-width", "opacity", "fill-opacity", "stroke-opacity"]
        guard numeric.allSatisfy({ key in
            guard let raw = style[key] else { return true }
            guard let value = Double(raw) else { return false }
            return value.isFinite && abs(value) <= 1e9 && (value == 0 || abs(value) >= 1e-9)
        }), !["use", "text", "image", "foreignObject", "script", "style", "animate", "animateTransform", "set"].contains(name),
        !style.keys.contains(where: { $0.hasPrefix("on") || ["filter", "clip-path", "mask", "class", "marker-start", "marker-mid", "marker-end", "stroke-dasharray"].contains($0) }),
        !style.values.contains(where: { $0.lowercased().contains("url(") }) else { valid = false; parser.abortParsing(); return }
        if attributes["opacity"] != nil {
            style["opacity"] = String((Double(styles.last?["opacity"] ?? "1") ?? 1) * (Double(style["opacity"] ?? "1") ?? 1))
        }
        styles.append(style)
        let transform = (transforms.last ?? .identity).concatenating(Self.transform(attributes["transform"] ?? ""))
        guard [transform.a, transform.b, transform.c, transform.d, transform.tx, transform.ty].allSatisfy({ $0.isFinite && abs($0) <= 1e12 }) else {
            valid = false; parser.abortParsing(); return
        }
        transforms.append(transform)
        if suppressed > 0 || style["display"] == "none" || style["visibility"] == "hidden" ||
            ["defs", "clipPath", "mask", "pattern", "symbol", "marker"].contains(name) { suppressed += 1; return }
        if name == "svg" {
            let values = Self.numbers(attributes["viewBox"] ?? "")
            if values.count == 4 { bounds = CGRect(x: values[0], y: values[1], width: values[2], height: values[3]) }
            else if let w = attributes["width"].flatMap(Double.init), let h = attributes["height"].flatMap(Double.init) { bounds.size = CGSize(width: w, height: h) }
        }
        func number(_ key: String, _ fallback: Double = 0) -> Double { attributes[key].flatMap(Double.init) ?? fallback }
        var path = Path()
        switch name {
        case "path": guard let value = SVGPath.parse(attributes["d"] ?? "") else { valid = false; parser.abortParsing(); return }; path = value
        case "rect": path.addRoundedRect(in: CGRect(x: number("x"), y: number("y"), width: number("width"), height: number("height")), cornerSize: CGSize(width: number("rx"), height: number("ry", number("rx"))))
        case "circle", "ellipse":
            let rx = number(name == "circle" ? "r" : "rx"), ry = number(name == "circle" ? "r" : "ry")
            path.addEllipse(in: CGRect(x: number("cx") - rx, y: number("cy") - ry, width: rx * 2, height: ry * 2))
        case "line": path.move(to: CGPoint(x: number("x1"), y: number("y1"))); path.addLine(to: CGPoint(x: number("x2"), y: number("y2")))
        case "polygon", "polyline":
            let values = Self.numbers(attributes["points"] ?? "")
            guard values.count >= 4, values.count % 2 == 0 else { return }
            path.move(to: CGPoint(x: values[0], y: values[1]))
            for i in stride(from: 2, to: values.count, by: 2) { path.addLine(to: CGPoint(x: values[i], y: values[i + 1])) }
            if name == "polygon" { path.closeSubpath() }
        default: return
        }
        let opacity = Double(style["opacity"] ?? "1") ?? 1
        shapes.append(Shape(path: path, fill: Self.color(style["fill"] ?? "#000000")?.opacity(opacity * (Double(style["fill-opacity"] ?? "1") ?? 1)),
                            stroke: Self.color(style["stroke"] ?? "none")?.opacity(opacity * (Double(style["stroke-opacity"] ?? "1") ?? 1)),
                            width: Double(style["stroke-width"] ?? "1") ?? 1, evenOdd: style["fill-rule"] == "evenodd", transform: transform))
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if suppressed > 0 { suppressed -= 1 }
        if !styles.isEmpty { styles.removeLast(); transforms.removeLast() }
    }
    static func numbers(_ source: String) -> [Double] {
        let regex = try! NSRegularExpression(pattern: #"[-+]?(?:\d*\.\d+|\d+\.?\d*)(?:[eE][-+]?\d+)?"#)
        return regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).prefix(16384).compactMap { Range($0.range, in: source).flatMap { Double(source[$0]) } }.filter { $0.isFinite && abs($0) <= 1e9 }
    }
    private static func color(_ source: String) -> Color? {
        let value = source.trimmingCharacters(in: .whitespaces).lowercased()
        if value == "none" || value.hasPrefix("url(") { return nil }
        if value.hasPrefix("#") {
            var hex = String(value.dropFirst())
            if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
            guard hex.count == 6, let rgb = UInt32(hex, radix: 16) else { return nil }
            return Color(red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
        }
        if value.hasPrefix("rgb(") {
            let rgb = numbers(value)
            if rgb.count == 3 { return Color(red: rgb[0] / 255, green: rgb[1] / 255, blue: rgb[2] / 255) }
        }
        if value == "transparent" { return .clear }
        guard let rgb = ["black": 0x000000, "white": 0xffffff, "red": 0xff0000, "green": 0x008000,
                         "blue": 0x0000ff, "gray": 0x808080, "currentcolor": 0x000000][value] else { return nil }
        return Color(red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
    }
    private static func transform(_ source: String) -> CGAffineTransform {
        var result = CGAffineTransform.identity
        let regex = try! NSRegularExpression(pattern: #"(matrix|translate|scale|rotate)\s*\(([^)]*)\)"#)
        for match in regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).prefix(32) {
            let kind = String(source[Range(match.range(at: 1), in: source)!]), values = numbers(String(source[Range(match.range(at: 2), in: source)!]))
            switch kind {
            case "matrix" where values.count == 6: result = result.concatenating(CGAffineTransform(a: values[0], b: values[1], c: values[2], d: values[3], tx: values[4], ty: values[5]))
            case "translate" where !values.isEmpty: result = result.translatedBy(x: values[0], y: values.count > 1 ? values[1] : 0)
            case "scale" where !values.isEmpty: result = result.scaledBy(x: values[0], y: values.count > 1 ? values[1] : values[0])
            case "rotate" where !values.isEmpty:
                let x = values.count == 3 ? values[1] : 0, y = values.count == 3 ? values[2] : 0
                result = result.translatedBy(x: x, y: y).rotated(by: values[0] * .pi / 180).translatedBy(x: -x, y: -y)
            default: break
            }
        }
        return result
    }
}

private enum SVGPath {
    static func parse(_ source: String) -> Path? {
        let regex = try! NSRegularExpression(pattern: #"[a-zA-Z]|[-+]?(?:\d*\.\d+|\d+\.?\d*)(?:[eE][-+]?\d+)?"#)
        let tokens = regex.matches(in: source, range: NSRange(source.startIndex..., in: source))
        guard tokens.count <= 16384 else { return nil }
        let values = tokens.map { String(source[Range($0.range, in: source)!]) }
        var i = 0, command = "", previous = "", point = CGPoint.zero, start = CGPoint.zero, control = CGPoint.zero
        var path = Path()
        func take(_ count: Int) -> [Double]? {
            guard i + count <= values.count else { return nil }
            let items = values[i..<i + count].compactMap(Double.init)
            guard items.count == count, items.allSatisfy({ $0.isFinite && abs($0) <= 1e9 && ($0 == 0 || abs($0) >= 1e-9) }) else { return nil }
            i += count; return items
        }
        while i < values.count {
            if Double(values[i]) == nil { command = values[i]; i += 1 }
            let upper = command.uppercased(), relative = upper != command
            func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x + (relative ? point.x : 0), y: y + (relative ? point.y : 0)) }
            func reflected() -> CGPoint { CGPoint(x: point.x * 2 - control.x, y: point.y * 2 - control.y) }
            switch upper {
            case "M", "L", "T":
                guard let n = take(2) else { return nil }; let next = p(n[0], n[1])
                if upper == "M" { path.move(to: next); start = next; command = relative ? "l" : "L" }
                else if upper == "T" { let c = ["Q", "T"].contains(previous) ? reflected() : point; path.addQuadCurve(to: next, control: c); control = c }
                else { path.addLine(to: next) }
                point = next
            case "H", "V":
                guard let n = take(1) else { return nil }
                point = upper == "H" ? CGPoint(x: n[0] + (relative ? point.x : 0), y: point.y) : CGPoint(x: point.x, y: n[0] + (relative ? point.y : 0))
                path.addLine(to: point)
            case "C", "S", "Q":
                guard let n = take(upper == "C" ? 6 : 4) else { return nil }
                let c1 = upper == "S" ? (["C", "S"].contains(previous) ? reflected() : point) : p(n[0], n[1])
                let c2 = upper == "C" ? p(n[2], n[3]) : upper == "S" ? p(n[0], n[1]) : c1
                let next = p(n[n.count - 2], n[n.count - 1])
                if upper == "Q" { path.addQuadCurve(to: next, control: c1) } else { path.addCurve(to: next, control1: c1, control2: c2) }
                control = c2; point = next
            case "A":
                guard let n = take(7), [0, 1].contains(n[3]), [0, 1].contains(n[4]) else { return nil }
                let end = p(n[5], n[6]); arc(&path, from: point, to: end, rx: abs(n[0]), ry: abs(n[1]), rotation: n[2], large: n[3] == 1, sweep: n[4] == 1); point = end
            case "Z": path.closeSubpath(); point = start; command = ""
            default: return nil
            }
            previous = upper
        }
        return path
    }
    private static func arc(_ path: inout Path, from start: CGPoint, to end: CGPoint, rx: Double, ry: Double, rotation: Double, large: Bool, sweep: Bool) {
        guard rx > 0, ry > 0, start != end else { path.addLine(to: end); return }
        let phi = rotation * .pi / 180, c = cos(phi), s = sin(phi)
        let dx = (start.x - end.x) / 2, dy = (start.y - end.y) / 2
        let x = c * dx + s * dy, y = -s * dx + c * dy
        let scale = max(1, sqrt(x * x / (rx * rx) + y * y / (ry * ry))), a = rx * scale, b = ry * scale
        let factor = (large == sweep ? -1.0 : 1.0) * sqrt(max(0, (a*a*b*b - a*a*y*y - b*b*x*x) / (a*a*y*y + b*b*x*x)))
        let cx = factor * a * y / b, cy = -factor * b * x / a
        let center = CGPoint(x: c * cx - s * cy + (start.x + end.x) / 2, y: s * cx + c * cy + (start.y + end.y) / 2)
        let first = atan2((y - cy) / b, (x - cx) / a), last = atan2((-y - cy) / b, (-x - cx) / a)
        var delta = last - first
        if sweep && delta < 0 { delta += 2 * .pi }; if !sweep && delta > 0 { delta -= 2 * .pi }
        let count = max(1, Int(ceil(abs(delta) / (.pi / 2)))), step = delta / Double(count)
        func position(_ t: Double) -> CGPoint { CGPoint(x: center.x + c*a*cos(t) - s*b*sin(t), y: center.y + s*a*cos(t) + c*b*sin(t)) }
        func tangent(_ t: Double) -> CGPoint { CGPoint(x: -c*a*sin(t) - s*b*cos(t), y: -s*a*sin(t) + c*b*cos(t)) }
        for index in 0..<count {
            let t = first + Double(index)*step, next = t + step, k = 4 / 3 * tan(step / 4)
            let p = position(t), q = position(next), u = tangent(t), v = tangent(next)
            path.addCurve(to: q, control1: CGPoint(x: p.x + k*u.x, y: p.y + k*u.y), control2: CGPoint(x: q.x - k*v.x, y: q.y - k*v.y))
        }
    }
}
