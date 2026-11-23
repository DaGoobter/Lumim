package com.huefin.desktop.core

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.net.URLEncoder
import java.util.concurrent.TimeUnit

fun JsonElement?.str(key: String): String? = (this as? JsonObject)?.get(key)?.let { (it as? JsonPrimitive)?.contentOrNull }
fun JsonElement?.int(key: String): Int? = (this as? JsonObject)?.get(key)?.let { (it as? JsonPrimitive)?.intOrNull }
fun JsonElement?.long(key: String): Long? = (this as? JsonObject)?.get(key)?.let { (it as? JsonPrimitive)?.contentOrNull?.toLongOrNull() }
fun JsonElement?.bool(key: String): Boolean? = (this as? JsonObject)?.get(key)?.let { (it as? JsonPrimitive)?.booleanOrNull }
fun JsonElement?.obj(key: String): JsonObject? = (this as? JsonObject)?.get(key) as? JsonObject
fun JsonElement?.arr(key: String): List<JsonElement> = ((this as? JsonObject)?.get(key) as? JsonArray) ?: emptyList()

/** Requests through Seerr (Jellyseerr): ask for movies and shows that aren't on the server yet. */
object Seerr {
    data class Result(val id: Int, val mediaType: String, val title: String, val year: String?, val overview: String?,
                      val posterPath: String?, val status: Int?) {
        val posterURL get() = posterPath?.let { "https://image.tmdb.org/t/p/w342$it" }
        val statusText get() = when (status) { 5 -> "Available"; 4 -> "Partly available"; 3 -> "Requested"; 2 -> "Waiting for approval"; else -> null }
    }
    data class Req(val id: Int, val status: Int, val mediaType: String, val tmdbId: Int, val requestedBy: String,
                   val mediaStatus: Int?, val title: String? = null, val posterPath: String? = null)

    var baseURL by mutableStateOf<String?>(null); private set
    var signedIn by mutableStateOf(false); private set
    var canManage by mutableStateOf(false); private set
    private var accountKey: String? = null
    private var cookie: String? = null
    private val http = OkHttpClient.Builder().connectTimeout(10, TimeUnit.SECONDS).readTimeout(15, TimeUnit.SECONDS).build()

    val isConfigured get() = baseURL != null && signedIn
    val needsSignIn get() = baseURL != null && !signedIn

    suspend fun activate(key: String?, jellyfinURL: String?) {
        if (key == accountKey && baseURL != null) return
        accountKey = key; signedIn = false; canManage = false
        cookie = key?.let { Prefs.string("seerr.cookie.$it") }
        baseURL = key?.let { Prefs.string("prism.seerr.$it") } ?: discover(jellyfinURL)
        if (baseURL != null && cookie != null) refreshMe()
    }

    /** Seerr usually lives at requests.<your Jellyfin domain>. */
    private suspend fun discover(jellyfinURL: String?): String? = withContext(Dispatchers.IO) {
        val host = jellyfinURL?.substringAfter("://")?.substringBefore("/")?.substringBefore(":") ?: return@withContext null
        if (!host.contains(".") || host.split(".").last().all { it.isDigit() }) return@withContext null
        val parts = host.split(".")
        val root = if (parts.size > 2 && parts[0] != "www" && !host.endsWith(".duckdns.org")) parts.drop(1).joinToString(".") else host
        for (h in listOf("requests.$host", "requests.$root", "seerr.$root", "jellyseerr.$root", "request.$root").distinct()) {
            val ok = runCatching {
                http.newBuilder().callTimeout(4, TimeUnit.SECONDS).build()
                    .newCall(Request.Builder().url("https://$h/api/v1/settings/public").build()).execute().use { r ->
                        r.isSuccessful && JellyfinJson.parseToJsonElement(r.body?.string() ?: "").let { it.bool("initialized") == true && it.int("mediaServerType") == 2 }
                    }
            }.getOrDefault(false)
            if (ok) return@withContext "https://$h"
        }
        null
    }

    suspend fun autoConnect(key: String, jellyfinURL: String, username: String, password: String) {
        accountKey = null
        activate(key, jellyfinURL)
        val base = baseURL ?: return
        if (!signedIn) runCatching { signIn(base, username, password) }
    }

    suspend fun signIn(address: String, username: String, password: String) {
        var raw = address.trim().trimEnd('/')
        if (!raw.contains("://")) raw = "http://$raw"
        baseURL = raw
        call("POST", "auth/jellyfin", buildJsonObject { put("username", username); put("password", password) })
        accountKey?.let { Prefs.set("prism.seerr.$it", raw) }
        refreshMe()
        if (!signedIn) throw HttpError(401)
    }

    suspend fun signOut() {
        runCatching { call("POST", "auth/logout") }
        accountKey?.let { Prefs.set("prism.seerr.$it", null); Prefs.set("seerr.cookie.$it", null) }
        cookie = null; signedIn = false
    }

    private suspend fun refreshMe() {
        val me = runCatching { call("GET", "auth/me") }.getOrNull()
        if (me?.int("id") == null) { signedIn = false; return }
        signedIn = true
        val perms = me.int("permissions") ?: 0
        canManage = perms and 2 != 0 || perms and 16 != 0
    }

    suspend fun search(q: String): List<Result> = parse(runCatching { call("GET", "search?query=${URLEncoder.encode(q, "UTF-8").replace("+", "%20")}&page=1") }.getOrNull().arr("results"))
    suspend fun trending(): List<Result> = parse(runCatching { call("GET", "discover/trending?page=1") }.getOrNull().arr("results"))
    suspend fun request(r: Result) {
        call("POST", "request", buildJsonObject {
            put("mediaType", r.mediaType); put("mediaId", r.id); if (r.mediaType == "tv") put("seasons", "all")
        })
    }
    suspend fun requests(): List<Req> = runCatching { call("GET", "request?take=40&skip=0&sort=added&filter=all") }.getOrNull()
        .arr("results").mapNotNull { r ->
            val media = r.obj("media") ?: return@mapNotNull null
            Req(r.int("id") ?: return@mapNotNull null, r.int("status") ?: 1, media.str("mediaType") ?: "movie",
                media.int("tmdbId") ?: return@mapNotNull null, r.obj("requestedBy").str("displayName") ?: "", media.int("status"))
        }
    suspend fun details(r: Req): Pair<String?, String?> {
        val o = runCatching { call("GET", "${if (r.mediaType == "tv") "tv" else "movie"}/${r.tmdbId}") }.getOrNull()
        return (o.str("title") ?: o.str("name")) to o.str("posterPath")
    }
    suspend fun approve(id: Int) { call("POST", "request/$id/approve") }
    suspend fun decline(id: Int) { call("POST", "request/$id/decline") }

    private fun parse(list: List<JsonElement>) = list.mapNotNull { r ->
        val type = r.str("mediaType")
        if (type != "movie" && type != "tv") return@mapNotNull null
        val date = r.str("releaseDate") ?: r.str("firstAirDate")
        Result(r.int("id") ?: return@mapNotNull null, type, r.str("title") ?: r.str("name") ?: "Untitled", date?.take(4),
            r.str("overview"), r.str("posterPath"), r.obj("mediaInfo").int("status"))
    }

    private suspend fun call(method: String, path: String, body: JsonObject? = null): JsonElement? = withContext(Dispatchers.IO) {
        val base = baseURL ?: throw HttpError(0)
        val b = Request.Builder().url("$base/api/v1/$path").header("Accept", "application/json")
        cookie?.let { b.header("Cookie", it) }
        b.method(method, if (method == "GET") null else (body?.toString() ?: "").toRequestBody("application/json".toMediaType()))
        http.newCall(b.build()).execute().use { r ->
            r.headers("Set-Cookie").firstOrNull { it.startsWith("connect.sid=") }?.let { sc ->
                cookie = sc.substringBefore(";")
                accountKey?.let { Prefs.set("seerr.cookie.$it", cookie) }
            }
            if (!r.isSuccessful) throw HttpError(r.code)
            val text = r.body?.string().orEmpty()
            if (text.isBlank()) null else runCatching { JellyfinJson.parseToJsonElement(text) }.getOrNull()
        }
    }
}
