import SwiftUI

enum Theme {
    static let accent = Color(red: 0.58, green: 0.45, blue: 1.0)
    static let accent2 = Color(red: 0.25, green: 0.78, blue: 0.98)
    static let background = Color(red: 0.035, green: 0.035, blue: 0.06)
    static let card = Color.white.opacity(0.06)
    static let gradient = LinearGradient(colors: [accent, accent2], startPoint: .topLeading, endPoint: .bottomTrailing)
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
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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

    var body: some View {
        let width: CGFloat = sizeClass == .regular ? 380 : 290
        VStack(alignment: .leading, spacing: 6) {
            Color.clear
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay { RemoteImage(url: app.client?.landscapeURL(for: item)) }
                .overlay(alignment: .bottom) {
                    if let p = item.progress { ProgressBar(value: p).padding(10) }
                }
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: .black.opacity(0.5), radius: 12, y: 6)
            Text(item.displayTitle).font(.subheadline.weight(.semibold)).lineLimit(1)
            if let ep = item.episodeLabel {
                Text(ep).font(.caption).foregroundStyle(.secondary).lineLimit(1)
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
                Capsule().fill(.white.opacity(0.25))
                Capsule().fill(Theme.gradient).frame(width: geo.size.width * value)
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
                .font(.system(size: 18)).foregroundStyle(.white, Theme.accent)
                .padding(6)
        } else if let n = item.userData?.unplayedItemCount, n > 0 {
            Text("\(n)").font(.caption2.bold()).padding(.horizontal, 7).padding(.vertical, 3)
                .background(Theme.accent, in: Capsule()).padding(6)
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
            Text(title).font(.title2.weight(.bold)).padding(.horizontal, 20)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 16) { content }
                    .scrollTargetLayout()
                    .padding(.horizontal, 20)
            }
            .scrollTargetBehavior(.viewAligned)
        }
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

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .padding(.horizontal, 22).padding(.vertical, 12)
            .background(Theme.gradient, in: Capsule())
            .foregroundStyle(.white)
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Apple TV–style white "Play" button.
struct PlayButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .padding(.horizontal, 26).padding(.vertical, 13)
            .background(.white, in: Capsule())
            .foregroundStyle(.black)
            .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
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
            .background(.ultraThinMaterial, in: Capsule())
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
