package com.huefin.app.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.navigation.NavHostController
import com.huefin.app.core.AppState
import com.huefin.app.core.formatBytes
import com.huefin.app.downloads.DownloadManager
import com.huefin.app.downloads.DownloadRecord
import com.huefin.app.downloads.DownloadState
import com.huefin.app.playback.AudioPlayer
import com.huefin.app.playback.Player

/** Everything saved on this device, grouped by show, with smart downloads and storage. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DownloadsScreen(nav: NavHostController) {
    val ctx = LocalContext.current
    val records = DownloadManager.records.values.toList()
    val groups = records.groupBy { it.groupTitle }.toSortedMap(compareBy<String> { if (it == "Movies") "" else it })
        .mapValues { (_, l) -> l.sortedWith(compareBy({ it.item.parentIndexNumber ?: 0 }, { it.item.indexNumber ?: 0 }, { it.item.displayTitle })) }
    var confirmGroup by remember { mutableStateOf<String?>(null) }
    fun open(r: DownloadRecord) {
        when (r.state) {
            DownloadState.Completed -> when {
                r.item.type == "Audio" || r.item.type == "AudioBook" -> {
                    val list = groups[r.groupTitle].orEmpty().filter { it.state == DownloadState.Completed }.map { it.item }
                    AudioPlayer.play(ctx, list, list.indexOfFirst { it.id == r.itemId }.coerceAtLeast(0))
                }
                r.item.type == "Book" -> nav.navigate("book/${r.itemId}")
                else -> Player.play(ctx, r.item, r.positionTicks ?: r.item.resumeTicks)
            }
            DownloadState.Paused -> DownloadManager.resume(r.itemId)
            DownloadState.Failed -> DownloadManager.retry(r.itemId)
            else -> {}
        }
    }
    Scaffold(containerColor = Color.Transparent, topBar = { HuefinTopBar("Downloads", nav) { AccountButton(nav) } }) { pad ->
        LazyColumn(Modifier.fillMaxSize().background(Brush.verticalGradient(listOf(Hue.mint.copy(alpha = 0.18f), Hue.night, Hue.night))),
            contentPadding = PaddingValues(16.dp, pad.calculateTopPadding(), 16.dp, 24.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            item {
                Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp)).background(Hue.card).padding(14.dp), verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Filled.Storage, null, tint = Hue.mint)
                    Text("  ${formatBytes(DownloadManager.storageUsed())} used", fontWeight = FontWeight.SemiBold)
                    Spacer(Modifier.weight(1f))
                    Text("${formatBytes(DownloadManager.freeSpace())} free", style = MaterialTheme.typography.bodySmall, color = Hue.secondaryText)
                }
            }
            if (records.isEmpty()) item {
                Column(Modifier.fillMaxWidth().padding(top = 80.dp, start = 24.dp, end = 24.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                    Icon(Icons.Filled.ArrowCircleDown, null, Modifier.size(52.dp), tint = Hue.mint)
                    Text("No downloads yet", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold, modifier = Modifier.padding(top = 12.dp))
                    Text("Tap the download button on any movie or episode, or download a whole season from its page. Files download at full quality.",
                        color = Hue.secondaryText, modifier = Modifier.padding(top = 8.dp))
                }
            }
            if (DownloadManager.smartRules.isNotEmpty()) {
                item { ShelfTitle("Smart downloads", Modifier.padding(top = 10.dp)) }
                item { Text("These shows keep their next unwatched episodes downloaded and clear out watched ones.", style = MaterialTheme.typography.bodySmall, color = Hue.secondaryText) }
                items(DownloadManager.smartRules.values.toList(), key = { "smart" + it.seriesId }) { rule ->
                    Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(Hue.card).padding(horizontal = 14.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Filled.AutoMode, null, tint = Hue.mint)
                        Text("  ${rule.name}", Modifier.weight(1f), fontWeight = FontWeight.SemiBold)
                        Text("Next ${rule.count}", color = Hue.secondaryText)
                        IconButton({ DownloadManager.setSmart(rule.seriesId, rule.name, 0) }) { Icon(Icons.Filled.Close, "Stop smart downloads for ${rule.name}") }
                    }
                }
            }
            groups.forEach { (title, list) ->
                item(key = "g$title") {
                    Row(Modifier.fillMaxWidth().padding(top = 14.dp), verticalAlignment = Alignment.CenterVertically) {
                        ShelfTitle(title, Modifier.weight(1f))
                        if (list.size > 1) TextButton({ confirmGroup = title }) { Text("Delete all ${list.size}", color = Hue.coral) }
                    }
                }
                items(list, key = { it.itemId }) { r -> DownloadRow(r) { open(r) } }
            }
        }
    }
    confirmGroup?.let { g ->
        AlertDialog({ confirmGroup = null }, confirmButton = { TextButton({ groups[g]?.forEach { DownloadManager.delete(it.itemId) }; confirmGroup = null }) { Text("Delete", color = Hue.coral) } },
            dismissButton = { TextButton({ confirmGroup = null }) { Text("Cancel") } }, title = { Text("Delete all of $g?") },
            text = { Text("They'll be removed from this device. You can download them again any time.") })
    }
}

@Composable
private fun DownloadRow(r: DownloadRecord, onClick: () -> Unit) {
    val c = AppState.client
    var menu by remember { mutableStateOf(false) }
    Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).clickable(onClick = onClick).padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
        val square = r.item.type == "Audio"
        RemoteImage(if (square) c?.albumArtURL(r.item, 200) else c?.landscapeURL(r.item, 400),
            Modifier.width(if (square) 56.dp else 110.dp).aspectRatio(if (square) 1f else 16f / 9f).clip(RoundedCornerShape(10.dp)))
        Column(Modifier.weight(1f).padding(horizontal = 12.dp), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(if (r.item.type == "Episode") r.item.name ?: "" else r.item.displayTitle, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
            val sub = listOfNotNull(r.item.episodeLabel, r.sizeBytes?.let(::formatBytes)).joinToString(" · ")
            when (r.state) {
                DownloadState.Completed -> { if (sub.isNotEmpty()) Text(sub, style = MaterialTheme.typography.bodySmall, color = Hue.secondaryText)
                    r.positionTicks?.let { t -> r.item.runTimeTicks?.takeIf { it > 0 }?.let { ProgressBar(t.toDouble() / it, Modifier.fillMaxWidth(0.6f)) } } }
                DownloadState.Queued -> Text("Waiting…", style = MaterialTheme.typography.bodySmall, color = Hue.secondaryText)
                DownloadState.Downloading -> { LinearProgressIndicator({ r.progress }, Modifier.fillMaxWidth(), color = Hue.mint)
                    Text("${(r.progress * 100).toInt()}%", style = MaterialTheme.typography.labelSmall, color = Hue.secondaryText) }
                DownloadState.Paused -> Text("Paused · ${(r.progress * 100).toInt()}% · tap to resume", style = MaterialTheme.typography.bodySmall, color = Hue.secondaryText)
                DownloadState.Failed -> Text("Failed · tap to retry${r.errorText?.let { " ($it)" } ?: ""}", style = MaterialTheme.typography.bodySmall, color = Hue.coral, maxLines = 2)
            }
        }
        Box {
            IconButton({ menu = true }) { Icon(Icons.Filled.MoreVert, "More") }
            DropdownMenu(menu, { menu = false }) {
                if (r.state == DownloadState.Downloading || r.state == DownloadState.Queued) DropdownMenuItem({ Text("Pause") }, { DownloadManager.pause(r.itemId); menu = false }, leadingIcon = { Icon(Icons.Filled.Pause, null) })
                if (r.state == DownloadState.Paused) DropdownMenuItem({ Text("Resume") }, { DownloadManager.resume(r.itemId); menu = false }, leadingIcon = { Icon(Icons.Filled.PlayArrow, null) })
                DropdownMenuItem({ Text("Delete") }, { DownloadManager.delete(r.itemId); menu = false }, leadingIcon = { Icon(Icons.Filled.Delete, null) })
            }
        }
    }
}
