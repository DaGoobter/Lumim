import Foundation

/// Builds endless radio stations from the library — including "Lumen DJ", a Spotify DJ–style mix of
/// your heavy rotation, favorites, throwbacks and things you haven't heard, with a spoken intro per set.
@MainActor
enum Stations {

    // MARK: Lumen DJ

    private enum DJSet: CaseIterable { case heavyRotation, favorite, throwback, discover }

    private final class DJState {
        var turn = 0
        var greeted = false
    }

    static func dj(libraryId: String?) -> Station {
        let state = DJState()
        return Station(name: "Lumen DJ") { client, exclude in
            // Try each kind of set in rotation until one produces music.
            for _ in 0..<DJSet.allCases.count {
                let kind = DJSet.allCases[state.turn % DJSet.allCases.count]
                state.turn += 1
                guard let seed = await seed(for: kind, libraryId: libraryId, client: client, exclude: exclude) else { continue }
                let similar = ((try? await client.instantMix(seed.id, limit: 40)) ?? [])
                    .filter { $0.id != seed.id && !exclude.contains($0.id) }
                let set = [seed] + Array(similar.prefix(12).shuffled().prefix(5))
                var line = intro(for: kind, seed: seed)
                if !state.greeted {
                    state.greeted = true
                    line = greeting + " " + line
                }
                return set.enumerated().map { i, item in QueueEntry(item: item, intro: i == 0 ? line : nil) }
            }
            return []
        }
    }

    private static func seed(for kind: DJSet, libraryId: String?, client: JellyfinClient,
                             exclude: Set<String>) async -> BaseItem? {
        let pool: [BaseItem]
        switch kind {
        case .heavyRotation:
            pool = await client.songs(parentId: libraryId, sortBy: "PlayCount", filters: "IsPlayed", limit: 40)
        case .favorite:
            pool = await client.songs(parentId: libraryId, sortBy: "Random", filters: "IsFavorite", limit: 30)
        case .throwback:
            pool = await client.songs(parentId: libraryId, sortBy: "DatePlayed", sortOrder: "Ascending",
                                      filters: "IsPlayed", limit: 40)
        case .discover:
            pool = await client.songs(parentId: libraryId, sortBy: "Random", filters: "IsUnplayed", limit: 30)
        }
        return pool.filter { !exclude.contains($0.id) }.randomElement()
    }

    private static func intro(for kind: DJSet, seed: BaseItem) -> String {
        let song = seed.name.map(cleanTitle) ?? "this one"
        let artist = seed.artistLine ?? "an artist you like"
        let lines: [String]
        switch kind {
        case .heavyRotation:
            lines = [
                "Okay, you've clearly had \(artist) on repeat lately. No judgment. Here's \(song).",
                "Let's go back to one you keep coming back to. \(song), by \(artist).",
                "This one's been getting a lot of love from you. \(artist), \(song). Then I've got a few more in the same lane.",
            ]
        case .favorite:
            lines = [
                "Here's one you hearted. \(song), by \(artist). Stick around, I've lined up some more like it.",
                "A favorite of yours coming up. \(artist), with \(song).",
                "You told me you love this one, so, \(song). Enjoy.",
            ]
        case .throwback:
            lines = [
                "Throwback time. You haven't played \(song) in a while, and honestly, it still holds up.",
                "Remember this? \(artist), \(song). It's been a minute.",
                "Let's dig into the archives for a second. Here's \(song).",
            ]
        case .discover:
            lines = [
                "Here's something sitting in your library that you've never actually played. \(artist), \(song). Let's see what you think.",
                "Trying something new on you. \(song), by \(artist).",
                "You've never played this one before, so, first listen. \(artist), \(song).",
            ]
        }
        return lines.randomElement()!
    }

    /// "Big Shot (Album Version)" → "Big Shot", so the DJ doesn't read out edition notes.
    private static func cleanTitle(_ title: String) -> String {
        var t = title
        while let r = t.range(of: #"\s*[\(\[][^\)\]]*(version|remaster|edit|mix|mono|stereo|live|explicit|feat\.?)[^\)\]]*[\)\]]"#,
                             options: [.regularExpression, .caseInsensitive]) {
            t.removeSubrange(r)
        }
        return t.trimmingCharacters(in: .whitespaces)
    }

    private static var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        switch h {
        case 5..<12: return "Good morning! It's your Lumen DJ."
        case 12..<17: return "Hey, good afternoon. Lumen DJ here."
        case 17..<22: return "Good evening. It's your Lumen DJ, let's get into it."
        default: return "Hey, night owl. Lumen DJ here."
        }
    }

    // MARK: Radio from anything

    private final class Seed { var id: String; init(_ id: String) { self.id = id } }

    /// Song/album/artist/genre/playlist radio. Drifts naturally: each refill seeds from the last song added.
    static func radio(name: String, seedId: String) -> Station {
        let seed = Seed(seedId)
        return Station(name: name) { client, exclude in
            let mix = ((try? await client.instantMix(seed.id, limit: 50)) ?? []).filter { !exclude.contains($0.id) }
            let picked = Array(mix.prefix(25))
            if let last = picked.last { seed.id = last.id }
            return picked.map { QueueEntry(item: $0) }
        }
    }

    // MARK: Library mixes

    static func heavyRotation(libraryId: String?) -> Station {
        mix(name: "Heavy Rotation", libraryId: libraryId, sortBy: "PlayCount", filters: "IsPlayed")
    }
    static func favorites(libraryId: String?) -> Station {
        mix(name: "Favorites Mix", libraryId: libraryId, sortBy: "Random", filters: "IsFavorite")
    }
    static func throwbacks(libraryId: String?) -> Station {
        mix(name: "Throwbacks", libraryId: libraryId, sortBy: "DatePlayed", sortOrder: "Ascending", filters: "IsPlayed")
    }
    static func discover(libraryId: String?) -> Station {
        mix(name: "Discover", libraryId: libraryId, sortBy: "Random", filters: "IsUnplayed")
    }
    static func shuffleAll(libraryId: String?) -> Station {
        mix(name: "Shuffle All", libraryId: libraryId, sortBy: "Random", filters: nil)
    }

    private static func mix(name: String, libraryId: String?, sortBy: String, sortOrder: String = "Descending",
                            filters: String?) -> Station {
        Station(name: name) { client, exclude in
            var pool = await client.songs(parentId: libraryId, sortBy: sortBy, sortOrder: sortOrder, filters: filters, limit: 80)
            pool = pool.filter { !exclude.contains($0.id) }
            if sortBy != "Random" { pool.shuffle() }
            return pool.prefix(25).map { QueueEntry(item: $0) }
        }
    }
}
