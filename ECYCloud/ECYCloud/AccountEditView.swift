import SwiftUI
import ECYCloudKit

struct AccountEditView: View {
    let session: ClientSession
    @Environment(\.dismiss) private var dismiss
    @State private var message: String?
    @State private var saving = false

    var body: some View {
        FeatureSheet(title: L10n.t("修改信息"), working: saving) {
            ScrollView {
                AccountSecurityView(session: session, message: $message, working: $saving)
                    .padding(.leading, 14).padding(.trailing, 16).padding(.bottom, 14).frame(maxWidth: .infinity)
            }
            .productToast($message)
        }
        .onChange(of: session.phase) { _, phase in
            if phase != .signedIn { dismiss() }
        }
    }
}
