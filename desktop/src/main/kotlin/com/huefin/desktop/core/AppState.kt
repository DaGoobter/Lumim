package com.huefin.desktop.core

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json

@Serializable
data class StoredSession(
    val serverURL: String,
    val serverName: String? = null,
    val userId: String,
    val userName: String,
    val token: String,
    val serverId: String? = null,
    val localURL: String? = null,
    val localURLIsManual: Boolean? = null,
) {
    /** One user on one server. */
    val key: String get() = (serverId ?: serverURL) + "|" + userId
}

class QuickConnectException(message: String) : Exception(message)

/** Who's signed in, which address we use (home Wi-Fi or remote), and app-wide settings. */
object AppState {
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val json = Json { ignoreUnknownKeys = true }

    enum class Route { Local, Remote }

    var session by mutableStateOf<StoredSession?>(null); private set
    var accounts by mutableStateOf<List<StoredSession>>(emptyList()); private set
    var client by mutableStateOf<JellyfinClient?>(null); private set
    var route by mutableStateOf(Route.Remote); private set
    var localStatus by mutableStateOf("Checking…"); private set
    var maxBitrate by mutableStateOf(200_000_000)
    var preferLocal by mutableStateOf(true)

    fun init() {
        maxBitrate = Prefs.int(Prefs.Keys.maxBitrate, 200_000_000).takeIf { it > 0 } ?: 200_000_000
        preferLocal = Prefs.bool(Prefs.Keys.preferLocal, true)
        accounts = Prefs.longString("accounts")?.let { runCatching { json.decodeFromString(ListSerializer(StoredSession.serializer()), it) }.getOrNull() } ?: emptyList()
        val s = Prefs.string("session")?.let { runCatching { json.decodeFromString(StoredSession.serializer(), it) }.getOrNull() }
        if (s != null) {
            session = s
            client = JellyfinClient(s.serverURL, s.token, s.userId)
            if (accounts.none { it.key == s.key }) { accounts = accounts + s; persistAccounts() }
            scope.launch { refreshRoute() }
        }
    }

    fun persistSettings() {
        Prefs.set(Prefs.Keys.maxBitrate, maxBitrate)
        Prefs.set(Prefs.Keys.preferLocal, preferLocal)
    }

    private fun save(s: StoredSession) {
        session = s
        Prefs.set("session", json.encodeToString(StoredSession.serializer(), s))
        accounts = if (accounts.any { it.key == s.key }) accounts.map { if (it.key == s.key) s else it } else accounts + s
        persistAccounts()
    }

    private fun persistAccounts() = Prefs.set("accounts", json.encodeToString(ListSerializer(StoredSession.serializer()), accounts))

    // MARK: Sign in

    private fun candidateURLs(server: String): List<String> {
        var raw = server.trim().trimEnd('/')
        if (raw.isEmpty()) return emptyList()
        if (raw.contains("://")) return listOf(raw)
        val hasPort = raw.substringAfter("]").contains(":")
        val isIp = raw.substringBefore(":").all { it.isDigit() || it == '.' }
        return if (isIp || raw.startsWith("localhost")) {
            listOfNotNull("http://$raw", if (!hasPort) "http://$raw:8096" else null)
        } else listOfNotNull("https://$raw", "http://$raw", if (!hasPort) "http://$raw:8096" else null)
    }

    private suspend fun connect(server: String): Pair<JellyfinClient, PublicSystemInfo> {
        var last: Exception = Exception("Enter your server's address.")
        for (u in candidateURLs(server)) {
            val c = JellyfinClient(u)
            try { return c to c.publicInfo() } catch (e: Exception) { last = e }
        }
        if (last is kotlinx.serialization.SerializationException)
            throw Exception("Something answered at that address, but it isn't a Jellyfin server. Check the spelling of the address.")
        throw Exception("Couldn't reach that server. Check the address and your internet connection.")
    }

    suspend fun login(server: String, username: String, password: String) {
        val (c, info) = connect(server)
        val auth = c.authenticate(username, password)
        adopt(c, info, auth)
        session?.let { s -> scope.launch { Seerr.autoConnect(s.key, s.serverURL, username, password) } }
    }

    suspend fun quickConnectStart(server: String): Triple<Pair<JellyfinClient, PublicSystemInfo>, String, String> {
        val (c, info) = connect(server)
        if (!c.quickConnectEnabled()) throw QuickConnectException("Quick Connect is turned off on this server. An admin can turn it on in Dashboard → General.")
        val r = c.quickConnectInitiate()
        return Triple(c to info, r.secret, r.code ?: "")
    }

    suspend fun quickConnectFinish(c: JellyfinClient, info: PublicSystemInfo, secret: String) {
        val deadline = System.currentTimeMillis() + 300_000
        while (System.currentTimeMillis() < deadline) {
            val st = runCatching { c.quickConnectState(secret) }.getOrNull()
            if (st?.authenticated == true) { adopt(c, info, c.quickConnectAuthenticate(secret)); return }
            delay(3000)
        }
        throw QuickConnectException("The code expired. Get a new one and try again.")
    }

    private fun adopt(c: JellyfinClient, info: PublicSystemInfo, auth: AuthResult) {
        c.accessToken = auth.accessToken
        c.userId = auth.user.id
        var s = StoredSession(c.baseUrl, info.serverName, auth.user.id, auth.user.name, auth.accessToken, info.id)
        accounts.firstOrNull { it.key == s.key }?.let { old -> s = s.copy(localURL = old.localURL, localURLIsManual = old.localURLIsManual) }
        save(s)
        client = c
        route = Route.Remote
        scope.launch { refreshRoute() }
    }

    fun switchTo(account: StoredSession) {
        if (account.key == session?.key) return
        save(account)
        client = JellyfinClient(account.serverURL, account.token, account.userId)
        route = Route.Remote
        localStatus = "Checking…"
        scope.launch { refreshRoute() }
    }

    suspend fun remove(account: StoredSession) {
        if (account.key == session?.key) { logout(); return }
        runCatching { JellyfinClient(account.serverURL, account.token, account.userId).send("Sessions/Logout") }
        accounts = accounts.filter { it.key != account.key }
        persistAccounts()
    }

    suspend fun logout() {
        runCatching { client?.send("Sessions/Logout") }
        val current = session?.key
        accounts = accounts.filter { it.key != current }
        persistAccounts()
        Prefs.set("session", null)
        session = null
        client = null
        accounts.firstOrNull()?.let { switchTo(it) }
    }

    // MARK: Home network vs remote

    fun setLocalURL(url: String?) {
        val s = session ?: return
        save(s.copy(localURL = url?.trim()?.ifEmpty { null }, localURLIsManual = !url.isNullOrBlank()))
        scope.launch { refreshRoute() }
    }

    private suspend fun probe(url: String, serverId: String?): String? {
        val info = withTimeoutOrNull(3500) { runCatching { JellyfinClient(url).publicInfo() }.getOrNull() } ?: return "Not reachable"
        if (serverId != null && info.id != null && info.id != serverId) return "A different server answered"
        return null
    }

    suspend fun refreshRoute() {
        var s = session ?: return
        if (s.localURL == null && s.localURLIsManual != true) {
            client?.localAddress()?.takeIf { it.isNotBlank() }?.let { s = s.copy(localURL = it); save(s) }
        }
        var target = s.serverURL
        var newRoute = Route.Remote
        if (!preferLocal) {
            localStatus = "Off"
        } else if (s.localURL != null) {
            val l = s.localURL!!
            val candidates = buildList {
                add(l)
                if (!l.substringAfter("://").contains(":")) add(l.trimEnd('/') + ":8096")
            }
            var problem = "Not reachable"
            for (cand in candidates) {
                if (cand == s.serverURL) continue
                val p = probe(cand, s.serverId)
                if (p == null) {
                    target = cand; newRoute = Route.Local
                    if (cand != l) { s = s.copy(localURL = cand); save(s) }
                    break
                } else problem = p
            }
            localStatus = if (newRoute == Route.Local) "Connected" else problem
        } else localStatus = "No home address yet"
        route = newRoute
        if (client?.baseUrl != target) client = JellyfinClient(target, s.token, s.userId)
        client?.let { com.huefin.desktop.downloads.DownloadManager.attach(it) }
    }
}
