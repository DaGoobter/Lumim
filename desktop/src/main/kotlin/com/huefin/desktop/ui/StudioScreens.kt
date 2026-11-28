package com.huefin.desktop.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
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
import androidx.compose.material.icons.automirrored.filled.Sort
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.huefin.desktop.core.AppState
import com.huefin.desktop.core.BaseItem
import com.huefin.desktop.core.StudioBrand
import com.huefin.desktop.core.StudioCatalog
import kotlinx.coroutines.launch

private val spectrum = listOf(Hue.coral, Hue.amber, Hue.sun, Hue.mint, Hue.sky, Hue.violet)

/** Libraries · Studios · Networks pills at the top of the Library tab. */
@Composable
fun BrowseModeRow(mode: String, onMode: (String) -> Unit) {
    Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp).clip(RoundedCornerShape(22.dp))
        .background(Hue.wash).padding(4.dp), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        listOf("libraries" to "Libraries", "studios" to "Studios", "networks" to "Networks").forEach { (tag, label) ->
            val on = mode == tag
            Box(Modifier.weight(1f).heightIn(min = 40.dp).clip(RoundedCornerShape(18.dp))
                .background(if (on) Hue.library else Color.Transparent).clickable { onMode(tag) }, Alignment.Center) {
                Text(label, color = if (on) Hue.ink else Hue.secondaryText, fontWeight = FontWeight.Bold, style = MaterialTheme.typography.labelLarge)
            }
        }
    }
}

/** Grid of studio or network brands with a search box. */
@Composable
fun StudioGrid(kind: StudioBrand.Kind, onOpen: (StudioBrand) -> Unit) {
    var search by rememberSaveable { mutableStateOf("") }
    val scope = rememberCoroutineScope()
    LaunchedEffect(AppState.client) { AppState.client?.let { StudioCatalog.load(it) } }
    val shown = StudioCatalog.brands.filter { it.kind == kind }.filter { b ->
        search.isBlank() || b.name.contains(search, true) || b.members.any { it.name.contains(search, true) }
    }
    LazyVerticalGrid(gridColumns(150), Modifier.fillMaxSize(), contentPadding = PaddingValues(16.dp, 8.dp, 16.dp, 24.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        item(span = { GridItemSpan(maxLineSpan) }) {
            OutlinedTextField(search, { search = it }, Modifier.fillMaxWidth(), singleLine = true,
                placeholder = { Text(if (kind == StudioBrand.Kind.Studio) "Find a studio" else "Find a network") },
                leadingIcon = { Icon(Icons.Filled.Search, null) }, shape = RoundedCornerShape(14.dp),
                colors = OutlinedTextFieldDefaults.colors(unfocusedContainerColor = Hue.card, focusedContainerColor = Hue.card,
                    unfocusedBorderColor = Color.Transparent, focusedBorderColor = Hue.library))
        }
        when {
            StudioCatalog.error != null && StudioCatalog.brands.isEmpty() -> item(span = { GridItemSpan(maxLineSpan) }) {
                ErrorBanner(StudioCatalog.error!!) { scope.launch { AppState.client?.let { StudioCatalog.load(it, force = true) } } }
            }
            !StudioCatalog.loaded -> item(span = { GridItemSpan(maxLineSpan) }) { Box(Modifier.fillMaxWidth().padding(40.dp), Alignment.Center) { CircularProgressIndicator() } }
            shown.isEmpty() -> item(span = { GridItemSpan(maxLineSpan) }) {
                Text(if (search.isBlank()) "Your server hasn't tagged any ${if (kind == StudioBrand.Kind.Studio) "studios" else "networks"} yet." else "No matches. Try another name.",
                    color = Hue.secondaryText, modifier = Modifier.padding(32.dp))
            }
            else -> items(shown, key = { it.id }) { StudioTile(it) { onOpen(it) } }
        }
    }
}

@Composable
fun StudioTile(brand: StudioBrand, onClick: () -> Unit) {
    val (a, b) = brand.hues
    Box(Modifier.fillMaxWidth().height(104.dp).clip(RoundedCornerShape(18.dp)).background(Hue.card)
        .background(Brush.radialGradient(listOf(spectrum[a], Color.Transparent), center = Offset(80f, 40f), radius = 420f))
        .background(Brush.radialGradient(listOf(spectrum[b].copy(alpha = 0.9f), Color.Transparent), center = Offset(560f, 300f), radius = 400f))
        .background(Brush.verticalGradient(0.4f to Color.Transparent, 1f to Color.Black.copy(alpha = 0.55f)))
        .clickable(onClick = onClick).padding(14.dp), contentAlignment = Alignment.BottomStart) {
        Column {
            Text(brand.name, color = Color.White, fontWeight = FontWeight.ExtraBold, fontSize = 20.sp, maxLines = 2, overflow = TextOverflow.Ellipsis, lineHeight = 22.sp)
            Text(brand.countText, color = Color.White.copy(alpha = 0.82f), style = MaterialTheme.typography.labelMedium, fontWeight = FontWeight.SemiBold)
        }
    }
}

private enum class BrandSort(val label: String, val by: String, val order: String) {
    Added("Recently added", "DateCreated,SortName", "Descending"), Name("Name", "SortName", "Ascending"),
    Released("Release date", "PremiereDate,ProductionYear,SortName", "Descending"), Rating("Rating", "CommunityRating,SortName", "Descending"),
}

/** Everything from one studio or network. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun StudioBrandScreen(id: String, nav: NavHostController) {
    val brand = StudioCatalog.find(id) ?: return Box(Modifier.fillMaxSize(), Alignment.Center) { CircularProgressIndicator() }
    var member by rememberSaveable { mutableStateOf<String?>(null) }
    var show by rememberSaveable { mutableIntStateOf(0) }   // 0 all, 1 movies, 2 shows
    var sort by rememberSaveable { mutableStateOf(BrandSort.Added) }
    var sortMenu by remember { mutableStateOf(false) }
    val items = remember { mutableStateListOf<BaseItem>() }
    var total by remember { mutableIntStateOf(Int.MAX_VALUE) }
    var loading by remember { mutableStateOf(false) }
    var gen by remember { mutableIntStateOf(0) }
    val both = brand.movieCount > 0 && brand.showCount > 0
    val types = when (show) {
        1 -> "Movie"; 2 -> "Series"
        else -> if (both) "Movie,Series" else if (brand.showCount > 0) "Series" else "Movie"
    }
    val grid = rememberLazyGridState()

    suspend fun more(g: Int) {
        val c = AppState.client ?: return
        if (loading || items.size >= total) return
        loading = true
        runCatching {
            c.browse(mapOf("studioIds" to (member ?: brand.studioIds), "includeItemTypes" to types, "recursive" to "true",
                "sortBy" to sort.by, "sortOrder" to sort.order, "startIndex" to "${items.size}", "limit" to "60",
                "enableImageTypes" to "Primary,Backdrop,Thumb"))
        }.onSuccess { if (g == gen) { items += it.items; total = it.totalRecordCount ?: items.size } }
            .onFailure { total = items.size }
        loading = false
    }
    LaunchedEffect(member, show, sort) { gen++; items.clear(); total = Int.MAX_VALUE; loading = false; more(gen) }
    val nearEnd by remember { derivedStateOf { (grid.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: 0) > items.size - 12 } }
    LaunchedEffect(nearEnd, items.size) { if (nearEnd) more(gen) }

    val (a, b) = brand.hues
    Scaffold(containerColor = Hue.night, topBar = {
        HuefinTopBar("", nav) {
            Box {
                IconButton({ sortMenu = true }) { Icon(Icons.AutoMirrored.Filled.Sort, "Sort") }
                DropdownMenu(sortMenu, { sortMenu = false }) {
                    BrandSort.entries.forEach { o -> DropdownMenuItem({ Text((if (o == sort) "✓ " else "") + o.label) }, { sort = o; sortMenu = false }) }
                }
            }
        }
    }) { pad ->
        LazyVerticalGrid(gridColumns(108), Modifier.fillMaxSize()
            .background(Brush.radialGradient(listOf(spectrum[a].copy(alpha = 0.5f), Color.Transparent), center = Offset(150f, 0f), radius = 900f))
            .background(Brush.radialGradient(listOf(spectrum[b].copy(alpha = 0.35f), Color.Transparent), center = Offset(1100f, 200f), radius = 800f)),
            state = grid, contentPadding = PaddingValues(16.dp, pad.calculateTopPadding(), 16.dp, 24.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp), verticalArrangement = Arrangement.spacedBy(18.dp)) {
            item(span = { GridItemSpan(maxLineSpan) }) {
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(if (brand.kind == StudioBrand.Kind.Studio) "STUDIO" else "NETWORK", color = Hue.secondaryText,
                        fontWeight = FontWeight.Bold, style = MaterialTheme.typography.labelMedium, letterSpacing = 1.2.sp)
                    Text(brand.name, fontWeight = FontWeight.ExtraBold, fontSize = 42.sp, lineHeight = 44.sp)
                    Text(brand.countText, color = Hue.secondaryText, fontWeight = FontWeight.SemiBold)
                }
            }
            if (brand.members.size > 1) item(span = { GridItemSpan(maxLineSpan) }) {
                LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    item { BrandChip("All", member == null) { member = null } }
                    items(brand.members, key = { it.id }) { m -> BrandChip(m.name, member == m.id) { member = m.id } }
                }
            }
            if (both) item(span = { GridItemSpan(maxLineSpan) }) {
                Row(Modifier.clip(RoundedCornerShape(18.dp)).background(Hue.wash).padding(3.dp), horizontalArrangement = Arrangement.spacedBy(2.dp)) {
                    listOf("All", "Movies", "Shows").forEachIndexed { i, t ->
                        Box(Modifier.heightIn(min = 36.dp).clip(RoundedCornerShape(15.dp)).background(if (show == i) Hue.library else Color.Transparent)
                            .clickable { show = i }.padding(horizontal = 16.dp), Alignment.Center) {
                            Text(t, color = if (show == i) Hue.ink else Hue.secondaryText, fontWeight = FontWeight.Bold, style = MaterialTheme.typography.labelLarge)
                        }
                    }
                }
            }
            items(items, key = { it.id }) { PosterCardFill(it) { nav.openItem(it) } }
            if (loading) item(span = { GridItemSpan(maxLineSpan) }) { Box(Modifier.fillMaxWidth().padding(20.dp), Alignment.Center) { CircularProgressIndicator() } }
        }
    }
}

@Composable
private fun BrandChip(text: String, on: Boolean, onClick: () -> Unit) {
    Box(Modifier.heightIn(min = 40.dp).clip(RoundedCornerShape(20.dp)).background(if (on) Hue.text else Color.Transparent)
        .border(1.dp, if (on) Color.Transparent else Hue.hairline, RoundedCornerShape(20.dp))
        .clickable(onClick = onClick).padding(horizontal = 14.dp), Alignment.Center) {
        Text(text, color = if (on) Hue.night else Hue.text, fontWeight = FontWeight.Bold, style = MaterialTheme.typography.labelLarge, maxLines = 1)
    }
}
