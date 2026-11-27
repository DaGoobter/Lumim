package com.huefin.app.core

import com.huefin.app.playback.Track
import java.util.Locale

enum class SubtitleMode(val key: String, val label: String) {
    Off("off", "Off"), Forced("forced", "Forced only"), Always("always", "Always on"), ForeignAudio("foreignAudio", "When audio isn't my language")
}

/** Default audio and subtitle choices, applied when something starts playing. */
object TrackPrefs {
    val languages = listOf("eng" to "English", "spa" to "Spanish", "fre" to "French", "ger" to "German", "ita" to "Italian", "por" to "Portuguese",
        "jpn" to "Japanese", "kor" to "Korean", "chi" to "Chinese", "rus" to "Russian", "ara" to "Arabic", "hin" to "Hindi", "dut" to "Dutch",
        "swe" to "Swedish", "nor" to "Norwegian", "dan" to "Danish", "fin" to "Finnish", "pol" to "Polish", "tur" to "Turkish", "gre" to "Greek",
        "heb" to "Hebrew", "tha" to "Thai", "vie" to "Vietnamese", "ind" to "Indonesian", "tgl" to "Tagalog")
    private val aliases = mapOf("eng" to setOf("en"), "spa" to setOf("es"), "fre" to setOf("fra", "fr"), "ger" to setOf("deu", "de"), "ita" to setOf("it"),
        "por" to setOf("pt"), "jpn" to setOf("ja"), "kor" to setOf("ko"), "chi" to setOf("zho", "zh"), "rus" to setOf("ru"), "ara" to setOf("ar"),
        "hin" to setOf("hi"), "dut" to setOf("nld", "nl"), "swe" to setOf("sv"), "nor" to setOf("nob", "nno", "no", "nb"), "dan" to setOf("da"),
        "fin" to setOf("fi"), "pol" to setOf("pl"), "tur" to setOf("tr"), "gre" to setOf("ell", "el"), "heb" to setOf("he", "iw"), "tha" to setOf("th"),
        "vie" to setOf("vi"), "ind" to setOf("id", "in"), "tgl" to setOf("fil", "tl"))

    var audioLanguage: String get() = Prefs.string("track.audioLanguage") ?: ""; set(v) = Prefs.set("track.audioLanguage", v)
    var subtitleLanguage: String get() = Prefs.string("track.subtitleLanguage") ?: "eng"; set(v) = Prefs.set("track.subtitleLanguage", v)
    var subtitleMode: SubtitleMode get() = SubtitleMode.entries.firstOrNull { it.key == Prefs.string("track.subtitleMode") } ?: SubtitleMode.Forced
        set(v) = Prefs.set("track.subtitleMode", v.key)

    fun name(code: String) = languages.firstOrNull { it.first == code }?.second ?: code.uppercase()

    private fun matches(t: Track, code: String): Boolean {
        if (code.isEmpty()) return false
        t.language?.lowercase()?.let { l -> if (l == code || l in (aliases[code] ?: emptySet()) || l.substringBefore('-') in (aliases[code] ?: emptySet())) return true }
        val n = name(code)
        return t.label.contains(n, true) || Locale(code).displayLanguage.let { it.isNotEmpty() && t.label.contains(it, true) }
    }

    /** Returns (audio track id or null = keep, subtitle track id or null = off). */
    fun choose(audio: List<Track>, subs: List<Track>): Pair<String?, String?> {
        var audioPick: String? = null
        var playing = audio.firstOrNull { it.selected } ?: audio.firstOrNull()
        if (audioLanguage.isNotEmpty()) audio.firstOrNull { matches(it, audioLanguage) }?.let { audioPick = it.id; playing = it }
        val lang = subs.filter { matches(it, subtitleLanguage) }
        val forced = lang.firstOrNull { it.label.contains("forced", true) }?.id
        val full = lang.firstOrNull { !it.label.contains("forced", true) }?.id
        val sub = when (subtitleMode) {
            SubtitleMode.Off -> null
            SubtitleMode.Forced -> forced
            SubtitleMode.Always -> full ?: forced
            SubtitleMode.ForeignAudio -> if (playing != null && matches(playing!!, subtitleLanguage)) forced else full ?: forced
        }
        return audioPick to sub
    }

    // MARK: Choices remembered per show (pick once, every episode of the show starts the same way).
    private const val OFF = "\u0000off"
    fun rememberAudio(seriesId: String?, label: String) { if (seriesId != null) Prefs.set("show.audio.$seriesId", label) }
    fun rememberSubtitle(seriesId: String?, label: String?) { if (seriesId != null) Prefs.set("show.sub.$seriesId", label ?: OFF) }
    private fun norm(s: String) = s.lowercase().replace("default", "").replace("external", "").trim(' ', '·', '-')

    fun choose(audio: List<Track>, subs: List<Track>, seriesId: String?): Pair<String?, String?> {
        var (a, s) = choose(audio, subs)
        if (seriesId == null) return a to s
        Prefs.string("show.audio.$seriesId")?.let { want -> audio.firstOrNull { norm(it.label) == norm(want) }?.let { a = it.id } }
        Prefs.string("show.sub.$seriesId")?.let { want ->
            if (want == OFF) s = null else subs.firstOrNull { norm(it.label) == norm(want) }?.let { s = it.id }
        }
        return a to s
    }
}
