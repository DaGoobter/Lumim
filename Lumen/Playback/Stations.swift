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
        var lastKind: DJSet?
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
                var parts: [String] = []
                if !state.greeted {
                    state.greeted = true
                    parts.append(greeting)
                } else if Int.random(in: 0..<3) > 0 {
                    parts.append(transitions.randomElement()!)
                }
                parts.append(intro(for: kind, seed: seed))
                state.lastKind = kind
                let line = parts.joined(separator: breath)
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

    // MARK: How the DJ talks
    //
    // Lines are written the way people actually talk on air: short phrases, contractions, little asides,
    // and a beat of silence before the song title lands. [pause:Ns] is understood by Kokoro (and turned
    // into the right pause for the other voices); it never shows on screen.

    /// A quick hitch, like a DJ catching a breath before the reveal.
    static let beat = " [pause:0.2s] "
    /// A real pause between thoughts.
    static let breath = " [pause:0.4s] "

    private static let transitions = [
        "Alright.", "Okay, switching it up.", "Mm, okay.", "Alright, new direction.",
        "Let's change the mood a little.", "Okay, so.", "Keeping it moving.", "Right, next up.",
    ]

    private static func intro(for kind: DJSet, seed: BaseItem) -> String {
        let song = seed.name.map(cleanTitle) ?? "this one"
        let artist = seed.artistLine ?? "someone you like"
        let reveal = [
            "Here's \(artist)," + beat + "\(song).",
            "This is \(song)," + beat + "from \(artist).",
            "\(artist)." + beat + "\(song).",
            "It's \(song)," + beat + "by \(artist).",
        ].randomElement()!

        var setup: [String]
        switch kind {
        case .heavyRotation:
            setup = [
                "So, you've had \(artist) on repeat lately. Like, a lot. No judgment, honestly, same.",
                "We're going back to one you just can't stop playing.",
                "You know this one. You really, really know this one.",
                "Okay, this is basically your theme song at this point.",
            ]
        case .favorite:
            setup = [
                "Here's one you hearted, and I get it.",
                "Pulling one straight from your favorites.",
                "You told me you love this one, so I'm not gonna overthink it.",
                "One of yours, a real favorite.",
            ]
        case .throwback:
            setup = [
                "Throwback time. You haven't played this in ages, and honestly? It still holds up.",
                "Remember this one? It's been a minute.",
                "Let's dig into the archives for a second.",
                "Okay, going way back in your history for this one.",
            ]
        case .discover:
            setup = [
                "So here's something that's been sitting in your library, and you've never actually played it.",
                "Trying something new on you. Trust me on this.",
                "First listen, for you anyway. Let's see what you think.",
                "Little bit of a wildcard here.",
            ]
        }
        var parts = [setup.randomElement()!, reveal]

        // A bit of color, sometimes, the way a real host drops in a fact.
        if Int.random(in: 0..<3) == 0, let year = seed.productionYear, year > 1900 {
            let age = Calendar.current.component(.year, from: Date()) - year
            parts.append([
                "That's from \(year).",
                age >= 15 ? "Straight out of \(decade(year)), by the way." : "Came out in \(year), believe it or not.",
            ].randomElement()!)
        }

        // And what comes after.
        let outro = [
            nil, nil,
            "Then I've got a few more in the same lane.",
            "Stick around, I've lined up some more like it.",
            "And a couple more after this that I think you'll like.",
            "Enjoy.",
        ].randomElement()!
        if let outro { parts.append(outro) }
        return parts.joined(separator: " ")
    }

    private static func decade(_ year: Int) -> String {
        let d = (year / 10) * 10
        let names = [1950: "the fifties", 1960: "the sixties", 1970: "the seventies", 1980: "the eighties",
                     1990: "the nineties", 2000: "the two thousands"]
        return names[d] ?? "\(d)s"
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
        let now = Date()
        let h = Calendar.current.component(.hour, from: now)
        let weekday = Calendar.current.component(.weekday, from: now) // 1 = Sunday
        let day = DateFormatter().weekdaySymbols[weekday - 1]
        switch h {
        case 5..<12:
            return ["Good morning!" + beat + "It's your Lumen DJ. Let's ease into this \(day).",
                    "Morning! Lumen DJ here. Got some good stuff for you today."].randomElement()!
        case 12..<17:
            return ["Hey, good afternoon! Lumen DJ here.",
                    "Hey there. Happy \(day)." + beat + "It's your Lumen DJ."].randomElement()!
        case 17..<22:
            let friday: String = "It's Friday night!" + beat + "Lumen DJ here, let's get into it."
            let evening: String = "Good evening. It's your Lumen DJ," + beat + "let's get into it."
            let company: String = "Hey, hey. Lumen DJ, keeping you company this \(day) night."
            return [weekday == 6 ? friday : evening, company].randomElement()!
        default:
            return ["Hey, night owl." + beat + "Lumen DJ here. Let's keep it going.",
                    "Still up? Me too. It's your Lumen DJ."].randomElement()!
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
