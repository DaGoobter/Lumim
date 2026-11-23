package com.huefin.desktop.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.huefin.desktop.core.AppState
import com.huefin.desktop.core.HttpError
import com.huefin.desktop.player.PlayerModel
import com.huefin.desktop.player.SyncPlay
import kotlinx.coroutines.launch

/** Watch Together (Jellyfin SyncPlay): start or join a group; play, pause and seeking are shared. */
@Composable
fun WatchTogetherDialog(model: PlayerModel?, onDismiss: () -> Unit) {
    val c = AppState.client ?: return onDismiss()
    var groups by remember { mutableStateOf<List<SyncPlay.Group>>(emptyList()) }
    var loading by remember { mutableStateOf(true) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    suspend fun refresh() { loading = true; groups = SyncPlay.listGroups(c); loading = false }
    LaunchedEffect(Unit) { refresh() }
    fun run(work: suspend () -> Unit) {
        busy = true; error = null
        scope.launch {
            runCatching { work() }.onSuccess { onDismiss() }.onFailure {
                error = if ((it as? HttpError)?.code == 403) "Your account isn't allowed to use SyncPlay. An admin can turn it on under Users → (you) → SyncPlay." else it.message
            }
            busy = false
        }
    }
    AlertDialog(onDismiss, containerColor = Hue.card, title = { Text("Watch Together") },
        confirmButton = { TextButton(onDismiss) { Text("Done") } },
        dismissButton = { IconButton({ scope.launch { refresh() } }) { Icon(Icons.Filled.Refresh, "Refresh") } },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                if (SyncPlay.groupId != null) {
                    Eyebrow("You're watching together", Hue.secondaryText)
                    Row(verticalAlignment = Alignment.CenterVertically) { Icon(Icons.Filled.Groups, null, tint = LocalHue.current); Text("  ${SyncPlay.groupName ?: "Watch Together"}", fontWeight = FontWeight.Bold) }
                    SyncPlay.participants.forEach { Row { Icon(Icons.Filled.Person, null, Modifier.size(18.dp)); Text("  $it") } }
                    SyncPlay.status?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = Hue.secondaryText) }
                    Text("Play, pause and seeking are shared with everyone in the group.", style = MaterialTheme.typography.bodySmall, color = Hue.secondaryText)
                    TextButton({ scope.launch { SyncPlay.leave(); onDismiss() } }) { Text("Leave group", color = Hue.coral) }
                } else {
                    if (model != null) {
                        HueButton({ run { SyncPlay.create(c, model, "${AppState.session?.userName ?: "Huefin"}'s room") } }, enabled = !busy) {
                            Icon(Icons.Filled.AddCircle, null); Text(" Start a group with “${model.item.displayTitle}”")
                        }
                        Text("Others join from Huefin (More → Watch Together) or Jellyfin's web app (the SyncPlay button).", style = MaterialTheme.typography.bodySmall, color = Hue.secondaryText)
                    }
                    Eyebrow("Join a group", Hue.secondaryText)
                    when {
                        loading -> CircularProgressIndicator()
                        groups.isEmpty() -> Text("No groups right now.", color = Hue.secondaryText)
                    }
                    groups.forEach { g ->
                        Column(Modifier.fillMaxWidth().clickable(enabled = !busy) { run { SyncPlay.join(c, g, model) } }.padding(vertical = 8.dp)) {
                            Text(g.name, fontWeight = FontWeight.SemiBold); Text(g.participants.joinToString(", "), style = MaterialTheme.typography.bodySmall, color = Hue.secondaryText)
                        }
                    }
                }
                error?.let { Text(it, color = Hue.coral, style = MaterialTheme.typography.bodySmall) }
            }
        })
}
