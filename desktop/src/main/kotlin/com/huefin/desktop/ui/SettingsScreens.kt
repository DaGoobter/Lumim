package com.huefin.desktop.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Logout
import androidx.compose.material.icons.automirrored.filled.Message
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.huefin.desktop.admin.AdminSession
import com.huefin.desktop.admin.canControlOthers
import com.huefin.desktop.admin.controllableSessions
import com.huefin.desktop.admin.isAdministrator
import com.huefin.desktop.admin.sendMessage
import com.huefin.desktop.admin.sessionCommand
import com.huefin.desktop.core.AppState
import com.huefin.desktop.core.JellyfinClient
import com.huefin.desktop.core.Prefs
import com.huefin.desktop.core.SubtitleMode
import com.huefin.desktop.core.TrackPrefs
import com.huefin.desktop.player.DJVoice
import kotlinx.coroutines.launch

// MARK: Settings

@Composable
fun SettingsScreen(nav: NavHostController) {
    val ctx = LocalContext.current
    val c = AppState.client
    val scope = rememberCoroutineScope()
    var isAdmin by remember { mutableStateOf(false) }
    var canFamily by remember { mutableStateOf(false) }
    var showAdd by remember { mutableStateOf(false) }
    var remote by remember { mutableStateOf(AppState.session?.serverURL ?: "") }
    var local by remember { mutableStateOf(if (AppState.session?.localURLIsManual == true) AppState.session?.localURL ?: "" else "") }
    var tick by remember { mutableIntStateOf(0) }   // bumps to re-read Prefs after a change
    fun set(key: String, v: Any?) { Prefs.set(key, v); tick++ }
    LaunchedEffect(AppState.session?.key) { isAdmin = c?.isAdministrator() == true; canFamily = c?.canControlOthers() == true }
    if (showAdd) { LoginScreen(adding = true) { showAdd = false }; return }
    key(tick) {
    FormScreen("Settings", nav) {
        if (isAdmin) item {
            FormSection {
                FormRow("Server Dashboard", "Now playing, stats, libraries, users, logs", Icons.Filled.Dns, Hue.violet, chevron = true, onClick = { nav.navigate("admin") })
            }
        }
        if (canFamily) item {
            FormSection {
                FormRow("Family", "See what everyone's watching, pause it, send a message", Icons.Filled.FamilyRestroom, Hue.coral, chevron = true, onClick = { nav.navigate("family") })
            }
        }
        item {
            FormSection("Accounts", "Tap to switch. Quick Connect approves a code shown on a TV or another device so it signs in as you, no password typing.") {
                AppState.accounts.forEach { a ->
                    val current = a.key == AppState.session?.key
                    var menu by remember { mutableStateOf(false) }
                    Box {
                        FormRow(a.userName, a.serverName ?: a.serverURL, onClick = { if (!current) AppState.switchTo(a) else menu = true },
                            trailing = {
                                if (current) Icon(Icons.Filled.CheckCircle, "Current", tint = LocalHue.current)
                                IconButton({ menu = true }) { Icon(Icons.Filled.MoreVert, "More") }
                            })
                        DropdownMenu(menu, { menu = false }) { DropdownMenuItem({ Text("Sign out", color = Hue.coral) }, { menu = false; scope.launch { AppState.remove(a) } }) }
                    }
                    FormDivider()
                }
                FormRow("Add user or server", icon = Icons.Filled.PersonAdd, onClick = { showAdd = true }); FormDivider()
                FormRow("Quick Connect", icon = Icons.Filled.QrCode, iconTint = Hue.mint, chevron = true, onClick = { nav.navigate("quickconnect") }); FormDivider()
                FormRow("Requests", icon = Icons.Filled.AddToQueue, iconTint = Hue.violet, chevron = true, onClick = { nav.navigate("requests") }); FormDivider()
                FormToggle("Ask who's watching on launch", Prefs.bool(Prefs.Keys.askWho, true)) { set(Prefs.Keys.askWho, it) }
            }
        }
        item {
            FormSection("Connection", "At home Huefin talks to your server directly over Wi‑Fi (faster, full quality, no internet needed); everywhere else it uses your remote address. It switches automatically. Leave the home address empty to auto-detect it.") {
                FormRow("Using", value = if (AppState.route == AppState.Route.Local) "Home network" else "Remote address")
                FormDivider(); FormRow("Home address check", value = AppState.localStatus)
                FormDivider(); FormToggle("Use home network when available", AppState.preferLocal) { AppState.preferLocal = it; AppState.persistSettings(); scope.launch { AppState.refreshRoute() } }
                FormDivider(); FormField("Remote address", remote, { remote = it })
                FormField("Home network address", local, { local = it }, "Auto-detect")
                FormRow("Save & reconnect", icon = Icons.Filled.Sync, onClick = { AppState.setLocalURL(local) })
                FormDivider(); FormRow("Check connection now", icon = Icons.Filled.NetworkCheck, iconTint = Hue.sky, onClick = { scope.launch { AppState.refreshRoute() } })
            }
        }
        item {
            FormSection("Subtitles", "How text subtitles look in the Huefin Engine. Styled anime subtitles keep their own look. Takes effect the next time a video starts.") {
                val st = com.huefin.desktop.core.SubtitleStyle
                FormPicker("Size", st.size, st.sizes) { st.size = it; tick++ }
                FormDivider(); FormPicker("Color", st.color, st.colors) { st.color = it; tick++ }
                FormDivider(); FormPicker("Background", st.background, st.backgrounds) { st.background = it; tick++ }
                FormDivider(); FormPicker("Position", st.position, st.positions) { st.position = it; tick++ }
            }
        }
        item {
            FormSection("Playback", if (AppState.autoQuality) "Huefin tests the connection to your server when it opens and whenever your network changes. When it's fast enough, files play untouched (full quality, HDR); when it isn't, the server sends a lighter stream so playback doesn't stutter. Downloads always use full quality."
                                    else "Keep this at Maximum for untouched Direct Play. Lower it only if remote playback stutters; the server will then re-encode, which loses Dolby Vision. Downloads always use full quality.") {
                FormToggle("Automatic quality", AppState.autoQuality) { AppState.autoQuality = it; AppState.persistSettings(); tick++ }
                FormDivider(); FormRow("Connection", subtitle = AppState.speedStatus, icon = Icons.Filled.NetworkCheck, iconTint = Hue.sky, value = "Test again", onClick = { AppState.checkSpeed(force = true) })
                FormDivider(); FormPicker(if (AppState.autoQuality) "Never more than" else "Max streaming quality", AppState.maxBitrate, listOf(200, 120, 80, 40, 20, 10, 8, 4, 2).map { it * 1_000_000 to if (it == 200) "Maximum" else "$it Mbps" }) {
                    AppState.maxBitrate = it; AppState.persistSettings(); tick++ }
            }
        }
        item {
            FormSection("Audio & Subtitles", "Applied automatically when something starts playing; change tracks anytime from the player. Picture-based subtitles are only used when you pick them yourself.") {
                FormPicker("Audio language", TrackPrefs.audioLanguage, listOf("" to "File default") + TrackPrefs.languages) { TrackPrefs.audioLanguage = it; tick++ }
                FormDivider()
                FormPicker("Subtitles", TrackPrefs.subtitleMode, SubtitleMode.entries.map { it to it.label }) { TrackPrefs.subtitleMode = it; tick++ }
                FormDivider()
                FormPicker("Subtitle language", TrackPrefs.subtitleLanguage, TrackPrefs.languages) { TrackPrefs.subtitleLanguage = it; tick++ }
            }
        }
        item {
            FormSection("Huefin Engine", "HDR10, HDR10+, HLG and Dolby Vision show as real HDR when Windows HDR is on (Settings → System → Display → Use HDR), and are tone-mapped properly when it's off. Dolby Vision is reshaped from its own metadata, so Profile 5 shows its true colours.") {
                FormToggle("Send Dolby and DTS untouched to my receiver", Prefs.bool(Prefs.Keys.passthrough)) { set(Prefs.Keys.passthrough, it) }
            }
        }
        item {
            FormSection("Skipping", "Auto-skip shows a \"Watch it\" button during the wait so you can keep an intro you like. Needs intro/credits markers on the server (Intro Skipper plugin).") {
                FormToggle("Skip intros automatically", Prefs.autoSkipIntro) { set(Prefs.Keys.autoIntro, it) }; FormDivider()
                FormToggle("Skip recaps automatically", Prefs.autoSkipRecap) { set(Prefs.Keys.autoRecap, it) }; FormDivider()
                FormToggle("Skip credits to the next episode", Prefs.autoSkipCredits) { set(Prefs.Keys.autoCredits, it) }; FormDivider()
                if (Prefs.autoSkipIntro || Prefs.autoSkipRecap) { FormPicker("Wait before skipping", Prefs.autoSkipDelay, listOf(0 to "Skip right away", 3 to "3 seconds", 5 to "5 seconds", 10 to "10 seconds")) { set(Prefs.Keys.delay, it) }; FormDivider() }
                FormPicker("Jump back", Prefs.skipBack, listOf(5, 10, 15, 30).map { it to "$it seconds" }) { set(Prefs.Keys.back, it) }; FormDivider()
                FormPicker("Jump forward", Prefs.skipForward, listOf(5, 10, 15, 30).map { it to "$it seconds" }) { set(Prefs.Keys.forward, it) }
            }
        }
        item { DJVoiceSection() }
        item {
            FormSection(footer = "Huefin ${JellyfinClient.VERSION} for Windows · Downloads stay on this PC after signing out.") {
                FormRow("Sign Out", icon = Icons.AutoMirrored.Filled.Logout, iconTint = Hue.coral, titleColor = Hue.coral, onClick = { scope.launch { AppState.logout() } })
            }
        }
    }
    }

}

@Composable
private fun DJVoiceSection() {
    var engine by remember { mutableStateOf(DJVoice.engine) }
    var kokoro by remember { mutableStateOf(DJVoice.kokoroURL.ifEmpty { AppState.session?.localURL?.substringAfter("://")?.substringBefore("/")?.substringBefore(":")?.let { "$it:8880" } ?: "" }) }
    var kokoroRemote by remember { mutableStateOf(DJVoice.kokoroRemoteURL) }
    var kokoroVoice by remember { mutableStateOf(DJVoice.kokoroVoice) }
    var kokoroSpeed by remember { mutableFloatStateOf(DJVoice.kokoroSpeed) }
    var openAIKey by remember { mutableStateOf(DJVoice.openAIKey) }
    var openAIVoice by remember { mutableStateOf(DJVoice.openAIVoice) }
    var elevenKey by remember { mutableStateOf(DJVoice.elevenKey) }
    var elevenVoice by remember { mutableStateOf(DJVoice.elevenVoice) }
    var testing by remember { mutableStateOf(false) }
    var result by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    fun save() {
        DJVoice.engine = engine; DJVoice.kokoroURL = kokoro; DJVoice.kokoroRemoteURL = kokoroRemote; DJVoice.kokoroVoice = kokoroVoice
        DJVoice.kokoroSpeed = kokoroSpeed; DJVoice.openAIKey = openAIKey; DJVoice.openAIVoice = openAIVoice; DJVoice.elevenKey = elevenKey; DJVoice.elevenVoice = elevenVoice
    }
    DisposableEffect(Unit) { onDispose { save() } }
    val footer = when (engine) {
        DJVoice.Engine.Kokoro -> "Free and private: a natural-sounding voice running on your own PC. Run the Kokoro installer on your PC once, then enter your PC's address above (port 8880). Michael + Puck or Heart + Bella sound most like radio."
        DJVoice.Engine.OpenAI -> "Very human voices that act like a radio DJ. Uses your OpenAI API key; DJ intros cost roughly a cent per few minutes of talking."
        DJVoice.Engine.ElevenLabs -> "The most lifelike voices. ElevenLabs has a free monthly allowance that easily covers DJ intros."
        DJVoice.Engine.Phone -> "Uses Windows' built-in speech. More voices can be added in Windows Settings → Time & language → Speech."
    }
    FormSection("DJ Voice", footer) {
        FormPicker("Voice", engine, DJVoice.Engine.entries.map { it to it.label }) { engine = it; save() }
        when (engine) {
            DJVoice.Engine.Kokoro -> {
                FormField("Kokoro address", kokoro, { kokoro = it }, "192.168.1.20:8880")
                FormField("Away-from-home address (optional)", kokoroRemote, { kokoroRemote = it })
                FormPicker("Kokoro voice", kokoroVoice, listOf("af_heart" to "Heart", "af_bella" to "Bella", "af_nicole" to "Nicole", "af_sky" to "Sky", "af_nova" to "Nova",
                    "am_michael" to "Michael", "am_puck" to "Puck", "am_fenrir" to "Fenrir", "am_adam" to "Adam", "bf_emma" to "Emma (UK)", "bm_george" to "George (UK)")) { kokoroVoice = it }
                Column(Modifier.padding(horizontal = 16.dp)) {
                    Text("Talking pace · ${"%.2f".format(kokoroSpeed)}×", style = MaterialTheme.typography.labelMedium, color = Hue.secondaryText)
                    Slider(kokoroSpeed, { kokoroSpeed = it }, valueRange = 0.8f..1.4f)
                }
            }
            DJVoice.Engine.OpenAI -> {
                FormField("OpenAI API key", openAIKey, { openAIKey = it }, password = true)
                FormPicker("OpenAI voice", openAIVoice, listOf("coral", "ash", "ballad", "sage", "verse", "nova", "shimmer", "echo", "onyx", "alloy", "fable").map { it to it.replaceFirstChar(Char::uppercase) }) { openAIVoice = it }
            }
            DJVoice.Engine.ElevenLabs -> {
                FormField("ElevenLabs API key", elevenKey, { elevenKey = it }, password = true)
                FormField("Voice ID (from your ElevenLabs voice library)", elevenVoice, { elevenVoice = it })
            }
            DJVoice.Engine.Phone -> {}
        }
        FormDivider()
        FormRow("Test voice", icon = Icons.Filled.RecordVoiceOver, onClick = {
            if (testing) return@FormRow
            save(); testing = true; result = null
            scope.launch {
                DJVoice.say("Hey, it's your Huefin DJ.${com.huefin.desktop.player.Stations.breath}Sounding good?")
                result = DJVoice.lastError?.let { "Fell back to the Windows voice: $it" } ?: "Sounds good."
                testing = false
            }
        }) { if (testing) CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp) }
        result?.let { Text(it, Modifier.padding(16.dp, 0.dp, 16.dp, 12.dp), style = MaterialTheme.typography.bodySmall, color = Hue.secondaryText) }
    }
}

// MARK: Who's watching

/** Pick who's watching (accounts on this device). Shown on launch when more than one person uses the device. */
@Composable
fun ProfilePickerDialog(onDismiss: () -> Unit) {
    var adding by remember { mutableStateOf(false) }
    run {
        Surface(Modifier.fillMaxSize(), color = Hue.night) {
            if (adding) LoginScreen(adding = true) { adding = false; onDismiss() }
            else Column(Modifier.fillMaxSize().systemBarsPadding().padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
                Text("Who's watching?", style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.ExtraBold)
                Spacer(Modifier.height(28.dp))
                LazyVerticalGrid(GridCells.Adaptive(130.dp), Modifier.widthIn(max = 720.dp), horizontalArrangement = Arrangement.spacedBy(18.dp), verticalArrangement = Arrangement.spacedBy(22.dp)) {
                    items(AppState.accounts, key = { it.key }) { a ->
                        val hues = listOf(Hue.coral, Hue.sky, Hue.amber, Hue.mint, Hue.violet)
                        val hue = hues[kotlin.math.abs(a.key.hashCode()) % hues.size]
                        Column(Modifier.clip(RoundedCornerShape(18.dp)).clickable { AppState.switchTo(a); onDismiss() }.padding(8.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                            Box(Modifier.size(96.dp).clip(RoundedCornerShape(26.dp)).background(hue)
                                .then(if (a.key == AppState.session?.key) Modifier.border(3.dp, Color.White, RoundedCornerShape(26.dp)) else Modifier), Alignment.Center) {
                                Text(a.userName.take(1).uppercase(), fontSize = 40.sp, fontWeight = FontWeight.Black, color = Hue.ink)
                                RemoteImage(JellyfinClient(a.serverURL, a.token, a.userId).userImageURL(a.userId), Modifier.fillMaxSize())
                            }
                            Text(a.userName, fontWeight = FontWeight.Bold, modifier = Modifier.padding(top = 8.dp))
                            Text(a.serverName ?: "", style = MaterialTheme.typography.labelSmall, color = Hue.secondaryText, maxLines = 1)
                        }
                    }
                    item {
                        Column(Modifier.clip(RoundedCornerShape(18.dp)).clickable { adding = true }.padding(8.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                            Box(Modifier.size(96.dp).clip(RoundedCornerShape(26.dp)).border(2.dp, Hue.hairline, RoundedCornerShape(26.dp)), Alignment.Center) { Icon(Icons.Filled.Add, null, Modifier.size(40.dp)) }
                            Text("Add", fontWeight = FontWeight.Bold, modifier = Modifier.padding(top = 8.dp))
                        }
                    }
                }
                Spacer(Modifier.height(24.dp))
                TextButton(onDismiss) { Text("Keep going as ${AppState.session?.userName ?: ""}") }
            }
        }
    }
}

// MARK: Quick Connect

@Composable
fun QuickConnectApproveScreen(nav: NavHostController) {
    var code by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var status by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    SectionHue(Hue.mint) {
        FormScreen("Quick Connect", nav) {
            item {
                Column(Modifier.widthIn(max = 480.dp).padding(top = 24.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(14.dp)) {
                    Icon(Icons.Filled.QrCode2, null, Modifier.size(64.dp), tint = Hue.mint)
                    Text("Approve a sign-in", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold)
                    Text("On the TV or other device, choose Quick Connect. Type the code it shows here to sign it in as you.", color = Hue.secondaryText, textAlign = TextAlign.Center)
                    OutlinedTextField(code, { code = it.filter(Char::isDigit).take(6) }, Modifier.width(220.dp), singleLine = true,
                        textStyle = MaterialTheme.typography.headlineMedium.copy(textAlign = TextAlign.Center, letterSpacing = 6.sp),
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.NumberPassword), placeholder = { Text("000000") })
                    HueButton({
                        busy = true; status = null
                        scope.launch {
                            status = runCatching { AppState.client?.quickConnectAuthorize(code); "Approved. The other device is signing in now." }
                                .getOrElse { "That code didn't work. Check it, or make sure Quick Connect is turned on in the server's settings." }
                            busy = false; code = ""
                        }
                    }, enabled = code.length == 6 && !busy) { Text("Approve") }
                    status?.let { Text(it, color = Hue.secondaryText, textAlign = TextAlign.Center) }
                }
            }
        }
    }
}

// MARK: Family

private val presets = listOf("Bedtime in 10 minutes 🌙", "Dinner's ready! 🍽️", "Last episode, then off 📺", "Homework first ✏️", "Time to take a break 👋")

/** See what everyone is watching, pause or stop it, and send a message to their screen. Admins and parents only (the server enforces it too). */
@Composable
fun FamilyScreen(nav: NavHostController) {
    val c = AppState.client ?: return
    var sessions by remember { mutableStateOf<List<AdminSession>>(emptyList()) }
    var loading by remember { mutableStateOf(true) }
    var status by remember { mutableStateOf<String?>(null) }
    var target by remember { mutableStateOf<AdminSession?>(null) }
    val scope = rememberCoroutineScope()
    suspend fun load() {
        runCatching { c.controllableSessions().filter { it.deviceId != JellyfinClient.deviceId } }.onSuccess { sessions = it }.onFailure { status = "Couldn't load devices: ${it.message}" }
        loading = false
    }
    LaunchedEffect(Unit) { while (true) { load(); kotlinx.coroutines.delay(5000) } }
    fun command(s: AdminSession, cmd: String) = scope.launch {
        status = runCatching { c.sessionCommand(s.id, cmd); "${when (cmd) { "Stop" -> "Stopped"; "Pause" -> "Paused"; else -> "Resumed" }} on ${s.userName ?: "their"} ${s.deviceName ?: "device"}." }
            .getOrElse { "That device didn't respond." }
        load()
    }
    val watching = sessions.filter { it.nowPlayingItem != null }
    val idle = sessions.filter { it.nowPlayingItem == null && it.supportsRemoteControl == true }
    SectionHue(Hue.coral) {
        FormScreen("Family", nav) {
            status?.let { item { Text(it, color = Hue.secondaryText) } }
            item {
                FormSection("Watching now") {
                    if (loading && sessions.isEmpty()) Box(Modifier.fillMaxWidth().padding(16.dp), Alignment.Center) { CircularProgressIndicator() }
                    else if (watching.isEmpty()) FormRow("Nobody is watching anything right now.")
                    watching.forEachIndexed { i, s ->
                        if (i > 0) FormDivider()
                        Column(Modifier.padding(12.dp)) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                RemoteImage(s.nowPlayingItem?.let { c.posterURL(it, 160) }, Modifier.size(52.dp, 78.dp).clip(RoundedCornerShape(8.dp)))
                                Column(Modifier.padding(start = 12.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                                    Text(s.userName ?: "Someone", style = MaterialTheme.typography.labelMedium, fontWeight = FontWeight.Bold, color = Hue.coral)
                                    Text(s.nowPlayingItem?.displayTitle ?: "", fontWeight = FontWeight.SemiBold, maxLines = 1)
                                    s.nowPlayingItem?.episodeLabel?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = Hue.secondaryText) }
                                    Text(listOfNotNull(s.deviceName, s.client).joinToString(" · "), style = MaterialTheme.typography.labelSmall, color = Hue.secondaryText)
                                    s.progress?.let { ProgressBar(it, Modifier.width(200.dp)) }
                                }
                            }
                            Row(Modifier.padding(top = 10.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                val ok = s.supportsRemoteControl != false
                                SoftButton({ command(s, if (s.isPaused) "Unpause" else "Pause") }, enabled = ok) { Icon(if (s.isPaused) Icons.Filled.PlayArrow else Icons.Filled.Pause, null, Modifier.size(18.dp)); Text(if (s.isPaused) " Resume" else " Pause") }
                                SoftButton({ command(s, "Stop") }, enabled = ok) { Icon(Icons.Filled.Stop, null, Modifier.size(18.dp), tint = Hue.coral); Text(" Stop") }
                                SoftButton({ target = s }, enabled = ok) { Icon(Icons.AutoMirrored.Filled.Message, null, Modifier.size(18.dp)); Text(" Message") }
                            }
                            if (s.supportsRemoteControl == false) Text("This app doesn't accept remote control.", style = MaterialTheme.typography.labelSmall, color = Hue.secondaryText)
                        }
                    }
                }
            }
            if (idle.isNotEmpty()) item {
                FormSection("Other devices", "Send a message to a screen even when nothing is playing.") {
                    idle.forEachIndexed { i, s ->
                        if (i > 0) FormDivider()
                        FormRow(s.userName ?: "Someone", listOfNotNull(s.deviceName, s.client).joinToString(" · ")) {
                            IconButton({ target = s }) { Icon(Icons.AutoMirrored.Filled.Message, "Message") }
                        }
                    }
                }
            }
        }
    }
    target?.let { t ->
        var custom by remember { mutableStateOf("") }
        fun send(text: String) {
            val msg = text.trim(); if (msg.isEmpty()) return
            target = null
            scope.launch { status = runCatching { c.sendMessage(t.id, "Message", msg); "Sent to ${t.userName ?: "them"}." }.getOrElse { "Couldn't send that message." } }
        }
        AlertDialog({ target = null }, containerColor = Hue.card, title = { Text("Message ${t.userName ?: ""}") },
            confirmButton = { TextButton({ send(custom) }, enabled = custom.isNotBlank()) { Text("Send") } },
            dismissButton = { TextButton({ target = null }) { Text("Cancel") } },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    presets.forEach { p -> Text(p, Modifier.fillMaxWidth().clip(RoundedCornerShape(10.dp)).clickable { send(p) }.padding(10.dp)) }
                    OutlinedTextField(custom, { custom = it }, Modifier.fillMaxWidth(), placeholder = { Text("Type a message") })
                }
            })
    }
}
