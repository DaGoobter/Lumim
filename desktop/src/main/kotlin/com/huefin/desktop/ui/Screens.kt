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
import com.huefin.desktop.core.AppState
import com.huefin.desktop.core.BaseItem
import com.huefin.desktop.core.JellyfinClient
import com.huefin.desktop.core.Prefs
import com.huefin.desktop.core.ProgramInfo
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
                    item.overview?.let { Text(it, maxLines = 3, overflow = TextOverflow.Ellipsis, color = Color.White.copy(alpha = 0.85f)) }
                    Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        PlayButton({ playOrResume(item) }) { Icon(Icons.Filled.PlayArrow, null); Text(if ((item.progress ?: 0.0) > 0) " Resume" else " Play") }
                        SoftButton({ Nav.open(item) }) { Icon(Icons.Filled.Info, null); Text(" Details") }
                    }
                }
            }
        }
        Row(Modifier.align(Alignment.BottomEnd).padding(40.dp), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            items.indices.forEach { i -> Box(Modifier.size(if (i == index) 22.dp else 8.dp, 8.dp).clip(CircleShape).background(if (i == index) LocalHue.current else Color.White.copy(alpha = 0.3f)).clickable { index = i }) }
        }
    }
}

// MARK: Library

@Composable
fun LibrariesScreen() {
    var views by remember { mutableStateOf<List<BaseItem>>(emptyList()) }
    var error by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(AppState.client) { runCatching { AppState.client?.userViews() ?: emptyList() }.onSuccess { views = it }.onFailure { error = it.message } }
    Column {
        PageHeader("Library")
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
        it.type == "MusicAlbum" || it.type == "Playlist" && it.mediaType == "Audio" -> AlbumScreen(it)
        it.type == "MusicArtist" -> ArtistScreen(it)
        it.type in setOf("CollectionFolder", "Folder", "BoxSet", "UserView", "Playlist") -> LibraryGrid(it)
        else -> DetailScreen(it)
    }
}

@Composable
private fun ArtistScreen(artist: BaseItem) {
    var albums by remember { mutableStateOf<List<BaseItem>>(emptyList()) }
    LaunchedEffect(artist.id) { albums = runCatching { AppState.client!!.artistAlbums(artist.id) }.getOrDefault(emptyList()) }
    Column {
        PageHeader(artist.name ?: "")
        LazyVerticalGrid(GridCells.Adaptive(168.dp), contentPadding = PaddingValues(24.dp), horizontalArrangement = Arrangement.spacedBy(18.dp), verticalArrangement = Arrangement.spacedBy(22.dp)) {
            gridItems(albums, key = { it.id }) { a -> SquareCard(a, { Nav.open(a) }, Dp.Unspecified) }
        }
    }
}

@Composable
private fun AlbumScreen(album: BaseItem) {
    var tracks by remember { mutableStateOf<List<BaseItem>>(emptyList()) }
    LaunchedEffect(album.id) { tracks = runCatching { AppState.client!!.browse(mapOf("parentId" to album.id, "includeItemTypes" to "Audio", "recursive" to "true", "sortBy" to "ParentIndexNumber,IndexNumber,SortName")).items }.getOrDefault(emptyList()) }
    Column {
        PageHeader(album.name ?: "")
        LazyColumn(contentPadding = PaddingValues(24.dp)) {
            item {
                Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(bottom = 20.dp)) {
                    RemoteImage(AppState.client?.albumArtURL(album, 600), Modifier.size(220.dp).clip(RoundedCornerShape(16.dp)))
                    Column(Modifier.padding(start = 24.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text(album.name ?: "", style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.ExtraBold)
                        album.artistLine?.let { Text(it, color = LocalHue.current) }
                        Text("Plays one song at a time on Windows for now; full music, DJ and stations are coming.", color = Hue.secondaryText, style = MaterialTheme.typography.bodySmall)
                    }
                }
            }
            items(tracks, key = { it.id }) { t ->
                Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(10.dp)).clickable { Nav.play(t) }.padding(10.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text("${t.indexNumber ?: ""}", Modifier.width(36.dp), color = Hue.secondaryText)
                    Text(t.name ?: "", Modifier.weight(1f), fontWeight = FontWeight.SemiBold)
                    Text(t.runtimeText ?: "", color = Hue.secondaryText)
                }
            }
        }
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
                    item.overview?.let { Text(it, maxLines = 5, overflow = TextOverflow.Ellipsis, color = Color.White.copy(alpha = 0.88f)) }
                    Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                        if (item.isPlayable || item.isSeries || item.isAudio) PlayButton({ playOrResume(item) }) {
                            Icon(Icons.Filled.PlayArrow, null); Text(if ((item.progress ?: 0.0) > 0) " Resume ${item.runTimeTicks?.let { formatLeft(it - item.resumeTicks) } ?: ""}" else " Play")
                        }
                        if ((item.progress ?: 0.0) > 0) SoftButton({ Nav.play(item, 0) }) { Icon(Icons.Filled.Replay, null); Text(" From start") }
                        val played = item.userData?.played == true
                        SoftButton({ scope.launch { c?.markPlayed(item.id, !played); refresh() } }, padding = PaddingValues(12.dp)) {
                            Icon(if (played) Icons.Filled.CheckCircle else Icons.Filled.CheckCircleOutline, if (played) "Mark unwatched" else "Mark watched", tint = if (played) LocalHue.current else Color.White)
                        }
                        val fav = item.userData?.isFavorite == true
                        SoftButton({ scope.launch { c?.setFavorite(item.id, !fav); refresh() } }, padding = PaddingValues(12.dp)) {
                            Icon(if (fav) Icons.Filled.Favorite else Icons.Filled.FavoriteBorder, if (fav) "Remove from My List" else "Add to My List", tint = if (fav) Hue.coral else Color.White)
                        }
                    }
                    item.progress?.let { ProgressBar(it, Modifier.width(320.dp)) }
                }
            }
        }
        if (seasons.isNotEmpty()) {
            item {
                LazyRow(contentPadding = PaddingValues(horizontal = 40.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    items(seasons, key = { it.id }) { s ->
                        val sel = s.id == season?.id
                        Text(s.name ?: "Season", Modifier.clip(RoundedCornerShape(12.dp)).background(if (sel) LocalHue.current else Hue.card).clickable { season = s }.padding(horizontal = 16.dp, vertical = 9.dp),
                            color = if (sel) Hue.ink else Color.White, fontWeight = FontWeight.SemiBold)
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
                    IconButton({ Nav.open(ep) }) { Icon(Icons.Filled.Info, "Episode details", tint = Hue.secondaryText) }
                }
            }
        }
        if (similar.isNotEmpty()) item { Column(Modifier.padding(top = 30.dp)) { Shelf("More Like This") { items(similar, key = { it.id }) { PosterCard(it, { Nav.open(it) }) } } } }
        item { Spacer(Modifier.height(60.dp)) }
    }
}

private fun formatLeft(ticks: Long): String { val m = (ticks / 600_000_000L).toInt(); return if (m >= 60) "· ${m / 60}h ${m % 60}m left" else "· ${m}m left" }

// MARK: Search

@Composable
fun SearchScreen() {
    var query by remember { mutableStateOf("") }
    var results by remember { mutableStateOf<List<BaseItem>>(emptyList()) }
    var searching by remember { mutableStateOf(false) }
    LaunchedEffect(query) {
        val q = query.trim()
        if (q.length < 2) { results = emptyList(); return@LaunchedEffect }
        delay(300); searching = true
        results = runCatching { AppState.client!!.search(q) }.getOrDefault(emptyList()); searching = false
    }
    val groups = listOf("Movies" to setOf("Movie"), "Shows" to setOf("Series"), "Episodes" to setOf("Episode"), "Collections" to setOf("BoxSet"),
        "Channels" to setOf("TvChannel"), "Artists" to setOf("MusicArtist"), "Albums" to setOf("MusicAlbum"), "Songs" to setOf("Audio"), "Books" to setOf("Book", "AudioBook"))
    Column {
        PageHeader("Search")
        OutlinedTextField(query, { query = it }, Modifier.padding(horizontal = 24.dp).widthIn(max = 720.dp).fillMaxWidth(), singleLine = true,
            placeholder = { Text("Movies, shows, episodes, people, channels…") }, leadingIcon = { Icon(Icons.Filled.Search, null) },
            trailingIcon = { if (searching) CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp) }, shape = RoundedCornerShape(16.dp))
        LazyColumn(contentPadding = PaddingValues(vertical = 20.dp), verticalArrangement = Arrangement.spacedBy(24.dp)) {
            if (query.trim().length >= 2 && !searching && results.isEmpty()) item { Text("Nothing on your server matches \"${query.trim()}\".", Modifier.padding(24.dp), color = Hue.secondaryText) }
            groups.forEach { (title, types) ->
                val list = results.filter { it.type in types }
                if (list.isNotEmpty()) item(key = title) {
                    Shelf(title) {
                        items(list, key = { it.id }) { r ->
                            when (r.type) {
                                "Episode" -> LandscapeCard(r, { Nav.open(r) }, subtitle = r.episodeLabel)
                                "TvChannel" -> SquareCard(r, { Nav.play(r) })
                                "Audio" -> SquareCard(r, { Nav.play(r) })
                                "MusicArtist" -> SquareCard(r, { Nav.open(r) }, circle = true)
                                "MusicAlbum" -> SquareCard(r, { Nav.open(r) })
                                else -> PosterCard(r, { Nav.open(r) })
                            }
                        }
                    }
                }
            }
        }
    }
}

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
                    Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(18.dp)).background(Color.White.copy(alpha = 0.06f)).clickable { Nav.play(ch) }.padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
                        Box(Modifier.size(104.dp, 64.dp).clip(RoundedCornerShape(12.dp)).background(Color.White.copy(alpha = 0.08f)), Alignment.Center) {
                            Text((ch.name ?: "TV").take(3).uppercase(), fontWeight = FontWeight.Black, color = Color.White.copy(alpha = 0.5f))
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

// MARK: Settings

@Composable
fun SettingsScreen() {
    val scope = rememberCoroutineScope()
    var adding by remember { mutableStateOf(false) }
    var local by remember { mutableStateOf(if (AppState.session?.localURLIsManual == true) AppState.session?.localURL ?: "" else "") }
    var tick by remember { mutableIntStateOf(0) }
    if (adding) { LoginScreen(adding = true) { adding = false }; return }
    key(tick) {
    Column {
        PageHeader("Settings")
        Column(Modifier.verticalScroll(rememberScrollState()).padding(24.dp).widthIn(max = 760.dp), verticalArrangement = Arrangement.spacedBy(22.dp)) {
            Section("Accounts") {
                AppState.accounts.forEach { a ->
                    val current = a.key == AppState.session?.key
                    Row(Modifier.fillMaxWidth().clickable { if (!current) AppState.switchTo(a) }.padding(14.dp), verticalAlignment = Alignment.CenterVertically) {
                        Avatar(a.userName, 36.dp)
                        Column(Modifier.weight(1f).padding(start = 12.dp)) { Text(a.userName, fontWeight = FontWeight.SemiBold); Text(a.serverName ?: a.serverURL, color = Hue.secondaryText, style = MaterialTheme.typography.bodySmall) }
                        if (current) Icon(Icons.Filled.CheckCircle, "Current", tint = LocalHue.current) else TextButton({ AppState.switchTo(a) }) { Text("Switch") }
                        TextButton({ scope.launch { AppState.remove(a) } }) { Text("Sign out", color = Hue.coral) }
                    }
                }
                Row(Modifier.fillMaxWidth().clickable { adding = true }.padding(14.dp), verticalAlignment = Alignment.CenterVertically) { Icon(Icons.Filled.PersonAdd, null); Text("  Add user or server") }
            }
            Section("Connection", "At home Huefin talks to your server directly (faster, full quality); away it uses your remote address. Leave the home address empty to detect it.") {
                Row(Modifier.padding(14.dp)) { Text("Using", Modifier.weight(1f)); Text(if (AppState.route == AppState.Route.Local) "Home network" else "Remote address", color = Hue.secondaryText) }
                Row(Modifier.padding(14.dp)) { Text("Home address check", Modifier.weight(1f)); Text(AppState.localStatus, color = Hue.secondaryText) }
                Toggle("Use home network when available", AppState.preferLocal) { AppState.preferLocal = it; AppState.persistSettings(); scope.launch { AppState.refreshRoute() }; tick++ }
                Row(Modifier.padding(14.dp), verticalAlignment = Alignment.CenterVertically) {
                    OutlinedTextField(local, { local = it }, Modifier.weight(1f), singleLine = true, label = { Text("Home network address") }, placeholder = { Text("Auto-detect") })
                    TextButton({ AppState.setLocalURL(local) }) { Text("Save & reconnect") }
                }
            }
            Section("Playback", "Keep Maximum for the original file. Lower it only if playback away from home stutters.") {
                Row(Modifier.padding(14.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text("Max streaming quality", Modifier.weight(1f))
                    Menu(if (AppState.maxBitrate >= 200_000_000) "Maximum" else "${AppState.maxBitrate / 1_000_000} Mbps", Icons.Filled.Speed,
                        listOf(200, 80, 40, 20, 10, 8, 4).map { m -> (if (m == 200) "Maximum" else "$m Mbps") to { AppState.maxBitrate = m * 1_000_000; AppState.persistSettings(); tick++ } })
                }
                Toggle("Skip intros automatically", Prefs.autoSkipIntro) { Prefs.set(Prefs.Keys.autoIntro, it); tick++ }
                Toggle("Skip credits to the next episode", Prefs.autoSkipCredits) { Prefs.set(Prefs.Keys.autoCredits, it); tick++ }
            }
            Section("Keyboard in the player") {
                Text("Space pause · ← → 10 seconds · ↑ ↓ volume · F full screen · M mute · S skip intro · Esc back", Modifier.padding(14.dp), color = Hue.secondaryText)
            }
            Section(footer = "Huefin for Windows ${JellyfinClient.VERSION}") {
                Row(Modifier.fillMaxWidth().clickable { scope.launch { AppState.logout() } }.padding(14.dp), verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.AutoMirrored.Filled.Logout, null, tint = Hue.coral); Text("  Sign out", color = Hue.coral)
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
