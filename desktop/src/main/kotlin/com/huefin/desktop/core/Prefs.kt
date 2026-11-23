package com.huefin.desktop.core

import java.util.UUID
import java.util.prefs.Preferences

/** Settings saved for this Windows user (in the registry, under Huefin). */
object Prefs {
    private val p: Preferences = Preferences.userRoot().node("huefin")
    val deviceId: String
        get() = p.get("deviceId", null) ?: UUID.randomUUID().toString().also { p.put("deviceId", it) }
    fun string(key: String): String? = p.get(key, null)
    fun bool(key: String, def: Boolean = false) = p.getBoolean(key, def)
    fun int(key: String, def: Int = 0) = p.getInt(key, def)
    fun set(key: String, value: Any?) {
        when (value) {
            null -> p.remove(key)
            is Boolean -> p.putBoolean(key, value)
            is Int -> p.putInt(key, value)
            is Long -> p.putLong(key, value)
            is Float -> p.putFloat(key, value)
            // Preferences values are limited to 8 KB; long ones (account lists) are split.
            is String -> if (value.length < 7000) { p.put(key, value); p.remove("$key.parts") } else {
                val parts = value.chunked(7000); p.putInt("$key.parts", parts.size); parts.forEachIndexed { i, s -> p.put("$key.$i", s) }; p.put(key, "\u0000split")
            }
            else -> p.put(key, value.toString())
        }
        runCatching { p.flush() }
    }
    fun longString(key: String): String? {
        val v = string(key) ?: return null
        if (v != "\u0000split") return v
        return (0 until int("$key.parts")).joinToString("") { p.get("$key.$it", "") }
    }

    object Keys {
        const val autoIntro = "prism.autoSkipIntro"
        const val autoCredits = "prism.autoSkipCredits"
        const val maxBitrate = "lumen.maxBitrate"
        const val preferLocal = "lumen.preferLocal"
    }
    val autoSkipIntro get() = bool(Keys.autoIntro)
    val autoSkipCredits get() = bool(Keys.autoCredits)
}
