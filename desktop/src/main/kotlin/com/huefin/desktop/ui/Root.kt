package com.huefin.desktop.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.snapshots.SnapshotStateList
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.WindowPlacement
import androidx.compose.ui.window.WindowState
import com.huefin.desktop.core.AppState
import com.huefin.desktop.core.BaseItem
import com.huefin.desktop.player.PlayerController

enum class Tab(val label: String, val icon: ImageVector, val hue: Color) {
    Home("Home", Icons.Filled.Home, Hue.home), Library("Library", Icons.Filled.GridView, Hue.library),
    Live("Live TV", Icons.Filled.LiveTv, Hue.live), Search("Search", Icons.Filled.Search, Hue.search),
}

sealed interface Route {
    data object Root : Route
    data class Item(val id: String, val preview: BaseItem? = null) : Route
    data object Settings : Route
}

/** Where you are: a tab, a back stack per tab, and the player on top when something plays. */
object Nav {
    var tab by mutableStateOf(Tab.Home)
    private val stacks = Tab.entries.associateWith { mutableStateListOf<Route>(Route.Root) }
    val stack: SnapshotStateList<Route> get() = stacks.getValue(tab)
    val canGoBack get() = player == null && stack.size > 1
    var player by mutableStateOf<PlayerController?>(null)
    var window: WindowState? = null
    private var placementBeforePlayer: WindowPlacement? = null

    fun push(r: Route) { stack.add(r) }
    fun open(item: BaseItem) = push(Route.Item(item.id, item))
    fun back() { if (stack.size > 1) stack.removeAt(stack.lastIndex) }
    fun select(t: Tab) { if (t == tab) { val s = stacks.getValue(t); while (s.size > 1) s.removeAt(s.lastIndex) } else tab = t }
    fun reset() { Tab.entries.forEach { t -> stacks.getValue(t).apply { clear(); add(Route.Root) } }; tab = Tab.Home }

    fun play(item: BaseItem, startTicks: Long = 0) {
        player?.close()
        val p = PlayerController(item, startTicks) {
            player = null
            window?.let { w -> placementBeforePlayer?.let { w.placement = it }; placementBeforePlayer = null }
        }
        player = p
        p.start()
    }

    fun toggleFullscreen() {
        val w = window ?: return
        if (w.placement == WindowPlacement.Fullscreen) w.placement = placementBeforePlayer ?: WindowPlacement.Floating
        else { placementBeforePlayer = w.placement; w.placement = WindowPlacement.Fullscreen }
    }

    /** Keyboard in the player: space/K pause, ←/→ 10 s, J/L 10 s, ↑/↓ volume, F full screen, M mute, S skip, Esc close. */
    fun playerKey(k: Key): Boolean {
        val p = player ?: return false
        when (k) {
            Key.Spacebar, Key.K -> p.togglePlay()
            Key.DirectionLeft, Key.J -> p.seekBy(-10)
            Key.DirectionRight, Key.L -> p.seekBy(10)
            Key.DirectionUp -> p.changeVolume(p.volume + 5)
            Key.DirectionDown -> p.changeVolume(p.volume - 5)
            Key.F -> toggleFullscreen()
            Key.M -> p.toggleMute()
            Key.S -> if (p.activeSkip != null) p.skipSegment() else if (p.upNextIn != null) p.playNext()
            Key.Escape -> if (window?.placement == WindowPlacement.Fullscreen) toggleFullscreen() else p.close()
            else -> return false
        }
        return true
    }
}

@Composable
fun HuefinRoot() {
    HuefinTheme {
        CompositionLocalProvider(LocalWidthClass provides WidthClass.Expanded) {
            Box(Modifier.fillMaxSize()) {
                val client = AppState.client
                if (client == null) LoginScreen(adding = false) {} else key(AppState.session?.key) { MainScaffold() }
                Nav.player?.let { PlayerScreen(it) }
            }
        }
    }
}

@Composable
private fun MainScaffold() {
    LaunchedEffect(Unit) { Nav.reset() }
    Row(Modifier.fillMaxSize()) {
        Column(Modifier.fillMaxHeight().width(96.dp).background(Hue.card).padding(vertical = 18.dp), horizontalAlignment = Alignment.CenterHorizontally) {
            Text("huefin", fontWeight = FontWeight.Black, style = MaterialTheme.typography.titleLarge)
            Box(Modifier.padding(top = 4.dp, bottom = 20.dp).width(40.dp).height(4.dp).clip(CircleShape).background(Hue.spectrum))
            Tab.entries.forEach { t ->
                val sel = t == Nav.tab
                Column(Modifier.padding(vertical = 6.dp).clip(RoundedCornerShape(14.dp)).clickable { Nav.select(t) }.padding(vertical = 6.dp, horizontal = 8.dp),
                    horizontalAlignment = Alignment.CenterHorizontally) {
                    Box(Modifier.clip(RoundedCornerShape(12.dp)).background(if (sel) t.hue else Color.Transparent).padding(horizontal = 16.dp, vertical = 6.dp)) {
                        Icon(t.icon, t.label, tint = if (sel) Hue.ink else Hue.secondaryText)
                    }
                    Text(t.label, style = MaterialTheme.typography.labelMedium, color = if (sel) t.hue else Hue.secondaryText, modifier = Modifier.padding(top = 4.dp))
                }
            }
            Spacer(Modifier.weight(1f))
            val name = AppState.session?.userName ?: "?"
            Box(Modifier.clip(CircleShape).clickable { Nav.push(Route.Settings) }) { Avatar(name, 44.dp, Nav.tab.hue) }
            Text("Settings", style = MaterialTheme.typography.labelSmall, color = Hue.secondaryText, modifier = Modifier.padding(top = 4.dp))
        }
        SectionHue(Nav.tab.hue) {
            Box(Modifier.weight(1f).fillMaxHeight()) {
                when (val r = Nav.stack.last()) {
                    Route.Root -> when (Nav.tab) {
                        Tab.Home -> HomeScreen(); Tab.Library -> LibrariesScreen(); Tab.Live -> LiveTVScreen(); Tab.Search -> SearchScreen()
                    }
                    is Route.Item -> key(r.id) { ItemScreen(r.id, r.preview) }
                    Route.Settings -> SettingsScreen()
                }
            }
        }
    }
}

/** A page title with a back arrow when there's somewhere to go back to. */
@Composable
fun PageHeader(title: String, actions: @Composable RowScope.() -> Unit = {}) {
    Row(Modifier.fillMaxWidth().padding(start = 12.dp, end = 20.dp, top = 14.dp, bottom = 6.dp), verticalAlignment = Alignment.CenterVertically) {
        if (Nav.stack.size > 1) IconButton({ Nav.back() }) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") } else Spacer(Modifier.width(8.dp))
        Text(title, style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.ExtraBold, modifier = Modifier.weight(1f).padding(start = 4.dp))
        actions()
    }
}
