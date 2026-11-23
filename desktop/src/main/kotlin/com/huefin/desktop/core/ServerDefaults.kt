package com.huefin.desktop.core

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put

/**
 * Huefin settings an admin sets per person on the server (stored in Jellyfin's per-user display preferences,
 * shared with the iPhone app). Each device applies them once per change; people can still adjust afterward.
 */
object ServerDefaults {
    private const val PREFS_ID = "usersettings"
    private const val CLIENT = "prism"

    data class Values(val maxBitrate: Int? = null, val autoSkipIntro: Boolean? = null, val autoSkipCredits: Boolean? = null, val engine: String? = null)

    private suspend fun load(c: JellyfinClient, userId: String): JsonObject? = runCatching {
        JellyfinJson.parseToJsonElement(c.send("DisplayPreferences/$PREFS_ID", mapOf("userId" to userId, "client" to CLIENT), "GET")).jsonObject
    }.getOrNull()

    suspend fun read(c: JellyfinClient, userId: String): Pair<Values, String?> {
        val custom = load(c, userId)?.get("CustomPrefs") as? JsonObject ?: JsonObject(emptyMap())
        fun str(k: String) = (custom[k] as? JsonPrimitive)?.content?.takeIf { it.isNotEmpty() && it != "null" }
        return Values(str("prism.maxBitrate")?.toIntOrNull(), str("prism.autoSkipIntro")?.let { it == "true" },
            str("prism.autoSkipCredits")?.let { it == "true" }, str("prism.engine")) to str("prism.defaultsVersion")
    }

    /** Admin: save defaults for someone. */
    suspend fun write(c: JellyfinClient, userId: String, v: Values) {
        val obj = load(c, userId) ?: buildJsonObject {
            put("Id", PREFS_ID); put("Client", CLIENT); put("SortBy", "SortName"); put("SortOrder", "Ascending")
            put("RememberIndexing", false); put("RememberSorting", false); put("ScrollDirection", "Horizontal")
            put("ShowBackdrop", true); put("ShowSidebar", false); put("PrimaryImageHeight", 250); put("PrimaryImageWidth", 250)
        }
        val custom = ((obj["CustomPrefs"] as? JsonObject) ?: JsonObject(emptyMap())).toMutableMap()
        custom["prism.maxBitrate"] = JsonPrimitive(v.maxBitrate?.toString() ?: "")
        custom["prism.autoSkipIntro"] = JsonPrimitive(v.autoSkipIntro?.toString() ?: "")
        custom["prism.autoSkipCredits"] = JsonPrimitive(v.autoSkipCredits?.toString() ?: "")
        custom["prism.engine"] = JsonPrimitive(v.engine ?: "")
        custom["prism.defaultsVersion"] = JsonPrimitive((System.currentTimeMillis() / 1000).toString())
        c.send("DisplayPreferences/$PREFS_ID", mapOf("userId" to userId, "client" to CLIENT), body = JsonObject(obj + ("CustomPrefs" to JsonObject(custom))))
    }

    /** Apply new defaults from the admin, once per change. */
    suspend fun apply() {
        val c = AppState.client ?: return
        val uid = AppState.session?.userId ?: return
        val (v, version) = read(c, uid)
        version ?: return
        val key = "prism.appliedDefaults.$uid"
        if (Prefs.string(key) == version) return
        Prefs.set(key, version)
        v.maxBitrate?.takeIf { it > 0 }?.let { AppState.maxBitrate = it; AppState.persistSettings() }
        v.autoSkipIntro?.let { Prefs.set(Prefs.Keys.autoIntro, it) }
        v.autoSkipCredits?.let { Prefs.set(Prefs.Keys.autoCredits, it) }
        v.engine?.let { Prefs.set(Prefs.Keys.engine, it) }
    }
}
