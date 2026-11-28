package com.huefin.desktop.ui

import androidx.compose.animation.Crossfade
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.itemsIndexed
import androidx.compose.foundation.lazy.grid.items as gridItems
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Logout
import androidx.compose.material.icons.automirrored.filled.Sort
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.huefin.desktop.core.StudioBrand
import com.huefin.desktop.core.AppState
import com.huefin.desktop.core.BaseItem
import com.huefin.desktop.core.JellyfinClient
import com.huefin.desktop.core.Prefs
import com.huefin.desktop.core.ProgramInfo
import com.huefin.desktop.downloads.DownloadManager
import com.huefin.desktop.downloads.DownloadState
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle

/** Play now: series pick up their next episode; everything else resumes where you left off. */
fun playOrResume(item: BaseItem) {
    if (item.isSeries) AppState.scope.launch {
        val next = runCatching { AppState.client?.nextUp(item.id)?.firstOrNull() }.getOrNull()
            ?: runCatching { AppState.client?.browse(mapOf("parentId" to item.id, "includeItemTypes" to "Episode", "recursive" to "true",
                "sortBy" to "ParentIndexNumber,IndexNumber", "limit" to "1"))?.items?.firstOrNull() }.getOrNull()
        if (next != null) Nav.play(next, next.resumeTicks) else Nav.open(item)
    } else if (item.isPlayable || item.isAudio) Nav.play(item, item.resumeTicks) else Nav.open(item)
}

// MARK: Home

private data class HomeData(val resume: List<BaseItem>, val nextUp: List<BaseItem>, val myList: List<BaseItem>,
                            val latest: List<Pair<BaseItem, List<BaseItem>>>, val collections: List<BaseItem>)
private object HomeCache { var data: HomeData? = null; var key: String? = null }

@Composable
fun HomeScreen() {
    val key = AppState.session?.key
    var data by remember { mutableStateOf(if (HomeCache.key == key) HomeCache.data else null) }
    var error by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    suspend fun load() {
        val c = AppState.client ?: return
        try {
            data = coroutineScope {
                val r = async { runCatching { c.resume() }.getOrDefault(emptyList()) }
                val n = async { runCatching { c.nextUp() }.getOrDefault(emptyList()) }
                val v = async { c.userViews() }
                val fav = async { c.favorites() }
                val col = async { c.collections() }
                val views = v.await().filter { it.collectionType in setOf("movies", "tvshows", "homevideos", "musicvideos", "mixed", null) }
                val latest = views.map { lib -> async { lib to runCatching { c.latest(lib.id) }.getOrDefault(emptyList()) } }.map { it.await() }.filter { it.second.isNotEmpty() }
                HomeData(r.await(), n.await(), fav.await(), latest, col.await())
            }
            HomeCache.data = data; HomeCache.key = key; error = null
        } catch (e: Exception) { error = e.message }
    }
    LaunchedEffect(key) { load() }
    val d = data
    val featured = (d?.resume.orEmpty() + d?.latest?.flatMap { it.second }.orEmpty().filter { it.backdropImageTags?.isNotEmpty() == true })
        .distinctBy { it.id }.take(8)
    LazyColumn(Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(28.dp)) {
        item { if (featured.isNotEmpty()) Hero(featured) else Spacer(Modifier.height(20.dp)) }
        error?.let { item { ErrorBanner(it) { scope.launch { load() } } } }
        if (d == null && error == null) item { Box(Modifier.fillMaxWidth().padding(40.dp), Alignment.Center) { CircularProgressIndicator() } }
        d?.let { h ->
            if (h.resume.isNotEmpty()) item { Shelf("Continue Watching") { items(h.resume, key = { it.id }) { LandscapeCard(it, { playOrResume(it) }) } } }
            if (h.nextUp.isNotEmpty()) item { Shelf("Up Next") { items(h.nextUp, key = { it.id }) { LandscapeCard(it, { playOrResume(it) }) } } }
            if (h.myList.isNotEmpty()) item { Shelf("My List") { items(h.myList, key = { it.id }) { PosterCard(it, { Nav.open(it) }) } } }
            h.latest.forEach { (lib, list) ->
                item(key = "latest-${lib.id}") {
                    Shelf("New in ${lib.name ?: "Library"}") {
                        items(list, key = { it.id }) { if (it.type == "Episode") LandscapeCard(it, { Nav.open(it) }) else PosterCard(it, { Nav.open(it) }) }
                    }
                }
            }
            if (h.collections.isNotEmpty()) item { Shelf("Collections") { items(h.collections, key = { it.id }) { PosterCard(it, { Nav.open(it) }) } } }
        }
        item { Spacer(Modifier.height(40.dp)) }
    }
}

@Composable
private fun Hero(items: List<BaseItem>) {
    var index by remember { mutableIntStateOf(0) }
    LaunchedEffect(items) { while (true) { delay(9000); index = (index + 1) % items.size } }
    val c = AppState.client
    Box(Modifier.fillMaxWidth().height(460.dp)) {
        Crossfade(items[index.coerceIn(0, items.lastIndex)]) { item ->
            Box(Modifier.fillMaxSize()) {
                RemoteImage(c?.backdropURL(item, 1920), Modifier.fillMaxSize())
                Box(Modifier.fillMaxSize().background(Brush.verticalGradient(0.35f to Color.Transparent, 1f to Hue.night)))
                Box(Modifier.fillMaxSize().background(Brush.horizontalGradient(0f to Hue.night.copy(alpha = 0.85f), 0.6f to Color.Transparent)))
                Column(Modifier.align(Alignment.BottomStart).padding(40.dp).widthIn(max = 620.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    val logo = c?.logoURL(item)
                    if (logo != null) RemoteImage(logo, Modifier.height(110.dp).widthIn(max = 420.dp).background(Color.Transparent), ContentScale.Fit)
                    else Text(item.displayTitle, style = MaterialTheme.typography.displaySmall, fontWeight = FontWeight.Black)
                    Text(listOfNotNull(item.episodeLabel, item.productionYear?.toString(), item.officialRating, item.runtimeText).joinToString("  ·  "), color = Hue.secondaryText)
                    item.overview?.let { Text(it, maxLines = 3, overflow = TextOverflow.Ellipsis, color = Hue.text.copy(alpha = 0.85f)) }
                    Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        PlayButton({ playOrResume(item) }) { Icon(Icons.Filled.PlayArrow, null); Text(if ((item.progress ?: 0.0) > 0) " Resume" else " Play") }
                        SoftButton({ Nav.open(item) }) { Icon(Icons.Filled.Info, null); Text(" Details") }
                    }
                }
            }
        }
        Row(Modifier.align(Alignment.BottomEnd).padding(40.dp), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            items.indices.forEach { i -> Box(Modifier.size(if (i == index) 22.dp else 8.dp, 8.dp).clip(CircleShape).background(if (i == index) LocalHue.current else Hue.text.copy(alpha = 0.3f)).clickable { index = i }) }
        }
    }
}

// MARK: Library

@Composable
fun LibrariesScreen() {
    var views by remember { mutableStateOf<List<BaseItem>>(emptyList()) }
    var error by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(AppState.client) { runCatching { AppState.client?.userViews() ?: emptyList() }.onSuccess { views = it }.onFailure { error = it.message } }
    var mode by remember { mutableStateOf(Prefs.string("huefin.libraryMode") ?: "libraries") }
    Column {
        PageHeader("Library")
        Box(Modifier.widthIn(max = 520.dp).padding(horizontal = 8.dp)) {
            BrowseModeRow(mode) { mode = it; Prefs.set("huefin.libraryMode", it) }
        }
        if (mode == "studios" || mode == "networks") {
            StudioGrid(if (mode == "studios") StudioBrand.Kind.Studio else StudioBrand.Kind.Network) { Nav.push(Route.Path("studio/" + it.id)) }
            return@Column
        }
        LazyVerticalGrid(GridCells.Adaptive(340.dp), contentPadding = PaddingValues(24.dp), horizontalArrangement = Arrangement.spacedBy(18.dp), verticalArrangement = Arrangement.spacedBy(18.dp)) {
            error?.let { item(span = { GridItemSpan(maxLineSpan) }) { ErrorBanner(it) } }
            gridItems(views, key = { it.id }) { lib ->
                Box(Modifier.fillMaxWidth().aspectRatio(16f / 9f).clip(RoundedCornerShape(20.dp)).border(1.dp, Hue.hairline, RoundedCornerShape(20.dp))
                    .clickable { if (lib.collectionType == "livetv") Nav.select(Tab.Live) else Nav.open(lib) }) {
                    RemoteImage(AppState.client?.imageURL(lib.id, maxWidth = 800, tag = lib.imageTag("Primary")), Modifier.fillMaxSize())
                    Box(Modifier.fillMaxSize().background(Brush.verticalGradient(0.4f to Color.Transparent, 1f to Color.Black.copy(alpha = 0.85f))))
                    Text(lib.name ?: "", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.ExtraBold, modifier = Modifier.align(Alignment.BottomStart).padding(18.dp))
                }
            }
        }
    }
}

private enum class SortOpt(val label: String, val by: String, val order: String) {
    Name("Name", "SortName", "Ascending"), Added("Recently added", "DateCreated,SortName", "Descending"),
    Released("Release date", "PremiereDate,ProductionYear,SortName", "Descending"), Rating("Rating", "CommunityRating,SortName", "Descending"),
    Random("Random", "Random", "Ascending"),
}
private enum class FilterOpt(val label: String, val api: String?) {
    All("All", null), Unwatched("Unwatched", "IsUnplayed"), Watched("Watched", "IsPlayed"), Favorites("Favorites", "IsFavorite"), InProgress("In progress", "IsResumable"),
}

/** Everything inside a library or folder, with sort, filter and genres. */
@Composable
fun LibraryGrid(parent: BaseItem) {
    val items = remember(parent.id) { mutableStateListOf<BaseItem>() }
    var total by remember(parent.id) { mutableIntStateOf(Int.MAX_VALUE) }
    var loading by remember { mutableStateOf(false) }
    var sort by remember { mutableStateOf(SortOpt.Name) }
    var filter by remember { mutableStateOf(FilterOpt.All) }
    var genre by remember { mutableStateOf<String?>(null) }
    var genres by remember { mutableStateOf<List<String>>(emptyList()) }
    var gen by remember { mutableIntStateOf(0) }
    val scope = rememberCoroutineScope()
    val (types, recursive) = when (parent.collectionType) {
        "movies" -> "Movie" to true; "tvshows" -> "Series" to true; "music" -> "MusicAlbum" to true; "musicvideos" -> "MusicVideo" to true
        "boxsets" -> "BoxSet" to true; "books" -> "Book,AudioBook" to true; else -> null to false
    }
    fun loadMore() {
        val c = AppState.client ?: return
        if (loading || items.size >= total) return
        loading = true
        val g = gen
        scope.launch {
            runCatching { c.items(parent.id, types, recursive, sort.by, sort.order, items.size, 120, filter.api, genre) }
                .onSuccess { if (g == gen) { items += it.items; total = it.totalRecordCount ?: items.size } }
                .onFailure { total = items.size }
            loading = false
        }
    }
    fun reload() { gen++; items.clear(); total = Int.MAX_VALUE; loading = false; loadMore() }
    LaunchedEffect(parent.id) { genres = AppState.client?.genres(parent.id) ?: emptyList(); loadMore() }
    Column {
        PageHeader(parent.name ?: "Library") {
            Menu(sort.label, Icons.AutoMirrored.Filled.Sort, SortOpt.entries.map { it.label to { sort = it; reload() } })
            Menu(filter.label, Icons.Filled.FilterList, FilterOpt.entries.map { it.label to { filter = it; reload() } })
            if (genres.isNotEmpty()) Menu(genre ?: "Genre", Icons.Filled.Category, listOf("All genres" to { genre = null; reload() }) + genres.map { g -> g to { genre = g; reload() } })
        }
        LazyVerticalGrid(GridCells.Adaptive(168.dp), contentPadding = PaddingValues(24.dp, 8.dp, 24.dp, 40.dp),
            horizontalArrangement = Arrangement.spacedBy(18.dp), verticalArrangement = Arrangement.spacedBy(22.dp)) {
            itemsIndexed(items, key = { _, it -> it.id }) { i, it ->
                if (i >= items.size - 20) LaunchedEffect(i) { loadMore() }
                if (it.type == "MusicAlbum" || it.type == "Audio") SquareCard(it, { Nav.open(it) }, Dp.Unspecified) else PosterCard(it, { Nav.open(it) }, Dp.Unspecified)
            }
            if (loading) item(span = { GridItemSpan(maxLineSpan) }) { Box(Modifier.fillMaxWidth().padding(20.dp), Alignment.Center) { CircularProgressIndicator() } }
        }
    }
}

@Composable
fun Menu(label: String, icon: androidx.compose.ui.graphics.vector.ImageVector, options: List<Pair<String, () -> Unit>>) {
    var open by remember { mutableStateOf(false) }
    Box(Modifier.padding(start = 8.dp)) {
        SoftButton({ open = true }, padding = PaddingValues(horizontal = 14.dp, vertical = 8.dp)) { Icon(icon, null, Modifier.size(18.dp)); Text(" $label") }
        DropdownMenu(open, { open = false }, Modifier.heightIn(max = 480.dp)) { options.forEach { (l, f) -> DropdownMenuItem({ Text(l) }, { open = false; f() }) } }
    }
}

private typealias Dp = androidx.compose.ui.unit.Dp

// MARK: Item

/** Opens the right page for any item: a folder grid, a show, a movie, an album. */
@Composable
fun ItemScreen(id: String, preview: BaseItem?) {
    var item by remember { mutableStateOf<BaseItem?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(id) { runCatching { AppState.client!!.item(id) }.onSuccess { item = it }.onFailure { error = it.message } }
    val it = item ?: preview?.takeIf { p -> p.type in setOf("CollectionFolder", "UserView", "Folder", "BoxSet") }
    when {
        it == null -> Column { PageHeader(preview?.displayTitle ?: ""); Box(Modifier.fillMaxSize(), Alignment.Center) { if (error != null) ErrorBanner(error!!) else CircularProgressIndicator() } }
        (it.type == "CollectionFolder" || it.type == "UserView") && it.collectionType == "music" -> MusicLibraryScreen(it, nav)
        (it.type == "CollectionFolder" || it.type == "UserView") && it.collectionType == "books" -> BooksLibraryScreen(it, nav)
        (it.type == "CollectionFolder" || it.type == "UserView") && it.collectionType == "livetv" -> LiveTVScreen()
        it.type == "Book" || it.type == "AudioBook" -> BookScreen(it.id, nav)
        it.type == "MusicAlbum" || it.type == "Playlist" && it.mediaType == "Audio" -> AlbumScreen(it, nav)
        it.type == "MusicArtist" -> ArtistScreen(it, nav)
        it.type in setOf("CollectionFolder", "Folder", "BoxSet", "UserView", "Playlist") -> LibraryGrid(it)
        else -> DetailScreen(it)
    }
}

@Composable
private fun DetailScreen(start: BaseItem) {
    var item by remember { mutableStateOf(start) }
    var seasons by remember { mutableStateOf<List<BaseItem>>(emptyList()) }
    var season by remember { mutableStateOf<BaseItem?>(null) }
    var episodes by remember { mutableStateOf<List<BaseItem>>(emptyList()) }
    var similar by remember { mutableStateOf<List<BaseItem>>(emptyList()) }
    val scope = rememberCoroutineScope()
    val c = AppState.client
    val showId = if (item.type == "Season") item.seriesId else if (item.isSeries) item.id else null
    LaunchedEffect(item.id) {
        val cl = c ?: return@LaunchedEffect
        com.huefin.desktop.player.PlayerController.prefetch(item)   // Instant Play: Play won't wait for the server
        similar = cl.similar(if (item.type == "Season" || item.type == "Episode") item.seriesId ?: item.id else item.id)
        if (showId != null) {
            seasons = runCatching { cl.seasons(showId) }.getOrDefault(emptyList())
            season = if (item.type == "Season") seasons.firstOrNull { it.id == item.id } else
                seasons.firstOrNull { s -> (s.userData?.unplayedItemCount ?: 0) > 0 && (s.indexNumber ?: 0) > 0 } ?: seasons.firstOrNull()
        }
    }
    LaunchedEffect(season?.id) { val s = season ?: return@LaunchedEffect; episodes = runCatching { c!!.episodes(showId!!, s.id) }.getOrDefault(emptyList()) }
    fun refresh() = scope.launch { runCatching { c!!.item(item.id) }.onSuccess { item = it } }
    LazyColumn(Modifier.fillMaxSize()) {
        item {
            Box(Modifier.fillMaxWidth().height(520.dp)) {
                RemoteImage(c?.backdropURL(item, 1920), Modifier.fillMaxSize())
                Box(Modifier.fillMaxSize().background(Brush.verticalGradient(0.3f to Color.Transparent, 1f to Hue.night)))
                Box(Modifier.fillMaxSize().background(Brush.horizontalGradient(0f to Hue.night.copy(alpha = 0.9f), 0.65f to Color.Transparent)))
                Box(Modifier.padding(12.dp)) { IconButton({ Nav.back() }) { Icon(Icons.Filled.ArrowBackIosNew, "Back") } }
                Column(Modifier.align(Alignment.BottomStart).padding(40.dp).widthIn(max = 720.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    val logo = c?.logoURL(item)
                    if (logo != null && item.type != "Episode") RemoteImage(logo, Modifier.height(120.dp).widthIn(max = 460.dp).background(Color.Transparent), ContentScale.Fit)
                    else Text(item.displayTitle, style = MaterialTheme.typography.displaySmall, fontWeight = FontWeight.Black)
                    item.episodeLabel?.let { Text(it, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold) }
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                        listOfNotNull(item.productionYear?.toString(), item.officialRating, item.runtimeText, item.communityRating?.let { "★ %.1f".format(it) }).forEach { Chip(it) }
                        item.mediaSources?.firstOrNull()?.let { src -> src.mediaStreams?.firstOrNull { it.type == "Video" }?.let { v ->
                            listOfNotNull(v.height?.let { h -> if (h >= 2000) "4K" else if (h >= 1000) "HD" else null }, v.videoRangeType?.takeIf { it != "SDR" }).forEach { Chip(it, LocalHue.current.copy(alpha = 0.25f)) } } }
                    }
                    item.genres?.takeIf { it.isNotEmpty() }?.let { Text(it.take(4).joinToString(" · "), color = Hue.secondaryText) }
                    item.overview?.let { Text(it, maxLines = 5, overflow = TextOverflow.Ellipsis, color = Hue.text.copy(alpha = 0.88f)) }
                    Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                        if (item.isPlayable || item.isSeries || item.isAudio) PlayButton({ playOrResume(item) }) {
                            Icon(Icons.Filled.PlayArrow, null); Text(if ((item.progress ?: 0.0) > 0) " Resume ${item.runTimeTicks?.let { formatLeft(it - item.resumeTicks) } ?: ""}" else " Play")
                        }
                        if ((item.progress ?: 0.0) > 0) SoftButton({ Nav.play(item, 0) }) { Icon(Icons.Filled.Replay, null); Text(" From start") }
                        val played = item.userData?.played == true
                        SoftButton({ scope.launch { c?.markPlayed(item.id, !played); refresh() } }, padding = PaddingValues(12.dp)) {
                            Icon(if (played) Icons.Filled.CheckCircle else Icons.Filled.CheckCircleOutline, if (played) "Mark unwatched" else "Mark watched", tint = if (played) LocalHue.current else Hue.text)
                        }
                        if (item.isPlayable && !item.isLiveChannel) DesktopDownloadButton(item)
                        val fav = item.userData?.isFavorite == true
                        SoftButton({ scope.launch { c?.setFavorite(item.id, !fav); refresh() } }, padding = PaddingValues(12.dp)) {
                            Icon(if (fav) Icons.Filled.Favorite else Icons.Filled.FavoriteBorder, if (fav) "Remove from My List" else "Add to My List", tint = if (fav) Hue.coral else Hue.text)
                        }
                    }
                    item.progress?.let { ProgressBar(it, Modifier.width(320.dp)) }
                }
            }
        }
        if (seasons.isNotEmpty()) {
            item {
                Row(Modifier.padding(horizontal = 40.dp, vertical = 8.dp), horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
                    val pending = episodes.filter { DownloadManager.records[it.id] == null }
                    SoftButton({ pending.forEach { DownloadManager.start(it) } }, enabled = pending.isNotEmpty()) {
                        Icon(Icons.Filled.Download, null, Modifier.size(18.dp)); Text(if (pending.isEmpty()) " Season downloaded" else " Download season")
                    }
                    showId?.let { sid ->
                        val rule = DownloadManager.smartRules[sid]
                        Menu(if (rule == null) "Smart downloads: off" else "Keep next ${rule.count} downloaded", Icons.Filled.AutoMode,
                            listOf("Off" to { DownloadManager.setSmart(sid, item.seriesName ?: item.name ?: "Show", 0) }) +
                            listOf(1, 3, 5, 10).map { n -> "Next $n unwatched" to { DownloadManager.setSmart(sid, item.seriesName ?: item.name ?: "Show", n) } })
                    }
                }
            }
            item {
                LazyRow(contentPadding = PaddingValues(horizontal = 40.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    items(seasons, key = { it.id }) { s ->
                        val sel = s.id == season?.id
                        Text(s.name ?: "Season", Modifier.clip(RoundedCornerShape(12.dp)).background(if (sel) LocalHue.current else Hue.card).clickable { season = s }.padding(horizontal = 16.dp, vertical = 9.dp),
                            color = if (sel) Hue.ink else Hue.text, fontWeight = FontWeight.SemiBold)
                    }
                }
            }
            items(episodes, key = { it.id }) { ep ->
                Row(Modifier.padding(horizontal = 32.dp, vertical = 4.dp).widthIn(max = 1100.dp).fillMaxWidth().clip(RoundedCornerShape(14.dp)).clickable { Nav.play(ep, ep.resumeTicks) }.padding(8.dp),
                    verticalAlignment = Alignment.CenterVertically) {
                    Box(Modifier.width(240.dp).aspectRatio(16f / 9f).clip(RoundedCornerShape(12.dp))) {
                        RemoteImage(c?.landscapeURL(ep, 500), Modifier.fillMaxSize())
                        ep.progress?.let { ProgressBar(it, Modifier.align(Alignment.BottomCenter).fillMaxWidth().padding(8.dp)) }
                        WatchedBadge(ep, Modifier.align(Alignment.TopEnd))
                    }
                    Column(Modifier.weight(1f).padding(horizontal = 18.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Text("${ep.indexNumber ?: ""}. ${ep.name ?: ""}", fontWeight = FontWeight.Bold, style = MaterialTheme.typography.titleMedium)
                        Text(ep.runtimeText ?: "", color = Hue.secondaryText, style = MaterialTheme.typography.bodySmall)
                        ep.overview?.let { Text(it, maxLines = 2, overflow = TextOverflow.Ellipsis, color = Hue.secondaryText) }
                    }
                    if (DownloadManager.records[ep.id]?.state == DownloadState.Completed) Icon(Icons.Filled.DownloadDone, "Downloaded", tint = Hue.mint)
                    IconButton({ Nav.open(ep) }) { Icon(Icons.Filled.Info, "Episode details", tint = Hue.secondaryText) }
                }
            }
        }
        if (similar.isNotEmpty()) item { Column(Modifier.padding(top = 30.dp)) { Shelf("More Like This") { items(similar, key = { it.id }) { PosterCard(it, { Nav.open(it) }) } } } }
        item { Spacer(Modifier.height(60.dp)) }
    }
}

private fun formatLeft(ticks: Long): String { val m = (ticks / 600_000_000L).toInt(); return if (m >= 60) "· ${m / 60}h ${m % 60}m left" else "· ${m}m left" }

// MARK: Live TV

private val timeFmt = DateTimeFormatter.ofLocalizedTime(FormatStyle.SHORT).withZone(ZoneId.systemDefault())

@Composable
fun LiveTVScreen() {
    var channels by remember { mutableStateOf<List<BaseItem>>(emptyList()) }
    var guide by remember { mutableStateOf<Map<String, List<ProgramInfo>>>(emptyMap()) }
    var loading by remember { mutableStateOf(true) }
    var search by remember { mutableStateOf("") }
    var now by remember { mutableStateOf(Instant.now()) }
    LaunchedEffect(AppState.client) {
        val c = AppState.client ?: return@LaunchedEffect
        channels = runCatching { c.liveChannels() }.getOrDefault(emptyList())
        guide = runCatching { c.liveGuide(6.0) }.getOrDefault(emptyMap()); loading = false
    }
    LaunchedEffect(Unit) { while (true) { delay(60_000); now = Instant.now() } }
    fun nowOn(ch: BaseItem) = guide[ch.id]?.firstOrNull { (it.start ?: Instant.MAX) <= now && (it.end ?: Instant.MIN) > now } ?: ch.currentProgram
    fun nextOn(ch: BaseItem) = guide[ch.id]?.firstOrNull { (it.start ?: Instant.MIN) > now }
    val q = search.trim()
    val list = if (q.isEmpty()) channels else channels.filter { (it.name ?: "").contains(q, true) || (it.channelNumber ?: "").startsWith(q) || (nowOn(it)?.name ?: "").contains(q, true) }
    Column {
        PageHeader("Live TV") {
            OutlinedTextField(search, { search = it }, Modifier.width(320.dp), singleLine = true, placeholder = { Text("Channels or shows") },
                leadingIcon = { Icon(Icons.Filled.Search, null) }, shape = RoundedCornerShape(14.dp))
        }
        when {
            loading -> Box(Modifier.fillMaxSize(), Alignment.Center) { CircularProgressIndicator() }
            channels.isEmpty() -> Text("No Live TV on this server.", Modifier.padding(24.dp), color = Hue.secondaryText)
            else -> LazyVerticalGrid(GridCells.Adaptive(460.dp), contentPadding = PaddingValues(24.dp), horizontalArrangement = Arrangement.spacedBy(14.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                gridItems(list, key = { it.id }) { ch ->
                    val n = nowOn(ch); val next = nextOn(ch)
                    Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(18.dp)).background(Hue.card).border(if (Hue.light) 1.25.dp else 0.dp, Hue.ink.copy(alpha = 0.9f), RoundedCornerShape(18.dp)).clickable { Nav.play(ch) }.padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
                        Box(Modifier.size(104.dp, 64.dp).clip(RoundedCornerShape(12.dp)).background(Hue.wash), Alignment.Center) {
                            Text((ch.name ?: "TV").take(3).uppercase(), fontWeight = FontWeight.Black, color = Hue.secondaryText)
                            if (ch.imageTag("Primary") != null) RemoteImage(AppState.client?.imageURL(ch.id, maxWidth = 240, tag = ch.imageTag("Primary")), Modifier.fillMaxSize().padding(8.dp).background(Color.Transparent), ContentScale.Fit)
                        }
                        Column(Modifier.weight(1f).padding(horizontal = 14.dp), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                                ch.channelNumber?.let { Text(it, fontWeight = FontWeight.Bold, color = LocalHue.current, style = MaterialTheme.typography.labelMedium) }
                                Text(ch.name ?: "", color = Hue.secondaryText, style = MaterialTheme.typography.labelMedium, maxLines = 1)
                            }
                            Text(n?.name ?: ch.name ?: "Live", fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                            n?.progress(now)?.let { ProgressBar(it, Modifier.width(220.dp)) }
                            next?.start?.let { Text("Next ${timeFmt.format(it)} · ${next.name ?: ""}", style = MaterialTheme.typography.bodySmall, color = Hue.secondaryText, maxLines = 1) }
                        }
                        Icon(Icons.Filled.PlayCircle, "Watch", Modifier.size(30.dp))
                    }
                }
            }
        }
    }
}

@Composable
private fun Section(title: String? = null, footer: String? = null, content: @Composable ColumnScope.() -> Unit) {
    Column {
        title?.let { Eyebrow(it, Hue.secondaryText); Spacer(Modifier.height(8.dp)) }
        Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(18.dp)).background(Hue.card), content = content)
        footer?.let { Text(it, Modifier.padding(6.dp, 8.dp), style = MaterialTheme.typography.bodySmall, color = Hue.secondaryText) }
    }
}

@Composable
private fun Toggle(title: String, on: Boolean, change: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().clickable { change(!on) }.padding(horizontal = 14.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(title, Modifier.weight(1f))
        Switch(on, change, colors = SwitchDefaults.colors(checkedTrackColor = LocalHue.current, checkedThumbColor = Hue.ink))
    }
}

/** Pages reached by name from shared screens (Settings → Family, Requests, Admin…). */
@Composable
fun PathScreen(path: String) {
    when {
        path == "settings" -> SettingsScreen(nav)
        path == "requests" -> RequestsScreen(nav)
        path == "family" -> FamilyScreen(nav)
        path == "quickconnect" -> QuickConnectApproveScreen(nav)
        path == "nowplaying" -> NowPlayingScreen(nav)
        path == "admin" -> com.huefin.desktop.admin.AdminDashboardScreen(nav)
        path.startsWith("admin/user/") -> com.huefin.desktop.admin.AdminUserScreen(path.removePrefix("admin/user/"), nav)
        path.startsWith("admin/") -> com.huefin.desktop.admin.AdminSectionScreen(path.removePrefix("admin/"), nav)
        path.startsWith("book/") -> BookScreen(path.removePrefix("book/"), nav)
        path.startsWith("studio/") -> StudioBrandScreen(path.removePrefix("studio/"), nav)
        else -> PageHeader("Not found")
    }
}

/** Save to this PC: tap to download, shows progress, tap again to retry if it failed. */
@Composable
fun DesktopDownloadButton(item: BaseItem) {
    val rec = DownloadManager.records[item.id]
    SoftButton({ when (rec?.state) { null -> DownloadManager.start(item); DownloadState.Failed -> DownloadManager.retry(item.id); DownloadState.Paused -> DownloadManager.resume(item.id); else -> {} } },
        padding = PaddingValues(12.dp)) {
        when (rec?.state) {
            null -> Icon(Icons.Filled.Download, "Download to this PC")
            DownloadState.Completed -> Icon(Icons.Filled.DownloadDone, "Downloaded", tint = Hue.mint)
            DownloadState.Failed -> Icon(Icons.Filled.Sync, "Download failed, click to retry", tint = Hue.coral)
            DownloadState.Paused -> Icon(Icons.Filled.Pause, "Paused, click to resume")
            else -> Box(Modifier.size(24.dp), Alignment.Center) { CircularProgressIndicator({ rec.progress }, Modifier.size(22.dp), color = Hue.mint, strokeWidth = 3.dp) }
        }
    }
}
