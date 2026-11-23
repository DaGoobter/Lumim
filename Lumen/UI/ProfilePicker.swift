import SwiftUI

/// Plex-style "Who's watching?" screen, shown at launch when more than one profile is saved.
struct ProfilePickerView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var editing = false
    @State private var adding = false
    @AppStorage("prism.askWhoIsWatching") private var askOnLaunch = true

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            Circle().fill(Theme.violet).frame(width: 360).blur(radius: 140).offset(x: -120, y: -260).opacity(0.45)
            Circle().fill(Theme.blue).frame(width: 300).blur(radius: 140).offset(x: 140, y: 280).opacity(0.35)
            ScrollView {
                VStack(spacing: 34) {
                    Spacer(minLength: 60)
                    Text("Who's watching?").font(.system(size: 34, weight: .heavy))
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120, maximum: 160), spacing: 26)], spacing: 30) {
                        ForEach(app.accounts, id: \.key) { account in
                            Button {
                                if editing { Task { await app.remove(account) } } else { pick(account) }
                            } label: { ProfileTile(account: account, current: account.key == app.session?.key, editing: editing) }
                            .buttonStyle(CardPressStyle())
                        }
                        Button { adding = true } label: {
                            VStack(spacing: 10) {
                                Image(systemName: "plus")
                                    .font(.system(size: 34, weight: .semibold))
                                    .frame(width: 108, height: 108)
                                    .background(Circle().strokeBorder(.white.opacity(0.35), style: StrokeStyle(lineWidth: 2, dash: [6])))
                                Text("Add profile").font(.subheadline.weight(.semibold))
                            }
                            .foregroundStyle(.white.opacity(0.8))
                        }
                        .buttonStyle(CardPressStyle())
                    }
                    .padding(.horizontal, 24)
                    .frame(maxWidth: 640)

                    HStack(spacing: 14) {
                        Button(editing ? "Done" : "Manage profiles") { withAnimation { editing.toggle() } }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                    Toggle("Ask every time Prism opens", isOn: $askOnLaunch)
                        .font(.footnote).frame(maxWidth: 300)
                    Spacer(minLength: 40)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .fullScreenCover(isPresented: $adding) { LoginView(adding: true) }
        .onChange(of: app.accounts.count) { _, n in if n <= 1 { dismiss() } }
    }

    private func pick(_ account: StoredSession) {
        app.switchTo(account)
        dismiss()
    }
}

struct ProfileTile: View {
    let account: StoredSession
    let current: Bool
    let editing: Bool

    private var avatarURL: URL? {
        URL(string: account.serverURL)?.appendingPathComponent("Users/\(account.userId)/Images/Primary")
    }

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().fill(Theme.gradient)
                Text(String(account.userName.prefix(1)).uppercased())
                    .font(.system(size: 44, weight: .heavy)).foregroundStyle(.white)
                AsyncImage(url: avatarURL) { phase in
                    if case .success(let img) = phase { img.resizable().scaledToFill() }
                }
            }
            .frame(width: 108, height: 108)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(current ? AnyShapeStyle(Theme.spectrum) : AnyShapeStyle(Color.white.opacity(0.15)),
                                           lineWidth: current ? 3 : 1))
            .overlay(alignment: .topTrailing) {
                if editing {
                    Image(systemName: "minus.circle.fill").font(.title).foregroundStyle(.white, .red)
                }
            }
            .shadow(color: .black.opacity(0.5), radius: 14, y: 8)
            Text(account.userName).font(.headline).lineLimit(1)
            Text(account.serverName ?? URL(string: account.serverURL)?.host ?? "")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .foregroundStyle(.white)
    }
}
