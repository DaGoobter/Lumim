package com.huefin.app.playback

import android.app.PictureInPictureParams
import android.content.res.Configuration
import android.graphics.Bitmap
import android.os.Build
import android.os.Bundle
import android.util.Rational
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.ClosedCaption
import androidx.compose.material.icons.filled.Forward10
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PictureInPictureAlt
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Replay10
import androidx.compose.material.icons.filled.SkipNext
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
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
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.lifecycle.lifecycleScope
import androidx.window.layout.FoldingFeature
import androidx.window.layout.WindowInfoTracker
import com.huefin.app.core.AppState
import com.huefin.app.core.Prefs
import com.huefin.app.ui.Hue
import com.huefin.app.ui.HuefinTheme
import com.huefin.app.ui.WatchTogetherDialog
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

class PlayerActivity : ComponentActivity() {
    private var model by mutableStateOf<PlayerModel?>(null)
    private var inPip by mutableStateOf(false)
    /** Half-folded with the hinge horizontal (laptop/"tabletop" posture on Galaxy Z Fold/Flip, Pixel Fold, Razr). */
    private var tabletopHinge by mutableStateOf<Int?>(null)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        WindowCompat.setDecorFitsSystemWindows(window, false)
        WindowInsetsControllerCompat(window, window.decorView).apply {
            hide(WindowInsetsCompat.Type.systemBars())
            systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        }
        val request = Player.pending ?: run { finish(); return }
        Player.pending = null
        lifecycleScope.launch {
            WindowInfoTracker.getOrCreate(this@PlayerActivity).windowLayoutInfo(this@PlayerActivity).collect { info ->
                val fold = info.displayFeatures.filterIsInstance<FoldingFeature>().firstOrNull()
                tabletopHinge = if (fold != null && fold.state == FoldingFeature.State.HALF_OPENED &&
                    fold.orientation == FoldingFeature.Orientation.HORIZONTAL) fold.bounds.top else null
            }
        }
        lifecycleScope.launch {
            val engine = EngineDecider.useEngine(request, AppState.client, AppState.maxBitrate) && SyncPlay.groupId == null
            val backend: Backend = if (engine) runCatching { MpvBackend(this@PlayerActivity) }.onFailure {
                com.huefin.app.core.CrashReport.engineStarting(false)
                com.huefin.app.core.CrashReport.note("The Huefin Engine couldn't load, so Android's player was used.", it)
            }.getOrNull() ?: ExoBackend(this@PlayerActivity) else ExoBackend(this@PlayerActivity)
            val m = PlayerModel(request, backend)
            m.onClose = { finish() }
            model = m
            m.start()
            SyncPlay.playerOpened(m)
        }
        setContent {
            HuefinTheme {
                val m = model
                if (m == null) Box(Modifier.fillMaxSize().background(Color.Black), Alignment.Center) { CircularProgressIndicator(color = Color.White) }
                else PlayerScreen(m, inPip, tabletopHinge, onClose = { finish() }, onPip = { enterPip() })
            }
        }
        if (Build.VERSION.SDK_INT >= 31) setPictureInPictureParams(PictureInPictureParams.Builder().setAutoEnterEnabled(true)
            .setAspectRatio(Rational(16, 9)).build())
    }

    private fun enterPip() {
        runCatching { enterPictureInPictureMode(PictureInPictureParams.Builder().setAspectRatio(Rational(16, 9)).build()) }
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (Build.VERSION.SDK_INT < 31 && model?.isPlaying == true) enterPip()
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: Configuration) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        inPip = isInPictureInPictureMode
    }

    override fun onStop() {
        super.onStop()
        // Closing the picture-in-picture window stops playback.
        if (isFinishing || (inPip && !isChangingConfigurations)) model?.backend?.pause()
    }

    override fun onDestroy() {
        val m = model
        if (m != null) AppState.scope.launch { m.stop() }
        super.onDestroy()
    }
}

private fun fmt(s: Double): String {
    val t = s.toLong().coerceAtLeast(0)
    return if (t >= 3600) "%d:%02d:%02d".format(t / 3600, t / 60 % 60, t % 60) else "%d:%02d".format(t / 60, t % 60)
}

@Composable
private fun PlayerScreen(m: PlayerModel, inPip: Boolean, tabletopHinge: Int?, onClose: () -> Unit, onPip: () -> Unit) {
    var visible by remember { mutableStateOf(true) }
    var scrubbing by remember { mutableStateOf<Float?>(null) }
    var lastTouch by remember { mutableStateOf(System.currentTimeMillis()) }
    var showSync by remember { mutableStateOf(false) }
    LaunchedEffect(lastTouch, m.isPlaying, scrubbing) {
        delay(4000)
        if (m.isPlaying && scrubbing == null) visible = false
    }
    val touch = { visible = true; lastTouch = System.currentTimeMillis() }

    BoxWithConstraints(Modifier.fillMaxSize().background(Color.Black)) {
        val density = androidx.compose.ui.platform.LocalDensity.current
        val hingeDp = tabletopHinge?.let { with(density) { it.toDp() } }
        // Tabletop: video on the top half, controls on the bottom half.
        val videoModifier = if (hingeDp != null) Modifier.fillMaxWidth().height(hingeDp) else Modifier.fillMaxSize()
        AndroidView({ ctx -> m.backend.createView(ctx) }, videoModifier
            .pointerInput(Unit) { detectTapGestures(onTap = { visible = !visible; lastTouch = System.currentTimeMillis() },
                onDoubleTap = { m.toggleFill() }) })
        m.overlaySubtitle?.let { line ->
            Text(line.replace("\\N", "\n"), Modifier.align(if (hingeDp != null) Alignment.TopCenter else Alignment.BottomCenter)
                .padding(start = 32.dp, end = 32.dp, top = (hingeDp ?: 0.dp) - 90.dp.coerceAtMost(hingeDp ?: 0.dp), bottom = if (inPip) 6.dp else 48.dp)
                .background(Color.Black.copy(alpha = 0.55f), RoundedCornerShape(6.dp)).padding(horizontal = 10.dp, vertical = 4.dp),
                color = Color.White, fontSize = if (inPip) 11.sp else 20.sp, fontWeight = FontWeight.SemiBold,
                textAlign = androidx.compose.ui.text.style.TextAlign.Center, lineHeight = if (inPip) 13.sp else 26.sp)
        }
        if (inPip) return@BoxWithConstraints

        if (m.loading && m.error == null || m.liveStatus != null) {
            Column(Modifier.align(if (hingeDp != null) Alignment.TopCenter else Alignment.Center).padding(top = (hingeDp ?: 0.dp) / 2 - 20.dp),
                horizontalAlignment = Alignment.CenterHorizontally) {
                CircularProgressIndicator(color = Color.White)
                m.liveStatus?.let { Text(it, color = Color.White, modifier = Modifier.padding(top = 8.dp)) }
            }
        }
        m.error?.let { e ->
            Column(Modifier.align(Alignment.Center).background(Hue.card, RoundedCornerShape(20.dp)).padding(24.dp),
                horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text("Can't play this", fontWeight = FontWeight.Bold); Text(e, color = Hue.secondaryText)
                com.huefin.app.ui.SoftButton(onClose) { Text("Close") }
            }
        }

        val controlsArea = if (hingeDp != null) Modifier.fillMaxWidth().offset(y = hingeDp).height(maxHeight - hingeDp).background(Color.Black)
        else Modifier.fillMaxSize()
        AnimatedVisibility(visible || !m.isPlaying || hingeDp != null, enter = fadeIn(), exit = fadeOut()) {
            Box(controlsArea.then(if (hingeDp == null) Modifier.background(Brush.verticalGradient(0f to Color.Black.copy(alpha = 0.6f),
                0.25f to Color.Transparent, 0.7f to Color.Transparent, 1f to Color.Black.copy(alpha = 0.75f))) else Modifier)
                .safeDrawingPadding()) {
                TopBar(m, onClose, onPip, onSync = { showSync = true; touch() }, onTouch = touch, modifier = Modifier.align(Alignment.TopCenter))
                Transport(m, touch, Modifier.align(Alignment.Center))
                Scrubber(m, scrubbing, { scrubbing = it; touch() }, Modifier.align(Alignment.BottomCenter))
            }
        }
        Cast.deviceName?.let { tv ->
            Column(Modifier.align(Alignment.Center).background(Hue.card, RoundedCornerShape(22.dp)).padding(24.dp),
                horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text("Playing on $tv", fontWeight = FontWeight.Bold)
                val c = androidx.compose.ui.platform.LocalContext.current
                com.huefin.app.ui.SoftButton({ Cast.stop(c) }) { Text("Stop casting") }
            }
        }
        SkipAndUpNext(m, visible, Modifier.align(Alignment.BottomEnd).safeDrawingPadding().padding(end = 20.dp, bottom = if (visible) 110.dp else 40.dp))
    }
    if (showSync) WatchTogetherDialog(m) { showSync = false }
}

@Composable
private fun RoundIcon(icon: androidx.compose.ui.graphics.vector.ImageVector, label: String, onClick: () -> Unit) {
    IconButton(onClick, Modifier.size(42.dp).background(Color.White.copy(alpha = 0.14f), CircleShape)) { Icon(icon, label, tint = Color.White) }
}

@Composable
private fun TopBar(m: PlayerModel, onClose: () -> Unit, onPip: () -> Unit, onSync: () -> Unit, onTouch: () -> Unit, modifier: Modifier) {
    var tracks by remember { mutableStateOf(false) }
    var more by remember { mutableStateOf(false) }
    var info by remember { mutableStateOf(false) }
    val ctx = androidx.compose.ui.platform.LocalContext.current
    Row(modifier.fillMaxWidth().padding(12.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        RoundIcon(Icons.Filled.Close, "Close", onClose)
        Column(Modifier.weight(1f)) {
            Text(m.item.displayTitle, fontWeight = FontWeight.Bold, color = Color.White, maxLines = 1)
            Text(listOfNotNull(m.item.episodeLabel, if (m.backend is MpvBackend) "Huefin Engine" else null).joinToString(" · "),
                color = Color.White.copy(alpha = 0.7f), style = MaterialTheme.typography.labelMedium, maxLines = 1)
        }
        Box {
            RoundIcon(Icons.Filled.ClosedCaption, "Audio and subtitles") { tracks = true; onTouch() }
            DropdownMenu(tracks, { tracks = false }) {
                Text("Audio", style = MaterialTheme.typography.labelMedium, modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp), color = Hue.secondaryText)
                m.backend.audioTracks().forEach { t -> DropdownMenuItem({ Text((if (t.selected) "✓ " else "") + t.label) }, { m.backend.selectAudio(t.id); tracks = false }) }
                HorizontalDivider()
                Text("Subtitles", style = MaterialTheme.typography.labelMedium, modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp), color = Hue.secondaryText)
                val subs = m.backend.subtitleTracks()
                DropdownMenuItem({ Text((if (subs.none { it.selected }) "✓ " else "") + "Off") }, { m.backend.selectSubtitle(null); tracks = false })
                subs.forEach { t -> DropdownMenuItem({ Text((if (t.selected) "✓ " else "") + t.label) }, { m.backend.selectSubtitle(t.id); tracks = false }) }
            }
        }
        if (!m.isLive) {
            RoundIcon(Icons.Filled.PictureInPictureAlt, "Picture in picture", onPip)
        }
        Box {
            RoundIcon(Icons.Filled.MoreVert, "More options") { more = true; onTouch() }
            DropdownMenu(more, { more = false }) {
                if (!m.isLive) {
                    Text("Speed", style = MaterialTheme.typography.labelMedium, modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp), color = Hue.secondaryText)
                    listOf(0.5f, 0.75f, 1f, 1.25f, 1.5f, 1.75f, 2f).forEach { s ->
                        DropdownMenuItem({ Text((if (s == m.speed) "✓ " else "") + if (s == 1f) "Normal" else "${s}×") }, { m.changeSpeed(s); more = false })
                    }
                    HorizontalDivider()
                }
                Text("Sleep timer", style = MaterialTheme.typography.labelMedium, modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp), color = Hue.secondaryText)
                DropdownMenuItem({ Text((if (m.sleepAt == null && !m.sleepAtEnd) "✓ " else "") + "Off") }, { m.setSleepTimer(null); more = false })
                listOf(15, 30, 45, 60, 90).forEach { n -> DropdownMenuItem({ Text("$n minutes") }, { m.setSleepTimer(n); more = false }) }
                if (!m.isLive) DropdownMenuItem({ Text((if (m.sleepAtEnd) "✓ " else "") + "End of this ${if (m.item.type == "Episode") "episode" else "video"}") }, { m.setSleepAtEnd(); more = false })
                if (m.backend.supportsBoost) {
                    HorizontalDivider()
                    Text("Volume boost", style = MaterialTheme.typography.labelMedium, modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp), color = Hue.secondaryText)
                    listOf(100, 125, 150, 200).forEach { v -> DropdownMenuItem({ Text((if (v == m.volumeBoost) "✓ " else "") + if (v == 100) "Normal" else "$v%") }, { m.setBoost(v); more = false }) }
                }
                HorizontalDivider()
                DropdownMenuItem({ Text(if (m.fill) "Fit to screen" else "Fill screen") }, { m.toggleFill(); more = false })
                if (!m.isLive && !m.isOffline) DropdownMenuItem({ Text(if (SyncPlay.groupId == null) "Watch Together" else "Watch Together · On") }, { more = false; onSync() })
                if (!m.isLive && !m.isOffline) DropdownMenuItem({ Text("Cast to a TV") }, { more = false; Cast.showPicker(ctx, m) })
                DropdownMenuItem({ Text("Stream info") }, { more = false; info = true })
            }
        }
    }
    if (info) androidx.compose.material3.AlertDialog({ info = false }, confirmButton = { androidx.compose.material3.TextButton({ info = false }) { Text("Done") } },
        title = { Text("Stream info") }, text = { Text("Engine: ${m.backend.name}\nMethod: ${m.playMethod}\nServer: ${if (AppState.route == AppState.Route.Local) "Home network" else "Remote"}") })
}

@Composable
private fun Transport(m: PlayerModel, onTouch: () -> Unit, modifier: Modifier) {
    Row(modifier, horizontalArrangement = Arrangement.spacedBy(48.dp), verticalAlignment = Alignment.CenterVertically) {
        if (!m.isLive) IconButton({ m.skip(-Prefs.skipBack.toDouble()); onTouch() }, Modifier.size(56.dp)) {
            Icon(Icons.Filled.Replay10, "Back ${Prefs.skipBack} seconds", Modifier.size(38.dp), tint = Color.White)
        }
        IconButton({ m.togglePlay(); onTouch() }, Modifier.size(78.dp).background(Color.White.copy(alpha = 0.16f), CircleShape)) {
            Icon(if (m.isPlaying) Icons.Filled.Pause else Icons.Filled.PlayArrow, if (m.isPlaying) "Pause" else "Play", Modifier.size(46.dp), tint = Color.White)
        }
        if (!m.isLive) IconButton({ m.skip(Prefs.skipForward.toDouble()); onTouch() }, Modifier.size(56.dp)) {
            Icon(Icons.Filled.Forward10, "Forward ${Prefs.skipForward} seconds", Modifier.size(38.dp), tint = Color.White)
        }
    }
}

@Composable
private fun Scrubber(m: PlayerModel, scrubbing: Float?, onScrub: (Float?) -> Unit, modifier: Modifier) {
    if (m.isLive) {
        Row(modifier.padding(20.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Box(Modifier.size(8.dp).background(Hue.coral, CircleShape)); Text("LIVE", color = Color.White, fontWeight = FontWeight.Bold)
        }
        return
    }
    var thumb by remember { mutableStateOf<Bitmap?>(null) }
    LaunchedEffect(scrubbing?.let { (it / 5).toInt() }) { thumb = scrubbing?.let { m.thumbnail(it.toDouble()) } }
    val dur = m.duration.coerceAtLeast(1.0).toFloat()
    val shown = scrubbing ?: m.position.toFloat()
    Column(modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 10.dp)) {
        if (scrubbing != null) {
            BoxWithConstraints(Modifier.fillMaxWidth()) {
                val x = (maxWidth - 170.dp) * (shown / dur)
                Column(Modifier.offset(x = x).width(170.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                    thumb?.let { Image(it.asImageBitmap(), null, Modifier.width(170.dp).clip(RoundedCornerShape(10.dp))) }
                    m.chapterAt(shown.toDouble())?.name?.let { Text(it, color = Color.White, fontSize = 12.sp, maxLines = 1) }
                    Text(fmt(shown.toDouble()), color = Color.White, fontWeight = FontWeight.Bold)
                }
            }
        }
        Box {
            // Chapter marks under the bar.
            BoxWithConstraints(Modifier.fillMaxWidth().padding(horizontal = 10.dp).height(48.dp)) {
                m.chapters.drop(1).forEach { ch ->
                    Box(Modifier.offset(x = maxWidth * (ch.start / dur).toFloat().coerceIn(0f, 1f), y = 30.dp).size(2.dp, 6.dp).background(Color.White.copy(alpha = 0.6f)))
                }
            }
            Slider(shown, { onScrub(it) }, valueRange = 0f..dur, onValueChangeFinished = { scrubbing?.let { m.seek(it.toDouble()) }; onScrub(null) },
                colors = SliderDefaults.colors(thumbColor = Color.White, activeTrackColor = Hue.coral,
                    inactiveTrackColor = Color.White.copy(alpha = 0.25f)))
        }
        Row(Modifier.fillMaxWidth()) {
            Text(fmt(shown.toDouble()), color = Color.White.copy(alpha = 0.85f), fontSize = 12.sp)
            Spacer(Modifier.weight(1f))
            Text("-" + fmt((m.duration - shown).coerceAtLeast(0.0)), color = Color.White.copy(alpha = 0.85f), fontSize = 12.sp)
        }
    }
}

@Composable
private fun SkipAndUpNext(m: PlayerModel, controlsShown: Boolean, modifier: Modifier) {
    val scope = rememberCoroutineScope()
    Column(modifier, horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(10.dp)) {
        val next = m.nextEpisode
        if (m.upNextCountdown != null && next != null) {
            Column(Modifier.width(300.dp).background(Hue.card.copy(alpha = 0.95f), RoundedCornerShape(18.dp)).padding(14.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text("Up next in ${m.upNextCountdown}", color = Hue.sun, fontWeight = FontWeight.ExtraBold, fontSize = 12.sp)
                Text(next.episodeLabel ?: next.displayTitle, color = Color.White, fontWeight = FontWeight.SemiBold, maxLines = 2)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    com.huefin.app.ui.PlayButton({ scope.launch { m.playNext() } }) { Icon(Icons.Filled.SkipNext, null); Text(" Play now") }
                    com.huefin.app.ui.SoftButton({ m.dismissUpNext() }) { Text("Watch credits") }
                }
            }
        } else if (m.activeSkip != null) {
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                if (m.autoSkipIn != null) Text("Watch it", color = Color.White, fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.clip(RoundedCornerShape(50)).background(Color.White.copy(alpha = 0.18f)).clickable { m.cancelAutoSkip() }.padding(horizontal = 16.dp, vertical = 12.dp))
                Text((m.autoSkipIn?.let { "${m.skipLabel} in $it" } ?: m.skipLabel) + "  ›", color = Hue.ink, fontWeight = FontWeight.ExtraBold,
                    modifier = Modifier.clip(RoundedCornerShape(16.dp)).background(Hue.paper).clickable { m.skipSegment() }.padding(horizontal = 20.dp, vertical = 12.dp))
            }
        }
    }
}
