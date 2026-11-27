package com.huefin.app.ui

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
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
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.blur
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.huefin.app.R
import com.huefin.app.core.AppState
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

@Composable
fun LoginScreen(adding: Boolean, onDone: () -> Unit) {
    var server by remember { mutableStateOf(if (adding) AppState.session?.serverURL ?: "" else "") }
    var username by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var code by remember { mutableStateOf<String?>(null) }
    var qcJob by remember { mutableStateOf<Job?>(null) }
    val scope = rememberCoroutineScope()

    Box(Modifier.fillMaxSize().background(Hue.night)) {
        // Soft colour glows: radial gradients fade smoothly on every device (blur left square edges on some).
        Box(Modifier.size(640.dp).offset((-240).dp, (-120).dp)
            .background(androidx.compose.ui.graphics.Brush.radialGradient(listOf(Hue.violet.copy(alpha = 0.42f), Hue.violet.copy(alpha = 0.12f), androidx.compose.ui.graphics.Color.Transparent))))
        Box(Modifier.size(600.dp).align(Alignment.BottomEnd).offset(220.dp, 80.dp)
            .background(androidx.compose.ui.graphics.Brush.radialGradient(listOf(Hue.coral.copy(alpha = 0.34f), Hue.coral.copy(alpha = 0.10f), androidx.compose.ui.graphics.Color.Transparent))))
        Column(
            Modifier.fillMaxSize().systemBarsPadding().imePadding().verticalScroll(rememberScrollState()).padding(28.dp),
            horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Column(Modifier.widthIn(max = 440.dp).fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(16.dp)) {
                Image(painterResource(R.drawable.huefin_mark), "Huefin", Modifier.padding(top = 48.dp).size(108.dp))
                Text("huefin", fontSize = 46.sp, fontWeight = FontWeight.ExtraBold, letterSpacing = (-1.5).sp)
                Text(if (adding) "Add a user or another server" else "Connect to your Jellyfin server", color = Hue.secondaryText)
                // Servers found on this network: tap one instead of typing its address.
                var found by remember { mutableStateOf<List<com.huefin.app.core.ServerDiscovery.Found>>(emptyList()) }
                LaunchedEffect(Unit) {
                    found = com.huefin.app.core.ServerDiscovery.scan()
                    if (found.size == 1 && server.isBlank()) server = found[0].address
                }
                found.forEach { f ->
                    SoftButton(modifier = Modifier.fillMaxWidth(), onClick = { server = f.address }) {
                        Text((if (server == f.address) "✓  " else "") + f.name + "  ·  " + f.address, maxLines = 1)
                    }
                }
                field("Server", server, { server = it }, KeyboardType.Uri)
                if (code == null) {
                    field("Username", username, { username = it }, KeyboardType.Text)
                    field("Password", password, { password = it }, KeyboardType.Password, secret = true)
                    error?.let { Text(it, color = Hue.coral, style = MaterialTheme.typography.bodySmall, textAlign = TextAlign.Center) }
                    HueButton(enabled = !busy && server.isNotBlank() && username.isNotBlank(), modifier = Modifier.fillMaxWidth(), onClick = {
                        busy = true; error = null
                        scope.launch {
                            try { AppState.login(server.trim(), username.trim(), password); onDone() }
                            catch (e: Exception) { error = e.message ?: "Couldn't sign in." }
                            busy = false
                        }
                    }) {
                        Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                            if (busy) CircularProgressIndicator(Modifier.size(20.dp), color = Hue.ink, strokeWidth = 2.dp) else Text("Sign in")
                        }
                    }
                    SoftButton(enabled = !busy && server.isNotBlank(), modifier = Modifier.fillMaxWidth(), onClick = {
                        busy = true; error = null
                        qcJob = scope.launch {
                            try {
                                val (pair, secret, c) = AppState.quickConnectStart(server)
                                code = c
                                AppState.quickConnectFinish(pair.first, pair.second, secret)
                                onDone()
                            } catch (e: CancellationException) {
                            } catch (e: Exception) { error = e.message }
                            code = null; busy = false
                        }
                    }) { Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) { Text("Sign in with Quick Connect") } }
                } else {
                    Column(Modifier.fillMaxWidth().background(Hue.card, RoundedCornerShape(18.dp)).padding(18.dp),
                        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        Text("Quick Connect code", style = MaterialTheme.typography.labelMedium, color = Hue.secondaryText)
                        Text(code ?: "", fontSize = 44.sp, fontWeight = FontWeight.ExtraBold, letterSpacing = 6.sp)
                        Text("On a device that's already signed in, open Quick Connect and enter this code. In Huefin it's Settings → Quick Connect.",
                            style = MaterialTheme.typography.bodySmall, color = Hue.secondaryText, textAlign = TextAlign.Center)
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp); Text("Waiting for approval…")
                        }
                        SoftButton({ qcJob?.cancel(); code = null; busy = false }) { Text("Cancel") }
                    }
                }
                if (adding) SoftButton({ qcJob?.cancel(); onDone() }) { Text("Cancel") }
                Text("Works with local addresses (192.168.x.x:8096) or your remote domain.",
                    style = MaterialTheme.typography.bodySmall, color = Hue.secondaryText, textAlign = TextAlign.Center)
            }
        }
    }
}

@Composable
private fun field(label: String, value: String, onChange: (String) -> Unit, type: KeyboardType, secret: Boolean = false) {
    OutlinedTextField(
        value, onChange, label = { Text(label) }, singleLine = true, modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(16.dp),
        keyboardOptions = KeyboardOptions(keyboardType = type, imeAction = ImeAction.Next, autoCorrectEnabled = false),
        visualTransformation = if (secret) PasswordVisualTransformation() else androidx.compose.ui.text.input.VisualTransformation.None,
        colors = OutlinedTextFieldDefaults.colors(focusedBorderColor = LocalHue.current, unfocusedBorderColor = Hue.hairline,
            focusedContainerColor = Hue.card, unfocusedContainerColor = Hue.card),
    )
}
