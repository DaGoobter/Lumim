package com.huefin.app.ui

import androidx.compose.foundation.background
import androidx.compose.ui.draw.clip
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
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
import com.huefin.app.playback.Player
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch

private data class HomeData(
    val resume: List<BaseItem> = emptyList(), val nextUp: List<BaseItem> = emptyList(),
    val myList: List<BaseItem> = emptyList(), val latest: List<Pair<BaseItem, List<BaseItem>>> = emptyList(),
    val collections: List<BaseItem> = emptyList(),
)

private object HomeCache { var data: HomeData? = null; var key: String? = null }

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HomeScreen(nav: NavHostController) {
    val key = AppState.session?.key
    var data by remember { mutableStateOf(if (HomeCache.key == key) HomeCache.data else null) }
    var error by remember { mutableStateOf<String?>(null) }
    var refreshing by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val context = LocalContext.current

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
                val latest = views.map { lib -> async { lib to runCatching { c.latest(lib.id) }.getOrDefault(emptyList()) } }
                    .map { it.await() }.filter { it.second.isNotEmpty() }
                HomeData(r.await(), n.await(), fav.await(), latest, col.await())
            }
            HomeCache.data = data; HomeCache.key = key
            error = null
        } catch (e: Exception) { error = e.message }
    }
    LaunchedEffect(key) { load() }

    fun play(item: BaseItem) = scope.launch {
        if (item.isSeries) {
            val next = runCatching { AppState.client?.nextUp(item.id)?.firstOrNull() }.getOrNull()
            if (next != null) Player.play(context, next, next.resumeTicks) else nav.openItem(item)
        } else Player.play(context, item, item.resumeTicks)
    }

    PullToRefreshBox(refreshing, onRefresh = { scope.launch { refreshing = true; load(); refreshing = false } }) {
        val d = data
        val featured = (d?.resume.orEmpty() + d?.latest?.flatMap { it.second }.orEmpty().filter { it.backdropImageTags?.isNotEmpty() == true }).distinctBy { it.id }.take(8)
        LazyColumn(Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(26.dp)) {
            item {
                Box {
                    if (featured.isNotEmpty()) FeaturedPager(featured, onPlay = { play(it) }, onInfo = { nav.openItem(it) })
                    else Box(Modifier.fillMaxWidth().height(160.dp).background(Brush.verticalGradient(listOf(LocalHue.current.copy(alpha = 0.3f), Hue.night))))
                    Row(Modifier.statusBarsPadding().padding(horizontal = 18.dp, vertical = 6.dp).fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically) {
                        Text("huefin", fontSize = 24.sp, fontWeight = FontWeight.ExtraBold, letterSpacing = (-0.8).sp)
                        Spacer(Modifier.weight(1f))
                        AccountButton(nav)
                    }
                }
            }
            error?.let { item { ErrorBanner(it) { scope.launch { load() } } } }
            if (d == null && error == null) item { Box(Modifier.fillMaxWidth().padding(40.dp), Alignment.Center) { CircularProgressIndicator() } }
            d?.let { h ->
                if (h.resume.isNotEmpty()) item { Shelf("Continue Watching") { items(h.resume, key = { it.id }) { LandscapeCard(it, { play(it) }) } } }
                if (h.nextUp.isNotEmpty()) item { Shelf("Up Next") { items(h.nextUp, key = { it.id }) { LandscapeCard(it, { play(it) }) } } }
                if (h.myList.isNotEmpty()) item { Shelf("My List") { items(h.myList, key = { it.id }) { PosterCard(it, { nav.openItem(it) }) } } }
                h.latest.forEach { (lib, list) ->
                    item(key = "latest-${lib.id}") {
                        Shelf("New in ${lib.name ?: "Library"}") {
                            items(list, key = { it.id }) { if (it.type == "Episode") LandscapeCard(it, { nav.openItem(it) }) else PosterCard(it, { nav.openItem(it) }) }
                        }
                    }
                }
                if (h.collections.isNotEmpty()) item { Shelf("Collections") { items(h.collections, key = { it.id }) { PosterCard(it, { nav.openItem(it) }) } } }
            }
            item { Spacer(Modifier.height(40.dp)) }
        }
    }
}

@Composable
private fun FeaturedPager(items: List<BaseItem>, onPlay: (BaseItem) -> Unit, onInfo: (BaseItem) -> Unit) {
    val pager = rememberPagerState { items.size }
    val wide = LocalWidthClass.current != WidthClass.Compact
    HorizontalPager(pager, Modifier.fillMaxWidth().heightIn(min = if (wide) 420.dp else 520.dp).height(if (wide) 460.dp else 560.dp)) { page ->
        val item = items[page]
        val c = AppState.client
        // Huefin look: the picture is a sticker card; Night: it melts into the page.
        val card = Hue.light
        val shape = androidx.compose.foundation.shape.RoundedCornerShape(24.dp)
        Box(Modifier.fillMaxSize().then(if (card) Modifier.padding(16.dp).sticker(24.dp, 6.dp).clip(shape).border(2.5.dp, Hue.ink, shape) else Modifier)) {
          androidx.compose.runtime.CompositionLocalProvider(androidx.compose.material3.LocalContentColor provides Color.White) {
            AsyncImage(c?.backdropURL(item, 1600), null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
            Box(Modifier.fillMaxSize().background(Brush.verticalGradient(0f to Color.Black.copy(alpha = 0.35f), 0.35f to Color.Transparent,
                1f to (if (card) Color.Black.copy(alpha = 0.8f) else Hue.night))))
            Column(Modifier.align(Alignment.BottomStart).padding(20.dp).widthIn(max = 560.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                if (item.progress != null) Eyebrow(item.episodeLabel?.let { "Continue · $it" } ?: "Continue watching", Hue.sun)
                val logo = c?.logoURL(item)
                if (logo != null) AsyncImage(logo, item.displayTitle, Modifier.height(80.dp).widthIn(max = 280.dp), contentScale = ContentScale.Fit, alignment = Alignment.CenterStart)
                else Text(item.displayTitle, fontSize = 34.sp, fontWeight = FontWeight.ExtraBold, lineHeight = 36.sp, maxLines = 2, overflow = TextOverflow.Ellipsis)
                Text(listOfNotNull(item.productionYear?.toString(), item.officialRating, item.runtimeText).joinToString(" · "),
                    color = Color.White.copy(alpha = 0.8f), style = MaterialTheme.typography.bodyMedium)
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                    PlayButton({ onPlay(item) }) { Icon(Icons.Filled.PlayArrow, null); Text(if (item.progress != null) " Resume" else " Play") }
                    SoftButton({ onInfo(item) }) { Icon(Icons.Filled.Info, null); Text(" Details") }
                }
                if (items.size > 1) Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    items.indices.forEach { i -> Box(Modifier.size(if (i == pager.currentPage) 8.dp else 6.dp)
                        .background(if (i == pager.currentPage) LocalHue.current else Color.White.copy(alpha = 0.3f), CircleShape)) }
                }
            }
        }
          }
    }
}
