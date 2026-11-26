package com.huefin.desktop.core

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.serialization.Serializable

/**
 * Studios & Networks: Jellyfin tags every movie with its studios and every show with its networks, all as
 * "Studios". Huefin folds the many company names into brands people recognise (Walt Disney Pictures +
 * Walt Disney Animation Studios = Disney) and splits them into movie studios and TV networks.
 * (Same rules as the iPhone app's StudioBrands.swift.)
 */
data class StudioBrand(val name: String, val kind: Kind, val members: List<Member>, val movieCount: Int, val showCount: Int) {
    enum class Kind { Studio, Network }
    data class Member(val id: String, val name: String, val count: Int)

    val id: String get() = kind.name.lowercase() + ":" + name
    val studioIds: String get() = members.joinToString(",") { it.id }
    val total: Int get() = movieCount + showCount

    /** "59 movies · 15 shows" */
    val countText: String get() = listOfNotNull(
        if (movieCount > 0) "$movieCount movie" + (if (movieCount == 1) "" else "s") else null,
        if (showCount > 0) "$showCount show" + (if (showCount == 1) "" else "s") else null,
    ).joinToString(" · ")

    /** Two spectrum colours (indexes 0–5: red, orange, yellow, green, blue, violet), steady per brand. */
    val hues: Pair<Int, Int> get() {
        var h = 7u
        for (c in name) h = h * 31u + c.code.toUInt()
        val a = (h % 6u).toInt()
        return a to (a + 1 + ((h / 6u) % 4u).toInt()) % 6
    }
}

@Serializable data class StudioTag(val name: String? = null, val id: String? = null)
@Serializable data class StudioTaggedItem(val id: String, val type: String? = null, val studios: List<StudioTag>? = null)
@Serializable data class StudioIndexResult(val items: List<StudioTaggedItem> = emptyList())

/** Every movie and show with just its studio/network tags. */
suspend fun JellyfinClient.studioIndex(): List<StudioTaggedItem> =
    get<StudioIndexResult>("Items", mapOf(
        "userId" to userId, "recursive" to "true", "includeItemTypes" to "Movie,Series", "fields" to "Studios",
        "enableImages" to "false", "enableUserData" to "false",
    )).items

object StudioBrands {
    val catalog: List<Triple<String, StudioBrand.Kind, List<String>>> = listOf(
        Triple("Disney", StudioBrand.Kind.Studio, listOf("Walt Disney Pictures", "Walt Disney Animation Studios", "Walt Disney Feature Animation", "Walt Disney Productions", "Disneytoon Studios", "Disney Television Animation", "Walt Disney Studios")),
        Triple("Pixar", StudioBrand.Kind.Studio, listOf("Pixar", "Pixar Animation Studios")),
        Triple("Marvel", StudioBrand.Kind.Studio, listOf("Marvel Studios", "Marvel Entertainment", "Marvel Animation", "Marvel Television", "Marvel Enterprises")),
        Triple("Star Wars", StudioBrand.Kind.Studio, listOf("Lucasfilm Ltd.", "Lucasfilm", "Lucasfilm Animation")),
        Triple("DC", StudioBrand.Kind.Studio, listOf("DC", "DC Comics", "DC Entertainment", "DC Studios", "DC Films")),
        Triple("Warner Bros.", StudioBrand.Kind.Studio, listOf("Warner Bros. Pictures", "Warner Bros.", "Warner Bros. Animation", "Warner Bros. Television", "Warner Bros. Pictures Animation", "New Line Cinema", "Castle Rock Entertainment")),
        Triple("DreamWorks", StudioBrand.Kind.Studio, listOf("DreamWorks Animation", "DreamWorks Pictures", "DreamWorks", "DreamWorks SKG")),
        Triple("Universal", StudioBrand.Kind.Studio, listOf("Universal Pictures", "Universal Television", "Universal Studios", "Focus Features")),
        Triple("Illumination", StudioBrand.Kind.Studio, listOf("Illumination", "Illumination Entertainment")),
        Triple("Sony", StudioBrand.Kind.Studio, listOf("Columbia Pictures", "Sony Pictures", "Sony Pictures Animation", "Sony Pictures Television", "TriStar Pictures", "Screen Gems", "Sony Pictures Classics")),
        Triple("20th Century", StudioBrand.Kind.Studio, listOf("20th Century Fox", "20th Century Studios", "20th Century Fox Animation", "Twentieth Century Fox", "Fox Searchlight Pictures", "Searchlight Pictures", "Blue Sky Studios")),
        Triple("Paramount", StudioBrand.Kind.Studio, listOf("Paramount Pictures", "Paramount Animation", "Paramount Television", "Paramount Players")),
        Triple("Lionsgate", StudioBrand.Kind.Studio, listOf("Lionsgate", "Lions Gate Films", "Summit Entertainment")),
        Triple("MGM", StudioBrand.Kind.Studio, listOf("Metro-Goldwyn-Mayer", "United Artists", "Amazon MGM Studios", "MGM")),
        Triple("A24", StudioBrand.Kind.Studio, listOf("A24")),
        Triple("Studio Ghibli", StudioBrand.Kind.Studio, listOf("Studio Ghibli")),
        Triple("James Bond", StudioBrand.Kind.Studio, listOf("EON Productions", "Eon Productions", "Danjaq")),
        Triple("Legendary", StudioBrand.Kind.Studio, listOf("Legendary Pictures", "Legendary Entertainment")),
        Triple("Laika", StudioBrand.Kind.Studio, listOf("Laika", "LAIKA")),
        Triple("Aardman", StudioBrand.Kind.Studio, listOf("Aardman", "Aardman Animations")),
        Triple("Blumhouse", StudioBrand.Kind.Studio, listOf("Blumhouse Productions")),
        Triple("Disney Channel", StudioBrand.Kind.Network, listOf("Disney Channel", "Disney Junior", "Disney XD", "Toon Disney")),
        Triple("Disney+", StudioBrand.Kind.Network, listOf("Disney+")),
        Triple("Netflix", StudioBrand.Kind.Network, listOf("Netflix")),
        Triple("Apple TV", StudioBrand.Kind.Network, listOf("Apple TV", "Apple TV+")),
        Triple("HBO", StudioBrand.Kind.Network, listOf("HBO", "HBO Max", "Max", "Cinemax")),
        Triple("Prime Video", StudioBrand.Kind.Network, listOf("Prime Video", "Amazon", "Amazon Prime Video", "Amazon Studios", "Freevee")),
        Triple("Hulu", StudioBrand.Kind.Network, listOf("Hulu")),
        Triple("Peacock", StudioBrand.Kind.Network, listOf("Peacock")),
        Triple("Paramount+", StudioBrand.Kind.Network, listOf("Paramount+", "CBS All Access")),
        Triple("Cartoon Network", StudioBrand.Kind.Network, listOf("Cartoon Network", "Cartoon Network Studios", "Boomerang")),
        Triple("Adult Swim", StudioBrand.Kind.Network, listOf("Adult Swim", "[adult swim]", "Williams Street")),
        Triple("Nickelodeon", StudioBrand.Kind.Network, listOf("Nickelodeon", "Nickelodeon Animation Studio", "Nickelodeon Productions", "Nick Jr.", "Nicktoons", "Nick at Nite", "Nickelodeon Movies")),
        Triple("PBS", StudioBrand.Kind.Network, listOf("PBS", "PBS Kids", "PBS KIDS")),
        Triple("NBC", StudioBrand.Kind.Network, listOf("NBC")),
        Triple("ABC", StudioBrand.Kind.Network, listOf("ABC", "ABC Family")),
        Triple("CBS", StudioBrand.Kind.Network, listOf("CBS")),
        Triple("FOX", StudioBrand.Kind.Network, listOf("FOX", "Fox Broadcasting Company", "Fox", "20th Television", "20th Century Fox Television")),
        Triple("FX", StudioBrand.Kind.Network, listOf("FX", "FXX", "FX Productions", "FX Networks")),
        Triple("Comedy Central", StudioBrand.Kind.Network, listOf("Comedy Central")),
        Triple("AMC", StudioBrand.Kind.Network, listOf("AMC", "AMC+")),
        Triple("Showtime", StudioBrand.Kind.Network, listOf("Showtime")),
        Triple("Starz", StudioBrand.Kind.Network, listOf("Starz", "STARZ")),
        Triple("BBC", StudioBrand.Kind.Network, listOf("BBC", "BBC One", "BBC Two", "BBC Three", "BBC America")),
        Triple("Crunchyroll", StudioBrand.Kind.Network, listOf("Crunchyroll")),
        Triple("Syfy", StudioBrand.Kind.Network, listOf("Syfy", "SyFy", "Sci-Fi Channel")),
        Triple("TBS", StudioBrand.Kind.Network, listOf("TBS")),
        Triple("TNT", StudioBrand.Kind.Network, listOf("TNT")),
        Triple("Freeform", StudioBrand.Kind.Network, listOf("Freeform")),
        Triple("MTV", StudioBrand.Kind.Network, listOf("MTV")),
        Triple("Discovery", StudioBrand.Kind.Network, listOf("Discovery", "Discovery Channel", "Discovery+")),
    )

    /** Big but anonymous money and production companies that would only clutter the grid. */
    val ignored: Set<String> = setOf("tsgentertainment", "duneentertainment", "ratpacdunetentertainment", "ratpacentertainment", "domainentertainment", "villageroadshowpictures", "pascalpictures", "dentsu", "3artsentertainment", "heydayfilms", "syncopy", "amblinentertainment", "originalfilm", "scottfreeproductions", "planbentertainment", "relativitymedia", "regencyenterprises", "newregencypictures", "lightstormentertainment", "skydance", "skydancemedia", "bad robot", "badrobot", "imagineentertainment", "dualstarentertainment", "atlasentertainment", "nippontelevisionnetworkcorporation", "shueisha", "kodansha", "aniplex", "tohoanimation", "fujitelevision")

    fun key(s: String) = s.lowercase().filter { it.isLetterOrDigit() }

    /** Below this many titles, a company that isn't in the catalog stays out of the grid. */
    const val AUTO_THRESHOLD = 10

    fun build(items: List<StudioTaggedItem>): List<StudioBrand> {
        class Tally(val id: String, val name: String) { var movies = 0; var shows = 0 }
        val tallies = HashMap<String, Tally>()
        for (item in items) {
            val isShow = item.type == "Series"
            for (tag in item.studios.orEmpty()) {
                val name = tag.name ?: continue; val id = tag.id ?: continue
                if (name.isEmpty()) continue
                val t = tallies.getOrPut(key(name)) { Tally(id, name) }
                if (isShow) t.shows++ else t.movies++
            }
        }
        val lookup = HashMap<String, Pair<String, StudioBrand.Kind>>()
        for ((brand, kind, names) in catalog) for (n in names) lookup[key(n)] = brand to kind
        val groups = LinkedHashMap<String, Pair<StudioBrand.Kind, MutableSet<String>>>()
        for ((k, t) in tallies) {
            val hit = lookup[k]
            if (hit != null) groups.getOrPut(hit.first) { hit.second to mutableSetOf() }.second += k
            else if (k !in ignored && t.movies + t.shows >= AUTO_THRESHOLD)
                groups[t.name] = (if (t.shows > t.movies) StudioBrand.Kind.Network else StudioBrand.Kind.Studio) to mutableSetOf(k)
        }
        return groups.map { (brand, g) ->
            val movies = HashSet<String>(); val shows = HashSet<String>()
            for (item in items) if (item.studios.orEmpty().any { key(it.name ?: "") in g.second }) {
                if (item.type == "Series") shows += item.id else movies += item.id
            }
            val members = g.second.mapNotNull { tallies[it] }.map { StudioBrand.Member(it.id, it.name, it.movies + it.shows) }.sortedByDescending { it.count }
            StudioBrand(brand, g.first, members, movies.size, shows.size)
        }.filter { it.total > 0 }.sortedWith(compareByDescending<StudioBrand> { it.total }.thenBy { it.name })
    }
}

/** The brand list for this session, so switching tabs is instant. */
object StudioCatalog {
    var brands by mutableStateOf<List<StudioBrand>>(emptyList()); private set
    var loaded by mutableStateOf(false); private set
    var error by mutableStateOf<String?>(null)
    private var loadedFor: Any? = null

    suspend fun load(client: JellyfinClient, force: Boolean = false) {
        if (!force && loadedFor === client) return
        runCatching { StudioBrands.build(client.studioIndex()) }
            .onSuccess { brands = it; loaded = true; loadedFor = client; error = null }
            .onFailure { error = it.message ?: "Couldn't load studios" }
    }

    fun find(id: String) = brands.firstOrNull { it.id == id }
}
