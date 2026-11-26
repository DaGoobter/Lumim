import Foundation

/// Studios & Networks: Jellyfin tags every movie with its studios and every show with its networks, all as
/// "Studios". Huefin folds the many company names into brands people recognise (Walt Disney Pictures +
/// Walt Disney Animation Studios = Disney) and splits them into movie studios and TV networks.
struct StudioBrand: Identifiable, Hashable {
    enum Kind: String { case studio, network }
    let name: String
    let kind: Kind
    /// The Jellyfin studios that make up this brand, biggest first.
    let members: [Member]
    let movieCount: Int
    let showCount: Int

    struct Member: Hashable { let id: String; let name: String; let count: Int }

    var id: String { kind.rawValue + ":" + name }
    var studioIds: String { members.map(\.id).joined(separator: ",") }
    var total: Int { movieCount + showCount }

    /// "59 movies · 15 shows"
    var countText: String {
        var parts: [String] = []
        if movieCount > 0 { parts.append("\(movieCount) movie" + (movieCount == 1 ? "" : "s")) }
        if showCount > 0 { parts.append("\(showCount) show" + (showCount == 1 ? "" : "s")) }
        return parts.joined(separator: " · ")
    }

    /// Two spectrum colours (indexes 0–5: red, orange, yellow, green, blue, violet), steady per brand.
    var hues: (Int, Int) {
        let h = name.unicodeScalars.reduce(UInt32(7)) { ($0 &* 31) &+ $1.value }
        let a = Int(h % 6)
        return (a, (a + 1 + Int((h / 6) % 4)) % 6)
    }
}

/// One movie or show with its studio tags (the light-weight list the brand grid is built from).
struct StudioTaggedItem: Decodable {
    struct Tag: Decodable { let name: String?; let id: String? }
    let id: String
    let type: String?
    let studios: [Tag]?
}

enum StudioBrands {
    /// Brand, kind, and the Jellyfin studio names that belong to it (matched ignoring case and punctuation).
    static let catalog: [(String, StudioBrand.Kind, [String])] = [
        // Movie studios
        ("Disney", .studio, ["Walt Disney Pictures", "Walt Disney Animation Studios", "Walt Disney Feature Animation",
                             "Walt Disney Productions", "Disneytoon Studios", "Disney Television Animation", "Walt Disney Studios"]),
        ("Pixar", .studio, ["Pixar", "Pixar Animation Studios"]),
        ("Marvel", .studio, ["Marvel Studios", "Marvel Entertainment", "Marvel Animation", "Marvel Television", "Marvel Enterprises"]),
        ("Star Wars", .studio, ["Lucasfilm Ltd.", "Lucasfilm", "Lucasfilm Animation"]),
        ("DC", .studio, ["DC", "DC Comics", "DC Entertainment", "DC Studios", "DC Films"]),
        ("Warner Bros.", .studio, ["Warner Bros. Pictures", "Warner Bros.", "Warner Bros. Animation", "Warner Bros. Television",
                                   "Warner Bros. Pictures Animation", "New Line Cinema", "Castle Rock Entertainment"]),
        ("DreamWorks", .studio, ["DreamWorks Animation", "DreamWorks Pictures", "DreamWorks", "DreamWorks SKG"]),
        ("Universal", .studio, ["Universal Pictures", "Universal Television", "Universal Studios", "Focus Features"]),
        ("Illumination", .studio, ["Illumination", "Illumination Entertainment"]),
        ("Sony", .studio, ["Columbia Pictures", "Sony Pictures", "Sony Pictures Animation", "Sony Pictures Television",
                           "TriStar Pictures", "Screen Gems", "Sony Pictures Classics"]),
        ("20th Century", .studio, ["20th Century Fox", "20th Century Studios", "20th Century Fox Animation",
                                   "Twentieth Century Fox", "Fox Searchlight Pictures", "Searchlight Pictures", "Blue Sky Studios"]),
        ("Paramount", .studio, ["Paramount Pictures", "Paramount Animation", "Paramount Television", "Paramount Players"]),
        ("Lionsgate", .studio, ["Lionsgate", "Lions Gate Films", "Summit Entertainment"]),
        ("MGM", .studio, ["Metro-Goldwyn-Mayer", "United Artists", "Amazon MGM Studios", "MGM"]),
        ("A24", .studio, ["A24"]),
        ("Studio Ghibli", .studio, ["Studio Ghibli"]),
        ("James Bond", .studio, ["EON Productions", "Eon Productions", "Danjaq"]),
        ("Legendary", .studio, ["Legendary Pictures", "Legendary Entertainment"]),
        ("Laika", .studio, ["Laika", "LAIKA"]),
        ("Aardman", .studio, ["Aardman", "Aardman Animations"]),
        ("Blumhouse", .studio, ["Blumhouse Productions"]),
        // TV networks and streaming services
        ("Disney Channel", .network, ["Disney Channel", "Disney Junior", "Disney XD", "Toon Disney"]),
        ("Disney+", .network, ["Disney+"]),
        ("Netflix", .network, ["Netflix"]),
        ("Apple TV", .network, ["Apple TV", "Apple TV+"]),
        ("HBO", .network, ["HBO", "HBO Max", "Max", "Cinemax"]),
        ("Prime Video", .network, ["Prime Video", "Amazon", "Amazon Prime Video", "Amazon Studios", "Freevee"]),
        ("Hulu", .network, ["Hulu"]),
        ("Peacock", .network, ["Peacock"]),
        ("Paramount+", .network, ["Paramount+", "CBS All Access"]),
        ("Cartoon Network", .network, ["Cartoon Network", "Cartoon Network Studios", "Boomerang"]),
        ("Adult Swim", .network, ["Adult Swim", "[adult swim]", "Williams Street"]),
        ("Nickelodeon", .network, ["Nickelodeon", "Nickelodeon Animation Studio", "Nickelodeon Productions", "Nick Jr.",
                                   "Nicktoons", "Nick at Nite", "Nickelodeon Movies"]),
        ("PBS", .network, ["PBS", "PBS Kids", "PBS KIDS"]),
        ("NBC", .network, ["NBC"]),
        ("ABC", .network, ["ABC", "ABC Family"]),
        ("CBS", .network, ["CBS"]),
        ("FOX", .network, ["FOX", "Fox Broadcasting Company", "Fox", "20th Television", "20th Century Fox Television"]),
        ("FX", .network, ["FX", "FXX", "FX Productions", "FX Networks"]),
        ("Comedy Central", .network, ["Comedy Central"]),
        ("AMC", .network, ["AMC", "AMC+"]),
        ("Showtime", .network, ["Showtime"]),
        ("Starz", .network, ["Starz", "STARZ"]),
        ("BBC", .network, ["BBC", "BBC One", "BBC Two", "BBC Three", "BBC America"]),
        ("Crunchyroll", .network, ["Crunchyroll"]),
        ("Syfy", .network, ["Syfy", "SyFy", "Sci-Fi Channel"]),
        ("TBS", .network, ["TBS"]),
        ("TNT", .network, ["TNT"]),
        ("Freeform", .network, ["Freeform"]),
        ("MTV", .network, ["MTV"]),
        ("Discovery", .network, ["Discovery", "Discovery Channel", "Discovery+"]),
    ]

    /// Big but anonymous money and production companies that would only clutter the grid.
    static let ignored: Set<String> = [
        "tsgentertainment", "duneentertainment", "ratpacdunetentertainment", "ratpacentertainment", "domainentertainment",
        "villageroadshowpictures", "pascalpictures", "dentsu", "3artsentertainment", "heydayfilms", "syncopy",
        "amblinentertainment", "originalfilm", "scottfreeproductions", "planbentertainment", "relativitymedia",
        "regencyenterprises", "newregencypictures", "lightstormentertainment", "skydance", "skydancemedia",
        "bad robot", "badrobot", "imagineentertainment", "dualstarentertainment", "atlasentertainment",
        "nippontelevisionnetworkcorporation", "shueisha", "kodansha", "aniplex", "tohoanimation", "fujitelevision",
    ]

    static func key(_ s: String) -> String {
        s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }

    /// Below this many titles, a company that isn't in the catalog stays out of the grid.
    static let autoThreshold = 10

    static func build(from items: [StudioTaggedItem]) -> [StudioBrand] {
        // Count titles per studio, split by type.
        struct Tally { var id: String; var name: String; var movies = 0; var shows = 0 }
        var tallies: [String: Tally] = [:]
        for item in items {
            let isShow = item.type == "Series"
            for tag in item.studios ?? [] {
                guard let name = tag.name, let id = tag.id, !name.isEmpty else { continue }
                let k = key(name)
                var t = tallies[k] ?? Tally(id: id, name: name)
                if isShow { t.shows += 1 } else { t.movies += 1 }
                tallies[k] = t
            }
        }
        var lookup: [String: (String, StudioBrand.Kind)] = [:]
        for (brand, kind, names) in catalog { for n in names { lookup[key(n)] = (brand, kind) } }

        // Group the catalog's studios; titles tagged with two studios of one brand count once.
        var groups: [String: (kind: StudioBrand.Kind, keys: Set<String>)] = [:]
        for (k, t) in tallies {
            if let (brand, kind) = lookup[k] {
                groups[brand, default: (kind, [])].keys.insert(k)
            } else if !ignored.contains(k), t.movies + t.shows >= autoThreshold {
                groups[t.name] = (t.shows > t.movies ? .network : .studio, [k])
            }
        }
        var brands: [StudioBrand] = []
        for (brand, g) in groups {
            var movieIds = Set<String>(), showIds = Set<String>()
            for item in items where (item.studios ?? []).contains(where: { g.keys.contains(key($0.name ?? "")) }) {
                if item.type == "Series" { showIds.insert(item.id) } else { movieIds.insert(item.id) }
            }
            let members = g.keys.compactMap { tallies[$0] }
                .map { StudioBrand.Member(id: $0.id, name: $0.name, count: $0.movies + $0.shows) }
                .sorted { $0.count > $1.count }
            brands.append(StudioBrand(name: brand, kind: g.kind, members: members,
                                      movieCount: movieIds.count, showCount: showIds.count))
        }
        return brands.filter { $0.total > 0 }.sorted { $0.total == $1.total ? $0.name < $1.name : $0.total > $1.total }
    }
}
