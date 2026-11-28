package com.huefin.app.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ViewList
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.navigation.NavHostController
import com.huefin.app.core.AppState
import com.huefin.app.core.BaseItem
import com.huefin.app.core.Prefs
import com.huefin.app.core.ProgramInfo
import com.huefin.app.playback.Player
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.time.temporal.ChronoUnit

private val timeFmt = DateTimeFormatter.ofLocalizedTime(FormatStyle.SHORT).withZone(ZoneId.systemDefault())

/** Live channels from the server's tuners, with what's on now and next, as a list or a guide grid. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LiveTVScreen(nav: NavHostController) {
    val ctx = LocalContext.current
    var channels by remember { mutableStateOf<List<BaseItem>>(emptyList()) }
    var guide by remember { mutableStateOf<Map<String, List<ProgramInfo>>>(emptyMap()) }
    var loading by remember { mutableStateOf(true) }
    var error by remember { mutableStateOf<String?>(null) }
    var search by remember { mutableStateOf("") }
    var layout by remember { mutableStateOf(Prefs.string(Prefs.Keys.liveLayout) ?: "list") }
    var now by remember { mutableStateOf(Instant.now()) }
    val scope = rememberCoroutineScope()
    suspend fun load() {
        val c = AppState.client ?: return
        loading = true
        runCatching { c.liveChannels() }.onSuccess { channels = it; error = null }.onFailure { error = "Couldn't load channels: ${it.message}" }
        guide = runCatching { c.liveGuide(6.0) }.getOrDefault(emptyMap())
        loading = false
    }
    LaunchedEffect(AppState.client) { load() }
    LaunchedEffect(Unit) { while (true) { delay(60_000); now = Instant.now() } }
    fun nowOn(ch: BaseItem) = guide[ch.id]?.firstOrNull { (it.start ?: Instant.MAX) <= now && (it.end ?: Instant.MIN) > now } ?: ch.currentProgram
    fun nextOn(ch: BaseItem) = guide[ch.id]?.firstOrNull { (it.start ?: Instant.MIN) > now }
    val q = search.trim()
    val filtered = if (q.isEmpty()) channels else channels.filter { ch ->
        (ch.name ?: "").contains(q, true) || (ch.channelNumber ?: "").startsWith(q) || (nowOn(ch)?.name ?: "").contains(q, true) }
    val play: (BaseItem) -> Unit = { Player.play(ctx, it, 0) }

    Scaffold(containerColor = Color.Transparent, topBar = {
        HuefinTopBar("Live TV", nav) {
            IconButton({ layout = if (layout == "list") "guide" else "list"; Prefs.set(Prefs.Keys.liveLayout, layout) }) {
                Icon(if (layout == "list") Icons.Filled.CalendarViewDay else Icons.AutoMirrored.Filled.ViewList, if (layout == "list") "Show guide" else "Show list")
            }
            AccountButton(nav)
        }
    }) { pad ->
        Column(Modifier.fillMaxSize().background(Brush.verticalGradient(listOf(Hue.amber.copy(alpha = 0.2f), Hue.night, Hue.night))).padding(top = pad.calculateTopPadding())) {
            when {
                loading && channels.isEmpty() -> Box(Modifier.fillMaxSize(), Alignment.Center) { CircularProgressIndicator() }
                channels.isEmpty() -> Column(Modifier.fillMaxSize().padding(32.dp), Arrangement.Center, Alignment.CenterHorizontally) {
                    Icon(Icons.Filled.LiveTv, null, Modifier.size(48.dp), tint = Hue.secondaryText)
                    Text("No Live TV", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold, modifier = Modifier.padding(top = 12.dp))
                    Text(error ?: "Add your M3U playlist on the server under Dashboard → Live TV → Tuner Devices, and an XMLTV guide for program info.",
                        color = Hue.secondaryText, modifier = Modifier.padding(vertical = 12.dp))
                    SoftButton({ scope.launch { load() } }) { Text("Reload") }
                }
                else -> {
                    OutlinedTextField(search, { search = it }, Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
                        placeholder = { Text("Channels or shows") }, leadingIcon = { Icon(Icons.Filled.Search, null) }, singleLine = true, shape = RoundedCornerShape(14.dp))
                    PullToRefreshBox(loading, { scope.launch { load() } }, Modifier.fillMaxSize()) {
                        if (layout == "guide") GuideGrid(filtered, guide, now, play)
                        else LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp),
                            horizontalAlignment = Alignment.CenterHorizontally) {
                            items(filtered, key = { it.id }) { ch -> ChannelRow(ch, nowOn(ch), nextOn(ch), now) { play(ch) } }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun ChannelLogo(ch: BaseItem, modifier: Modifier) {
    Box(modifier.clip(RoundedCornerShape(12.dp)).background(Hue.wash), Alignment.Center) {
        Text((ch.name ?: "TV").take(3).uppercase(), fontWeight = FontWeight.Black, color = Hue.secondaryText)
        if (ch.imageTag("Primary") != null) RemoteImage(AppState.client?.imageURL(ch.id, maxWidth = 240, tag = ch.imageTag("Primary")),
            Modifier.fillMaxSize().padding(8.dp), ContentScale.Fit)
    }
}

@Composable
private fun ChannelRow(ch: BaseItem, now: ProgramInfo?, next: ProgramInfo?, at: Instant, onClick: () -> Unit) {
    Row(Modifier.widthIn(max = 900.dp).fillMaxWidth().clip(RoundedCornerShape(18.dp)).background(Hue.card).border(if (Hue.light) 2.dp else 0.dp, Hue.ink, RoundedCornerShape(18.dp)).clickable(onClick = onClick).padding(12.dp),
        verticalAlignment = Alignment.CenterVertically) {
        ChannelLogo(ch, Modifier.size(96.dp, 60.dp))
        Column(Modifier.weight(1f).padding(horizontal = 14.dp), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                ch.channelNumber?.takeIf { it.isNotEmpty() }?.let { Text(it, style = MaterialTheme.typography.labelMedium, fontWeight = FontWeight.Bold, color = Hue.amber) }
                Text(ch.name ?: "Channel", style = MaterialTheme.typography.labelMedium, color = Hue.secondaryText, maxLines = 1)
            }
            Text(now?.name?.takeIf { it.isNotEmpty() } ?: ch.name ?: "Live", fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis)
            now?.progress(at)?.let { ProgressBar(it, Modifier.widthIn(max = 220.dp)) }
            next?.start?.let { Text("Next ${timeFmt.format(it)} · ${next.name ?: ""}", style = MaterialTheme.typography.bodySmall, color = Hue.secondaryText, maxLines = 1) }
        }
        Icon(Icons.Filled.PlayCircle, "Watch", Modifier.size(30.dp))
    }
}

/** The TV guide: channels down the side, time across the top, programs as blocks. */
@Composable
private fun GuideGrid(channels: List<BaseItem>, guide: Map<String, List<ProgramInfo>>, now: Instant, play: (BaseItem) -> Unit) {
    val origin = now.truncatedTo(ChronoUnit.HOURS).let { if (now.atZone(ZoneId.systemDefault()).minute >= 30) it.plus(30, ChronoUnit.MINUTES) else it }
    val end = origin.plus(6, ChronoUnit.HOURS)
    val perMinute = 5.dp
    val rowH = 66.dp
    val hScroll = rememberScrollState()
    val totalW = perMinute * (6 * 60)
    fun x(t: Instant) = perMinute * ChronoUnit.MINUTES.between(origin, t).coerceIn(0, 360).toFloat()
    var picked by remember { mutableStateOf<Pair<BaseItem, ProgramInfo>?>(null) }
    LazyColumn(Modifier.fillMaxSize()) {
        item {
            Row {
                Spacer(Modifier.width(92.dp))
                Box(Modifier.horizontalScroll(hScroll).width(totalW).height(32.dp)) {
                    var t = origin
                    while (t < end) {
                        Text(timeFmt.format(t), Modifier.offset(x = x(t)).padding(start = 6.dp, top = 6.dp), style = MaterialTheme.typography.labelMedium, color = Hue.secondaryText)
                        t = t.plus(30, ChronoUnit.MINUTES)
                    }
                    Box(Modifier.offset(x = x(now)).width(2.dp).fillMaxHeight().background(Hue.amber))
                }
            }
        }
        items(channels, key = { it.id }) { ch ->
            Row(Modifier.height(rowH).padding(vertical = 3.dp)) {
                ChannelLogo(ch, Modifier.width(86.dp).fillMaxHeight().padding(start = 6.dp).clickable { play(ch) })
                Box(Modifier.padding(start = 6.dp).horizontalScroll(hScroll).width(totalW).fillMaxHeight()) {
                    val progs = guide[ch.id].orEmpty().filter { (it.end ?: Instant.MIN) > origin && (it.start ?: Instant.MAX) < end }
                    if (progs.isEmpty()) Box(Modifier.fillMaxSize().clip(RoundedCornerShape(10.dp)).background(Hue.card).clickable { play(ch) }.padding(10.dp)) {
                        Text(ch.name ?: "Live", maxLines = 1, color = Hue.secondaryText)
                    }
                    progs.forEach { p ->
                        val s = p.start ?: origin; val e = p.end ?: end
                        val live = s <= now && e > now
                        Box(Modifier.offset(x = x(s)).width((x(e) - x(s) - 3.dp).coerceAtLeast(8.dp)).fillMaxHeight()
                            .clip(RoundedCornerShape(10.dp)).background(if (live) Hue.amber.copy(alpha = 0.22f) else Hue.card)
                            .border(1.dp, if (live) Hue.amber.copy(alpha = 0.6f) else Hue.hairline, RoundedCornerShape(10.dp))
                            .clickable { if (live) play(ch) else picked = ch to p }.padding(horizontal = 10.dp, vertical = 6.dp)) {
                            Column {
                                Text(p.name ?: "", fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.bodyMedium)
                                Text("${timeFmt.format(s)} – ${timeFmt.format(e)}", style = MaterialTheme.typography.labelSmall, color = Hue.secondaryText, maxLines = 1)
                            }
                        }
                    }
                }
            }
        }
    }
    picked?.let { (ch, p) ->
        AlertDialog({ picked = null }, confirmButton = { TextButton({ play(ch); picked = null }) { Text("Watch ${ch.name ?: "channel"} now") } },
            dismissButton = { TextButton({ picked = null }) { Text("Close") } },
            title = { Text(p.name ?: "") },
            text = { Column { Text("${ch.name ?: ""} · ${p.start?.let(timeFmt::format) ?: ""} – ${p.end?.let(timeFmt::format) ?: ""}", color = Hue.secondaryText)
                p.overview?.let { Text(it, Modifier.padding(top = 8.dp)) } } })
    }
}
