import SwiftUI

struct LoginView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    /// Adding another account from Settings (shows Cancel, prefills the current server).
    var adding = false
    @State private var server = ""
    @State private var quickCode: String?
    @State private var quickTask: Task<Void, Never>?
    @State private var username = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?
    @State private var glow = false
    @State private var found: [ServerDiscovery.Found] = []
    @State private var searching = false

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            Circle().fill(Theme.blue).frame(width: 340).blur(radius: 130)
                .offset(x: glow ? -90 : 60, y: glow ? -260 : -180).opacity(0.55)
            Circle().fill(Theme.red).frame(width: 300).blur(radius: 130)
                .offset(x: glow ? 120 : -40, y: glow ? 260 : 200).opacity(0.4)

            ScrollView {
                VStack(spacing: 22) {
                    Spacer(minLength: 70)
                    Image("HuefinMark")
                        .resizable()
                        .frame(width: 112, height: 112)
                        .shadow(color: Theme.violet.opacity(0.45), radius: 30, y: 12)
                    VStack(spacing: 6) {
                        Text("huefin").font(.system(size: 46, weight: .heavy)).tracking(-1.5)
                        Text(adding ? "Add a user or another server" : "Connect to your Jellyfin server").foregroundStyle(.secondary)
                    }

                    foundServers

                    VStack(spacing: 12) {
                        field("Server address", systemImage: "server.rack") {
                            TextField("https://jellyfin.example.com", text: $server)
                                .keyboardType(.URL).textContentType(.URL)
                        }
                        field("Username", systemImage: "person.fill") {
                            TextField("Username", text: $username).textContentType(.username)
                        }
                        field("Password", systemImage: "lock.fill") {
                            SecureField("Password", text: $password).textContentType(.password)
                                .onSubmit { Task { await signIn() } }
                        }
                    }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                    if let error {
                        Text(error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
                    }

                    Button { Task { await signIn() } } label: {
                        HStack {
                            if busy { ProgressView().tint(.white) }
                            Text(busy ? "Connecting…" : "Sign In")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(busy || server.isEmpty || username.isEmpty)
                    .opacity(server.isEmpty || username.isEmpty ? 0.6 : 1)

                    quickConnectSection

                    Text("Works with local addresses (192.168.x.x:8096) or your remote domain.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)

                    if adding {
                        Button("Cancel") { quickTask?.cancel(); dismiss() }.buttonStyle(SecondaryButtonStyle())
                    }
                }
                .padding(24)
                .frame(maxWidth: 460)
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 6).repeatForever(autoreverses: true)) { glow = true }
            if adding, server.isEmpty, let s = app.session { server = s.serverURL }
        }
        .task { await lookForServers() }
        .onDisappear { quickTask?.cancel() }
    }

    /// Jellyfin servers found on this network: tap one instead of typing its address.
    @ViewBuilder
    private var foundServers: some View {
        if searching && found.isEmpty {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Looking for servers on your network…").font(.footnote) }
                .foregroundStyle(.secondary)
        } else if !found.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Found on your network").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(found) { f in
                    Button { server = f.address } label: {
                        HStack {
                            Image(systemName: "server.rack").foregroundStyle(Theme.violet)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(f.name).font(.headline)
                                Text(f.address + (f.version.isEmpty ? "" : " · Jellyfin \(f.version)")).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if server == f.address { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.violet) }
                        }
                        .padding(12)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func lookForServers() async {
        guard !searching else { return }
        searching = true
        found = await ServerDiscovery.scan()
        searching = false
        // One server and nothing typed yet: fill it in.
        if found.count == 1, server.isEmpty { server = found[0].address }
    }

    /// Sign in without typing a password: approve the code on any device that's already signed in.
    @ViewBuilder
    private var quickConnectSection: some View {
        if let quickCode {
            VStack(spacing: 10) {
                Text("Quick Connect code").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(quickCode)
                    .font(.system(size: 44, weight: .heavy, design: .rounded).monospacedDigit())
                    .tracking(6)
                    .foregroundStyle(Theme.spectrum)
                    .textSelection(.enabled)
                Text("On a device that's already signed in, open Quick Connect and enter this code. In Huefin it's Settings → Quick Connect; in Jellyfin's web app it's your profile → Quick Connect.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for approval…").font(.caption)
                }
                Button("Cancel") { quickTask?.cancel(); self.quickCode = nil; busy = false }
                    .font(.footnote.weight(.semibold))
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        } else {
            Button { startQuickConnect() } label: {
                Label("Sign in with Quick Connect", systemImage: "qrcode")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(busy || server.isEmpty)
            .opacity(server.isEmpty ? 0.6 : 1)
        }
    }

    private func startQuickConnect() {
        guard !busy else { return }
        busy = true
        error = nil
        quickTask = Task {
            do {
                let start = try await app.quickConnectStart(server: server)
                quickCode = start.code
                try await app.quickConnectFinish(client: start.client, info: start.info, secret: start.secret)
                if adding { dismiss() }
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
            quickCode = nil
            busy = false
        }
    }

    private func field<Content: View>(_ label: String, systemImage: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage).foregroundStyle(.secondary).frame(width: 20)
            content()
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityLabel(label)
    }

    private func signIn() async {
        guard !busy else { return }
        busy = true
        error = nil
        do {
            try await app.login(server: server, username: username, password: password)
            if adding { dismiss() }
        } catch {
            self.error = error.localizedDescription
        }
        busy = false
    }
}
