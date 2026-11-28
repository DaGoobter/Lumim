import SwiftUI

/// Plex-style "Who's watching?" screen, shown at launch when more than one profile is saved.
struct ProfilePickerView: View {
    /// Opened because the last profile is locked: even that profile needs its PIN.
    var atLaunch = false
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var editing = false
    @State private var adding = false
    /// A locked profile waiting for its PIN, and whether it's being opened or removed.
    @State private var unlocking: StoredSession?
    @State private var unlockToRemove = false
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
                                if editing { remove(account) } else { pick(account) }
                            } label: { ProfileTile(account: account, current: account.key == app.session?.key, editing: editing) }
                            .buttonStyle(CardPressStyle())
                        }
                        Button { adding = true } label: {
                            VStack(spacing: 10) {
                                Image(systemName: "plus")
                                    .font(.system(size: 34, weight: .semibold))
                                    .frame(width: 108, height: 108)
                                    .background(Circle().strokeBorder(Color.primary.opacity(0.35), style: StrokeStyle(lineWidth: 2, dash: [6])))
                                Text("Add profile").font(.subheadline.weight(.semibold))
                            }
                            .foregroundStyle(.primary.opacity(0.8))
                        }
                        .buttonStyle(CardPressStyle())
                    }
                    .padding(.horizontal, 24)
                    .frame(maxWidth: 640)

                    HStack(spacing: 14) {
                        Button(editing ? "Done" : "Manage profiles") { withAnimation { editing.toggle() } }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                    Toggle("Ask every time Huefin opens", isOn: $askOnLaunch)
                        .font(.footnote).frame(maxWidth: 300)
                    Spacer(minLength: 40)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .fullScreenCover(isPresented: $adding) { LoginView(adding: true) }
        .fullScreenCover(item: Binding(get: { unlocking.map(LockedProfile.init) }, set: { if $0 == nil { unlocking = nil } })) { locked in
            PINPad(title: unlockToRemove ? "Enter \(locked.account.userName)'s PIN to remove it" : "Enter \(locked.account.userName)'s PIN",
                   submit: { pin in
                       guard ProfileLock.check(pin, for: locked.account.key) else { return false }
                       let a = locked.account, removing = unlockToRemove
                       unlocking = nil
                       if removing { ProfileLock.removePIN(for: a.key); Task { await app.remove(a) } }
                       else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { open(a) } }
                       return true
                   }, cancel: { unlocking = nil })
        }
        .onChange(of: app.accounts.count) { _, n in if n <= 1 && !atLaunch { dismiss() } }
        .interactiveDismissDisabled(atLaunch)
    }

    private func pick(_ account: StoredSession) {
        if account.key != app.session?.key || atLaunch, ProfileLock.hasPIN(account.key) {
            unlockToRemove = false; unlocking = account; return
        }
        open(account)
    }

    private func remove(_ account: StoredSession) {
        if ProfileLock.hasPIN(account.key) { unlockToRemove = true; unlocking = account; return }
        Task { await app.remove(account) }
    }

    private func open(_ account: StoredSession) {
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
            .overlay(Circle().strokeBorder(current ? AnyShapeStyle(Theme.spectrum) : AnyShapeStyle(Theme.outline.opacity(0.9)),
                                           lineWidth: current ? 3 : 1.5))
            .overlay(alignment: .topTrailing) {
                if editing {
                    Image(systemName: "minus.circle.fill").font(.title).foregroundStyle(.white, .red)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if ProfileLock.hasPIN(account.key) && !editing {
                    Image(systemName: "lock.fill").font(.system(size: 13, weight: .bold))
                        .padding(7).background(.black.opacity(0.7), in: Circle())
                }
            }
            .shadow(color: .black.opacity(0.5), radius: 14, y: 8)
            Text(account.userName).font(.headline).lineLimit(1)
            if let limit = ProfileLock.limitLabel(account.key) {
                Text("Kids · up to \(limit)").font(.caption2.weight(.bold)).foregroundStyle(Theme.green)
            }
            Text(account.serverName ?? URL(string: account.serverURL)?.host ?? "")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .foregroundStyle(.primary)
    }
}
