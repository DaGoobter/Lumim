package com.huefin.app.ui

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.itemsIndexed as gridItemsIndexed
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.QueueMusic
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.navigation.NavHostController
import com.huefin.app.core.AppState
import com.huefin.app.core.BaseItem
import com.huefin.app.core.NameId
import com.huefin.app.core.formatTicks
import com.huefin.app.downloads.DownloadManager
import com.huefin.app.playback.AudioPlayer
import com.huefin.app.playback.Station
import com.huefin.app.playback.Stations
import kotlinx.coroutines.launch

private fun clock(ms: Long): String { val s = ms / 1000; return if (s >= 3600) "%d:%02d:%02d".format(s / 3600, s / 60 % 60, s % 60) else "%d:%02d".format(s / 60, s % 60) }

// MARK: Mini player and Now Playing

/** The bar above the tabs while music or an audiobook plays. */
@Composable
fun MiniPlayer() {
    val item = AudioPlayer.current ?: return
    val c = AppState.client
    Column(Modifier.fillMaxWidth().padding(horizontal = 10.dp, vertical = 6.dp)
        .clip(RoundedCornerShape(18.dp)).background(Hue.card).border(1.dp, Hue.hairline, RoundedCornerShape(18.dp))
        .clickable { AudioPlayer.showNowPlaying = true }) {
        Row(Modifier.padding(8.dp), verticalAlignment = Alignment.CenterVertically) {
            RemoteImage(c?.albumArtURL(item, 200), Modifier.size(46.dp).clip(RoundedCornerShape(10.dp)))
            Column(Modifier.weight(1f).padding(horizontal = 12.dp)) {
                Text(AudioPlayer.djLine?.let { "🎙 Huefin DJ" } ?: (item.name ?: ""), fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(AudioPlayer.station?.name?.let { "$it · ${item.artistLine ?: ""}" } ?: (item.artistLine ?: ""),
                    style = MaterialTheme.typography.bodySmall, color = Hue.secondaryText, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            IconButton({ AudioPlayer.togglePlay() }) { Icon(if (AudioPlayer.isPlaying) Icons.Filled.Pause else Icons.Filled.PlayArrow, if (AudioPlayer.isPlaying) "Pause" else "Play") }
            IconButton({ AudioPlayer.next() }) { Icon(Icons.Filled.SkipNext, "Next") }
        }
        val d = AudioPlayer.duration
        Box(Modifier.fillMaxWidth().height(3.dp).background(Hue.hairline)) {
            Box(Modifier.fillMaxWidth(if (d > 0) (AudioPlayer.position.toFloat() / d).coerceIn(0f, 1f) else 0f).fillMaxHeight().background(Hue.spectrum))
        }
    }
    if (AudioPlayer.showNowPlaying) Dialog({ AudioPlayer.showNowPlaying = false }, DialogProperties(usePlatformDefaultWidth = false)) {
        Surface(Modifier.fillMaxSize(), color = Hue.night) { NowPlayingContent { AudioPlayer.showNowPlaying = false } }
    }
}

@Composable
fun NowPlayingScreen(nav: NavHostController) = NowPlayingContent { nav.popBackStack() }

/** Big artwork, scrubber, controls, the DJ's line and Up Next. Two columns on unfolded and tabletop screens. */
@Composable
fun NowPlayingContent(onClose: () -> Unit) {
    val item = AudioPlayer.current
    val c = AppState.client
    var showQueue by remember { mutableStateOf(false) }
    val wide = LocalWidthClass.current != WidthClass.Compact
    if (item == null) { Box(Modifier.fillMaxSize(), Alignment.Center) { Text("Nothing playing", color = Hue.secondaryText) }; return }
    Box(Modifier.fillMaxSize().background(Brush.verticalGradient(listOf(Hue.violet.copy(alpha = 0.35f), Hue.night, Hue.night)))) {
        Column(Modifier.fillMaxSize().systemBarsPadding().padding(horizontal = 22.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClose) { Icon(Icons.Filled.KeyboardArrowDown, "Close") }
                Column(Modifier.weight(1f), horizontalAlignment = Alignment.CenterHorizontally) {
                    Eyebrow(AudioPlayer.station?.let { "Playing from ${it.name}" } ?: "Now playing", Hue.violet)
                }
                IconButton({ showQueue = !showQueue }) { Icon(Icons.AutoMirrored.Filled.QueueMusic, "Up Next") }
            }
            if (wide) Row(Modifier.weight(1f), horizontalArrangement = Arrangement.spacedBy(28.dp), verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.weight(1f)) { Artwork(item) }
                Column(Modifier.weight(1f)) { if (showQueue) QueueList(Modifier.weight(1f)) else { Spacer(Modifier.weight(1f)); Controls(item) } }
            } else Column(Modifier.weight(1f)) {
                if (showQueue) QueueList(Modifier.weight(1f)) else { Box(Modifier.weight(1f), Alignment.Center) { Artwork(item) } }
                Controls(item)
            }
        }
    }
}

@Composable
private fun Artwork(item: BaseItem) {
    Box(Modifier.fillMaxWidth().aspectRatio(1f).widthIn(max = 520.dp)) {
        RemoteImage(AppState.client?.albumArtURL(item, 900), Modifier.fillMaxSize().clip(RoundedCornerShape(22.dp)))
        AnimatedVisibility(AudioPlayer.djLine != null, Modifier.align(Alignment.BottomCenter)) {
            Row(Modifier.padding(12.dp).clip(RoundedCornerShape(16.dp)).background(Hue.ink.copy(alpha = 0.88f)).padding(14.dp)) {
                Icon(Icons.Filled.Mic, null, tint = Hue.violet)
                Text(AudioPlayer.djLine ?: "", Modifier.padding(start = 10.dp), style = MaterialTheme.typography.bodyMedium)
            }
        }
    }
}

@Composable
private fun Controls(item: BaseItem) {
    val isBook = item.type == "AudioBook"
    Column(Modifier.padding(vertical = 16.dp)) {
        Text(item.name ?: "", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.ExtraBold, maxLines = 2)
        Text(item.artistLine ?: item.album ?: "", color = Hue.violet, fontWeight = FontWeight.SemiBold, maxLines = 1)
        var drag by remember { mutableStateOf<Float?>(null) }
        val d = AudioPlayer.duration.coerceAtLeast(1)
        Slider(drag ?: (AudioPlayer.position.toFloat() / d), { drag = it }, onValueChangeFinished = { drag?.let { AudioPlayer.seek((it * d).toLong()) }; drag = null },
            colors = SliderDefaults.colors(thumbColor = Color.White, activeTrackColor = Hue.violet))
        Row { Text(clock(AudioPlayer.position), style = MaterialTheme.typography.labelSmall, color = Hue.secondaryText); Spacer(Modifier.weight(1f))
            Text("-" + clock((AudioPlayer.duration - AudioPlayer.position).coerceAtLeast(0)), style = MaterialTheme.typography.labelSmall, color = Hue.secondaryText) }
        Row(Modifier.fillMaxWidth().padding(top = 8.dp), horizontalArrangement = Arrangement.SpaceEvenly, verticalAlignment = Alignment.CenterVertically) {
            if (isBook) IconButton({ AudioPlayer.seek((AudioPlayer.position - 15_000).coerceAtLeast(0)) }) { Icon(Icons.Filled.Replay10, "Back 15 seconds") }
            else IconButton({ AudioPlayer.toggleShuffle() }, enabled = AudioPlayer.station == null) { Icon(Icons.Filled.Shuffle, "Shuffle", tint = if (AudioPlayer.shuffle) Hue.violet else Color.White) }
            IconButton({ AudioPlayer.previous() }) { Icon(Icons.Filled.SkipPrevious, "Previous", Modifier.size(34.dp)) }
            Box(Modifier.size(72.dp).clip(CircleShape).background(Hue.paper).clickable { AudioPlayer.togglePlay() }, Alignment.Center) {
                Icon(if (AudioPlayer.isPlaying) Icons.Filled.Pause else Icons.Filled.PlayArrow, if (AudioPlayer.isPlaying) "Pause" else "Play", Modifier.size(40.dp), tint = Hue.ink)
            }
            IconButton({ AudioPlayer.next() }) { Icon(Icons.Filled.SkipNext, "Next", Modifier.size(34.dp)) }
            if (isBook) IconButton({ AudioPlayer.seek(AudioPlayer.position + 30_000) }) { Icon(Icons.Filled.Forward30, "Forward 30 seconds") }
            else IconButton({ AudioPlayer.toggleRepeat() }) { Icon(Icons.Filled.Repeat, "Repeat", tint = if (AudioPlayer.repeat) Hue.violet else Color.White) }
        }
        Row(Modifier.fillMaxWidth().padding(top = 6.dp), horizontalArrangement = Arrangement.Center) {
            var speedMenu by remember { mutableStateOf(false) }
            Box {
                TextButton({ speedMenu = true }) { Text("${AudioPlayer.speed}×", color = Hue.secondaryText) }
                DropdownMenu(speedMenu, { speedMenu = false }) {
                    listOf(0.75f, 1f, 1.25f, 1.5f, 1.75f, 2f).forEach { s -> DropdownMenuItem({ Text("$s×") }, { AudioPlayer.setSpeed(s); speedMenu = false }) }
                }
            }
            val ctx = LocalContext.current
            if (!isBook) TextButton({ AudioPlayer.playStation(ctx, Stations.radio("${item.name ?: "Song"} Radio", item.id)) }) {
                Icon(Icons.Filled.Radio, null, Modifier.size(18.dp), tint = Hue.secondaryText); Text(" Start radio", color = Hue.secondaryText)
            }
        }
    }
}

@Composable
private fun QueueList(modifier: Modifier) {
    val c = AppState.client
    LazyColumn(modifier.fillMaxWidth()) {
        AudioPlayer.station?.let { s ->
            item { Row(Modifier.fillMaxWidth().padding(vertical = 10.dp).clip(RoundedCornerShape(14.dp)).background(Hue.card).padding(14.dp)) {
                Icon(Icons.Filled.AllInclusive, null, tint = Hue.violet)
                Column(Modifier.padding(start = 12.dp)) { Text("Playing from ${s.name}", fontWeight = FontWeight.SemiBold)
                    Text("Keeps going with more music automatically", style = MaterialTheme.typography.bodySmall, color = Hue.secondaryText) }
            } }
        }
        item { Text("Up Next", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold, modifier = Modifier.padding(vertical = 8.dp)) }
        itemsIndexed(AudioPlayer.queue.drop(AudioPlayer.index + 1), key = { i, e -> "$i-${e.id}" }) { i, e ->
            Row(Modifier.fillMaxWidth().clickable { AudioPlayer.jump(AudioPlayer.index + 1 + i) }.padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                RemoteImage(c?.albumArtURL(e.item, 120), Modifier.size(42.dp).clip(RoundedCornerShape(8.dp)))
                Column(Modifier.weight(1f).padding(start = 12.dp)) {
                    Text(e.item.name ?: "", maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text(e.item.artistLine ?: "", style = MaterialTheme.typography.bodySmall, color = Hue.secondaryText, maxLines = 1)
                }
                if (e.intro != null) Icon(Icons.Filled.Mic, "DJ intro", Modifier.size(16.dp), tint = Hue.violet)
            }
        }
    }
}

// MARK: Library

private enum class MusicSection(val label: String) { ForYou("For You"), Albums("Albums"), Artists("Artists"), Songs("Songs"), Playlists("Playlists") }

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MusicLibraryScreen(library: BaseItem, nav: NavHostController) {
    var section by rememberSaveable { mutableStateOf(MusicSection.ForYou) }
    val items = remember(section) { mutableStateListOf<BaseItem>() }
    var total by remember(section) { mutableIntStateOf(Int.MAX_VALUE) }
    var loading by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    val ctx = LocalContext.current
    fun loadMore() {
        val c = AppState.client ?: return
        if (loading || items.size >= total || section == MusicSection.ForYou) return
        loading = true
        scope.launch {
            runCatching {
                val start = items.size.toString()
                when (section) {
                    MusicSection.Albums -> c.browse(mapOf("parentId" to library.id, "includeItemTypes" to "MusicAlbum", "recursive" to "true", "sortBy" to "SortName", "startIndex" to start, "limit" to "100"))
                    MusicSection.Artists -> c.albumArtists(library.id, items.size)
                    MusicSection.Songs -> c.browse(mapOf("parentId" to library.id, "includeItemTypes" to "Audio", "recursive" to "true", "sortBy" to "Album,ParentIndexNumber,IndexNumber,SortName", "startIndex" to start, "limit" to "200"))
                    else -> c.browse(mapOf("includeItemTypes" to "Playlist", "recursive" to "true", "mediaTypes" to "Audio", "sortBy" to "SortName", "startIndex" to start, "limit" to "100"))
                }
            }.onSuccess { r -> items += r.items; total = r.totalRecordCount ?: items.size; error = null }
                .onFailure { error = it.message; total = items.size }
            loading = false
        }
    }
    LaunchedEffect(section) { loadMore() }
    Scaffold(containerColor = Color.Transparent, topBar = { HuefinTopBar(library.name ?: "Music", nav) }) { pad ->
        LazyVerticalGrid(gridColumns(if (section == MusicSection.Songs) 1000 else if (section == MusicSection.Artists) 110 else 150),
            Modifier.fillMaxSize().background(Brush.verticalGradient(listOf(Hue.violet.copy(alpha = 0.2f), Hue.night, Hue.night))),
            contentPadding = PaddingValues(16.dp, pad.calculateTopPadding(), 16.dp, 24.dp),
            horizontalArrangement = Arrangement.spacedBy(14.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            item(span = { GridItemSpan(maxLineSpan) }) {
                LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    items(MusicSection.entries) { s ->
                        FilterChip(s == section, { section = s }, { Text(s.label) },
                            colors = FilterChipDefaults.filterChipColors(selectedContainerColor = LocalHue.current, selectedLabelColor = Hue.ink))
                    }
                }
            }
            error?.let { item(span = { GridItemSpan(maxLineSpan) }) { ErrorBanner(it) } }
            if (section == MusicSection.ForYou) item(span = { GridItemSpan(maxLineSpan) }) { ForYou(library, nav) }
            if (section == MusicSection.Songs && items.isNotEmpty()) item(span = { GridItemSpan(maxLineSpan) }) {
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    PlayButton({ AudioPlayer.play(ctx, items.toList()) }) { Icon(Icons.Filled.PlayArrow, null); Text(" Play") }
                    SoftButton({ AudioPlayer.play(ctx, items.shuffled()) }) { Icon(Icons.Filled.Shuffle, null); Text(" Shuffle") }
                }
            }
            gridItemsIndexed(items, key = { _, it -> it.id }) { i, it ->
                if (i == items.lastIndex) LaunchedEffect(i) { loadMore() }
                when (section) {
                    MusicSection.Songs -> TrackRow(it, null, showArt = true) { AudioPlayer.play(ctx, items.toList(), i) }
                    MusicSection.Artists -> SquareCard(it, { nav.openItem(it) }, width = Dp.Unspecified, circle = true)
                    else -> SquareCard(it, { nav.openItem(it) }, width = Dp.Unspecified)
                }
            }
            if (loading) item(span = { GridItemSpan(maxLineSpan) }) { Box(Modifier.fillMaxWidth().padding(16.dp), Alignment.Center) { CircularProgressIndicator() } }
        }
    }
}

@Composable
private fun ForYou(library: BaseItem, nav: NavHostController) {
    val ctx = LocalContext.current
    var genres by remember { mutableStateOf<List<BaseItem>>(emptyList()) }
    var artists by remember { mutableStateOf<List<NameId>>(emptyList()) }
    var starting by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    LaunchedEffect(library.id) {
        val c = AppState.client ?: return@LaunchedEffect
        genres = runCatching { c.musicGenres(library.id) }.getOrDefault(emptyList())
        artists = c.songs(library.id, "PlayCount", filters = "IsPlayed", limit = 80).mapNotNull { it.artistItems?.firstOrNull() }.distinctBy { it.id }.take(12)
    }
    fun start(s: Station) {
        if (starting != null) return
        starting = s.name
        AudioPlayer.playStation(ctx, s)
        scope.launch { kotlinx.coroutines.delay(1500); starting = null; if (AudioPlayer.current != null) AudioPlayer.showNowPlaying = true }
    }
    Column(verticalArrangement = Arrangement.spacedBy(24.dp)) {
        // The DJ card.
        Box(Modifier.fillMaxWidth().clip(RoundedCornerShape(24.dp)).background(Brush.linearGradient(listOf(Hue.violet, Hue.coral, Hue.amber)))
            .clickable { start(Stations.dj(library.id)) }.padding(22.dp)) {
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) { Icon(Icons.Filled.GraphicEq, null, tint = Hue.ink); Text("  HUEFIN DJ", color = Hue.ink, fontWeight = FontWeight.Black) }
                Text("Your music, mixed for you", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.ExtraBold, color = Hue.ink)
                Text("Heavy rotation, favorites, throwbacks and new finds, with a voice between sets.", color = Hue.ink.copy(alpha = 0.8f))
                Spacer(Modifier.height(6.dp))
                Row(Modifier.clip(RoundedCornerShape(50)).background(Hue.ink).padding(horizontal = 18.dp, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
                    if (starting == "Huefin DJ") CircularProgressIndicator(Modifier.size(18.dp), color = Color.White, strokeWidth = 2.dp)
                    else Icon(if (AudioPlayer.station?.name == "Huefin DJ") Icons.Filled.GraphicEq else Icons.Filled.PlayArrow, null, tint = Color.White)
                    Text(if (AudioPlayer.station?.name == "Huefin DJ") "  Playing" else "  Start", color = Color.White, fontWeight = FontWeight.Bold)
                }
            }
        }
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text("Stations", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
            val tiles = listOf(
                Triple(Stations.heavyRotation(library.id), "Your most played", Icons.Filled.LocalFireDepartment) to listOf(Hue.amber, Hue.coral),
                Triple(Stations.favorites(library.id), "Songs you've hearted", Icons.Filled.Favorite) to listOf(Hue.coral, Hue.violet),
                Triple(Stations.throwbacks(library.id), "Not played in a while", Icons.Filled.History) to listOf(Hue.mint, Hue.sky),
                Triple(Stations.discover(library.id), "Never played yet", Icons.Filled.AutoAwesome) to listOf(Hue.sun, Hue.mint),
                Triple(Stations.shuffleAll(library.id), "Your whole music library", Icons.Filled.Shuffle) to listOf(Hue.sky, Hue.violet))
            tiles.chunked(2).forEach { row ->
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    row.forEach { (t, colors) ->
                        Column(Modifier.weight(1f).clip(RoundedCornerShape(18.dp)).background(Brush.linearGradient(colors)).clickable { start(t.first) }.padding(16.dp)) {
                            if (starting == t.first.name) CircularProgressIndicator(Modifier.size(22.dp), color = Hue.ink, strokeWidth = 2.dp) else Icon(t.third, null, tint = Hue.ink)
                            Spacer(Modifier.height(10.dp))
                            Text(if (t.first.name == "Shuffle All") "Shuffle Everything" else t.first.name, color = Hue.ink, fontWeight = FontWeight.ExtraBold)
                            Text(t.second, color = Hue.ink.copy(alpha = 0.75f), style = MaterialTheme.typography.bodySmall)
                        }
                    }
                    if (row.size == 1) Spacer(Modifier.weight(1f))
                }
            }
        }
        if (artists.isNotEmpty()) Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text("Artist Radio", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
            LazyRow(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                items(artists, key = { it.id }) { a ->
                    Column(Modifier.width(96.dp).clickable { start(Stations.radio("${a.name ?: "Artist"} Radio", a.id)) }, horizontalAlignment = Alignment.CenterHorizontally) {
                        Box { RemoteImage(AppState.client?.imageURL(a.id, maxWidth = 240), Modifier.size(96.dp).clip(CircleShape))
                            Icon(Icons.Filled.Radio, null, Modifier.align(Alignment.BottomEnd).clip(CircleShape).background(Hue.violet).padding(5.dp).size(16.dp), tint = Hue.ink) }
                        Text(a.name ?: "", style = MaterialTheme.typography.labelMedium, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(top = 6.dp))
                    }
                }
            }
        }
        if (genres.isNotEmpty()) Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text("Genre Radio", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
            LazyRow(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                items(genres, key = { it.id }) { g ->
                    val hue = (kotlin.math.abs((g.name ?: "").hashCode()) % 360).toFloat()
                    Text(g.name ?: "", fontWeight = FontWeight.Bold, modifier = Modifier.clip(RoundedCornerShape(14.dp))
                        .background(Brush.linearGradient(listOf(Color.hsv(hue, 0.75f, 0.75f), Color.hsv((hue + 30) % 360, 0.8f, 0.5f))))
                        .clickable { start(Stations.radio("${g.name ?: "Genre"} Radio", g.id)) }.padding(horizontal = 16.dp, vertical = 12.dp))
                }
            }
        }
    }
}

/** One song: tap to play, long-press for Play Next / Add to Queue / Start Radio. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun TrackRow(track: BaseItem, number: Int?, showArt: Boolean = false, onPlay: () -> Unit) {
    val ctx = LocalContext.current
    var menu by remember { mutableStateOf(false) }
    val playing = AudioPlayer.current?.id == track.id
    Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(10.dp)).combinedClickable(onClick = onPlay, onLongClick = { menu = true }).padding(vertical = 8.dp, horizontal = 4.dp),
        verticalAlignment = Alignment.CenterVertically) {
        if (showArt) RemoteImage(AppState.client?.albumArtURL(track, 120), Modifier.size(44.dp).clip(RoundedCornerShape(8.dp)))
        else Text(number?.toString() ?: "", Modifier.width(28.dp), color = if (playing) LocalHue.current else Hue.secondaryText, textAlign = TextAlign.Center)
        Column(Modifier.weight(1f).padding(horizontal = 12.dp)) {
            Text(track.name ?: "", maxLines = 1, overflow = TextOverflow.Ellipsis, color = if (playing) LocalHue.current else Color.Unspecified, fontWeight = FontWeight.SemiBold)
            Text(listOfNotNull(track.artistLine, if (showArt) track.album else null).joinToString(" · "), style = MaterialTheme.typography.bodySmall, color = Hue.secondaryText, maxLines = 1)
        }
        if (DownloadManager.records[track.id] != null) Icon(Icons.Filled.DownloadDone, "Downloaded", Modifier.size(16.dp), tint = Hue.mint)
        Text(track.runTimeTicks?.let(::formatTicks) ?: "", style = MaterialTheme.typography.labelSmall, color = Hue.secondaryText, modifier = Modifier.padding(horizontal = 6.dp))
        Box {
            IconButton({ menu = true }) { Icon(Icons.Filled.MoreVert, "More") }
            DropdownMenu(menu, { menu = false }) {
                DropdownMenuItem({ Text("Play Next") }, { AudioPlayer.addNext(listOf(track)); menu = false })
                DropdownMenuItem({ Text("Add to Queue") }, { AudioPlayer.addToQueue(listOf(track)); menu = false })
                DropdownMenuItem({ Text("Start Radio") }, { AudioPlayer.playStation(ctx, Stations.radio("${track.name ?: "Song"} Radio", track.id)); menu = false })
                if (DownloadManager.records[track.id] == null) DropdownMenuItem({ Text("Download") }, { DownloadManager.start(track); menu = false })
            }
        }
    }
}

@Composable
private fun CollectionHeader(art: String?, title: String, subtitle: String?, meta: String, onPlay: () -> Unit, onShuffle: () -> Unit, onRadio: (() -> Unit)?, onDownload: (() -> Unit)?) {
    val wide = LocalWidthClass.current == WidthClass.Expanded
    val content: @Composable () -> Unit = {
        Column(horizontalAlignment = if (wide) Alignment.Start else Alignment.CenterHorizontally) {
            Text(title, style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.ExtraBold, textAlign = if (wide) TextAlign.Start else TextAlign.Center)
            subtitle?.let { Text(it, color = LocalHue.current, fontWeight = FontWeight.SemiBold) }
            Text(meta, style = MaterialTheme.typography.bodySmall, color = Hue.secondaryText)
            Spacer(Modifier.height(14.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                PlayButton(onPlay) { Icon(Icons.Filled.PlayArrow, null); Text(" Play") }
                SoftButton(onShuffle) { Icon(Icons.Filled.Shuffle, null); Text(" Shuffle") }
                onRadio?.let { SoftButton(it, padding = PaddingValues(12.dp)) { Icon(Icons.Filled.Radio, "Start radio") } }
                onDownload?.let { SoftButton(it, padding = PaddingValues(12.dp)) { Icon(Icons.Filled.Download, "Download all") } }
            }
        }
    }
    if (wide) Row(Modifier.fillMaxWidth().padding(vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
        RemoteImage(art, Modifier.size(240.dp).clip(RoundedCornerShape(18.dp))); Spacer(Modifier.width(24.dp)); content()
    } else Column(Modifier.fillMaxWidth().padding(vertical = 12.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        RemoteImage(art, Modifier.size(230.dp).clip(RoundedCornerShape(18.dp))); Spacer(Modifier.height(16.dp)); content()
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AlbumScreen(album: BaseItem, nav: NavHostController) {
    val ctx = LocalContext.current
    var tracks by remember { mutableStateOf<List<BaseItem>>(emptyList()) }
    var error by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(album.id) {
        val c = AppState.client ?: return@LaunchedEffect
        runCatching { if (album.type == "Playlist") c.playlistItems(album.id) else c.albumTracks(album.id) }.onSuccess { tracks = it }.onFailure { error = it.message }
    }
    val total = tracks.sumOf { it.runTimeTicks ?: 0 }
    Scaffold(containerColor = Color.Transparent, topBar = { HuefinTopBar("", nav) }) { pad ->
        LazyColumn(Modifier.fillMaxSize().background(Brush.verticalGradient(listOf(Hue.violet.copy(alpha = 0.25f), Hue.night))),
            contentPadding = PaddingValues(16.dp, pad.calculateTopPadding(), 16.dp, 24.dp)) {
            item {
                CollectionHeader(AppState.client?.albumArtURL(album, 700), album.name ?: "", album.artistLine,
                    listOfNotNull(album.productionYear?.toString(), "${tracks.size} songs", if (total > 0) formatTicks(total) else null).joinToString(" · "),
                    { AudioPlayer.play(ctx, tracks) }, { AudioPlayer.play(ctx, tracks.shuffled()) },
                    { AudioPlayer.playStation(ctx, Stations.radio("${album.name ?: "Album"} Radio", album.id)) },
                    { tracks.filter { DownloadManager.records[it.id] == null }.forEach { DownloadManager.start(it) } })
            }
            error?.let { item { ErrorBanner(it) } }
            val multiDisc = tracks.mapNotNull { it.parentIndexNumber }.distinct().size > 1
            itemsIndexed(tracks, key = { _, t -> t.id }) { i, t ->
                if (multiDisc && (i == 0 || tracks[i - 1].parentIndexNumber != t.parentIndexNumber))
                    Eyebrow("Disc ${t.parentIndexNumber ?: 1}", Hue.secondaryText)
                TrackRow(t, if (album.type == "Playlist") null else t.indexNumber, showArt = album.type == "Playlist") { AudioPlayer.play(ctx, tracks, i) }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ArtistScreen(artist: BaseItem, nav: NavHostController) {
    val ctx = LocalContext.current
    var albums by remember { mutableStateOf<List<BaseItem>>(emptyList()) }
    var top by remember { mutableStateOf<List<BaseItem>>(emptyList()) }
    LaunchedEffect(artist.id) {
        val c = AppState.client ?: return@LaunchedEffect
        albums = runCatching { c.artistAlbums(artist.id) }.getOrDefault(emptyList())
        top = runCatching { c.browse(mapOf("artistIds" to artist.id, "includeItemTypes" to "Audio", "recursive" to "true", "sortBy" to "PlayCount,SortName", "sortOrder" to "Descending", "limit" to "10")).items }.getOrDefault(emptyList())
    }
    Scaffold(containerColor = Color.Transparent, topBar = { HuefinTopBar("", nav) }) { pad ->
        LazyVerticalGrid(gridColumns(150), Modifier.fillMaxSize().background(Brush.verticalGradient(listOf(Hue.violet.copy(alpha = 0.25f), Hue.night))),
            contentPadding = PaddingValues(16.dp, pad.calculateTopPadding(), 16.dp, 24.dp),
            horizontalArrangement = Arrangement.spacedBy(14.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            item(span = { GridItemSpan(maxLineSpan) }) {
                Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally) {
                    RemoteImage(AppState.client?.imageURL(artist.id, maxWidth = 500, tag = artist.imageTag("Primary")), Modifier.size(180.dp).clip(CircleShape))
                    Text(artist.name ?: "", style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.ExtraBold, modifier = Modifier.padding(top = 12.dp))
                    Row(Modifier.padding(top = 12.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        PlayButton({ AudioPlayer.playStation(ctx, Stations.radio("${artist.name ?: "Artist"} Radio", artist.id)) }) { Icon(Icons.Filled.Radio, null); Text(" Radio") }
                        SoftButton({ scopeShuffle(ctx, artist) }) { Icon(Icons.Filled.Shuffle, null); Text(" Shuffle") }
                    }
                }
            }
            if (top.isNotEmpty()) {
                item(span = { GridItemSpan(maxLineSpan) }) { ShelfTitle("Top songs") }
                gridItemsIndexed(top, key = { _, t -> "top" + t.id }, span = { _, _ -> GridItemSpan(maxLineSpan) }) { i, t -> TrackRow(t, i + 1) { AudioPlayer.play(ctx, top, i) } }
            }
            if (albums.isNotEmpty()) item(span = { GridItemSpan(maxLineSpan) }) { ShelfTitle("Albums") }
            gridItemsIndexed(albums, key = { _, a -> a.id }) { _, a -> SquareCard(a, { nav.openItem(a) }, width = Dp.Unspecified) }
        }
    }
}

private fun scopeShuffle(ctx: android.content.Context, artist: BaseItem) {
    AppState.scope.launch {
        val c = AppState.client ?: return@launch
        val songs = runCatching { c.browse(mapOf("artistIds" to artist.id, "includeItemTypes" to "Audio", "recursive" to "true", "sortBy" to "Random", "limit" to "100")).items }.getOrDefault(emptyList())
        if (songs.isNotEmpty()) AudioPlayer.play(ctx, songs)
    }
}

