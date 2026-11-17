import SwiftUI

struct LoginView: View {
    @Environment(AppState.self) private var app
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?
    @State private var glow = false

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            Circle().fill(Theme.accent).frame(width: 340).blur(radius: 130)
                .offset(x: glow ? -90 : 60, y: glow ? -260 : -180).opacity(0.55)
            Circle().fill(Theme.accent2).frame(width: 300).blur(radius: 130)
                .offset(x: glow ? 120 : -40, y: glow ? 260 : 200).opacity(0.4)

            ScrollView {
                VStack(spacing: 22) {
                    Spacer(minLength: 70)
                    Image(systemName: "play.rectangle.fill")
                        .font(.system(size: 60))
                        .foregroundStyle(Theme.gradient)
                    VStack(spacing: 6) {
                        Text("Lumen").font(.system(size: 42, weight: .heavy, design: .rounded))
                        Text("Connect to your Jellyfin server").foregroundStyle(.secondary)
                    }

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

                    Text("Works with local addresses (192.168.x.x:8096) or your remote domain.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding(24)
                .frame(maxWidth: 460)
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 6).repeatForever(autoreverses: true)) { glow = true }
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
        } catch {
            self.error = error.localizedDescription
        }
        busy = false
    }
}
