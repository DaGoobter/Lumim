package com.huefin.desktop.player

import com.huefin.desktop.core.BaseItem
import com.huefin.desktop.core.JellyfinClient
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.format.TextStyle
import java.util.Locale

data class QueueEntry(val item: BaseItem, val intro: String? = null) { val id get() = item.id }

/** An endless station: refill returns more entries, given the ids already queued or played. */
class Station(val name: String, val refill: suspend (JellyfinClient, Set<String>) -> List<QueueEntry>)

/** Endless radio from the library, including "Huefin DJ" with spoken intros. Same lines as the iPhone app. */
object Stations {
    private enum class DJSet { HeavyRotation, Favorite, Throwback, Discover }
    const val beat = " [pause:0.2s] "
    const val breath = " [pause:0.4s] "
    private val transitions = listOf("Alright.", "Okay, switching it up.", "Mm, okay.", "Alright, new direction.",
        "Let's change the mood a little.", "Okay, so.", "Keeping it moving.", "Right, next up.")

    fun dj(libraryId: String?): Station {
        var turn = 0
        var greeted = false
        return Station("Huefin DJ") { c, exclude ->
            var out = emptyList<QueueEntry>()
            for (attempt in DJSet.entries.indices) {
                val kind = DJSet.entries[turn % DJSet.entries.size]; turn++
                val seed = seed(kind, libraryId, c, exclude) ?: continue
                val similar = runCatching { c.instantMix(seed.id, 40) }.getOrDefault(emptyList()).filter { it.id != seed.id && it.id !in exclude }
                val set = listOf(seed) + similar.take(12).shuffled().take(5)
                val parts = mutableListOf<String>()
                if (!greeted) { greeted = true; parts += greeting() } else if ((0..2).random() > 0) parts += transitions.random()
                parts += intro(kind, seed)
                val line = parts.joinToString(breath)
                out = set.mapIndexed { i, item -> QueueEntry(item, if (i == 0) line else null) }
                break
            }
            out
        }
    }

    private suspend fun seed(kind: DJSet, lib: String?, c: JellyfinClient, exclude: Set<String>): BaseItem? {
        val pool = when (kind) {
            DJSet.HeavyRotation -> c.songs(lib, "PlayCount", filters = "IsPlayed", limit = 40)
            DJSet.Favorite -> c.songs(lib, "Random", filters = "IsFavorite", limit = 30)
            DJSet.Throwback -> c.songs(lib, "DatePlayed", "Ascending", "IsPlayed", limit = 40)
            DJSet.Discover -> c.songs(lib, "Random", filters = "IsUnplayed", limit = 30)
        }
        return pool.filter { it.id !in exclude }.randomOrNull()
    }

    private fun intro(kind: DJSet, seed: BaseItem): String {
        val song = seed.name?.let(::cleanTitle) ?: "this one"
        val artist = seed.artistLine ?: "someone you like"
        val reveal = listOf("Here's $artist,$beat$song.", "This is $song,${beat}from $artist.", "$artist.$beat$song.", "It's $song,${beat}by $artist.").random()
        val setup = when (kind) {
            DJSet.HeavyRotation -> listOf("So, you've had $artist on repeat lately. Like, a lot. No judgment, honestly, same.",
                "We're going back to one you just can't stop playing.", "You know this one. You really, really know this one.",
                "Okay, this is basically your theme song at this point.")
            DJSet.Favorite -> listOf("Here's one you hearted, and I get it.", "Pulling one straight from your favorites.",
                "You told me you love this one, so I'm not gonna overthink it.", "One of yours, a real favorite.")
            DJSet.Throwback -> listOf("Throwback time. You haven't played this in ages, and honestly? It still holds up.",
                "Remember this one? It's been a minute.", "Let's dig into the archives for a second.", "Okay, going way back in your history for this one.")
            DJSet.Discover -> listOf("So here's something that's been sitting in your library, and you've never actually played it.",
                "Trying something new on you. Trust me on this.", "First listen, for you anyway. Let's see what you think.", "Little bit of a wildcard here.")
        }
        val parts = mutableListOf(setup.random(), reveal)
        val year = seed.productionYear
        if ((0..2).random() == 0 && year != null && year > 1900) {
            val age = LocalDate.now().year - year
            parts += listOf("That's from $year.", if (age >= 15) "Straight out of ${decade(year)}, by the way." else "Came out in $year, believe it or not.").random()
        }
        listOf(null, null, "Then I've got a few more in the same lane.", "Stick around, I've lined up some more like it.",
            "And a couple more after this that I think you'll like.", "Enjoy.").random()?.let { parts += it }
        return parts.joinToString(" ")
    }

    private fun decade(year: Int): String {
        val d = year / 10 * 10
        return mapOf(1950 to "the fifties", 1960 to "the sixties", 1970 to "the seventies", 1980 to "the eighties",
            1990 to "the nineties", 2000 to "the two thousands")[d] ?: "${d}s"
    }

    private val editionNote = Regex("""\s*[(\[][^)\]]*(version|remaster|edit|mix|mono|stereo|live|explicit|feat\.?)[^)\]]*[)\]]""", RegexOption.IGNORE_CASE)
    private fun cleanTitle(t: String) = editionNote.replace(t, "").trim()

    private fun greeting(): String {
        val now = LocalDateTime.now()
        val day = now.dayOfWeek.getDisplayName(TextStyle.FULL, Locale.getDefault())
        return when (now.hour) {
            in 5..11 -> listOf("Good morning!${beat}It's your Huefin DJ. Let's ease into this $day.", "Morning! Huefin DJ here. Got some good stuff for you today.").random()
            in 12..16 -> listOf("Hey, good afternoon! Huefin DJ here.", "Hey there. Happy $day.${beat}It's your Huefin DJ.").random()
            in 17..21 -> listOf(if (now.dayOfWeek == java.time.DayOfWeek.FRIDAY) "It's Friday night!${beat}Huefin DJ here, let's get into it."
                else "Good evening. It's your Huefin DJ,${beat}let's get into it.", "Hey, hey. Huefin DJ, keeping you company this $day night.").random()
            else -> listOf("Hey, night owl.${beat}Huefin DJ here. Let's keep it going.", "Still up? Me too. It's your Huefin DJ.").random()
        }
    }

    /** Song/album/artist/genre/playlist radio that drifts: each refill seeds from the last song added. */
    fun radio(name: String, seedId: String): Station {
        var seed = seedId
        return Station(name) { c, exclude ->
            val picked = runCatching { c.instantMix(seed, 50) }.getOrDefault(emptyList()).filter { it.id !in exclude }.take(25)
            picked.lastOrNull()?.let { seed = it.id }
            picked.map { QueueEntry(it) }
        }
    }
    fun heavyRotation(lib: String?) = mix("Heavy Rotation", lib, "PlayCount", filters = "IsPlayed")
    fun favorites(lib: String?) = mix("Favorites Mix", lib, "Random", filters = "IsFavorite")
    fun throwbacks(lib: String?) = mix("Throwbacks", lib, "DatePlayed", "Ascending", "IsPlayed")
    fun discover(lib: String?) = mix("Discover", lib, "Random", filters = "IsUnplayed")
    fun shuffleAll(lib: String?) = mix("Shuffle All", lib, "Random", filters = null)

    private fun mix(name: String, lib: String?, sortBy: String, order: String = "Descending", filters: String?) = Station(name) { c, exclude ->
        var pool = c.songs(lib, sortBy, order, filters, limit = 80).filter { it.id !in exclude }
        if (sortBy != "Random") pool = pool.shuffled()
        pool.take(25).map { QueueEntry(it) }
    }

    fun byId(id: String, lib: String?): Station? = when (id) {
        "dj" -> dj(lib); "heavy" -> heavyRotation(lib); "favorites" -> favorites(lib); "throwbacks" -> throwbacks(lib)
        "discover" -> discover(lib); "shuffle" -> shuffleAll(lib); else -> null
    }
}
