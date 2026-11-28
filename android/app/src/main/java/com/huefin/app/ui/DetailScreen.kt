package com.huefin.app.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.DownloadDone
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.FavoriteBorder
import androidx.compose.material.icons.filled.Layers
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Sync
import androidx.compose.material.icons.filled.Verified
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
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
import androidx.compose.ui.unit.sp
import androidx.navigation.NavHostController
import coil.compose.AsyncImage
import com.huefin.app.core.AppState
import com.huefin.app.core.BaseItem
import com.huefin.app.core.MediaSource
import com.huefin.app.core.formatBytes
import com.huefin.app.downloads.DownloadManager
import com.huefin.app.downloads.DownloadState
import com.huefin.app.playback.EngineDecider
import com.huefin.app.playback.Playability
import com.huefin.app.playback.Player
import kotlinx.coroutines.launch

@OptIn(ExperimentalLayoutApi::class)
@Composable
fun DetailScreen(initial: BaseItem, nav: NavHostController) {
    var item by remember(initial.id) { mutableStateOf(initial) }
    var favorite by remember(initial.id) { mutableStateOf(initial.userData?.isFavorite == true) }
    var similar by remember { mutableStateOf<List<BaseItem>>(emptyList()) }
    var extras by remember { mutableStateOf<List<BaseItem>>(emptyList()) }
    var parts by remember { mutableStateOf<List<BaseItem>>(emptyList()) }
    var seasons by remember { mutableStateOf<List<BaseItem>>(emptyList()) }
    var season by remember { mutableStateOf<BaseItem?>(null) }
    var episodes by remember { mutableStateOf<List<BaseItem>>(emptyList()) }
    var version by remember { mutableStateOf<String?>(null) }
    var playability by remember { mutableStateOf<Playability?>(null) }
    var nextUp by remember { mutableStateOf<BaseItem?>(null) }
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    val c = AppState.client
    val wide = LocalWidthClass.current == WidthClass.Expanded

    LaunchedEffect(initial.id) {
        val cl = c ?: return@LaunchedEffect
        runCatching { cl.item(initial.id) }.onSuccess { item = it; favorite = it.userData?.isFavorite == true }
        if (item.type == "Movie" || item.isSeries) similar = cl.similar(item.id)
        if (item.type in setOf("Movie", "Series", "Episode")) extras = cl.specialFeatures(item.id)
        if (item.type == "Movie") parts = cl.additionalParts(item.id)
        if (item.isSeries) {
            seasons = runCatching { cl.seasons(item.id) }.getOrDefault(emptyList())
            nextUp = runCatching { cl.nextUp(item.id).firstOrNull() }.getOrNull()
            season = seasons.firstOrNull { it.id == nextUp?.seasonId } ?: seasons.firstOrNull()
        }
    }
    LaunchedEffect(season?.id) {
        val s = season ?: return@LaunchedEffect
        episodes = runCatching { c?.episodes(item.id, s.id) ?: emptyList() }.getOrDefault(emptyList())
    }
    LaunchedEffect(item.id, version) {
        if (!item.isPlayable || item.isLiveChannel || c == null) return@LaunchedEffect
        playability = if (DownloadManager.records[item.id]?.state == DownloadState.Completed)
            Playability(Playability.Kind.Original, "Downloaded to this device.")
        else EngineDecider.playability(item, c, AppState.playbackBitrate, version)
    }

    fun play() {
        if (item.isSeries) {
            val target = nextUp ?: episodes.firstOrNull() ?: return
            Player.play(context, target, target.resumeTicks)
        } else Player.play(context, item, item.resumeTicks, version)
    }

    LazyColumn(Modifier.fillMaxSize()) {
        item {
            Box(Modifier.fillMaxWidth().height(if (wide) 420.dp else 340.dp)) {
                AsyncImage(c?.backdropURL(item, 1600), null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
                Box(Modifier.fillMaxSize().background(Brush.verticalGradient(0f to Color.Black.copy(alpha = 0.4f), 0.3f to Color.Transparent, 1f to Hue.night)))
                IconButton({ nav.popBackStack() }, Modifier.statusBarsPadding().padding(8.dp).background(Color.Black.copy(alpha = 0.35f), CircleShape)) {
                    Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back")
                }
            }
        }
        item {
            val header = @Composable {
                Column(Modifier.padding(horizontal = 20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    val logo = c?.logoURL(item)
                    if (logo != null && item.type != "Episode") AsyncImage(logo, item.displayTitle, Modifier.height(90.dp).widthIn(max = 320.dp), contentScale = ContentScale.Fit, alignment = Alignment.CenterStart)
                    else Text(item.displayTitle, fontSize = 30.sp, fontWeight = FontWeight.ExtraBold, lineHeight = 33.sp)
                    item.episodeLabel?.let { Text(it, style = MaterialTheme.typography.titleMedium, color = Hue.secondaryText) }
                    Text(listOfNotNull(item.productionYear?.toString(), item.officialRating, item.runtimeText,
                        item.communityRating?.let { "★ %.1f".format(it) }).joinToString(" · "), color = Hue.secondaryText)
                    val src = item.mediaSources?.firstOrNull { it.id == version } ?: item.mediaSources?.firstOrNull()
                    if (src != null) FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) { src.badges.forEach { Chip(it) } }
                    Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
                        if (item.isPlayable || item.isSeries) PlayButton({ play() }) {
                            Icon(Icons.Filled.PlayArrow, null)
                            Text(when {
                                item.isSeries && nextUp != null -> " ${nextUp?.episodeLabel?.substringBefore(" ·") ?: "Play"}"
                                item.progress != null -> " Resume"
                                else -> " Play"
                            })
                        }
                        if (item.isPlayable && !item.isLiveChannel) DownloadButton(item)
                        if (!item.isLiveChannel) SoftButton({
                            val on = !favorite; favorite = on
                            scope.launch { if (c?.setFavorite(item.id, on) != true) favorite = !on }
                        }, padding = androidx.compose.foundation.layout.PaddingValues(12.dp)) {
                            Icon(if (favorite) Icons.Filled.Favorite else Icons.Filled.FavoriteBorder, if (favorite) "Remove from My List" else "Add to My List",
                                tint = if (favorite) Hue.coral else Hue.text)
                        }
                    }
                    item.progress?.let { ProgressBar(it, Modifier.widthIn(max = 260.dp).fillMaxWidth()) }
                    playability?.takeIf { it.kind != Playability.Kind.Unknown }?.let { PlayabilityCard(it) }
                    item.mediaSources?.takeIf { it.size > 1 }?.let { VersionPicker(it, version) { v -> version = v } }
                    if (item.isSeries) SmartDownloadsRow(item)
                }
            }
            val body = @Composable {
                Column(Modifier.padding(horizontal = 20.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    item.overview?.let { Text(it, style = MaterialTheme.typography.bodyMedium, lineHeight = 21.sp) }
                    item.genres?.takeIf { it.isNotEmpty() }?.let { Text(it.joinToString(" · "), style = MaterialTheme.typography.bodySmall, color = Hue.secondaryText) }
                    item.mediaSources?.firstOrNull()?.let { if (item.isPlayable) TechSpecs(it) }
                }
            }
            // Unfolded (Fold inner screen, tablets): title column and story side by side.
            if (wide) Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Box(Modifier.weight(1f)) { header() }; Box(Modifier.weight(1f)) { body() }
            } else Column(verticalArrangement = Arrangement.spacedBy(16.dp)) { header(); body() }
        }
        if (item.isSeries && seasons.isNotEmpty()) {
            item {
                LazyRow(contentPadding = androidx.compose.foundation.layout.PaddingValues(20.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    items(seasons, key = { it.id }) { s ->
                        val on = s.id == season?.id
                        Text(s.name ?: "Season", fontWeight = FontWeight.SemiBold, color = if (on) Hue.ink else Hue.text,
                            modifier = Modifier.clip(RoundedCornerShape(12.dp)).background(if (on) LocalHue.current else Hue.card)
                                .clickable { season = s }.padding(horizontal = 14.dp, vertical = 9.dp))
                    }
                }
            }
            items(episodes, key = { it.id }) { ep -> EpisodeRow(ep, onPlay = { Player.play(context, ep, ep.resumeTicks) }, onDetails = { nav.openItem(ep) }) }
            item {
                val pending = episodes.filter { DownloadManager.records[it.id] == null }
                if (episodes.isNotEmpty()) SoftButton({ pending.forEach { DownloadManager.start(it) } }, Modifier.padding(20.dp), enabled = pending.isNotEmpty()) {
                    Icon(Icons.Filled.Download, null); Text(if (pending.isEmpty()) " Season downloaded" else " Download season (${pending.size})")
                }
            }
        }
        if (parts.isNotEmpty() || extras.isNotEmpty()) item {
            Box(Modifier.padding(top = 20.dp)) {
                Shelf(if (parts.isEmpty()) "Extras" else "Parts & Extras") {
                    items(parts + extras, key = { it.id }) { LandscapeCard(it, { Player.play(context, it, it.resumeTicks) }) }
                }
            }
        }
        if (similar.isNotEmpty()) item {
            Box(Modifier.padding(vertical = 20.dp)) { Shelf("More Like This") { items(similar, key = { it.id }) { PosterCard(it, { nav.openItem(it) }) } } }
        }
        item { Spacer(Modifier.height(48.dp)) }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun EpisodeRow(ep: BaseItem, onPlay: () -> Unit, onDetails: () -> Unit) {
    Row(Modifier.fillMaxWidth().combinedClickable(onClick = onPlay, onLongClick = onDetails).padding(horizontal = 20.dp, vertical = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Box(Modifier.width(150.dp * cardScale()).aspectRatio(16f / 9f).clip(RoundedCornerShape(12.dp))) {
            RemoteImage(AppState.client?.landscapeURL(ep, 400), Modifier.fillMaxSize())
            ep.progress?.let { ProgressBar(it, Modifier.align(Alignment.BottomCenter).fillMaxWidth().padding(6.dp)) }
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Text("${ep.indexNumber?.let { "$it. " } ?: ""}${ep.name ?: ""}", fontWeight = FontWeight.SemiBold, maxLines = 2,
                    overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, false))
                if (ep.userData?.played == true) Icon(Icons.Filled.CheckCircle, "Watched", Modifier.size(16.dp), tint = LocalHue.current)
                if (DownloadManager.records[ep.id]?.state == DownloadState.Completed) Icon(Icons.Filled.DownloadDone, "Downloaded", Modifier.size(16.dp), tint = Hue.mint)
            }
            ep.runtimeText?.let { Text(it, style = MaterialTheme.typography.labelSmall, color = Hue.secondaryText) }
            ep.overview?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = Hue.secondaryText, maxLines = 2, overflow = TextOverflow.Ellipsis) }
        }
    }
}

@Composable
fun DownloadButton(item: BaseItem) {
    val rec = DownloadManager.records[item.id]
    SoftButton({ if (rec == null) DownloadManager.start(item) }, padding = androidx.compose.foundation.layout.PaddingValues(12.dp)) {
        when (rec?.state) {
            null -> Icon(Icons.Filled.Download, "Download")
            DownloadState.Completed -> Icon(Icons.Filled.DownloadDone, "Downloaded", tint = Hue.mint)
            DownloadState.Failed -> Icon(Icons.Filled.Sync, "Download failed, tap to retry", Modifier.clickable { DownloadManager.retry(item.id) }, tint = Hue.coral)
            else -> CircularProgressIndicator(progress = { rec.progress }, modifier = Modifier.size(22.dp), strokeWidth = 3.dp)
        }
    }
}

@Composable
private fun PlayabilityCard(p: Playability) {
    Row(Modifier.background(Hue.card, RoundedCornerShape(14.dp)).padding(12.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        Icon(when (p.kind) { Playability.Kind.Converted -> Icons.Filled.Sync; Playability.Kind.HuefinEngine -> Icons.Filled.AutoAwesome; else -> Icons.Filled.Verified },
            null, tint = if (p.kind == Playability.Kind.Converted) Hue.amber else LocalHue.current)
        Column {
            Text(p.title, fontWeight = FontWeight.SemiBold, style = MaterialTheme.typography.bodyMedium)
            Text(p.detail, style = MaterialTheme.typography.bodySmall, color = Hue.secondaryText)
        }
    }
}

private fun versionLabel(s: MediaSource): String = buildList {
    s.name?.takeIf { it.isNotBlank() }?.let { add(it) }
    s.videoStream?.height?.let { h -> add(if (h >= 2000) "4K" else if (h >= 1000) "1080p" else "${h}p") }
    s.size?.let { add(formatBytes(it)) }
}.joinToString(" · ").ifEmpty { "Version" }

@Composable
private fun VersionPicker(sources: List<MediaSource>, selected: String?, onPick: (String) -> Unit) {
    var open by remember { mutableStateOf(false) }
    val current = sources.firstOrNull { it.id == selected } ?: sources[0]
    Box {
        SoftButton({ open = true }) { Icon(Icons.Filled.Layers, null); Text(" Version: ${versionLabel(current)}") }
        DropdownMenu(open, { open = false }) {
            sources.forEach { s -> DropdownMenuItem({ Text((if (s.id == current.id) "✓ " else "") + versionLabel(s)) }, { onPick(s.id); open = false }) }
        }
    }
}

@Composable
private fun SmartDownloadsRow(series: BaseItem) {
    var open by remember { mutableStateOf(false) }
    val rule = DownloadManager.smartRules[series.id]
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Box {
            SoftButton({ open = true }) { Icon(Icons.Filled.AutoAwesome, null); Text(rule?.let { " Smart: keeping next ${it.count}" } ?: " Smart downloads") }
            DropdownMenu(open, { open = false }) {
                DropdownMenuItem({ Text((if (rule == null) "✓ " else "") + "Off") }, { DownloadManager.setSmart(series.id, series.name ?: "Show", 0); open = false })
                listOf(1, 2, 3, 5, 10).forEach { n ->
                    DropdownMenuItem({ Text((if (rule?.count == n) "✓ " else "") + "Next $n unwatched") }, { DownloadManager.setSmart(series.id, series.name ?: "Show", n); open = false })
                }
            }
        }
        Text("Smart downloads keep the next unwatched episodes on this device and remove ones you've finished.",
            style = MaterialTheme.typography.labelSmall, color = Hue.secondaryText)
    }
}

@Composable
private fun TechSpecs(src: MediaSource) {
    Column(Modifier.padding(top = 8.dp).fillMaxWidth().background(Hue.card, RoundedCornerShape(14.dp)).padding(14.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text("Media", fontWeight = FontWeight.Bold)
        src.videoStream?.let { v -> Text("Video: ${listOfNotNull(v.codec?.uppercase(), v.width?.let { "${it}×${v.height}" }, v.videoRangeType).joinToString(" · ")}", style = MaterialTheme.typography.bodySmall) }
        src.audioStreams.take(4).forEach { a -> Text("Audio: ${a.displayTitle ?: a.codec}", style = MaterialTheme.typography.bodySmall) }
        if (src.subtitleStreams.isNotEmpty()) Text("Subtitles: ${src.subtitleStreams.mapNotNull { it.language ?: it.displayTitle }.distinct().take(8).joinToString(", ")}", style = MaterialTheme.typography.bodySmall)
        Text(listOfNotNull(src.container?.uppercase(), src.size?.let(::formatBytes), src.bitrate?.let { "${it / 1_000_000} Mbps" }).joinToString(" · "),
            style = MaterialTheme.typography.bodySmall, color = Hue.secondaryText)
    }
}
