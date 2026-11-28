import SwiftUI

/// An image from the server. It always takes exactly the space it's given (filling and cropping inside it),
/// so a wide picture can never push the rest of the screen sideways.
struct TVImage: View {
    let url: URL?
    var contentMode: ContentMode = .fill
    var body: some View {
        Rectangle().fill(contentMode == .fill ? Theme.wash : .clear)
            .overlay {
                AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.25))) { phase in
                    if let img = phase.image { img.resizable().aspectRatio(contentMode: contentMode) }
                }
            }
            .clipped()
    }
}

struct TVProgress: View {
    let value: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.25))
                Capsule().fill(Theme.spectrum).frame(width: g.size.width * min(1, max(0, value)))
            }
        }.frame(height: 6)
    }
}

/// Opens the right thing for an item when picked: plays videos, opens everything else.
@MainActor func open(_ item: BaseItem, app: AppState) -> Bool {
    if item.isLiveChannel { AppRouter.shared.playRequest = PlaybackRequest(item: item, startTicks: 0); return true }
    if item.type == "Audio" { AudioPlayer.shared.play([item], client: app.client); return true }
    return false
}

/// A poster that lifts and tilts when focused (the Apple TV "card" look), with its name underneath.
struct TVPosterCard: View {
    let item: BaseItem
    var width: CGFloat = 200
    @Environment(AppState.self) private var app
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            NavigationLink(value: item) {
                ZStack(alignment: .bottom) {
                    TVImage(url: app.client?.posterURL(for: item, width: Int(width * 2)))
                    if let p = item.progress { TVProgress(value: p).padding(12) }
                    if item.userData?.played == true {
                        Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(.white, Theme.green)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(10)
                    } else if let n = item.userData?.unplayedItemCount, n > 0, item.isSeries {
                        Text("\(n)").font(.caption.bold()).foregroundStyle(Theme.ink).padding(.horizontal, 10).padding(.vertical, 4)
                            .background(Theme.red, in: Capsule())
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(10)
                    }
                }
                .frame(width: width, height: width * 1.5)
            }
            .buttonStyle(.card)
            Text(item.displayTitle).font(.caption.weight(.semibold)).lineLimit(1)
            Text(item.productionYear.map(String.init) ?? " ").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: width)
    }
}

/// A wide card with the title underneath, for episodes and Continue Watching.
struct TVLandscapeCard: View {
    let item: BaseItem
    var width: CGFloat = 380
    var subtitle: String?
    var action: (() -> Void)?
    @Environment(AppState.self) private var app
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Group {
                if let action { Button(action: action) { art } } else { NavigationLink(value: item) { art } }
            }.buttonStyle(.card)
            Text(item.displayTitle).font(.callout.weight(.semibold)).lineLimit(1)
            Text(subtitle ?? item.episodeLabel ?? item.productionYear.map(String.init) ?? " ").font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }.frame(width: width)
    }
    private var art: some View {
        ZStack(alignment: .bottom) {
            TVImage(url: app.client?.landscapeURL(for: item, width: Int(width * 2)))
            if let p = item.progress { TVProgress(value: p).padding(14) }
        }.frame(width: width, height: width * 9 / 16)
    }
}

struct TVShelf<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(Theme.display(31, .heavy, relativeTo: .headline)).padding(.horizontal, 80)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 40) { content }.padding(.horizontal, 80).padding(.vertical, 24)
            }.scrollClipDisabled()
        }
    }
}

extension View {
    /// Every screen opens items the same way.
    func itemDestinations() -> some View {
        navigationDestination(for: BaseItem.self) { TVItemRoute(item: $0) }
    }
}

/// Huefin's TV buttons: always readable. Filled ones use the hue with dark text; plain ones are dark with white text.
/// Focused buttons grow and turn bright, so it's obvious where the remote is.
struct TVHueButtonStyle: ButtonStyle {
    var filled = false
    var hue: Color = Theme.red
    /// Fill the width (forms) or hug the label (rows of actions).
    var expand = true
    func makeBody(configuration: Configuration) -> some View { StyledButton(configuration: configuration, filled: filled, hue: hue, expand: expand) }

    private struct StyledButton: View {
        let configuration: Configuration
        let filled: Bool
        let hue: Color
        let expand: Bool
        @Environment(\.isFocused) private var focused
        @Environment(\.isEnabled) private var enabled
        @Environment(\.colorScheme) private var scheme
        var body: some View {
            let paper = scheme == .light
            configuration.label
                .font(expand ? Theme.display(29, .heavy, relativeTo: .headline) : Theme.display(25, .bold, relativeTo: .callout))
                .foregroundStyle(filled || focused || paper ? Theme.ink : Color.white)
                .padding(.horizontal, expand ? 36 : 26).padding(.vertical, expand ? 18 : 13)
                .frame(maxWidth: expand ? .infinity : nil)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(focused ? (filled ? hue : (paper ? hue : Theme.paper))
                              : (filled ? hue.opacity(0.85) : (paper ? Color.white : Color.white.opacity(0.12))))
                )
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(paper ? Theme.ink : .clear, lineWidth: 3))
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(paper ? Theme.ink : .clear)
                    .offset(x: focused ? 6 : 4, y: focused ? 6 : 4))
                .shadow(color: focused && !paper ? hue.opacity(0.6) : .clear, radius: 24, y: 8)
                .scaleEffect(configuration.isPressed ? 0.97 : (focused ? 1.05 : 1))
                .opacity(enabled ? 1 : 0.45)
                .animation(.easeOut(duration: 0.18), value: focused)
        }
    }
}

extension View {
    /// A Huefin action button that hugs its label (Play, Shuffle, ♥…). `primary` fills it with the section hue.
    func hueAction(primary: Bool = false, hue: Color = Theme.red) -> some View {
        buttonStyle(TVHueButtonStyle(filled: primary, hue: hue, expand: false))
    }
}
