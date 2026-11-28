import SwiftUI

/// A 4-digit PIN keypad. Used to open a locked profile and to set or remove a profile's PIN.
struct PINPad: View {
    let title: String
    var subtitle: String? = nil
    /// Returns true when the PIN is accepted; false shakes the dots and clears them.
    let submit: (String) -> Bool
    let cancel: () -> Void

    @State private var digits = ""
    @State private var wrong = 0

    #if os(tvOS)
    private let key: CGFloat = 110, font: Font = .system(size: 40, weight: .bold), gap: CGFloat = 26
    #else
    private let key: CGFloat = 76, font: Font = .system(size: 30, weight: .semibold), gap: CGFloat = 18
    #endif

    var body: some View {
        VStack(spacing: gap * 1.4) {
            Image(systemName: "lock.fill").font(.system(size: 30, weight: .semibold)).foregroundStyle(.secondary)
            VStack(spacing: 8) {
                Text(title).font(.title2.bold()).multilineTextAlignment(.center)
                if let subtitle { Text(subtitle).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center) }
            }
            HStack(spacing: 18) {
                ForEach(0..<4, id: \.self) { i in
                    Circle()
                        .fill(i < digits.count ? Color.primary : Color.primary.opacity(0.18))
                        .frame(width: 16, height: 16)
                }
            }
            .modifier(Shake(amount: CGFloat(wrong)))
            .animation(.default, value: wrong)

            VStack(spacing: gap) {
                ForEach([[1, 2, 3], [4, 5, 6], [7, 8, 9]], id: \.self) { row in
                    HStack(spacing: gap) { ForEach(row, id: \.self) { n in digitKey(String(n)) } }
                }
                HStack(spacing: gap) {
                    textKey("Cancel") { cancel() }
                    digitKey("0")
                    textKey("Delete") { if !digits.isEmpty { digits.removeLast() } }
                }
            }
        }
        .foregroundStyle(.primary)
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background.ignoresSafeArea())
    }

    private func press(_ d: String) {
        guard digits.count < 4 else { return }
        digits += d
        guard digits.count == 4 else { return }
        let entered = digits
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            if !submit(entered) {
                wrong += 1
                digits = ""
            }
        }
    }

    private func digitKey(_ d: String) -> some View {
        Button { press(d) } label: {
            Text(d).font(font).frame(width: key, height: key)
                #if !os(tvOS)
                .background(Theme.card, in: Circle())
                .overlay(Circle().strokeBorder(Theme.outline.opacity(0.9), lineWidth: 1.25))
                #endif
        }
        #if os(tvOS)
        .buttonStyle(.card)
        #else
        .buttonStyle(.plain)
        #endif
    }

    private func textKey(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.callout.weight(.semibold)).frame(width: key, height: key)
        }
        #if os(tvOS)
        .buttonStyle(.card)
        #else
        .buttonStyle(.plain)
        #endif
    }
}

private struct Shake: GeometryEffect {
    var amount: CGFloat
    var animatableData: CGFloat { get { amount } set { amount = newValue } }
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 10 * sin(amount * .pi * 4), y: 0))
    }
}

/// Asks for a new PIN twice, then saves it for the profile.
struct SetPINFlow: View {
    let account: String
    let done: () -> Void
    @State private var first: String?

    var body: some View {
        if let first {
            PINPad(title: "Enter it again", submit: { pin in
                guard pin == first else { self.first = nil; return false }
                ProfileLock.setPIN(pin, for: account)
                done()
                return true
            }, cancel: done)
            .id("confirm")
        } else {
            PINPad(title: "Choose a 4-digit PIN", subtitle: "Needed to open this profile on this device.",
                   submit: { pin in first = pin; return true }, cancel: done)
            .id("first")
        }
    }
}

/// Opening or removing a locked profile, or setting / clearing a profile's PIN.
struct ProfilePINTask: Identifiable {
    enum Kind { case open, remove, set, clear }
    let kind: Kind
    let account: StoredSession
    var id: String { "\(kind)-\(account.key)" }
}

struct ProfilePINScreen: View {
    let task: ProfilePINTask
    let finish: () -> Void
    @Environment(AppState.self) private var app

    var body: some View {
        if task.kind == .set {
            SetPINFlow(account: task.account.key, done: finish)
        } else {
            PINPad(title: task.kind == .clear ? "Enter your current PIN" : "Enter \(task.account.userName)'s PIN", submit: { pin in
                guard ProfileLock.check(pin, for: task.account.key) else { return false }
                let t = task, app = app
                finish()
                switch t.kind {
                case .open: app.switchTo(t.account)
                case .remove: ProfileLock.removePIN(for: t.account.key); Task { await app.remove(t.account) }
                case .clear: ProfileLock.removePIN(for: t.account.key)
                case .set: break
                }
                return true
            }, cancel: finish)
        }
    }
}

/// A locked profile waiting for its PIN.
struct LockedProfile: Identifiable {
    let account: StoredSession
    var id: String { account.key }
}
