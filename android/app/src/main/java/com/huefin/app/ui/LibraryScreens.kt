package com.huefin.app.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.Sort
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.FilterList
import androidx.compose.material3.CenterAlignedTopAppBar
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.navigation.NavHostController
import com.huefin.app.core.AppState
import com.huefin.app.core.BaseItem

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HuefinTopBar(title: String, nav: NavHostController?, actions: @Composable androidx.compose.foundation.layout.RowScope.() -> Unit = {}) {
    TopAppBar(
        title = { Text(title, fontWeight = FontWeight.Bold, maxLines = 1) },
        navigationIcon = { if (nav != null && nav.previousBackStackEntry != null) IconButton({ nav.popBackStack() }) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") } },
        actions = actions,
        colors = TopAppBarDefaults.topAppBarColors(containerColor = Color.Transparent),
    )
}

@Composable
fun gridColumns(min: Int): GridCells = GridCells.Adaptive(min.dp * cardScale())

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LibrariesScreen(nav: NavHostController) {
    var views by remember { mutableStateOf<List<BaseItem>>(emptyList()) }
    var error by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(AppState.client) {
        runCatching { AppState.client?.userViews() ?: emptyList() }.onSuccess { views = it; error = null }.onFailure { error = it.message }
    }
    var mode by rememberSaveable { mutableStateOf(com.huefin.app.core.Prefs.libraryMode) }
    Scaffold(containerColor = Color.Transparent, topBar = { HuefinTopBar("Library", null) { AccountButton(nav) } }) { pad ->
      Column(Modifier.fillMaxSize().background(Brush.verticalGradient(listOf(LocalHue.current.copy(alpha = 0.22f), Hue.night, Hue.night)))
          .padding(top = pad.calculateTopPadding())) {
        BrowseModeRow(mode) { mode = it; com.huefin.app.core.Prefs.libraryMode = it }
        if (mode == "studios" || mode == "networks") {
            StudioGrid(if (mode == "studios") com.huefin.app.core.StudioBrand.Kind.Studio else com.huefin.app.core.StudioBrand.Kind.Network) {
                nav.navigate("studio/" + android.net.Uri.encode(it.id))
            }
        } else
        LazyVerticalGrid(GridCells.Adaptive(280.dp), Modifier.fillMaxSize(),
            contentPadding = PaddingValues(16.dp, 8.dp, 16.dp, 24.dp),
            horizontalArrangement = Arrangement.spacedBy(14.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            error?.let { item(span = { GridItemSpan(maxLineSpan) }) { ErrorBanner(it) } }
            items(views, key = { it.id }) { lib ->
                Box(Modifier.fillMaxWidth().aspectRatio(16f / 9f).clip(RoundedCornerShape(20.dp))
                    .border(1.dp, Hue.hairline, RoundedCornerShape(20.dp)).clickable { nav.openItem(lib) }) {
                    RemoteImage(AppState.client?.imageURL(lib.id, maxWidth = 700, tag = lib.imageTag("Primary")), Modifier.fillMaxSize())
                    Box(Modifier.fillMaxSize().background(Brush.verticalGradient(0.4f to Color.Transparent, 1f to Color.Black.copy(alpha = 0.85f))))
                    Text(lib.name ?: "", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.ExtraBold,
                        modifier = Modifier.align(Alignment.BottomStart).padding(16.dp))
                }
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
    All("All", null), Unwatched("Unwatched", "IsUnplayed"), Watched("Watched", "IsPlayed"),
    Favorites("Favorites", "IsFavorite"), InProgress("In Progress", "IsResumable"),
}

/** Every item inside a library or folder, with sort, filters and genres. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LibraryGridScreen(id: String, nav: NavHostController) {
    var parent by remember { mutableStateOf<BaseItem?>(null) }
    LaunchedEffect(id) { parent = runCatching { AppState.client?.item(id) }.getOrNull() }
    val p = parent ?: return Box(Modifier.fillMaxSize(), Alignment.Center) { CircularProgressIndicator() }
    LibraryGrid(p, nav)
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LibraryGrid(parent: BaseItem, nav: NavHostController) {
    val items = remember(parent.id) { mutableStateListOf<BaseItem>() }
    var total by remember(parent.id) { mutableIntStateOf(Int.MAX_VALUE) }
    var loading by remember { mutableStateOf(false) }
    var sort by rememberSaveable { mutableStateOf(SortOpt.Name) }
    var filter by rememberSaveable { mutableStateOf(FilterOpt.All) }
    var genre by rememberSaveable { mutableStateOf<String?>(null) }
    var genres by remember { mutableStateOf<List<String>>(emptyList()) }
    var sortMenu by remember { mutableStateOf(false) }
    var filterMenu by remember { mutableStateOf(false) }
    var gen by remember { mutableIntStateOf(0) }
    val filtering = filter != FilterOpt.All || genre != null
    val (types, recursive) = when (parent.collectionType) {
        "movies" -> "Movie" to true
        "tvshows" -> "Series" to true
        "boxsets" -> "BoxSet" to true
        "musicvideos" -> "MusicVideo" to true
        "homevideos" -> null to false
        else -> null to false
    }
    val grid = rememberLazyGridState()

    suspend fun more(g: Int) {
        val c = AppState.client ?: return
        if (loading || items.size >= total) return
        loading = true
        try {
            val r = c.items(parent.id, types, recursive || filtering, sort.by, sort.order, items.size, 100, filter.api, genre)
            if (g == gen) { items += r.items; total = r.totalRecordCount ?: items.size }
        } catch (_: Exception) { total = items.size }
        loading = false
    }
    LaunchedEffect(sort, filter, genre, parent.id) { gen++; items.clear(); total = Int.MAX_VALUE; loading = false; more(gen) }
    LaunchedEffect(parent.id) { genres = AppState.client?.genres(parent.id) ?: emptyList() }
    val nearEnd by remember { derivedStateOf { (grid.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: 0) > items.size - 20 } }
    LaunchedEffect(nearEnd, items.size) { if (nearEnd) more(gen) }

    Scaffold(containerColor = Color.Transparent, topBar = {
        HuefinTopBar(parent.name ?: "Library", nav) {
            Box {
                IconButton({ sortMenu = true }) { Icon(Icons.AutoMirrored.Filled.Sort, "Sort") }
                DropdownMenu(sortMenu, { sortMenu = false }) {
                    SortOpt.entries.forEach { o -> DropdownMenuItem({ Text((if (o == sort) "✓ " else "") + o.label) }, { sort = o; sortMenu = false }) }
                }
            }
            Box {
                IconButton({ filterMenu = true }) { Icon(Icons.Filled.FilterList, "Filter", tint = if (filtering) LocalHue.current else LocalContentColorCompat()) }
                DropdownMenu(filterMenu, { filterMenu = false }) {
                    FilterOpt.entries.forEach { o -> DropdownMenuItem({ Text((if (o == filter) "✓ " else "") + o.label) }, { filter = o; filterMenu = false }) }
                    if (genres.isNotEmpty()) {
                        HorizontalDivider()
                        DropdownMenuItem({ Text((if (genre == null) "✓ " else "") + "Any genre") }, { genre = null; filterMenu = false })
                        genres.forEach { g -> DropdownMenuItem({ Text((if (g == genre) "✓ " else "") + g) }, { genre = g; filterMenu = false }) }
                    }
                }
            }
        }
    }) { pad ->
        Column(Modifier.padding(top = pad.calculateTopPadding())) {
            if (filtering) LazyRow(contentPadding = PaddingValues(horizontal = 16.dp, vertical = 6.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                if (filter != FilterOpt.All) item { FilterChip(filter.label) { filter = FilterOpt.All } }
                genre?.let { g -> item { FilterChip(g) { genre = null } } }
            }
            val wide = parent.collectionType == "homevideos" || items.firstOrNull()?.type in setOf("Episode", "Video")
            LazyVerticalGrid(if (wide) gridColumns(220) else gridColumns(112), state = grid,
                contentPadding = PaddingValues(16.dp), horizontalArrangement = Arrangement.spacedBy(12.dp), verticalArrangement = Arrangement.spacedBy(18.dp)) {
                items(items, key = { it.id }) {
                    if (wide) LandscapeCard(it, { nav.openItem(it) }, width = 400.dp) else PosterCardFill(it) { nav.openItem(it) }
                }
                if (loading) item(span = { GridItemSpan(maxLineSpan) }) { Box(Modifier.fillMaxWidth().padding(20.dp), Alignment.Center) { CircularProgressIndicator() } }
                if (!loading && items.isEmpty() && total != Int.MAX_VALUE) item(span = { GridItemSpan(maxLineSpan) }) {
                    Text(if (filtering) "Nothing matches. Try a different filter." else "Nothing here yet.", color = Hue.secondaryText, modifier = Modifier.padding(40.dp))
                }
            }
        }
    }
}

@Composable
private fun LocalContentColorCompat() = androidx.compose.material3.LocalContentColor.current

@Composable
private fun FilterChip(text: String, clear: () -> Unit) {
    Row(Modifier.clip(RoundedCornerShape(50)).background(LocalHue.current).clickable(onClick = clear).padding(horizontal = 12.dp, vertical = 7.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(text, color = Hue.ink, fontWeight = FontWeight.SemiBold, style = MaterialTheme.typography.labelLarge)
        Icon(Icons.Filled.Close, "Clear", tint = Hue.ink, modifier = Modifier.padding(0.dp))
    }
}

/** Poster that fills its grid cell. */
@Composable
fun PosterCardFill(item: BaseItem, onClick: () -> Unit) {
    Column(Modifier.fillMaxWidth().clickable(onClick = onClick), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Box(Modifier.fillMaxWidth().aspectRatio(2f / 3f).clip(RoundedCornerShape(16.dp)).border(1.dp, Hue.hairline, RoundedCornerShape(16.dp))) {
            RemoteImage(AppState.client?.posterURL(item, 400), Modifier.fillMaxSize())
            WatchedBadge(item, Modifier.align(Alignment.TopEnd))
            item.progress?.let { ProgressBar(it, Modifier.align(Alignment.BottomCenter).fillMaxWidth().padding(8.dp)) }
        }
        Text(item.displayTitle, style = MaterialTheme.typography.bodySmall, fontWeight = FontWeight.SemiBold, maxLines = 1)
        item.productionYear?.let { Text("$it", style = MaterialTheme.typography.labelSmall, color = Hue.secondaryText) }
    }
}

/** Opens the right screen for any item. */
@Composable
fun ItemRouteScreen(id: String, nav: NavHostController) {
    var item by remember { mutableStateOf<BaseItem?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(id) { runCatching { AppState.client?.item(id) }.onSuccess { item = it }.onFailure { error = it.message } }
    val it = item ?: return Box(Modifier.fillMaxSize(), Alignment.Center) { if (error != null) ErrorBanner(error!!) else CircularProgressIndicator() }
    when {
        (it.type == "CollectionFolder" || it.type == "UserView") && it.collectionType == "music" -> MusicLibraryScreen(it, nav)
        (it.type == "CollectionFolder" || it.type == "UserView") && it.collectionType == "books" -> BooksLibraryScreen(it, nav)
        (it.type == "CollectionFolder" || it.type == "UserView") && it.collectionType == "livetv" -> LiveTVScreen(nav)
        it.type == "Book" || it.type == "AudioBook" -> BookScreen(it.id, nav)
        it.type == "MusicAlbum" || (it.type == "Playlist" && it.mediaType == "Audio") -> AlbumScreen(it, nav)
        it.type == "MusicArtist" -> ArtistScreen(it, nav)
        it.type in setOf("CollectionFolder", "Folder", "BoxSet", "UserView", "Playlist") -> LibraryGrid(it, nav)
        else -> DetailScreen(it, nav)
    }
}
