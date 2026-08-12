import SwiftUI

struct AuthenticationView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    private let title: String
    private let buttonTitle: String
    @State private var serverURL = ""
    @State private var username = ""
    @State private var password = ""
    @State private var certificateSha256 = ""
    @State private var cleartextHTTPConfirmed = false
    @State private var isConnecting = false

    init(serverURL: String = "", username: String = "", certificateSha256: String? = nil,
         title: String = "连接 BookOrbit", buttonTitle: String = "连接并登录") {
        self.title = title
        self.buttonTitle = buttonTitle
        _serverURL = State(initialValue: serverURL)
        _username = State(initialValue: username)
        _certificateSha256 = State(initialValue: certificateSha256 ?? "")
    }

    private var isCleartextHTTP: Bool {
        serverURL.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("http://")
    }

    private var confirmedHTTPTarget: String? {
        guard isCleartextHTTP, cleartextHTTPConfirmed else { return nil }
        return BookOrbitServerURLPolicy.httpConfirmationTarget(for: serverURL)
    }

    var body: some View {
        NavigationView {
            Form {
                Section("BookOrbit") {
                    TextField("服务器地址", text: $serverURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("用户名", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("密码", text: $password)
                    TextField("已确认的证书 SHA-256 指纹（可选）", text: $certificateSha256)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if isCleartextHTTP {
                        Toggle("我已核对当前局域网 HTTP 主机和端口，并明确允许明文连接", isOn: $cleartextHTTPConfirmed)
                        Text("仅允许私网 IP 或 .local 主机；修改地址或端口后需要重新确认。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Button(isConnecting ? "正在连接" : buttonTitle) {
                        Task {
                            isConnecting = true
                            await environment.connect(serverURL: serverURL, username: username, password: password,
                                                      certificateSha256: certificateSha256.isEmpty ? nil : certificateSha256,
                                                      httpConfirmationTarget: confirmedHTTPTarget)
                            isConnecting = false
                            if environment.isAuthenticated && environment.bookOrbitConnectionError == nil {
                                dismiss()
                            }
                        }
                    }
                    .disabled(isConnecting || serverURL.isEmpty || username.isEmpty || password.isEmpty || (isCleartextHTTP && confirmedHTTPTarget == nil))
                }
                Section {
                    Text("也可以先使用本地书库和 Wi-Fi 传书。")
                        .foregroundStyle(.secondary)
                }
            }
            .onChange(of: serverURL) { _ in cleartextHTTPConfirmed = false }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }
}
