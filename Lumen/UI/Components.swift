import SwiftUI

enum Theme {
    // Huefin palette: six hues on a deep, warm night. Each part of the app owns one hue.
    static let red = Color(red: 1.0, green: 0.30, blue: 0.43)        // #FF4D6D
    static let orange = Color(red: 1.0, green: 0.65, blue: 0.17)     // #FFA62B
    static let yellow = Color(red: 1.0, green: 0.89, blue: 0.36)     // #FFE45C
    static let green = Color(red: 0.24, green: 0.94, blue: 0.63)     // #3EF0A0
    static let blue = Color(red: 0.24, green: 0.66, blue: 1.0)       // #3DA9FF
    static let violet = Color(red: 0.61, green: 0.36, blue: 1.0)     // #9B5CFF

    static let accent = red                                             // default when no section hue applies
    static let accent2 = red
    static let midnight = Color(red: 0.098, green: 0.090, blue: 0.141) // #191724, raised surfaces
    static let background = Color(red: 0.055, green: 0.051, blue: 0.078) // #0E0D14, warm night
    static let card = Color(red: 0.098, green: 0.090, blue: 0.141)      // #191724
    static let ink = Color(red: 0.078, green: 0.067, blue: 0.122)       // #14111F, text on bright hues
    static let paper = Color(red: 1.0, green: 0.973, blue: 0.933)       // #FFF8EE, the light button
    static let hairline = Color.white.opacity(0.09)

    /// Each section's hue.
    static let home = red, library = blue, live = orange, downloads = green, search = violet

    /// The full rainbow: progress, highlights, the brand mark.
    static let spectrum = LinearGradient(colors: [red, orange, yellow, green, blue, violet],
                                         startPoint: .leading, endPoint: .trailing)
    /// Cool side of the spectrum: fills that carry white text stay readable.
    static let gradient = LinearGradient(colors: [blue, violet, red],
                                         startPoint: .topLeading, endPoint: .bottomTrailing)
}

// MARK: - Section hue

private struct HueKey: EnvironmentKey { static let defaultValue: Color = Theme.red }
extension EnvironmentValues {
    /// The hue of the section you're in (Home coral, Library sky, Live TV amber…).
    var hue: Color {
        get { self[HueKey.self] }
        set { self[HueKey.self] = newValue }
    }
}

extension View {
    /// Colors this part of the app: buttons, tab icon, heading dots and the soft tint at the top.
    func sectionHue(_ color: Color) -> some View {
        environment(\.hue, color).tint(color).accentColor(color)
    }
}

/// Huefin's signature: a hard little shadow in the section's hue under the main buttons.
struct HueLift: ViewModifier {
    @Environment(\.hue) private var hue
    var pressed: Bool
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(hue.opacity(0.55))
                .offset(x: pressed ? 0 : 3, y: pressed ? 0 : 3))
            .offset(x: pressed ? 2 : 0, y: pressed ? 2 : 0)
    }
}

// MARK: - Images

struct RemoteImage: View {
    let url: URL?

    var body: some View {
        AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.25))) { phase in
            switch phase {
            case .success(let image): image.resizable().scaledToFill()
            default: Rectangle().fill(Theme.card)
            }
        }
    }
}

/// Artwork scaled to fit, never cropped.
struct FitImage: View {
    let url: URL?

    var body: some View {
        AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.3))) { phase in
            if case .success(let image) = phase {
                image.resizable().scaledToFit()
            } else {
                Color.clear
            }
        }
    }
}

/// Full, uncropped backdrop. Fills the width on phones; on wide screens (iPad, landscape)
/// it's capped in height and centered, with the ambient glow filling the sides.
struct ArtHeader: View {
    let url: URL?
    let width: CGFloat
    let maxHeight: CGFloat

    private var height: CGFloat { max(1, min(width * 9 / 16, maxHeight)) }

    var body: some View {
        FitImage(url: url)
            .frame(width: width, height: height)
            .mask(
                LinearGradient(stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: 0.9),
                    .init(color: .black.opacity(0), location: 1),
                ], startPoint: .top, endPoint: .bottom)
            )
            .shadow(color: .black.opacity(0.35), radius: 20, y: 10)
    }
}

/// A soft, blurred wash of the artwork behind the page, so its colors bleed into the UI.
struct AmbientGlow: View {
    let url: URL?
    let size: CGSize

    var body: some View {
        RemoteImage(url: url)
            .frame(width: size.width, height: size.height * 0.8)
            .blur(radius: 70)
            .opacity(0.5)
            .clipped()
            .mask(LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .top, endPoint: .bottom))
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }
}

/// Shows a title logo when the server has one, otherwise falls back to text.
struct LogoOrTitle: View {
    let url: URL?
    let title: String
    var maxHeight: CGFloat = 90

    var body: some View {
        if let url {
            AsyncImage(url: url) { phase in
                if case .success(let image) = phase {
                    image.resizable().scaledToFit()
                        .frame(maxWidth: 300, maxHeight: maxHeight, alignment: .leading)
                        .shadow(color: .black.opacity(0.5), radius: 10)
                } else {
                    titleText
                }
            }
        } else {
            titleText
        }
    }

    private var titleText: some View {
        Text(title).font(.system(size: 34, weight: .heavy, design: .rounded)).lineLimit(2)
            .shadow(color: .black.opacity(0.5), radius: 8)
    }
}

// MARK: - Cards

struct PosterCard: View {
    @Environment(AppState.self) private var app
    @Environment(\.horizontalSizeClass) private var sizeClass
    let item: BaseItem
    /// When false the card fills its grid cell.
    var fixedWidth = true

    var body: some View {
        let width: CGFloat = sizeClass == .regular ? 180 : 128
        VStack(alignment: .leading, spacing: 6) {
            Color.clear
                .aspectRatio(2 / 3, contentMode: .fit)
                .overlay { RemoteImage(url: app.client?.posterURL(for: item)) }
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
                .overlay(alignment: .topTrailing) { WatchedBadge(item: item) }
                .shadow(color: .black.opacity(0.5), radius: 12, y: 6)
            Text(item.displayTitle).font(.caption.weight(.semibold)).lineLimit(1)
            Text(item.productionYear.map(String.init) ?? " ").font(.caption2).foregroundStyle(.secondary)
        }
        .frame(width: fixedWidth ? width : nil)
    }
}

struct LandscapeCard: View {
    @Environment(AppState.self) private var app
    @Environment(\.horizontalSizeClass) private var sizeClass
    let item: BaseItem
    /// Show the title artwork (Thumb) instead of the episode still — used on Home.
    var titleArt = false

    var body: some View {
        let width: CGFloat = sizeClass == .regular ? 380 : 290
        VStack(alignment: .leading, spacing: 3) {
            Color.clear
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay { RemoteImage(url: titleArt ? app.client?.thumbCardURL(for: item) : app.client?.landscapeURL(for: item)) }
                .overlay(alignment: .bottom) {
                    if let p = item.progress {
                        ProgressBar(value: p).padding(.horizontal, 14).padding(.bottom, 12)
                            .shadow(color: .black.opacity(0.5), radius: 4)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
                .shadow(color: .black.opacity(0.5), radius: 12, y: 6)
                .padding(.bottom, 8)
            if let top = item.episodeLabel ?? item.productionYear.map(String.init) {
                Text(top).font(.caption.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(item.displayTitle).font(.subheadline.weight(.bold)).lineLimit(1)
            if let left = item.timeLeftText {
                Text(left).font(.caption.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(width: width)
    }
}

struct ProgressBar: View {
    let value: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.18))
                Capsule().fill(Theme.spectrum).frame(width: geo.size.width * value)
            }
        }
        .frame(height: 4)
    }
}

struct WatchedBadge: View {
    let item: BaseItem
    var body: some View {
        if item.userData?.played == true {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18)).foregroundStyle(.white, Color.accentColor)
                .padding(6)
        } else if let n = item.userData?.unplayedItemCount, n > 0 {
            Text("\(n)").font(.caption2.bold()).padding(.horizontal, 7).padding(.vertical, 3)
                .background(Color.accentColor, in: Capsule()).padding(6)
        }
    }
}

struct Badge: View {
    let text: String
    var body: some View {
        let special = text == "Dolby Vision" || text == "Atmos"
        Text(text)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(special ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Color.white.opacity(0.14)),
                        in: RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Layout

struct Shelf<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ShelfTitle(title).padding(.horizontal, 20)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 16) { content }
                    .scrollTargetLayout()
                    .padding(.horizontal, 20)
            }
            .scrollTargetBehavior(.viewAligned)
        }
    }
}

struct ShelfTitle: View {
    @Environment(\.hue) private var hue
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 3, style: .continuous).fill(hue).frame(width: 10, height: 10)
            Text(title).font(.title2.weight(.bold))
        }
        .accessibilityElement(children: .combine)
    }
}

struct ErrorBanner: View {
    let message: String
    var retry: (() -> Void)?
    var body: some View {
        VStack(spacing: 10) {
            Label(message, systemImage: "wifi.exclamationmark").font(.footnote)
            if let retry { Button("Try again", action: retry).buttonStyle(SecondaryButtonStyle()) }
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal)
    }
}

// MARK: - Buttons

/// Filled with the section's hue, dark text, a small hue shadow.
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HuePrimary(configuration: configuration)
    }
    private struct HuePrimary: View {
        @Environment(\.hue) private var hue
        let configuration: Configuration
        var body: some View {
            configuration.label
                .font(.headline)
                .padding(.horizontal, 22).padding(.vertical, 13)
                .background(hue, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .foregroundStyle(Theme.ink)
                .modifier(HueLift(pressed: configuration.isPressed))
                .animation(.spring(response: 0.22, dampingFraction: 0.7), value: configuration.isPressed)
        }
    }
}

/// The main "Play": warm paper button with the section's hue as its shadow.
struct PlayButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .padding(.horizontal, 26).padding(.vertical, 13)
            .background(Theme.paper, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .foregroundStyle(Theme.ink)
            .modifier(HueLift(pressed: configuration.isPressed))
            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Cards lift slightly and shrink on press, like tvOS focus.
struct CardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .brightness(configuration.isPressed ? 0.06 : 0)
            .animation(.spring(response: 0.3, dampingFraction: 0.65), value: configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .padding(.horizontal, 18).padding(.vertical, 12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1.5))
            .foregroundStyle(.white)
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Decides where tapping an item goes.
struct ItemRouter: View {
    let item: BaseItem
    var body: some View {
        switch item.type ?? "" {
        case "CollectionFolder" where item.collectionType == "music",
             "UserView" where item.collectionType == "music":
            MusicLibraryView(library: item)
        case "CollectionFolder" where item.collectionType == "books",
             "UserView" where item.collectionType == "books":
            BooksLibraryView(library: item)
        case "CollectionFolder" where item.collectionType == "livetv",
             "UserView" where item.collectionType == "livetv":
            LiveTVView()
        case "Book", "AudioBook":
            BookDetailView(book: item)
        case "MusicAlbum":
            AlbumView(album: item)
        case "Playlist" where item.mediaType == "Audio":
            AlbumView(album: item)
        case "MusicArtist":
            ArtistView(artist: item)
        case "CollectionFolder", "Folder", "BoxSet", "UserView", "Playlist":
            LibraryGridView(parent: item)
        default:
            ItemDetailView(itemId: item.id, preview: item)
        }
    }
}
