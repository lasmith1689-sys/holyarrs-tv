import SwiftUI

/// Sign in to HolyArrs with the same name and password as its web page.
struct SignInView: View {
    @EnvironmentObject private var api: HolyArrs
    @State private var name = ""
    @State private var password = ""
    @State private var code = ""
    @State private var remember = true
    @State private var needsCode = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        HStack(alignment: .top, spacing: 120) {
            VStack(alignment: .leading, spacing: 20) {
                Text("HolyArrs").font(.system(size: 90, weight: .heavy)).foregroundStyle(Theme.accent)
                Text("Movies, shows and music: browse, ask for and follow them from the couch.")
                    .font(.title3).foregroundStyle(Theme.dim).frame(maxWidth: 640, alignment: .leading)
                Text(api.address).font(.callout.monospaced()).foregroundStyle(Theme.dim).padding(.top, 20)
            }
            VStack(alignment: .leading, spacing: 26) {
                TextField("HolyArrs address", text: $api.address)
                    .keyboardType(.URL).autocorrectionDisabled().textInputAutocapitalization(.never)
                if needsCode {
                    Text("Enter the 6-digit code from your authenticator app.").foregroundStyle(Theme.dim)
                    TextField("Code", text: $code).keyboardType(.numberPad)
                    Button(busy ? "Checking..." : "Continue") { Task { await finish() } }.disabled(busy || code.count < 6)
                } else {
                    TextField("Name", text: $name).autocorrectionDisabled().textInputAutocapitalization(.never)
                        .textContentType(.username)
                    SecureField("Password", text: $password).textContentType(.password)
                    Toggle("Stay signed in", isOn: $remember)
                    Button(busy ? "Signing in..." : "Sign in") { Task { await signIn() } }
                        .disabled(busy || name.isEmpty || password.isEmpty)
                }
                if let error { Text(error).foregroundStyle(.red.opacity(0.9)).frame(maxWidth: 700, alignment: .leading) }
            }
            .frame(width: 760)
        }
        .padding(120)
    }

    private func signIn() async {
        busy = true
        defer { busy = false }
        do {
            try await api.signIn(name: name, password: password, remember: remember)
            error = nil
        } catch APIError.twoFactor {
            needsCode = true
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func finish() async {
        busy = true
        defer { busy = false }
        do { try await api.finishTwoFactor(code: code); error = nil } catch { self.error = error.localizedDescription }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var api: HolyArrs
    @EnvironmentObject private var rtx: RTXServer

    var body: some View {
        Form {
            Section("HolyArrs") {
                LabeledContent("Signed in as", value: api.me.map { "\($0.name) (\($0.role))" } ?? "-")
                TextField(HolyArrs.defaultAddress, text: $api.address)
                    .keyboardType(.URL).autocorrectionDisabled().textInputAutocapitalization(.never)
                Button("Sign out", role: .destructive) { Task { await api.signOut() } }
            }
            Section {
                TextField(RTXServer.defaultAddress, text: $rtx.address)
                    .keyboardType(.URL).autocorrectionDisabled().textInputAutocapitalization(.never)
                Toggle("Show Play in 4K", isOn: $rtx.enabled)
                LabeledContent("Films on the PC", value: rtx.films.isEmpty ? (rtx.error ?? "none found") : "\(rtx.films.count)")
                Button("Check again") { Task { await rtx.refresh() } }
            } header: {
                Text("RTX 4K upscaling server")
            } footer: {
                Text("Titles that are also in the RTX 4K library get a Play in 4K button, which plays them upscaled by the PC's GPU.")
            }
            Section {
                Text("Indexers, download apps, pick rules, keys and backups are set in HolyArrs' web page on the PC: \(api.address)")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
    }
}
