package com.huefin.desktop.core

import java.util.UUID
import java.util.prefs.Preferences

/** Settings saved for this Windows user (in the registry, under Huefin). Same keys as the phone apps. */
object Prefs {
    private val p: Preferences = Preferences.userRoot().node("huefin")
    /** Matches the Android SharedPreferences calls the shared screens make. */
    object sp {
        fun getFloat(key: String, def: Float) = p.getFloat(key, def)
        fun contains(key: String) = p.get(key, null) != null
    }
    val deviceId: String
        get() = p.get("deviceId", null) ?: UUID.randomUUID().toString().also { p.put("deviceId", it); runCatching { p.flush() } }
    fun string(key: String): String? = longString(key)
    fun bool(key: String, def: Boolean = false) = p.getBoolean(key, def)
    fun int(key: String, def: Int = 0) = p.getInt(key, def)
    fun float(key: String, def: Float = 0f) = p.getFloat(key, def)
    fun set(key: String, value: Any?) {
        for (i in 0 until p.getInt("$key.parts", 0)) p.remove("$key.$i")
        p.remove("$key.parts")
        when (value) {
            null -> p.remove(key)
            is Boolean -> p.putBoolean(key, value)
            is Int -> p.putInt(key, value)
            is Long -> p.putLong(key, value)
            is Float -> p.putFloat(key, value)
            // Values are limited to 8 KB; long ones (account lists) are split.
            is String -> if (value.length < 7000) p.put(key, value) else {
                val parts = value.chunked(7000); p.putInt("$key.parts", parts.size); parts.forEachIndexed { i, s -> p.put("$key.$i", s) }; p.put(key, SPLIT)
            }
            else -> p.put(key, value.toString())
        }
        runCatching { p.flush() }
    }
    private const val SPLIT = "\u0001split"
    fun longString(key: String): String? {
        val v = p.get(key, null) ?: return null
        if (v != SPLIT) return v
        return (0 until p.getInt("$key.parts", 0)).joinToString("") { p.get("$key.$it", "") }
    }

    object Keys {
        const val autoIntro = "prism.autoSkipIntro"
        const val autoRecap = "prism.autoSkipRecap"
        const val autoCredits = "prism.autoSkipCredits"
        const val delay = "prism.autoSkipDelay"
        const val back = "prism.skipBack"
        const val forward = "prism.skipForward"
        const val engine = "prism.engine"
        const val maxBitrate = "lumen.maxBitrate"
        const val preferLocal = "lumen.preferLocal"
        const val askWho = "prism.askWhoIsWatching"
        const val liveLayout = "prism.liveLayout"
        const val recentSearches = "prism.recentSearches"
    }
    val autoSkipIntro get() = bool(Keys.autoIntro)
    val autoSkipRecap get() = bool(Keys.autoRecap)
    val autoSkipCredits get() = bool(Keys.autoCredits)
    val autoSkipDelay get() = if (sp.contains(Keys.delay)) int(Keys.delay) else 3
    val skipBack get() = int(Keys.back, 10).takeIf { it in listOf(5, 10, 15, 30) } ?: 10
    val skipForward get() = int(Keys.forward, 10).takeIf { it in listOf(5, 10, 15, 30) } ?: 10
}
