import SwiftUI
import UniformTypeIdentifiers
import ECYCloudKit

struct TicketAttachmentPicker: View {
    let session: ClientSession
    @Binding var attachments: [TicketAttachment]
    @Binding var uploading: Bool
    @Binding var message: String?
    @State private var choosing: [UTType]?
    @Environment(\.colorScheme) private var scheme
    private static let allowed = TicketUpload.extensions.compactMap { UTType(filenameExtension: $0) }
    var body: some View {
        let colors = ProductPalette(scheme: scheme)
        VStack(alignment: .leading, spacing: 10) {
            ProductFlow(spacing: 8) {
                #if !os(tvOS)
                pickButton(L10n.t("图片"), icon: "image_outlined") { choosing = Self.allowed.filter { $0.conforms(to: .image) } }
                pickButton(L10n.t("视频"), icon: "videocam_outlined") { choosing = Self.allowed.filter { $0.conforms(to: .audiovisualContent) } }
                #endif
                pickButton(L10n.t("运行日志"), icon: "bug_report_outlined") { Task { await uploadRuntimeLog() } }
                if uploading { ProgressView().controlSize(.small).frame(width: 18, height: 18) }
            }
            #if os(tvOS)
            Text(L10n.t("如需添加附件，请在手机、电脑或网站提交。")).font(.system(size: 12)).foregroundStyle(colors.secondary)
            #endif
            if !attachments.isEmpty {
                ProductFlow(spacing: 6) {
                    ForEach(attachments) { attachment in
                        HStack(spacing: 6) {
                            ProductGlyph(name: attachment.kind == "image" ? "image_outlined" : attachment.kind == "video" ? "videocam_outlined" : "attach_file", size: 16)
                            Text(verbatim: attachment.originalName).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            Button { attachments.removeAll { $0.id == attachment.id } } label: { ProductGlyph(name: "close", size: 16) }
                                .buttonStyle(.productPlain).disabled(uploading).accessibilityLabel(L10n.t("删除"))
                        }
                        .foregroundStyle(colors.text).padding(.horizontal, 8).frame(minHeight: 32)
                        .overlay(Capsule().strokeBorder(colors.outline, lineWidth: 1))
                    }
                }
            }
        }
        #if !os(tvOS)
        .fileImporter(isPresented: Binding(get: { choosing != nil }, set: { if !$0 { choosing = nil } }), allowedContentTypes: choosing ?? [], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls): if let url = urls.first { Task { await upload(url) } }
            case .failure: message = L10n.t("无法读取所选文件，请重试。")
            }
        }
        #endif
    }
    private func pickButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label { Text(title) } icon: { ProductGlyph(name: icon, size: 16) } }
            .buttonStyle(ProductButtonStyle()).disabled(uploading || attachments.count >= 20)
    }
    private func uploadRuntimeLog() async {
        guard let url = session.latestRuntimeLog else { message = L10n.t("暂无运行日志"); return }
        await upload(url)
    }
    private func upload(_ url: URL) async {
        guard !uploading else { return }
        uploading = true
        defer { uploading = false }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let name = url.lastPathComponent
            let data = try await Task.detached {
                let attributes = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard attributes.isRegularFile == true, let size = attributes.fileSize else { throw ClientError.invalidResponse }
                try TicketUpload.validate(name: name, size: size)
                let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
                var data = Data()
                while let chunk = try file.read(upToCount: min(1_048_576, TicketUpload.maximumBytes + 1 - data.count)), !chunk.isEmpty {
                    try Task.checkCancellation()
                    data.append(chunk)
                    try TicketUpload.validate(name: name, size: data.count)
                }
                return data
            }.value
            let attachment = try await session.uploadTicketAttachment(data: data, name: name)
            attachments.append(attachment)
        } catch is CancellationError { }
        catch { message = (error as? ClientError)?.localizedDescription ?? L10n.t("附件上传失败，请重试。") }
    }
}
