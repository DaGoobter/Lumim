package com.huefin.app.ui

import android.content.Context
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.runtime.key
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowCircleDown
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.GridView
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.LiveTv
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.adaptive.navigationsuite.NavigationSuiteDefaults
import androidx.compose.material3.adaptive.navigationsuite.NavigationSuiteScaffold
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.NavigationRailItemDefaults
import androidx.compose.material3.NavigationDrawerItemDefaults
import androidx.compose.material3.adaptive.navigationsuite.NavigationSuiteItemColors
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.navigation.NavGraphBuilder
import androidx.navigation.NavHostController
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import com.huefin.app.core.AppState
import com.huefin.app.core.BaseItem
import com.huefin.app.core.Prefs
import com.huefin.app.core.SessionSocket
import com.huefin.app.core.ServerDefaults
import com.huefin.app.playback.AudioPlayer
import com.huefin.app.playback.Player
import com.huefin.app.playback.Stations
import kotlinx.coroutines.delay

/** Siri-equivalent actions (shortcuts, Assistant) and app-wide "open this" requests. */
object AppRouter {
    sealed interface Action { data object Resume : Action; data class Live(val channel: String?) : Action; data object DJ : Action }
    var pending by mutableStateOf<Action?>(null)
    var showProfiles by mutableStateOf(false)

    suspend fun perform(action: Action, context: Context) {
        val c = AppState.client ?: return
        when (action) {
            Action.Resume -> {
                val item = runCatching { c.resume().firstOrNull() ?: c.nextUp().firstOrNull() }.getOrNull() ?: return
                Player.play(context, item, item.resumeTicks)
            }
            is Action.Live -> {
                val channels = runCatching { c.liveChannels() }.getOrDefault(emptyList())
                val q = action.channel?.trim().orEmpty()
                val match = if (q.isEmpty()) channels.firstOrNull() else channels.firstOrNull {
                    (it.name ?: "").contains(q, true) || it.channelNumber == q }
                match?.let { Player.play(context, it, 0) }
            }
            Action.DJ -> {
                val music = runCatching { c.userViews().firstOrNull { it.collectionType == "music" } }.getOrNull()
                AudioPlayer.playStation(context, Stations.dj(music?.id))
            }
        }
    }
}

enum class Tab(val label: String, val icon: ImageVector, val hue: Color) {
    Home("Home", Icons.Filled.Home, Hue.home),
    Library("Library", Icons.Filled.GridView, Hue.library),
    Live("Live TV", Icons.Filled.LiveTv, Hue.live),
    Downloads("Downloads", Icons.Filled.ArrowCircleDown, Hue.downloads),
    Search("Search", Icons.Filled.Search, Hue.search),
}

@Composable
fun HuefinRoot() {
    val config = LocalConfiguration.current
    val width = when {
        config.screenWidthDp < 600 -> WidthClass.Compact
        config.screenWidthDp < 840 -> WidthClass.Medium
        else -> WidthClass.Expanded
    }
    val context = LocalContext.current
    CompositionLocalProvider(LocalWidthClass provides width) {
        Box(Modifier.fillMaxSize()) {
            val client = AppState.client
            if (client == null) LoginScreen(adding = false, onDone = {}) else MainScaffold(key = AppState.session?.key ?: "")
            NoticeOverlay()
        }
    }
    LaunchedEffect(AppState.client) {
        val c = AppState.client ?: return@LaunchedEffect
        ServerDefaults.apply()
        SessionSocket.connect(c)
    }
    LaunchedEffect(AppRouter.pending, AppState.client) {
        val a = AppRouter.pending ?: return@LaunchedEffect
        if (AppState.client == null) return@LaunchedEffect
        AppRouter.pending = null
        AppRouter.perform(a, context)
    }
}

@Composable
private fun MainScaffold(key: String) {
    var tab by rememberSaveable(key) { mutableStateOf(Tab.Home) }
    val navs = Tab.entries.associateWith { rememberNavController() }
    var askedProfiles by rememberSaveable { mutableStateOf(false) }
    var showProfiles by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) {
        if (!askedProfiles) {
            askedProfiles = true
            if (Prefs.bool(Prefs.Keys.askWho, true) && AppState.accounts.size > 1 && AppRouter.pending == null) showProfiles = true
        }
    }
    LaunchedEffect(AppRouter.showProfiles) { if (AppRouter.showProfiles) { AppRouter.showProfiles = false; showProfiles = true } }

    val colors = NavigationSuiteItemColors(
        navigationBarItemColors = NavigationBarItemDefaults.colors(selectedIconColor = Hue.ink, selectedTextColor = tab.hue,
            indicatorColor = tab.hue, unselectedIconColor = Hue.secondaryText, unselectedTextColor = Hue.secondaryText),
        navigationRailItemColors = NavigationRailItemDefaults.colors(selectedIconColor = Hue.ink, selectedTextColor = tab.hue,
            indicatorColor = tab.hue, unselectedIconColor = Hue.secondaryText, unselectedTextColor = Hue.secondaryText),
        navigationDrawerItemColors = NavigationDrawerItemDefaults.colors(selectedIconColor = Hue.ink, selectedTextColor = Hue.ink,
            selectedContainerColor = tab.hue),
    )
    NavigationSuiteScaffold(
        navigationSuiteItems = {
            Tab.entries.forEach { t ->
                item(selected = t == tab,
                    onClick = { if (t == tab) navs[t]?.popBackStack(navs[t]!!.graph.startDestinationId, false) else tab = t },
                    icon = { Icon(t.icon, t.label) }, label = { Text(t.label) }, colors = colors)
            }
        },
        navigationSuiteColors = NavigationSuiteDefaults.colors(navigationBarContainerColor = Hue.card, navigationRailContainerColor = Hue.night),
        containerColor = Hue.night,
    ) {
        SectionHue(tab.hue) {
            Column(Modifier.fillMaxSize()) {
                Box(Modifier.weight(1f)) {
                    val nav = navs.getValue(tab)
                    key(tab) { NavHost(nav, startDestination = "root") {
                        composable("root") {
                            when (tab) {
                                Tab.Home -> HomeScreen(nav)
                                Tab.Library -> LibrariesScreen(nav)
                                Tab.Live -> LiveTVScreen(nav)
                                Tab.Downloads -> DownloadsScreen(nav)
                                Tab.Search -> SearchScreen(nav)
                            }
                        }
                        sharedRoutes(nav)
                    } }
                }
                MiniPlayer()
            }
        }
    }
    if (showProfiles) ProfilePickerDialog { showProfiles = false }
}

/** Screens reachable from any tab. */
fun NavGraphBuilder.sharedRoutes(nav: NavHostController) {
    composable("item/{id}") { ItemRouteScreen(it.arguments?.getString("id") ?: "", nav) }
    composable("library/{id}") { LibraryGridScreen(it.arguments?.getString("id") ?: "", nav) }
    composable("studio/{id}") { StudioBrandScreen(it.arguments?.getString("id") ?: "", nav) }
    composable("settings") { SettingsScreen(nav) }
    composable("requests") { RequestsScreen(nav) }
    composable("family") { FamilyScreen(nav) }
    composable("quickconnect") { QuickConnectApproveScreen(nav) }
    composable("admin") { com.huefin.app.admin.AdminDashboardScreen(nav) }
    composable("admin/{section}") { com.huefin.app.admin.AdminSectionScreen(it.arguments?.getString("section") ?: "", nav) }
    composable("admin/user/{id}") { com.huefin.app.admin.AdminUserScreen(it.arguments?.getString("id") ?: "", nav) }
    composable("nowplaying") { NowPlayingScreen(nav) }
    composable("book/{id}") { BookScreen(it.arguments?.getString("id") ?: "", nav) }
}

/** Where tapping an item goes: folders open as grids, music as albums/artists, everything else as a title page. */
fun NavHostController.openItem(item: BaseItem) {
    when (item.type) {
        "Season", "MusicGenre", "Genre" -> navigate("library/${item.id}")
        "Book" -> navigate("book/${item.id}")
        else -> navigate("item/${item.id}")
    }
}

/** Your account bubble: tap for Settings, long-press to switch user or server. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun AccountButton(nav: NavHostController) {
    var menu by remember { mutableStateOf(false) }
    val name = AppState.session?.userName ?: "?"
    Box {
        Box(Modifier.size(44.dp).combinedClickable(onClick = { nav.navigate("settings") }, onLongClick = { menu = true },
            onClickLabel = "Account and settings"), contentAlignment = Alignment.Center) {
            Avatar(name, 34.dp)
        }
        DropdownMenu(menu, { menu = false }) {
            DropdownMenuItem({ Text("Who's watching?") }, { menu = false; AppRouter.showProfiles = true })
            AppState.accounts.forEach { a ->
                DropdownMenuItem({ Text("${a.userName} · ${a.serverName ?: "Jellyfin"}") }, { menu = false; AppState.switchTo(a) })
            }
        }
    }
}

@Composable
private fun NoticeOverlay() {
    val notice = SessionSocket.notice
    LaunchedEffect(notice?.id) { if (notice != null) { delay(12_000); if (SessionSocket.notice?.id == notice.id) SessionSocket.notice = null } }
    AnimatedVisibility(notice != null, enter = slideInVertically() + fadeIn(), exit = slideOutVertically() + fadeOut()) {
        notice?.let { n ->
            Row(Modifier.statusBarsPadding().padding(16.dp).fillMaxWidth()
                .background(Hue.card, RoundedCornerShape(18.dp)).border(1.dp, Hue.hairline, RoundedCornerShape(18.dp)).padding(14.dp),
                horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.Top) {
                Box(Modifier.size(28.dp).background(Hue.spectrum, RoundedCornerShape(14.dp)))
                Column(Modifier.weight(1f)) {
                    Text(n.header, fontWeight = FontWeight.Bold, style = MaterialTheme.typography.titleSmall)
                    Text(n.text, style = MaterialTheme.typography.bodyMedium)
                }
                Icon(Icons.Filled.Close, "Dismiss", Modifier.clickable { SessionSocket.notice = null })
            }
        }
    }
}
