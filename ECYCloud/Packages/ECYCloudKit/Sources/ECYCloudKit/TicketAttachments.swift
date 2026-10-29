import Foundation

public struct TicketAttachment: Decodable, Identifiable, Sendable {
    public let url: String, originalName: String, kind: String
    public var id: String { url }
    public init(url: String, originalName: String, kind: String) { self.url = url; self.originalName = originalName; self.kind = kind }
}
public enum TicketUpload {
    public static let maximumBytes = 50 * 1024 * 1024
    public static let extensions = ["jpg", "jpeg", "png", "gif", "bmp", "webp", "mp4", "avi", "mov", "wmv", "flv", "webm", "mkv", "log", "txt", "zip"]
    public static func validate(name: String, size: Int) throws {
        guard size > 0, size <= maximumBytes else { throw ClientError.input(L10n.t("附件不能为空，且不能超过 50 MB。")) }
        guard !name.isEmpty, name.utf8.count <= 255, !name.contains("/"), !name.contains("\\"),
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              extensions.contains((name as NSString).pathExtension.lowercased()) else { throw ClientError.input(L10n.t("不支持的附件类型或文件名。")) }
    }
}
struct UploadGrant: Decodable, Sendable {
    let direct: Int
    let uploadUrl: String?, token: String?, url: String?, originalName: String?, kind: String?
}
extension PanelAPI {
    func uploadDirect(_ data: Data, grant: UploadGrant) async throws -> TicketAttachment {
        guard let address = grant.uploadUrl, let url = ClientLink.external(address), url.scheme?.lowercased() == "https",
              let token = grant.token, !token.isEmpty, token.utf8.count <= 8192, token.utf8.allSatisfy({ (33...126).contains($0) }),
              let attachmentURL = grant.url, ClientLink.external(attachmentURL)?.scheme?.lowercased() == "https",
              let name = grant.originalName, let kind = grant.kind, ["image", "video", "file"].contains(kind) else { throw ClientError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"; request.httpBody = data; request.timeoutInterval = 120
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(token, forHTTPHeaderField: "X-Files-Token")
        let result = try await transport.send(request)
        struct Header: Decodable { let ret: Int }
        guard result.data.count <= URLSessionTransport.maximumResponseBytes, (200..<300).contains(result.status),
              (try? JSONDecoder().decode(Header.self, from: result.data).ret) == 1 else { throw ClientError.input(L10n.t("附件上传未完成，请重试。")) }
        return TicketAttachment(url: attachmentURL, originalName: name, kind: kind)
    }
    func uploadMultipart(_ endpoints: PanelEndpoints, token: String, data: Data, name: String) async throws -> TicketAttachment {
        let boundary = "ECY-" + UUID().uuidString
        let name = name.replacingOccurrences(of: "\"", with: "_")
        var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(name)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8)
        body.append(data); body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return try await request("/tickets/upload", origin: endpoints.site, token: token, jsonBody: body, contentType: "multipart/form-data; boundary=\(boundary)", timeout: 120)
    }
}
extension ClientSession {
    public func uploadTicketAttachment(data: Data, name: String) async throws -> TicketAttachment {
        try TicketUpload.validate(name: name, size: data.count)
        let grant: UploadGrant = try await authenticated(allowRestricted: true) {
            try await api.request("/tickets/upload", origin: endpoints.site, token: $0.token, body: ["prepare": "1", "name": name])
        }
        let attachment: TicketAttachment = try await authenticated(allowRestricted: true) {
            if grant.direct == 1 { return try await api.uploadDirect(data, grant: grant) }
            guard grant.direct == 0 else { throw ClientError.invalidResponse }
            return try await api.uploadMultipart(endpoints, token: $0.token, data: data, name: name)
        }
        guard let url = URL(string: attachment.url, relativeTo: endpoints.site)?.absoluteURL,
              ["https", "http"].contains(url.scheme?.lowercased()), url.user == nil, url.password == nil else { throw ClientError.invalidResponse }
        return TicketAttachment(url: url.absoluteString, originalName: attachment.originalName, kind: attachment.kind)
    }
}
extension TicketContent {
    public static func html(_ text: String, attachments: [TicketAttachment]) throws -> String {
        if attachments.isEmpty { return try html(text) }
        guard attachments.count <= 20 else { throw ClientError.input(L10n.t("每次最多添加 20 个附件。")) }
        var output = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : try html(text)
        for attachment in attachments {
            guard let url = ClientLink.external(attachment.url), ["http", "https"].contains(url.scheme?.lowercased()) else { throw ClientError.invalidResponse }
            guard !attachment.originalName.isEmpty, attachment.originalName.utf8.count <= 1024 else { throw ClientError.invalidResponse }
            let source = escape(url.absoluteString), name = escape(attachment.originalName)
            switch attachment.kind {
            case "image": output += "<p><img src=\"\(source)\" alt=\"\(name)\"></p>"
            case "video": output += "<p><video src=\"\(source)\" controls></video></p>"
            default: output += "<p><a href=\"\(source)\">\(name)</a></p>"
            }
        }
        guard text.unicodeScalars.count + attachments.reduce(0, { $0 + $1.originalName.unicodeScalars.count }) <= 1000 else { throw ClientError.input(L10n.t("正文与附件名称合计不能超过 1000 字。")) }
        return output
    }
}
