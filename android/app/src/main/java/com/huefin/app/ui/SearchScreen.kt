package com.huefin.app.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
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
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AddToQueue
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.navigation.NavHostController
import com.huefin.app.core.AppState
import com.huefin.app.core.BaseItem
import com.huefin.app.core.Prefs
import com.huefin.app.core.Seerr
import com.huefin.app.playback.AudioPlayer
import com.huefin.app.playback.Player
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

private val groups = listOf("Movies" to listOf("Movie"), "Shows" to listOf("Series"), "Episodes" to listOf("Episode"),
    "Collections" to listOf("BoxSet"), "Channels" to listOf("TvChannel"), "Artists" to listOf("MusicArtist"),
    "Albums" to listOf("MusicAlbum"), "Songs" to listOf("Audio"), "Books" to listOf("Book", "AudioBook"), "Playlists" to listOf("Playlist"))

@Composable
fun SearchScreen(nav: NavHostController) {
    var query by rememberSaveable { mutableStateOf("") }
    var results by remember { mutableStateOf<List<BaseItem>>(emptyList()) }
    var requestable by remember { mutableStateOf<List<Seerr.Result>>(emptyList()) }
    var searching by remember { mutableStateOf(false) }
    var picked by remember { mutableStateOf<Seerr.Result?>(null) }
    var recent by remember { mutableStateOf(Prefs.string(Prefs.Keys.recentSearches)?.split("\u0001")?.filter { it.isNotBlank() } ?: emptyList()) }
    val context = LocalContext.current
    val scope = rememberCoroutineScope()

    fun saveRecent(term: String) {
        val t = term.trim(); if (t.length < 2) return
        recent = (listOf(t) + recent.filterNot { it.equals(t, true) }).take(8)
        Prefs.set(Prefs.Keys.recentSearches, recent.joinToString("\u0001"))
    }
    LaunchedEffect(AppState.session?.key) { Seerr.activate(AppState.session?.key, AppState.session?.serverURL) }
    LaunchedEffect(query) {
        delay(350)
        val t = query.trim()
        if (t.length < 2) { results = emptyList(); requestable = emptyList(); return@LaunchedEffect }
        searching = true
        results = runCatching { AppState.client?.search(t) ?: emptyList() }.getOrDefault(emptyList())
        searching = false
        if (Seerr.isConfigured) requestable = Seerr.search(t).filter { it.status != 5 }
    }

    LazyColumn(Modifier.fillMaxSize().statusBarsPadding(), verticalArrangement = Arrangement.spacedBy(22.dp)) {
        item {
            Row(Modifier.padding(start = 16.dp, end = 8.dp, top = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                OutlinedTextField(query, { query = it }, Modifier.weight(1f), singleLine = true,
                    placeholder = { Text("Movies, shows, music…") }, leadingIcon = { Icon(Icons.Filled.Search, null) },
                    trailingIcon = { if (query.isNotEmpty()) IconButton({ query = "" }) { Icon(Icons.Filled.Close, "Clear") } },
                    shape = RoundedCornerShape(16.dp),
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search), keyboardActions = KeyboardActions(onSearch = { saveRecent(query) }),
                    colors = OutlinedTextFieldDefaults.colors(focusedBorderColor = LocalHue.current, unfocusedBorderColor = Hue.hairline,
                        focusedContainerColor = Hue.card, unfocusedContainerColor = Hue.card))
                IconButton({ nav.navigate("requests") }) { Icon(Icons.Filled.AddToQueue, "Requests") }
            }
        }
        val t = query.trim()
        if (t.isEmpty()) {
            if (recent.isNotEmpty()) {
                item { Row(Modifier.padding(horizontal = 20.dp)) { ShelfTitle("Recent", Modifier.weight(1f))
                    Text("Clear", color = LocalHue.current, modifier = Modifier.clickable { recent = emptyList(); Prefs.set(Prefs.Keys.recentSearches, null) }) } }
                items(recent) { r -> Row(Modifier.fillMaxWidth().clickable { query = r }.padding(horizontal = 20.dp, vertical = 6.dp),
                    horizontalArrangement = Arrangement.spacedBy(10.dp)) { Icon(Icons.Filled.History, null, tint = Hue.secondaryText); Text(r) } }
            } else item { Text("Search movies, shows, episodes, music, books and channels.", color = Hue.secondaryText, modifier = Modifier.padding(40.dp)) }
        } else {
            if (searching && results.isEmpty()) item { Box(Modifier.fillMaxWidth().padding(40.dp), Alignment.Center) { CircularProgressIndicator() } }
            if (!searching && results.isEmpty() && requestable.isEmpty()) item { Text("No results for \"$t\".", color = Hue.secondaryText, modifier = Modifier.padding(horizontal = 20.dp)) }
            groups.forEach { (title, types) ->
                val matched = results.filter { it.type in types }
                if (matched.isNotEmpty()) item(key = title) {
                    Shelf(title) {
                        items(matched, key = { it.id }) { item ->
                            val open = { saveRecent(query); nav.openItem(item) }
                            when (item.type) {
                                "Audio" -> SquareCard(item, { saveRecent(query); AudioPlayer.play(context, listOf(item)) })
                                "TvChannel" -> SquareCard(item, { saveRecent(query); Player.play(context, item, 0) })
                                "Episode" -> LandscapeCard(item, open)
                                "MusicArtist" -> SquareCard(item, open, circle = true)
                                "MusicAlbum", "Playlist" -> SquareCard(item, open)
                                else -> PosterCard(item, open)
                            }
                        }
                    }
                }
            }
            if (Seerr.needsSignIn && !searching) item { SeerrInlineConnect() }
            if (requestable.isNotEmpty()) item {
                Shelf("Not on your server? Request it") {
                    items(requestable, key = { it.id }) { r -> Box(Modifier.width(120.dp * cardScale()).clickable { picked = r }) { SeerrPoster(r) } }
                }
            }
        }
        item { Spacer(Modifier.height(40.dp)) }
    }
    picked?.let { SeerrDetailDialog(it) { picked = null } }
}

@Composable
fun SeerrInlineConnect() {
    var password by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var failed by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    Column(Modifier.padding(horizontal = 20.dp).fillMaxWidth().background(Hue.card, RoundedCornerShape(18.dp)).padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Text("Not finding it? Request it", fontWeight = FontWeight.Bold, style = MaterialTheme.typography.titleMedium)
        Text("Enter your Huefin password once to turn on requests for movies and shows that aren't on the server yet.",
            style = MaterialTheme.typography.bodySmall, color = Hue.secondaryText)
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            OutlinedTextField(password, { password = it }, Modifier.weight(1f), singleLine = true, placeholder = { Text("Password") },
                visualTransformation = PasswordVisualTransformation(), shape = RoundedCornerShape(12.dp))
            HueButton(enabled = !busy && password.isNotEmpty(), onClick = {
                val base = Seerr.baseURL ?: return@HueButton
                busy = true; failed = false
                scope.launch {
                    runCatching { Seerr.signIn(base, AppState.session?.userName ?: "", password) }.onFailure { failed = true }
                    password = ""; busy = false
                }
            }) { if (busy) CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp) else Text("Turn on") }
        }
        if (failed) Text("That password didn't work.", color = Hue.coral, style = MaterialTheme.typography.bodySmall)
    }
}

@Composable
fun SeerrPoster(r: Seerr.Result) {
    Column(verticalArrangement = Arrangement.spacedBy(5.dp)) {
        Box(Modifier.fillMaxWidth().aspectRatio(2f / 3f).clip(RoundedCornerShape(12.dp))) {
            RemoteImage(r.posterURL, Modifier.fillMaxSize())
            r.statusText?.let { s ->
                Text(if (s == "Available") "✓" else "•••", fontWeight = FontWeight.ExtraBold, color = Hue.ink,
                    modifier = Modifier.align(Alignment.TopEnd).padding(6.dp).background(if (s == "Available") Hue.mint else Hue.amber, RoundedCornerShape(50)).padding(horizontal = 6.dp, vertical = 2.dp))
            }
        }
        Text(r.title, style = MaterialTheme.typography.bodySmall, fontWeight = FontWeight.SemiBold, maxLines = 1)
        Text(listOfNotNull(r.year, if (r.mediaType == "tv") "Show" else "Movie").joinToString(" · "), style = MaterialTheme.typography.labelSmall, color = Hue.secondaryText)
    }
}
