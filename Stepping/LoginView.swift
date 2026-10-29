import SwiftUI
import AuthenticationServices

/// CareLink EU login sheet. Credentials are entered ONLY in Medtronic's own
/// page; the app keeps just the OAuth tokens (Keychain) — login once.
struct LoginView: View {
    @ObservedObject var carelink = CareLinkClient.shared
    @Environment(\.dismiss) var dismiss
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "drop.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(.blue)
                Text("Medtronic CareLink (EU)")
                    .font(.title2.bold())
                Text("Log in with your CareLink username and passcode. " +
                     "The login stays saved on this phone — you won't need to log in again.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                if let u = carelink.username {
                    Text("Last user: \(u)").font(.caption).foregroundStyle(.secondary)
                }
                Text(carelink.state).font(.caption).foregroundStyle(.secondary)
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
                Button(busy ? "Logging in…" : "Log in with CareLink") {
                    busy = true
                    error = nil
                    Task {
                        do {
                            try await carelink.login()
                            dismiss()
                        } catch {
                            self.error = (error as NSError).localizedDescription.isEmpty
                                ? "Login failed. Check credentials and connection."
                                : error.localizedDescription
                        }
                        busy = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy)
                if carelink.isLoggedIn {
                    Button("Log out (clears saved session)", role: .destructive) {
                        carelink.logout()
                    }
                }
                Spacer()
            }
            .padding()
            .navigationTitle("CareLink Login")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}
