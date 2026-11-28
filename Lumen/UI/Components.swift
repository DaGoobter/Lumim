import SwiftUI
import CoreText

enum Theme {
    // Huefin palette: six hues. On paper (the Huefin look) everything is outlined in ink with a hard
    // sticker shadow; on night (the dark option) the same hues glow on a deep, warm background.
    static let red = Color(red: 1.0, green: 0.30, blue: 0.43)        // #FF4D6D
    static let orange = Color(red: 1.0, green: 0.65, blue: 0.17)     // #FFA62B
    static let yellow = Color(red: 1.0, green: 0.89, blue: 0.36)     // #FFE45C
    static let green = Color(red: 0.24, green: 0.94, blue: 0.63)     // #3EF0A0
    static let blue = Color(red: 0.24, green: 0.66, blue: 1.0)       // #3DA9FF
    static let violet = Color(red: 0.61, green: 0.36, blue: 1.0)     // #9B5CFF

    static let accent = red                                             // default when no section hue applies
    static let accent2 = red

    /// Light value for the Huefin look, dark value for Night.
    static func look(_ light: UIColor, _ dark: UIColor) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }
    private static func hex(_ v: UInt32, _ a: CGFloat = 1) -> UIColor {
        UIColor(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: a)
    }

    static let background = look(hex(0xFFF8EE), hex(0x0E0D14))          // paper / warm night
    static let card = look(hex(0xFFFFFF), hex(0x191724))
    static let midnight = card                                            // raised surfaces
    static let ink = Color(red: 0.106, green: 0.082, blue: 0.188)        // #1B1530, text on bright hues
    static let paper = Color(red: 1.0, green: 0.973, blue: 0.933)        // #FFF8EE, the light button
    /// Thin borders: ink on paper, a faint line at night.
    static let hairline = look(hex(0x1B1530, 0.85), UIColor.white.withAlphaComponent(0.09))
    /// Thick sticker outline (paper) or nothing visible (night).
    static let outline = look(hex(0x1B1530), .clear)
    /// Quiet fills behind rows and chips.
    static let wash = look(hex(0x1B1530, 0.06), UIColor.white.withAlphaComponent(0.07))
    static let secondaryText = look(hex(0x5C5670), UIColor.white.withAlphaComponent(0.6))

    /// Each section's hue.
    static let home = red, library = blue, live = orange, downloads = green, search = violet

    /// The full rainbow: progress, highlights, the brand mark.
    static let spectrum = LinearGradient(colors: [red, orange, yellow, green, blue, violet],
                                         startPoint: .leading, endPoint: .trailing)
    /// Cool side of the spectrum: fills that carry white text stay readable.
    static let gradient = LinearGradient(colors: [blue, violet, red],
                                         startPoint: .topLeading, endPoint: .bottomTrailing)

    /// Huefin's display type: Bricolage Grotesque when it's bundled, rounded system type otherwise.
    static func display(_ size: CGFloat, _ weight: Font.Weight = .heavy, relativeTo style: Font.TextStyle = .title) -> Font {
        HuefinFont.available ? .custom(HuefinFont.family, size: size, relativeTo: style).weight(weight)
            : .system(size: size, weight: weight, design: .rounded)
    }
}

/// The chosen look: "huefin" (paper, the default) or "night".
enum Appearance {
    static let key = "huefin.appearance"
    static var isNight: Bool { UserDefaults.standard.string(forKey: key) == "night" }
}

/// Registers Bricolage Grotesque (added to the app when it's built) so headings can use it.
enum HuefinFont {
    static let family = "Bricolage Grotesque"
    static let available: Bool = {
        guard let url = Bundle.main.url(forResource: "BricolageGrotesque", withExtension: "ttf") else { return false }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        return UIFont(name: "BricolageGrotesque-Regular", size: 12) != nil
            || UIFont.fontNames(forFamilyName: family).isEmpty == false
    }()
}

// MARK: - Sticker

/// The Huefin look's signature: an ink outline and a hard ink shadow, like a sticker you can press.
/// At night it's a faint line and a soft shadow instead.
struct Sticker: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    var radius: CGFloat = 16
    var depth: CGFloat = 4
    var pressed = false
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if scheme == .dark {
            content
                .overlay(shape.strokeBorder(Theme.hairline, lineWidth: 1))
                .shadow(color: .black.opacity(0.45), radius: 12, y: 6)
        } else {
            content
                .overlay(shape.strokeBorder(Theme.ink, lineWidth: 2.5))
                .background(shape.fill(Theme.ink).offset(x: pressed ? 0 : depth, y: pressed ? 0 : depth))
                .offset(x: pressed ? depth / 2 : 0, y: pressed ? depth / 2 : 0)
        }
    }
}

extension View {
    func sticker(_ radius: CGFloat = 16, depth: CGFloat = 4, pressed: Bool = false) -> some View {
        modifier(Sticker(radius: radius, depth: depth, pressed: pressed))
    }
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

/// The main buttons' press: an ink sticker on paper, a hard shadow in the section's hue at night.
struct HueLift: ViewModifier {
    @Environment(\.hue) private var hue
    @Environment(\.colorScheme) private var scheme
    var pressed: Bool
    func body(content: Content) -> some View {
        if scheme == .dark {
            content
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(hue.opacity(0.55))
                    .offset(x: pressed ? 0 : 3, y: pressed ? 0 : 3))
                .offset(x: pressed ? 2 : 0, y: pressed ? 2 : 0)
        } else {
            content.sticker(16, depth: 3, pressed: pressed)
        }
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
                .overlay(alignment: .topTrailing) { WatchedBadge(item: item) }
                .sticker(16)
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
                .sticker(16)
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
            Text(title).font(Theme.display(24, .heavy, relativeTo: .title2))
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
                .font(Theme.display(17, .heavy, relativeTo: .headline))
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
            .font(Theme.display(17, .heavy, relativeTo: .headline))
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
            .font(Theme.display(17, .heavy, relativeTo: .headline))
            .padding(.horizontal, 18).padding(.vertical, 12)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .foregroundStyle(.primary)
            .sticker(16, depth: 3, pressed: configuration.isPressed)
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
