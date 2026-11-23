package com.huefin.app.core

import android.content.Context
import android.content.SharedPreferences
import java.util.UUID

/** App-wide settings (the iOS app's UserDefaults). Keys match the iOS ones where it matters. */
object Prefs {
    lateinit var sp: SharedPreferences
        private set

    fun init(context: Context) {
        sp = context.getSharedPreferences("huefin", Context.MODE_PRIVATE)
    }

    val deviceId: String
        get() = sp.getString("deviceId", null) ?: UUID.randomUUID().toString().also { sp.edit().putString("deviceId", it).apply() }

    fun bool(key: String, def: Boolean = false) = sp.getBoolean(key, def)
    fun int(key: String, def: Int = 0) = sp.getInt(key, def)
    fun string(key: String): String? = sp.getString(key, null)
    fun set(key: String, value: Any?) {
        sp.edit().apply {
            when (value) {
                null -> remove(key)
                is Boolean -> putBoolean(key, value)
                is Int -> putInt(key, value)
                is Long -> putLong(key, value)
                is Float -> putFloat(key, value)
                is String -> putString(key, value)
                else -> putString(key, value.toString())
            }
        }.apply()
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
