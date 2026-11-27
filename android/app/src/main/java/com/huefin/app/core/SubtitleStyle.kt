package com.huefin.app.core

/** How subtitles look (Settings → Subtitles), applied to mpv's text subtitles. Styled anime subtitles keep their look. */
object SubtitleStyle {
    val sizes = listOf("small" to "Small", "medium" to "Medium", "large" to "Large", "huge" to "Extra large")
    val colors = listOf("white" to "White", "yellow" to "Yellow", "cyan" to "Light blue")
    val backgrounds = listOf("shadow" to "Outline", "box" to "Dark box", "none" to "None")
    val positions = listOf("bottom" to "Bottom", "raised" to "Raised")
    var size: String get() = Prefs.string("huefin.sub.size") ?: "medium"; set(v) = Prefs.set("huefin.sub.size", v)
    var color: String get() = Prefs.string("huefin.sub.color") ?: "white"; set(v) = Prefs.set("huefin.sub.color", v)
    var background: String get() = Prefs.string("huefin.sub.background") ?: "shadow"; set(v) = Prefs.set("huefin.sub.background", v)
    var position: String get() = Prefs.string("huefin.sub.position") ?: "bottom"; set(v) = Prefs.set("huefin.sub.position", v)

    /** mpv options for the current choices. */
    fun mpvOptions(): List<Pair<String, String>> = listOf(
        "sub-scale" to when (size) { "small" -> "0.8"; "large" -> "1.3"; "huge" -> "1.65"; else -> "1" },
        "sub-color" to when (color) { "yellow" -> "#FFEB4D"; "cyan" -> "#99E6FF"; else -> "#FFFFFF" },
        "sub-border-style" to if (background == "box") "background-box" else "outline-and-shadow",
        "sub-back-color" to "#B8000000",
        "sub-border-size" to if (background == "none") "0" else "2.5",
        "sub-shadow-offset" to if (background == "shadow") "1" else "0",
        "sub-pos" to if (position == "raised") "90" else "100",
    )
}
