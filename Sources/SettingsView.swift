import CoreImage.CIFilterBuiltins
import SwiftUI

/// Sign in to HolyArrs. With Plex (the TV shows a QR code of Plex's approval page; the iPhone opens it), or with
/// the name and password from HolyArrs' web page. On a HolyArrs that has no owner yet, the Plex button makes
/// that Plex account the owner (HolyArrs' first-run "set up with Plex").
struct SignInView: View {
    @EnvironmentObject private var api: HolyArrs
    @State private var name = ""
    @State private var password = ""
    @State private var code = ""
    @State private var remember = true
    @State private var needsCode = false
    @State private var busy = false
    @State private var error: String?
    @State private var needsSetup = false
    @State private var ways: Set<String> = ["password"]
    @State private var setupWays: Set<String> = []
    @State private var plexLink: URL?
    @State private var plexTask: Task<Void, Never>?
    @State private var showPassword = false
    @State private var pin: (id: Int, setup: Bool)?
    @Environment(\.scenePhase) private var scenePhase

    private var plexOn: Bool { needsSetup ? setupWays.contains("plex") : ways.contains("plex") }

    var body: some View {
        AdaptiveStack(tvAlignment: .top, spacing: S(120)) {
            VStack(alignment: .leading, spacing: S(20)) {
                Text("HolyArrs").font(.system(size: F(90), weight: .heavy)).foregroundStyle(Theme.accent)
                Text(needsSetup ? "This HolyArrs has no owner yet. Set it up with your Plex account and you are its owner."
                                : "Movies, shows and music: browse, ask for and follow them from the couch.")
                    .font(.title3).foregroundStyle(Theme.dim).frame(maxWidth: W(640), alignment: .leading)
                Text(api.address).font(.callout.monospaced()).foregroundStyle(Theme.dim).padding(.top, S(20))
            }
            VStack(alignment: .leading, spacing: S(26)) {
                if let plexLink {
                    plexWaiting(plexLink)
                } else if needsCode {
                    Text("Enter the 6-digit code from your authenticator app.").foregroundStyle(Theme.dim)
                    TextField("Code", text: $code).keyboardType(.numberPad)
                    Button(busy ? "Checking..." : "Continue") { Task { await finish() } }.disabled(busy || code.count < 6)
                } else {
                    if plexOn {
                        Button { startPlex() } label: {
                            Label(needsSetup ? "Set up HolyArrs with Plex" : "Sign in with Plex", systemImage: "person.badge.key")
                                .font(.system(size: F(30), weight: .semibold)).padding(.horizontal, S(20))
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(busy)
                    }
                    if !needsSetup && ways.contains("password") {
                        if showPassword || !plexOn {
                            TextField("Name", text: $name).autocorrectionDisabled().textInputAutocapitalization(.never)
                                .textContentType(.username)
                            SecureField("Password", text: $password).textContentType(.password)
                            Toggle("Stay signed in", isOn: $remember)
                            Button(busy ? "Signing in..." : "Sign in") { Task { await signIn() } }
                                .disabled(busy || name.isEmpty || password.isEmpty)
                        } else {
                            Button("Use a name and password instead") { showPassword = true }
                        }
                    }
                    if needsSetup && !plexOn {
                        Text("Open \(api.address) on the PC to make the owner account, then sign in here.").foregroundStyle(Theme.dim)
                    }
                    TextField("HolyArrs address", text: $api.address)
                        .keyboardType(.URL).autocorrectionDisabled().textInputAutocapitalization(.never)
                }
                if let error { Text(error).foregroundStyle(.red.opacity(0.9)).frame(maxWidth: W(700), alignment: .leading) }
            }
            .frame(width: W(760))
        }
        .padding(S(120))
        .task(id: api.address) { await readState() }
        .onDisappear { plexTask?.cancel(); PlexWebSignIn.close() }
        .onChange(of: scenePhase) { _, phase in
            // Back from another app (Safari, Plex): check straight away instead of waiting for the next round.
            if phase == .active, let pin { Task { await checkOnce(pin.id, setup: pin.setup) } }
        }
    }

    /// The Plex step: a QR code of Plex's approval page (scan it with a phone), and on iPhone the page itself.
    private func plexWaiting(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: S(26)) {
            Text(Device.isTV ? "Scan with your phone's camera and approve HolyArrs on Plex." : "Approve HolyArrs on Plex, then come back here.")
                .font(.title3)
                .fixedSize(horizontal: false, vertical: true)
            if Device.isTV, let qr = QRCode.image(url.absoluteString) {
                Image(uiImage: qr).interpolation(.none).resizable().frame(width: 420, height: 420)
                    .padding(24).background(Color.white).clipShape(RoundedRectangle(cornerRadius: 16))
                    .accessibilityLabel("QR code for Plex sign-in")
            }
            if !Device.isTV {
                Button { PlexWebSignIn.open(url) } label: { Label("Open Plex", systemImage: "safari") }.buttonStyle(.borderedProminent)
            }
            HStack(spacing: S(20)) {
                ProgressView()
                Text("Waiting for Plex...").foregroundStyle(Theme.dim)
            }
            Button("Cancel") { plexTask?.cancel(); PlexWebSignIn.close(); plexLink = nil; pin = nil }
        }
    }

    private func readState() async {
        guard let st = await api.signInState() else { return }
        needsSetup = st.needsSetup
        ways = st.ways
        setupWays = st.setupWays
    }

    private func startPlex() {
        plexTask?.cancel()
        error = nil
        let setup = needsSetup
        plexTask = Task {
            busy = true
            defer { busy = false; pin = nil; PlexWebSignIn.close() }
            do {
                let started = try await api.plexStart(setup: setup)
                pin = (started.id, setup)
                plexLink = started.url
                // iPhone: Plex opens in Apple's sign-in sheet inside the app (it uses Safari's Plex sign-in), so the
                // app is never suspended while waiting. Not against the test server on this machine.
                if !Device.isTV && !api.isLocalServer { PlexWebSignIn.open(started.url) }
                // Plex keeps the PIN for 10 minutes; HolyArrs lets us ask once a second.
                let deadline = Date().addingTimeInterval(600)
                var dropped = 0
                while !Task.isCancelled, Date() < deadline {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    if api.me != nil { return }  // signed in by the check made on returning to the app
                    do {
                        if try await api.plexFinish(id: started.id, setup: setup) { return }
                        dropped = 0
                    } catch let e as URLError where PlexWebSignIn.isTransient(e) {
                        // The connection dropped (iOS cuts them when the app goes to the background, or Wi-Fi
                        // blipped). Keep asking; give up only after a minute of nothing getting through.
                        dropped += 1
                        if dropped >= 30 { throw e }
                    }
                }
                if !Task.isCancelled { error = "The Plex sign-in timed out. Start again." }
                plexLink = nil
            } catch APIError.twoFactor {
                plexLink = nil
                needsCode = true
            } catch is CancellationError {
                plexLink = nil
            } catch {
                plexLink = nil
                self.error = error.localizedDescription
            }
        }
    }

    /// One check, made when the app comes back to the foreground.
    private func checkOnce(_ id: Int, setup: Bool) async {
        do {
            if try await api.plexFinish(id: id, setup: setup) { plexTask?.cancel(); PlexWebSignIn.close() }
        } catch APIError.twoFactor {
            plexTask?.cancel()
            plexLink = nil
            needsCode = true
        } catch {
            // The polling loop keeps trying; nothing to show yet.
        }
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

enum QRCode {
    static func image(_ text: String) -> UIImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 12, y: 12)),
              let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

struct SettingsView: View {
    @EnvironmentObject private var api: HolyArrs
    @EnvironmentObject private var rtx: RTXServer
    @EnvironmentObject private var sportarr: Sportarr

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
                Toggle("Show the Sports tab", isOn: $sportarr.enabled)
                TextField(Sportarr.defaultAddress, text: $sportarr.address)
                    .keyboardType(.URL).autocorrectionDisabled().textInputAutocapitalization(.never)
                LabeledContent("Status", value: sportarrStatus)
                Button("Check again") { Task { await sportarr.connect() } }
            } header: {
                Text("Sportarr (sports)")
            } footer: {
                Text("Sports come from Sportarr on the PC. Downloaded games and races play through the RTX 4K server.")
            }
            Section {
                Text("Indexers, download apps, pick rules, keys and backups are set in HolyArrs' web page on the PC: \(api.address)")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
    }

    private var sportarrStatus: String {
        switch sportarr.state {
        case .checking: return "checking"
        case .ready: return sportarr.version.map { "connected (\($0))" } ?? "connected"
        case .needsKey: return "needs its key (see the Sports tab)"
        case let .unreachable(why): return why
        }
    }
}
