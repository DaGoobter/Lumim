package com.huefin.desktop.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import com.huefin.desktop.core.AppState
import com.huefin.desktop.core.Seerr
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** Ask for movies and shows that aren't on the server yet, and (for admins) approve what others asked for. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RequestsScreen(nav: NavHostController) {
    var tab by remember { mutableIntStateOf(0) }
    var query by remember { mutableStateOf("") }
    var results by remember { mutableStateOf<List<Seerr.Result>>(emptyList()) }
    var requests by remember { mutableStateOf<List<Seerr.Req>>(emptyList()) }
    val details = remember { mutableStateMapOf<Int, Pair<String?, String?>>() }
    var picked by remember { mutableStateOf<Seerr.Result?>(null) }
    var menu by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    LaunchedEffect(AppState.session?.key) { Seerr.activate(AppState.session?.key, AppState.session?.serverURL) }
    LaunchedEffect(query, Seerr.isConfigured) {
        if (!Seerr.isConfigured) return@LaunchedEffect
        delay(350)
        val q = query.trim()
        results = if (q.length >= 2) Seerr.search(q) else Seerr.trending()
    }
    LaunchedEffect(tab, Seerr.isConfigured) { if (tab == 1 && Seerr.isConfigured) requests = Seerr.requests() }
    SectionHue(Hue.violet) {
        Scaffold(containerColor = Color.Transparent, topBar = {
            HuefinTopBar("Requests", nav) {
                if (Seerr.isConfigured) Box {
                    IconButton({ menu = true }) { Icon(Icons.Filled.MoreVert, "More") }
                    DropdownMenu(menu, { menu = false }) { DropdownMenuItem({ Text("Sign out of Seerr") }, { menu = false; scope.launch { Seerr.signOut() } }) }
                }
            }
        }) { pad ->
            Column(Modifier.fillMaxSize().background(Brush.verticalGradient(listOf(Hue.violet.copy(alpha = 0.2f), Hue.night, Hue.night))).padding(top = pad.calculateTopPadding())) {
                if (!Seerr.isConfigured) { SeerrSetup(); return@Column }
                SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth().padding(horizontal = 16.dp)) {
                    listOf("Discover", if (Seerr.canManage) "All requests" else "My requests").forEachIndexed { i, l ->
                        SegmentedButton(tab == i, { tab = i }, SegmentedButtonDefaults.itemShape(i, 2),
                            colors = SegmentedButtonDefaults.colors(activeContainerColor = Hue.violet, activeContentColor = Hue.ink)) { Text(l) }
                    }
                }
                if (tab == 0) {
                    OutlinedTextField(query, { query = it }, Modifier.fillMaxWidth().padding(16.dp), placeholder = { Text("Find a movie or show") },
                        leadingIcon = { Icon(Icons.Filled.Search, null) }, singleLine = true, shape = RoundedCornerShape(14.dp))
                    LazyVerticalGrid(gridColumns(110), contentPadding = PaddingValues(16.dp, 0.dp, 16.dp, 24.dp),
                        horizontalArrangement = Arrangement.spacedBy(12.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                        items(results, key = { it.mediaType + it.id }) { r -> Box(Modifier.clickable { picked = r }) { SeerrPoster(r) } }
                    }
                } else LazyColumn(contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    if (requests.isEmpty()) item { Text("No requests yet.", color = Hue.secondaryText) }
                    items(requests, key = { it.id }) { r ->
                        LaunchedEffect(r.id) { if (details[r.id] == null) details[r.id] = Seerr.details(r) }
                        val d = details[r.id]
                        Row(Modifier.widthIn(max = 720.dp).fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(Hue.card).padding(10.dp), verticalAlignment = Alignment.CenterVertically) {
                            RemoteImage(d?.second?.let { "https://image.tmdb.org/t/p/w154$it" }, Modifier.size(46.dp, 69.dp).clip(RoundedCornerShape(6.dp)))
                            Column(Modifier.weight(1f).padding(horizontal = 12.dp)) {
                                Text(d?.first ?: "…", fontWeight = FontWeight.SemiBold, maxLines = 1)
                                Text(when { r.mediaStatus == 5 -> "Available to watch"; r.status == 1 -> "Waiting for approval"; r.status == 2 -> "Approved, downloading"; r.status == 3 -> "Declined"; else -> "Requested" },
                                    style = MaterialTheme.typography.bodySmall, color = if (r.status == 3) Hue.coral else Hue.secondaryText)
                                if (Seerr.canManage && r.requestedBy.isNotEmpty()) Text("Asked by ${r.requestedBy}", style = MaterialTheme.typography.labelSmall, color = Hue.secondaryText)
                            }
                            if (Seerr.canManage && r.status == 1) {
                                IconButton({ scope.launch { runCatching { Seerr.approve(r.id) }; requests = Seerr.requests() } }) { Icon(Icons.Filled.CheckCircle, "Approve", tint = Hue.mint) }
                                IconButton({ scope.launch { runCatching { Seerr.decline(r.id) }; requests = Seerr.requests() } }) { Icon(Icons.Filled.Cancel, "Decline", tint = Hue.coral) }
                            }
                        }
                    }
                }
            }
        }
    }
    picked?.let { SeerrDetailDialog(it) { picked = null } }
}

@Composable
private fun SeerrSetup() {
    var address by remember { mutableStateOf(Seerr.baseURL ?: "") }
    var password by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    Column(Modifier.widthIn(max = 600.dp).fillMaxWidth().padding(20.dp).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text("Connect requests", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
        Text("Requests use Seerr (Jellyseerr). Sign in once with your Jellyfin password; Huefin doesn't keep it.", color = Hue.secondaryText)
        OutlinedTextField(address, { address = it }, Modifier.fillMaxWidth(), label = { Text("Seerr address") }, placeholder = { Text("https://requests.example.com") }, singleLine = true)
        OutlinedTextField(AppState.session?.userName ?: "", {}, Modifier.fillMaxWidth(), label = { Text("Username") }, readOnly = true, singleLine = true)
        OutlinedTextField(password, { password = it }, Modifier.fillMaxWidth(), label = { Text("Your Jellyfin password") }, visualTransformation = PasswordVisualTransformation(), singleLine = true)
        HueButton({
            busy = true; error = null
            scope.launch {
                runCatching { Seerr.signIn(address, AppState.session?.userName ?: "", password) }.onFailure { error = "Couldn't sign in. Check the address and password." }
                password = ""; busy = false
            }
        }, enabled = !busy && address.isNotBlank() && password.isNotEmpty()) { if (busy) CircularProgressIndicator(Modifier.size(18.dp), color = Hue.ink, strokeWidth = 2.dp) else Text("Connect") }
        error?.let { Text(it, color = Hue.coral) }
    }
}

/** A movie or show from Seerr, with the Request button. */
@Composable
fun SeerrDetailDialog(result: Seerr.Result, onDismiss: () -> Unit) {
    var busy by remember { mutableStateOf(false) }
    var done by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    AlertDialog(onDismiss, containerColor = Hue.card,
        confirmButton = {
            if (result.status != 5) SectionHue(Hue.violet) {
                HueButton({
                    busy = true
                    scope.launch { runCatching { Seerr.request(result) }.onSuccess { done = true }.onFailure { error = "Couldn't request it: ${it.message}" }; busy = false }
                }, enabled = !busy && !done && (result.status ?: 0) < 2) {
                    Icon(if (done) Icons.Filled.CheckCircle else Icons.Filled.AddCircle, null)
                    Text(if (done) " Requested!" else if (result.mediaType == "tv") " Request all seasons" else " Request")
                }
            }
        },
        dismissButton = { TextButton(onDismiss) { Text("Close") } },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                    RemoteImage(result.posterURL, Modifier.size(110.dp, 165.dp).clip(RoundedCornerShape(12.dp)))
                    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        Text(result.title, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
                        Text(listOfNotNull(result.year, if (result.mediaType == "tv") "TV show" else "Movie").joinToString(" · "), color = Hue.secondaryText)
                        result.statusText?.let { Chip(it) }
                    }
                }
                result.overview?.let { Text(it, style = MaterialTheme.typography.bodyMedium) }
                if (result.status == 5) Text("It's already on your server. Search for it in Huefin to watch.", style = MaterialTheme.typography.bodySmall, color = Hue.secondaryText)
                error?.let { Text(it, color = Hue.coral, style = MaterialTheme.typography.bodySmall) }
            }
        })
}
