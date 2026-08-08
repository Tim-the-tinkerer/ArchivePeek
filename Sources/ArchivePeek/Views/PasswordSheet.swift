import SwiftUI

struct PasswordSheet: View {
    @EnvironmentObject private var browser: ArchiveBrowserModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Password Required", systemImage: "lock.fill")
                .font(.title2.bold())

            Text("This archive is encrypted. Enter the password to view and extract its contents.")
                .foregroundStyle(.secondary)

            SecureField("Password", text: $browser.password)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit {
                    browser.unlockArchiveWithPassword()
                }

            if let passwordError = browser.passwordErrorMessage {
                Text(passwordError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    browser.closeArchive()
                    dismiss()
                }
                Button("Unlock") {
                    browser.unlockArchiveWithPassword()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(browser.password.isEmpty || browser.isLoading)
            }
        }
        .padding(24)
        .frame(width: 380)
        .onAppear { focused = true }
    }
}