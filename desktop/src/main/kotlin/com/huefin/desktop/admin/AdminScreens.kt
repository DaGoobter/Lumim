package com.huefin.desktop.admin

import com.huefin.desktop.ui.NavHostController

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Message
import androidx.compose.material.icons.automirrored.filled.Article
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.huefin.desktop.core.AppState
import com.huefin.desktop.core.ServerDefaults
import com.huefin.desktop.core.formatBytes
import com.huefin.desktop.core.parseJellyfinDate
import com.huefin.desktop.ui.*
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonPrimitive
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle

private fun ago(t: Instant?): String {
    t ?: return ""
    val s = (System.currentTimeMillis() - t.toEpochMilli()) / 1000
    return when { s < 60 -> "just now"; s < 3600 -> "${s / 60} min ago"; s < 86400 -> "${s / 3600} h ago"; else -> "${s / 86400} d ago" }
}
private val stamp = DateTimeFormatter.ofLocalizedDateTime(FormatStyle.SHORT).withZone(ZoneId.systemDefault())

// MARK: Dashboard

/** Your server at a glance: who's watching, stats, storage, and the tools to manage it. */
@Composable
fun AdminDashboardScreen(nav: NavHostController) {
    val c = AppState.client ?: return
    var info by remember { mutableStateOf<AdminSystemInfo?>(null) }
    var counts by remember { mutableStateOf<ItemCounts?>(null) }
    var sessions by remember { mutableStateOf<List<AdminSession>>(emptyList()) }
    var storage by remember { mutableStateOf<SystemStorage?>(null) }
    var stats by remember { mutableStateOf<WatchStats?>(null) }
    var statsLoaded by remember { mutableStateOf(false) }
    var tasks by remember { mutableStateOf<List<ScheduledTask>>(emptyList()) }
    var status by remember { mutableStateOf<String?>(null) }
    var confirm by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    LaunchedEffect(Unit) {
        info = runCatching { c.adminSystemInfo() }.getOrNull()
        counts = runCatching { c.adminCounts() }.getOrNull()
        storage = runCatching { c.adminStorage() }.getOrNull()
        launch { stats = c.adminWatchStats(); statsLoaded = true }
        while (true) {
            sessions = runCatching { c.adminSessions() }.getOrDefault(sessions)
            tasks = runCatching { c.adminTasks().filter { it.isRunning } }.getOrDefault(tasks)
            delay(5000)
        }
    }
    val playing = sessions.filter { it.nowPlayingItem != null }
    FormScreen("Server Dashboard", nav) {
        item {
            Column(Modifier.widthIn(max = 900.dp).fillMaxWidth().clip(RoundedCornerShape(22.dp)).background(Brush.linearGradient(listOf(Hue.violet, Hue.sky))).padding(20.dp)) {
                Text(info?.serverName ?: "Jellyfin", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.ExtraBold, color = Hue.ink)
                Text(listOfNotNull(info?.version?.let { "Jellyfin $it" }, info?.operatingSystemDisplayName).joinToString(" · "), color = Hue.ink.copy(alpha = 0.75f))
                if (info?.hasPendingRestart == true) Text("Restart needed to finish an update", color = Hue.ink, fontWeight = FontWeight.Bold)
                if (info?.hasUpdateAvailable == true) Text("A Jellyfin update is available", color = Hue.ink, fontWeight = FontWeight.Bold)
                Spacer(Modifier.height(14.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    PowerButton("Scan all", Icons.Filled.Sync) { scope.launch { status = runCatching { c.adminScanAll(); "Scanning all libraries" }.getOrElse { it.message } } }
                    PowerButton("Restart", Icons.Filled.RestartAlt) { confirm = "restart" }
                    PowerButton("Shut down", Icons.Filled.PowerSettingsNew) { confirm = "shutdown" }
                }
            }
        }
        status?.let { item { Text(it, color = Hue.secondaryText, modifier = Modifier.padding(8.dp)) } }
        counts?.let { k -> item {
            Row(Modifier.widthIn(max = 900.dp).fillMaxWidth().horizontalScroll(rememberScrollState()).padding(top = 8.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                listOf("Movies" to k.movieCount, "Shows" to k.seriesCount, "Episodes" to k.episodeCount, "Albums" to k.albumCount, "Songs" to k.songCount, "Books" to k.bookCount)
                    .filter { (it.second ?: 0) > 0 }.forEach { (l, n) ->
                        Column(Modifier.clip(RoundedCornerShape(16.dp)).background(Hue.card).padding(horizontal = 18.dp, vertical = 12.dp)) {
                            Text("%,d".format(n), style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.ExtraBold); Text(l, color = Hue.secondaryText, style = MaterialTheme.typography.bodySmall)
                        }
                    }
            }
        } }
        item {
            FormSection("Now playing · ${playing.size}") {
                if (playing.isEmpty()) FormRow("All quiet", "Nobody is watching or listening right now.", Icons.Filled.Bedtime, Hue.mint)
                playing.forEachIndexed { i, s ->
                    if (i > 0) FormDivider()
                    SessionRow(s) { nav.navigate("admin/session:${s.id}") }
                }
                FormDivider()
                FormRow("${sessions.size} active devices", chevron = true, onClick = { nav.navigate("admin/devices") })
            }
        }
        if (tasks.isNotEmpty()) item {
            FormSection("Running") {
                tasks.forEach { t -> FormRow(t.name ?: "Task", value = "${(t.currentProgressPercentage ?: 0.0).toInt()}%") }
            }
        }
        item {
            FormSection("Watching · 14 days", if (statsLoaded && stats == null) "Install the Playback Reporting plugin on your server to see hours watched, who's watching and how much is transcoded." else null) {
                val st = stats
                if (st == null) FormRow(if (statsLoaded) "No stats" else "Loading…")
                else Column(Modifier.padding(16.dp)) {
                    Row(verticalAlignment = Alignment.Bottom) { Text("%.0f".format(st.totalHours), style = MaterialTheme.typography.displaySmall, fontWeight = FontWeight.ExtraBold); Text(" hours", color = Hue.secondaryText) }
                    val max = st.days.maxOfOrNull { it.second }?.takeIf { it > 0 } ?: 1.0
                    Row(Modifier.fillMaxWidth().height(90.dp).padding(top = 10.dp), horizontalArrangement = Arrangement.spacedBy(4.dp), verticalAlignment = Alignment.Bottom) {
                        st.days.forEach { (_, h) -> Box(Modifier.weight(1f).fillMaxHeight((h / max).toFloat().coerceAtLeast(0.02f)).clip(RoundedCornerShape(4.dp)).background(Hue.violet)) }
                    }
                    if (st.methods.isNotEmpty()) {
                        Eyebrow("How it's played · 30 days", Hue.secondaryText); Spacer(Modifier.height(6.dp))
                        val total = st.methods.sumOf { it.second }.coerceAtLeast(1)
                        st.methods.forEach { (l, n) -> Row { Text(l, Modifier.weight(1f)); Text("${n * 100 / total}%", fontWeight = FontWeight.SemiBold) } }
                    }
                    if (st.titles.isNotEmpty()) {
                        Spacer(Modifier.height(10.dp)); Eyebrow("Most watched · 30 days", Hue.secondaryText); Spacer(Modifier.height(6.dp))
                        st.titles.forEach { (n, h, p) -> Row { Text(n, Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis); Text("%.1f h · %d plays".format(h, p), color = Hue.secondaryText) } }
                    }
                }
            }
        }
        storage?.let { st -> item {
            FormSection("Storage") {
                st.drives.forEachIndexed { i, (d, uses) ->
                    if (i > 0) FormDivider()
                    Column(Modifier.padding(16.dp)) {
                        Row { Text(d.driveLabel, Modifier.weight(1f), fontWeight = FontWeight.SemiBold); Text("${formatBytes(d.freeSpace ?: 0)} free", color = Hue.secondaryText) }
                        LinearProgressIndicator({ d.fraction.toFloat() }, Modifier.fillMaxWidth().padding(vertical = 6.dp), color = if (d.fraction > 0.9) Hue.coral else Hue.sky)
                        Text(uses.joinToString(" · "), style = MaterialTheme.typography.bodySmall, color = Hue.secondaryText)
                    }
                }
            }
        } }
        item {
            FormSection("Manage") {
                listOf(Triple("libraries", "Libraries" to "Scan, refresh metadata", Icons.Filled.VideoLibrary to Hue.violet),
                    Triple("users", "Users" to "Access, downloads, remote, parents", Icons.Filled.Group to Hue.coral),
                    Triple("activity", "Activity" to "Logins, plays, changes", Icons.Filled.MonitorHeart to Hue.mint),
                    Triple("tasks", "Scheduled Tasks" to "Run or stop server jobs", Icons.Filled.Schedule to Hue.sky),
                    Triple("logs", "Logs" to "Read server and FFmpeg logs", Icons.AutoMirrored.Filled.Article to Hue.amber),
                    Triple("devices", "Devices" to "Everything signed in", Icons.Filled.Devices to Hue.sky),
                    Triple("plugins", "Plugins" to "What's installed", Icons.Filled.Extension to Hue.sun),
                    Triple("quickconnect", "Quick Connect" to "Approve a TV sign-in code", Icons.Filled.QrCode to Hue.mint),
                    Triple("web", "Full Dashboard" to "Everything else, from Jellyfin", Icons.Filled.Public to Hue.coral),
                ).forEachIndexed { i, (route, text, look) ->
                    if (i > 0) FormDivider()
                    FormRow(text.first, text.second, look.first, look.second, chevron = true, onClick = { nav.navigate(if (route == "quickconnect") "quickconnect" else "admin/$route") })
                }
            }
        }
    }
    confirm?.let { what ->
        AlertDialog({ confirm = null }, confirmButton = { TextButton({
            confirm = null
            scope.launch { status = runCatching { if (what == "restart") { c.adminRestart(); "Restarting…" } else { c.adminShutdown(); "Shutting down." } }.getOrElse { it.message } }
        }) { Text(if (what == "restart") "Restart" else "Shut down", color = Hue.coral) } },
            dismissButton = { TextButton({ confirm = null }) { Text("Cancel") } },
            title = { Text(if (what == "restart") "Restart the server?" else "Shut down the server?") },
            text = { Text(if (what == "restart") "Anyone watching will be interrupted." else "You'll need to start Jellyfin on your PC again to bring it back.") })
    }
}

@Composable
private fun PowerButton(label: String, icon: ImageVector, onClick: () -> Unit) {
    Row(Modifier.clip(RoundedCornerShape(14.dp)).background(Hue.ink.copy(alpha = 0.85f)).clickable(onClick = onClick).padding(horizontal = 14.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically) { Icon(icon, null, Modifier.size(18.dp), tint = Color.White); Text(" $label", color = Color.White, fontWeight = FontWeight.SemiBold) }
}

@Composable
private fun SessionRow(s: AdminSession, onClick: () -> Unit) {
    val c = AppState.client
    Row(Modifier.fillMaxWidth().clickable(onClick = onClick).padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
        RemoteImage(s.nowPlayingItem?.let { c?.posterURL(it, 160) }, Modifier.size(48.dp, 72.dp).clip(RoundedCornerShape(8.dp)))
        Column(Modifier.weight(1f).padding(horizontal = 12.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(s.userName ?: "Someone", style = MaterialTheme.typography.labelMedium, fontWeight = FontWeight.Bold, color = LocalHue.current)
            Text(s.nowPlayingItem?.displayTitle ?: "", fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(listOfNotNull(s.nowPlayingItem?.episodeLabel, s.deviceName, s.client).joinToString(" · "), style = MaterialTheme.typography.bodySmall, color = Hue.secondaryText, maxLines = 1)
            s.progress?.let { ProgressBar(it, Modifier.fillMaxWidth(0.7f)) }
        }
        Column(horizontalAlignment = Alignment.End) {
            Chip(s.method, color = (if (s.method == "Transcode") Hue.coral else Hue.mint).copy(alpha = 0.2f), textColor = if (s.method == "Transcode") Hue.coral else Hue.mint)
            Spacer(Modifier.height(4.dp))
            Text(if (s.isLocal) "Home" else "Remote", style = MaterialTheme.typography.labelSmall, color = Hue.secondaryText)
        }
    }
}

// MARK: Sections

@Composable
fun AdminSectionScreen(section: String, nav: NavHostController) {
    when {
        section.startsWith("session:") -> SessionDetail(section.removePrefix("session:"), nav)
        section.startsWith("log:") -> LogViewer(section.removePrefix("log:"), nav)
        section == "libraries" -> Libraries(nav)
        section == "users" -> Users(nav)
        section == "activity" -> Activity(nav)
        section == "tasks" -> Tasks(nav)
        section == "logs" -> Logs(nav)
        section == "devices" -> Devices(nav)
        section == "plugins" -> Plugins(nav)
        section == "web" -> WebDashboard(nav)
        else -> FormScreen("Admin", nav) { item { Text("Unknown section") } }
    }
}

@Composable
private fun SessionDetail(id: String, nav: NavHostController) {
    val c = AppState.client ?: return
    var s by remember { mutableStateOf<AdminSession?>(null) }
    var status by remember { mutableStateOf<String?>(null) }
    var msg by remember { mutableStateOf("") }
    val scope = rememberCoroutineScope()
    LaunchedEffect(id) { while (true) { s = runCatching { c.adminSessions().firstOrNull { it.id == id } }.getOrNull() ?: s; delay(3000) } }
    val x = s
    FormScreen(x?.userName ?: "Session", nav) {
        if (x == null) { item { CircularProgressIndicator() }; return@FormScreen }
        item { SessionRow(x) {} }
        status?.let { item { Text(it, color = Hue.secondaryText) } }
        item {
            FormSection("Playback") {
                FormRow("Device", value = listOfNotNull(x.deviceName, x.client).joinToString(" · "))
                FormDivider(); FormRow("Address", value = (x.remoteEndPoint ?: "") + if (x.isLocal) " (home)" else "")
                FormDivider(); FormRow("Method", value = x.method)
                x.transcodingInfo?.let { t ->
                    FormDivider(); FormRow("Converting to", value = listOfNotNull(t.videoCodec?.uppercase(), t.audioCodec?.uppercase(), t.container).joinToString(" · "))
                    t.bitrate?.let { FormDivider(); FormRow("Bitrate", value = "%.1f Mbps".format(it / 1_000_000.0)) }
                    t.hardwareAccelerationType?.let { FormDivider(); FormRow("Hardware acceleration", value = it) }
                    t.completionPercentage?.let { FormDivider(); FormRow("Converted so far", value = "${it.toInt()}%") }
                    if (!t.transcodeReasons.isNullOrEmpty()) { FormDivider(); FormRow("Why it's converting", t.transcodeReasons.joinToString(", ") { r -> r.replace(Regex("([a-z])([A-Z])"), "$1 $2") }) }
                }
            }
        }
        if (x.supportsRemoteControl != false) item {
            FormSection("Control") {
                FormRow(if (x.isPaused) "Resume" else "Pause", icon = if (x.isPaused) Icons.Filled.PlayArrow else Icons.Filled.Pause, onClick = {
                    scope.launch { status = runCatching { c.sessionCommand(x.id, if (x.isPaused) "Unpause" else "Pause"); "Done." }.getOrElse { "That device didn't respond." } } })
                FormDivider()
                FormRow("Stop", icon = Icons.Filled.Stop, iconTint = Hue.coral, onClick = { scope.launch { status = runCatching { c.sessionCommand(x.id, "Stop"); "Stopped." }.getOrElse { "That device didn't respond." } } })
                FormDivider()
                FormField("Send a message to their screen", msg, { msg = it }, "Type a message")
                FormRow("Send", icon = Icons.AutoMirrored.Filled.Message, onClick = {
                    val t = msg.trim(); if (t.isEmpty()) return@FormRow
                    scope.launch { status = runCatching { c.sendMessage(x.id, "Message", t); msg = ""; "Sent." }.getOrElse { "Couldn't send that message." } } })
            }
        }
    }
}

@Composable
private fun Libraries(nav: NavHostController) {
    val c = AppState.client ?: return
    var libs by remember { mutableStateOf<List<VirtualFolder>>(emptyList()) }
    var status by remember { mutableStateOf<String?>(null) }
    var confirm by remember { mutableStateOf<VirtualFolder?>(null) }
    val scope = rememberCoroutineScope()
    LaunchedEffect(Unit) { while (true) { libs = runCatching { c.adminLibraries() }.getOrDefault(libs); delay(4000) } }
    FormScreen("Libraries", nav) {
        status?.let { item { Text(it, color = Hue.secondaryText) } }
        items(libs, key = { it.itemId ?: it.name ?: "" }) { lib ->
            FormSection {
                FormRow(lib.name ?: "Library", lib.locations?.joinToString("\n"), Icons.Filled.Folder, Hue.violet, value = lib.collectionType ?: "")
                lib.refreshProgress?.takeIf { lib.refreshStatus == "Active" }?.let { p ->
                    LinearProgressIndicator({ (p / 100).toFloat() }, Modifier.fillMaxWidth().padding(horizontal = 16.dp), color = Hue.violet)
                    Text("Scanning… ${p.toInt()}%", style = MaterialTheme.typography.bodySmall, modifier = Modifier.padding(horizontal = 16.dp))
                }
                FormDivider()
                FormRow("Scan for new files", icon = Icons.Filled.Sync, onClick = { lib.itemId?.let { id -> scope.launch { status = runCatching { c.adminRefresh(id, false); "Scanning ${lib.name}" }.getOrElse { it.message } } } })
                FormDivider()
                FormRow("Replace all metadata", icon = Icons.Filled.AutoFixHigh, iconTint = Hue.amber, onClick = { confirm = lib })
            }
        }
    }
    confirm?.let { lib ->
        AlertDialog({ confirm = null }, confirmButton = { TextButton({ confirm = null; lib.itemId?.let { id -> scope.launch { status = runCatching { c.adminRefresh(id, true); "Refreshing everything in ${lib.name}" }.getOrElse { it.message } } } }) { Text("Replace") } },
            dismissButton = { TextButton({ confirm = null }) { Text("Cancel") } }, title = { Text("Replace all metadata in ${lib.name}?") },
            text = { Text("Re-downloads titles, descriptions and artwork for every item. This can take a long time on big libraries.") })
    }
}

@Composable
private fun Users(nav: NavHostController) {
    val c = AppState.client ?: return
    var users by remember { mutableStateOf<List<AdminUser>>(emptyList()) }
    LaunchedEffect(Unit) { users = runCatching { c.adminUsers() }.getOrDefault(emptyList()) }
    FormScreen("Users", nav) {
        item {
            FormSection {
                users.forEachIndexed { i, u ->
                    if (i > 0) FormDivider()
                    FormRow(u.name ?: "User", listOfNotNull(
                        when { u.policy?.isAdministrator == true -> "Admin"; u.policy?.enableRemoteControlOfOtherUsers == true -> "Parent"; else -> null },
                        if (u.policy?.isDisabled == true) "Can't sign in" else null, u.lastActive?.let { "Active ${ago(it)}" }).joinToString(" · ").ifEmpty { null },
                        chevron = true, onClick = { nav.navigate("admin/user/${u.id}") },
                        trailing = null)
                }
            }
        }
    }
}

/** One person: what they're allowed to do, the Parent switch, their remote limit and their Huefin defaults. */
@Composable
fun AdminUserScreen(id: String, nav: NavHostController) {
    val c = AppState.client ?: return
    var user by remember { mutableStateOf<AdminUser?>(null) }
    var status by remember { mutableStateOf<String?>(null) }
    var defaults by remember { mutableStateOf(ServerDefaults.Values()) }
    val scope = rememberCoroutineScope()
    LaunchedEffect(id) { user = runCatching { c.adminUser(id) }.getOrNull(); defaults = ServerDefaults.read(c, id).first }
    val u = user
    fun change(key: String, v: JsonPrimitive) {
        scope.launch {
            runCatching { c.adminUpdatePolicy(id, mapOf(key to v)); user = c.adminUser(id) }.onSuccess { status = "Saved." }.onFailure { status = "Couldn't save: ${it.message}" }
        }
    }
    FormScreen(u?.name ?: "User", nav) {
        if (u == null) { item { CircularProgressIndicator() }; return@FormScreen }
        val p = u.policy ?: AdminUserPolicy()
        item {
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                RemoteImage(c.userImageURL(u.id), Modifier.size(84.dp).clip(CircleShape))
                Text(u.name ?: "", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold, modifier = Modifier.padding(top = 8.dp))
                u.lastActive?.let { Text("Last active ${ago(it)}", style = MaterialTheme.typography.bodySmall, color = Hue.secondaryText) }
            }
        }
        status?.let { item { Text(it, color = Hue.secondaryText) } }
        item {
            FormSection("Access", "Turning off transcoding means this person only gets files their device can play as-is. Changes apply right away.") {
                FormToggle("Allow sign-in", p.isDisabled != true) { change("IsDisabled", JsonPrimitive(!it)) }; FormDivider()
                FormToggle("Allow access away from home", p.enableRemoteAccess == true) { change("EnableRemoteAccess", JsonPrimitive(it)) }; FormDivider()
                FormToggle("Allow downloads", p.enableContentDownloading == true) { change("EnableContentDownloading", JsonPrimitive(it)) }; FormDivider()
                FormToggle("Allow video transcoding", p.enableVideoPlaybackTranscoding == true) { change("EnableVideoPlaybackTranscoding", JsonPrimitive(it)) }; FormDivider()
                FormToggle("Allow Live TV", p.enableLiveTvAccess == true) { change("EnableLiveTvAccess", JsonPrimitive(it)) }
            }
        }
        item {
            FormSection("Family", "Parents get Family in Huefin: they can see what everyone is watching, pause or stop it, and send a message to their screen (\"Bedtime in 10 minutes\"). Admins always have it.") {
                FormToggle("Parent", p.enableRemoteControlOfOtherUsers == true, enabled = p.isAdministrator != true) { change("EnableRemoteControlOfOtherUsers", JsonPrimitive(it)) }
            }
        }
        item {
            FormSection("Away from home", "The most this person can stream when they're not on your home Wi‑Fi. Anything bigger is shrunk to fit. 8 Mbps looks great on a 1080p TV; 4K originals run 25–80 Mbps.") {
                FormPicker("Remote streaming limit", p.remoteClientBitrateLimit ?: 0, listOf(0 to "No limit") + listOf(40, 20, 15, 12, 10, 8, 6, 4, 3, 2).map { it * 1_000_000 to "$it Mbps" }) {
                    change("RemoteClientBitrateLimit", JsonPrimitive(it))
                }
            }
        }
        item {
            FormSection("Huefin defaults", "Set up Huefin for them from here. They can still change things on their phone afterward.") {
                FormPicker("Streaming quality", defaults.maxBitrate ?: 0, listOf(0 to "Their choice") + listOf(200, 40, 20, 10, 8, 4).map { it * 1_000_000 to if (it == 200) "Maximum" else "$it Mbps" }) {
                    defaults = defaults.copy(maxBitrate = it.takeIf { v -> v > 0 }) }
                FormDivider()
                FormPicker("Skip intros", defaults.autoSkipIntro, listOf(null to "Their choice", true to "Automatically", false to "Ask (button)")) { defaults = defaults.copy(autoSkipIntro = it) }
                FormDivider()
                FormPicker("Credits", defaults.autoSkipCredits, listOf(null to "Their choice", true to "Go straight to next episode", false to "Show countdown")) { defaults = defaults.copy(autoSkipCredits = it) }
                FormDivider()
                FormPicker("Player", defaults.engine, listOf<Pair<String?, String>>(null to "Their choice", "auto" to "Automatic", "apple" to "Built-in player only", "prism" to "Huefin Engine always")) {
                    defaults = defaults.copy(engine = it) }
                FormDivider()
                FormRow("Send to their Huefin", icon = Icons.AutoMirrored.Filled.Send, onClick = {
                    scope.launch { status = runCatching { ServerDefaults.write(c, id, defaults); "Saved. Their Huefin picks it up next time it opens." }.getOrElse { "Couldn't save: ${it.message}" } }
                })
            }
        }
    }
}

@Composable
private fun Activity(nav: NavHostController) {
    val c = AppState.client ?: return
    val entries = remember { mutableStateListOf<ActivityEntry>() }
    var total by remember { mutableIntStateOf(Int.MAX_VALUE) }
    var loading by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    fun more() { if (loading || entries.size >= total) return; loading = true
        scope.launch { runCatching { c.adminActivity(entries.size) }.onSuccess { entries += it.items; total = it.totalRecordCount ?: entries.size }.onFailure { total = entries.size }; loading = false } }
    LaunchedEffect(Unit) { more() }
    FormScreen("Activity", nav) {
        items(entries, key = { it.id }) { e ->
            if (e === entries.last()) LaunchedEffect(e.id) { more() }
            Row(Modifier.widthIn(max = 720.dp).fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(Hue.card).padding(14.dp)) {
                Box(Modifier.padding(top = 6.dp).size(8.dp).clip(CircleShape).background(if (e.severity == "Error") Hue.coral else if (e.severity == "Warning") Hue.amber else Hue.mint))
                Column(Modifier.padding(start = 12.dp)) {
                    Text(e.name ?: "", fontWeight = FontWeight.Medium)
                    (e.shortOverview ?: e.overview)?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = Hue.secondaryText, maxLines = 3) }
                    Text(e.date?.let(::parseJellyfinDate)?.let(::ago) ?: "", style = MaterialTheme.typography.labelSmall, color = Hue.secondaryText)
                }
            }
        }
        if (loading) item { CircularProgressIndicator() }
    }
}

@Composable
private fun Tasks(nav: NavHostController) {
    val c = AppState.client ?: return
    var tasks by remember { mutableStateOf<List<ScheduledTask>>(emptyList()) }
    val scope = rememberCoroutineScope()
    LaunchedEffect(Unit) { while (true) { tasks = runCatching { c.adminTasks() }.getOrDefault(tasks); delay(3000) } }
    FormScreen("Scheduled Tasks", nav) {
        tasks.groupBy { it.category ?: "Other" }.toSortedMap().forEach { (cat, list) ->
            item(key = cat) {
                FormSection(cat) {
                    list.sortedBy { it.name }.forEachIndexed { i, t ->
                        if (i > 0) FormDivider()
                        FormRow(t.name ?: "Task", when {
                            t.isRunning -> "Running · ${(t.currentProgressPercentage ?: 0.0).toInt()}%"
                            t.lastExecutionResult?.endTimeUtc != null -> "${t.lastExecutionResult.status ?: ""} · ${ago(parseJellyfinDate(t.lastExecutionResult.endTimeUtc))}"
                            else -> "Never run" }) {
                            IconButton({ scope.launch { runCatching { if (t.isRunning) c.adminStopTask(t.id) else c.adminStartTask(t.id) }; tasks = runCatching { c.adminTasks() }.getOrDefault(tasks) } }) {
                                Icon(if (t.isRunning) Icons.Filled.Stop else Icons.Filled.PlayArrow, if (t.isRunning) "Stop" else "Run", tint = LocalHue.current)
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun Logs(nav: NavHostController) {
    val c = AppState.client ?: return
    var logs by remember { mutableStateOf<List<LogFile>>(emptyList()) }
    LaunchedEffect(Unit) { logs = runCatching { c.adminLogs().sortedByDescending { it.dateModified } }.getOrDefault(emptyList()) }
    FormScreen("Logs", nav) {
        item {
            FormSection {
                logs.forEachIndexed { i, l ->
                    if (i > 0) FormDivider()
                    FormRow(l.name, listOfNotNull(l.size?.let(::formatBytes), l.dateModified?.let(::parseJellyfinDate)?.let(stamp::format)).joinToString(" · "), chevron = true,
                        onClick = { nav.navigate("admin/log:" + java.net.URLEncoder.encode(l.name, "UTF-8")) })
                }
            }
        }
    }
}

@Composable
private fun LogViewer(encoded: String, nav: NavHostController) {
    val c = AppState.client ?: return
    val name = java.net.URLDecoder.decode(encoded, "UTF-8")
    var text by remember { mutableStateOf<String?>(null) }
    var errorsOnly by remember { mutableStateOf(false) }
    LaunchedEffect(name) { text = runCatching { c.adminLog(name) }.getOrElse { "Couldn't load: ${it.message}" } }
    FormScreen(name, nav, actions = { TextButton({ errorsOnly = !errorsOnly }) { Text(if (errorsOnly) "All lines" else "Errors only") } }) {
        item {
            val t = text
            if (t == null) CircularProgressIndicator()
            else SelectionContainer {
                val lines = t.lines().takeLast(3000).let { l -> if (errorsOnly) l.filter { it.contains("[ERR]") || it.contains("[WRN]") || it.contains("error", true) } else l }
                Text(lines.joinToString("\n"), fontFamily = FontFamily.Monospace, fontSize = 11.sp, lineHeight = 15.sp,
                    modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(Hue.card).padding(12.dp))
            }
        }
    }
}

@Composable
private fun Devices(nav: NavHostController) {
    val c = AppState.client ?: return
    var devices by remember { mutableStateOf<List<DeviceEntry>>(emptyList()) }
    var confirm by remember { mutableStateOf<DeviceEntry?>(null) }
    val scope = rememberCoroutineScope()
    suspend fun load() { devices = runCatching { c.adminDevices().sortedByDescending { it.dateLastActivity } }.getOrDefault(emptyList()) }
    LaunchedEffect(Unit) { load() }
    FormScreen("Devices", nav) {
        item {
            FormSection(footer = "Removing a device signs it out.") {
                devices.forEachIndexed { i, d ->
                    if (i > 0) FormDivider()
                    FormRow(d.customName?.ifEmpty { null } ?: d.name ?: "Device",
                        listOfNotNull(d.appName?.let { a -> a + (d.appVersion?.let { " $it" } ?: "") }, d.lastUserName, d.dateLastActivity?.let(::parseJellyfinDate)?.let(::ago)).joinToString(" · ")) {
                        IconButton({ confirm = d }) { Icon(Icons.Filled.Delete, "Sign out this device", tint = Hue.secondaryText) }
                    }
                }
            }
        }
    }
    confirm?.let { d ->
        AlertDialog({ confirm = null }, confirmButton = { TextButton({ confirm = null; scope.launch { runCatching { c.adminDeleteDevice(d.id) }; load() } }) { Text("Sign out", color = Hue.coral) } },
            dismissButton = { TextButton({ confirm = null }) { Text("Cancel") } }, title = { Text("Sign out ${d.name ?: "this device"}?") })
    }
}

@Composable
private fun Plugins(nav: NavHostController) {
    val c = AppState.client ?: return
    var plugins by remember { mutableStateOf<List<PluginInfo>>(emptyList()) }
    LaunchedEffect(Unit) { plugins = runCatching { c.adminPlugins().sortedBy { it.name } }.getOrDefault(emptyList()) }
    FormScreen("Plugins", nav) {
        item {
            FormSection {
                plugins.forEachIndexed { i, p ->
                    if (i > 0) FormDivider()
                    FormRow(p.name ?: "Plugin", listOfNotNull(p.version?.let { "Version $it" }, p.status?.takeIf { it != "Active" }).joinToString(" · "))
                }
            }
        }
    }
}

/** Jellyfin's own dashboard, opened in your web browser. */
@Composable
private fun WebDashboard(nav: NavHostController) {
    val c = AppState.client ?: return
    val url = c.baseUrl.trimEnd('/') + "/web/#/dashboard"
    fun open() { runCatching { java.awt.Desktop.getDesktop().browse(java.net.URI(url)) } }
    LaunchedEffect(Unit) { open() }
    FormScreen("Jellyfin Dashboard", nav) {
        item {
            FormSection(footer = "Opened in your web browser. Sign in there with your Jellyfin account if it asks.") {
                FormRow("Open the Jellyfin Dashboard again", url, Icons.Filled.Public, Hue.coral, chevron = true, onClick = { open() })
            }
        }
    }
}
