import Foundation
import libxml2

/// 仅输出原生文字与链接，不执行 HTML、加载图片或创建浏览器。
public struct RichDocument: Sendable {
    public struct Run: Sendable, Equatable {
        public var text: String
        public let bold: Bool
        public let italic: Bool
        public let link: URL?
    }
    public let runs: [Run]
    public var plainText: String { runs.map(\.text).joined() }

    public init(html: String, origin: URL) throws {
        guard html.utf8.count <= 1_048_576 else { throw ClientError.responseTooLarge }
        if html.isEmpty { runs = []; return }
        let flags = Int32(HTML_PARSE_NONET.rawValue | HTML_PARSE_NOERROR.rawValue | HTML_PARSE_NOWARNING.rawValue)
        let document = html.withCString { htmlReadMemory($0, Int32(html.utf8.count), nil, "UTF-8", flags) }
        guard let document else { throw ClientError.invalidResponse }
        defer { xmlFreeDoc(document) }
        var output: [Run] = []
        var count = 0
        let allowed: Set<String> = ["html", "body", "div", "span", "p", "br", "a", "strong", "b", "em", "i", "u", "s", "del", "code", "pre", "blockquote", "ul", "ol", "li", "h1", "h2", "h3", "h4", "h5", "h6", "table", "thead", "tbody", "tr", "td", "th", "hr", "img", "video", "audio"]
        let blocks: Set<String> = ["div", "p", "pre", "blockquote", "ul", "ol", "li", "h1", "h2", "h3", "h4", "h5", "h6", "tr", "hr"]
        func append(_ text: String, bold: Bool = false, italic: Bool = false, link: URL? = nil) {
            guard !text.isEmpty else { return }
            if let last = output.last, last.bold == bold, last.italic == italic, last.link == link {
                output[output.count - 1].text += text
            } else { output.append(Run(text: text, bold: bold, italic: italic, link: link)) }
        }
        func newline() {
            if let last = output.last, !last.text.hasSuffix("\n") { append("\n") }
        }
        func attribute(_ node: xmlNodePtr, _ name: String) -> String? {
            var cursor = node.pointee.properties
            while let value = cursor {
                if String(decodingCString: value.pointee.name, as: UTF8.self) == name {
                    var result = ""
                    var child = value.pointee.children
                    while let text = child {
                        if text.pointee.type == XML_TEXT_NODE, let content = text.pointee.content { result += String(decodingCString: content, as: UTF8.self) }
                        child = text.pointee.next
                    }
                    return result
                }
                cursor = value.pointee.next
            }
            return nil
        }
        func contentURL(_ raw: String?, media: Bool = false) -> URL? {
            guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), raw.utf8.count <= 8192,
                  !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  let url = URL(string: raw, relativeTo: origin)?.absoluteURL,
                  (media ? ["https", "http"] : ["https", "http", "mailto"]).contains(url.scheme?.lowercased()),
                  url.user == nil, url.password == nil else { return nil }
            return url
        }
        func walk(_ first: xmlNodePtr?, depth: Int, bold: Bool, italic: Bool, link: URL?) throws {
            guard depth < 128 else { throw ClientError.invalidResponse }
            var cursor = first
            while let node = cursor {
                count += 1
                guard count <= 20_000 else { throw ClientError.responseTooLarge }
                defer { cursor = node.pointee.next }
                if node.pointee.type == XML_TEXT_NODE {
                    if let value = node.pointee.content {
                        append(String(decodingCString: value, as: UTF8.self), bold: bold, italic: italic, link: link)
                    }
                    continue
                }
                guard node.pointee.type == XML_ELEMENT_NODE, let rawName = node.pointee.name else { continue }
                let name = String(decodingCString: rawName, as: UTF8.self).lowercased()
                guard allowed.contains(name) else { continue }
                if name == "br" { append("\n"); continue }
                if blocks.contains(name) { newline() }
                if name == "li" { append("• ") }
                var target = link
                if name == "a" { target = contentURL(attribute(node, "href")) }
                if ["img", "video", "audio"].contains(name) {
                    var source = attribute(node, "src")
                    if source == nil {
                        var child = node.pointee.children
                        while let item = child {
                            if item.pointee.type == XML_ELEMENT_NODE, let childName = item.pointee.name,
                               String(decodingCString: childName, as: UTF8.self) == "source" { source = attribute(item, "src"); break }
                            child = item.pointee.next
                        }
                    }
                    if let url = contentURL(source, media: true) {
                        newline()
                        let label = attribute(node, "alt").flatMap { $0.isEmpty ? nil : $0 } ?? (name == "img" ? L10n.t("查看图片附件") : L10n.t("查看音视频附件"))
                        append(label, link: url); newline()
                    }
                    continue
                }
                try walk(node.pointee.children, depth: depth + 1,
                         bold: bold || ["strong", "b", "th", "h1", "h2", "h3", "h4", "h5", "h6"].contains(name),
                         italic: italic || ["em", "i"].contains(name), link: target)
                if blocks.contains(name) { newline() }
                if ["td", "th"].contains(name) { append("  ") }
            }
        }
        try walk(xmlDocGetRootElement(document), depth: 0, bold: false, italic: false, link: nil)
        runs = output
    }
}
