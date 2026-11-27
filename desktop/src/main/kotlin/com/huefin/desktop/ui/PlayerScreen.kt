package com.huefin.desktop.ui

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.VolumeOff
import androidx.compose.material.icons.automirrored.filled.VolumeUp
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.input.pointer.PointerEventType
import androidx.compose.ui.input.pointer.PointerIcon
import androidx.compose.ui.input.pointer.onPointerEvent
import androidx.compose.ui.input.pointer.pointerHoverIcon
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.focus.focusRequester
import androidx.compose.foundation.focusable
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.input.key.key
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import com.huefin.desktop.core.AppState
import com.huefin.desktop.player.PlayerController
import kotlinx.coroutines.delay
import java.awt.Cursor

private fun clock(ms: Long): String { val s = ms / 1000; return if (s >= 3600) "%d:%02d:%02d".format(s / 3600, s / 60 % 60, s % 60) else "%d:%02d".format(s / 60, s % 60) }

/**
 * Full-window player. The picture is a native window the Huefin Engine draws into with Direct3D 11 (that's what lets
 * HDR reach the screen). Compose can't paint over a native window, so the controls live in a see-through window
 * that sits exactly on top of it and follows the main window around.
 */
@Composable
fun PlayerScreen(p: PlayerController) {
    Box(Modifier.fillMaxSize().background(Color.Black)) {
        androidx.compose.ui.awt.SwingPanel(background = Color.Black, modifier = Modifier.fillMaxSize(),
            factory = { VideoHost { p.attachWindow(it) } })
    }
    Nav.awtWindow?.let { owner -> OverlayWindow(owner) { PlayerControls(p) } }
}

/** The native window mpv draws into. */
private class VideoHost(private val onHandle: (Long) -> Unit) : java.awt.Canvas() {
    init { background = java.awt.Color.BLACK }
    override fun addNotify() {
        super.addNotify()
        runCatching { onHandle(com.sun.jna.Native.getComponentID(this)) }
    }
}

/** A borderless, see-through window kept exactly over the main window's content, for the player controls. */
@Composable
private fun OverlayWindow(owner: java.awt.Window, content: @Composable () -> Unit) {
    val latest by rememberUpdatedState(content)
    DisposableEffect(owner) {
        val d = androidx.compose.ui.awt.ComposeDialog(owner, java.awt.Dialog.ModalityType.MODELESS)
        d.isUndecorated = true
        d.isTransparent = true
        d.isResizable = false
        d.title = "Huefin"
        d.setContent {
            HuefinTheme { CompositionLocalProvider(LocalWidthClass provides WidthClass.Expanded) {
                // The player's keyboard shortcuts work while this window has focus, same as in the main window.
                val focus = remember { androidx.compose.ui.focus.FocusRequester() }
                Box(Modifier.fillMaxSize().focusRequester(focus).focusable()
                    .onPreviewKeyEvent { e -> e.type == androidx.compose.ui.input.key.KeyEventType.KeyDown && Nav.playerKey(e.key) }) { latest() }
                LaunchedEffect(Unit) { runCatching { focus.requestFocus() } }
            } }
        }
        val pane = (owner as? javax.swing.RootPaneContainer)?.contentPane
        fun sync() {
            val c: java.awt.Component = pane ?: owner
            if (!c.isShowing) return
            val at = c.locationOnScreen
            val r = java.awt.Rectangle(at.x, at.y, c.width, c.height)
            if (d.bounds != r) d.bounds = r
        }
        val follow = object : java.awt.event.ComponentAdapter() {
            override fun componentMoved(e: java.awt.event.ComponentEvent?) = sync()
            override fun componentResized(e: java.awt.event.ComponentEvent?) = sync()
        }
        owner.addComponentListener(follow); pane?.addComponentListener(follow)
        val timer = javax.swing.Timer(300) { sync() }.apply { start() }
        sync()
        d.isVisible = true
        d.toFront()
        onDispose {
            timer.stop(); owner.removeComponentListener(follow); pane?.removeComponentListener(follow)
            d.isVisible = false; d.dispose()
        }
    }
}

@OptIn(androidx.compose.ui.ExperimentalComposeUiApi::class)
@Composable
private fun PlayerControls(p: PlayerController) {
    var lastMove by remember { mutableStateOf(System.currentTimeMillis()) }
    var now by remember { mutableStateOf(System.currentTimeMillis()) }
    var menuOpen by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { while (true) { delay(300); now = System.currentTimeMillis() } }
    val show = !p.playing || menuOpen || now - lastMove < 3000 || p.loading
    val hidden = Cursor.getPredefinedCursor(Cursor.DEFAULT_CURSOR)
    // Almost-clear (not fully clear) so Windows still sends the mouse here rather than to the video underneath.
    Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.004f))
        .onPointerEvent(PointerEventType.Move) { lastMove = System.currentTimeMillis() }
        .pointerHoverIcon(if (show) PointerIcon.Default else PointerIcon(java.awt.Toolkit.getDefaultToolkit().createCustomCursor(
            java.awt.image.BufferedImage(1, 1, java.awt.image.BufferedImage.TYPE_INT_ARGB), java.awt.Point(0, 0), "none")))
        .pointerInput(Unit) { detectTapGestures(onDoubleTap = { Nav.toggleFullscreen() }, onTap = { p.togglePlay(); lastMove = System.currentTimeMillis() }) }) {
        if (p.item.isAudio && !p.loading && p.error == null) {
            RemoteImage(AppState.client?.albumArtURL(p.item, 800), Modifier.align(Alignment.Center).size(420.dp).clip(RoundedCornerShape(24.dp)))
        }
        if (p.loading && p.error == null) CircularProgressIndicator(Modifier.align(Alignment.Center).size(56.dp), color = Color.White)
        p.error?.let { e ->
            Column(Modifier.align(Alignment.Center).clip(RoundedCornerShape(22.dp)).background(Hue.card).padding(28.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                Icon(Icons.Filled.Warning, null, Modifier.size(40.dp), tint = Hue.sun)
                Text("Couldn't play this", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold, modifier = Modifier.padding(top = 8.dp))
                Text(e, color = Hue.secondaryText, modifier = Modifier.padding(vertical = 8.dp).widthIn(max = 420.dp))
                SoftButton({ p.close() }) { Text("Close") }
            }
        }

        // Skip intro / up next.
        val skip = p.activeSkip
        Column(Modifier.align(Alignment.BottomEnd).padding(end = 32.dp, bottom = if (show) 130.dp else 40.dp), horizontalAlignment = Alignment.End) {
            if (skip != null) SectionHue(Hue.coral) { HueButton({ p.skipSegment() }) { Text(p.skipLabel); Icon(Icons.Filled.SkipNext, null) } }
            val next = p.nextEpisode
            if (p.upNextIn != null && next != null) {
                Row(Modifier.clip(RoundedCornerShape(18.dp)).background(Hue.card.copy(alpha = 0.95f)).padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
                    RemoteImage(AppState.client?.landscapeURL(next, 400), Modifier.size(160.dp, 90.dp).clip(RoundedCornerShape(10.dp)))
                    Column(Modifier.padding(horizontal = 14.dp).widthIn(max = 260.dp)) {
                        Eyebrow("Up next in ${p.upNextIn}", Hue.coral)
                        Text(next.episodeLabel ?: next.displayTitle, fontWeight = FontWeight.SemiBold, maxLines = 2)
                        Row(Modifier.padding(top = 8.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            SectionHue(Hue.coral) { HueButton({ p.playNext() }) { Text("Play now") } }
                            TextButton({ p.dismissUpNext() }) { Text("Keep watching") }
                        }
                    }
                }
            }
        }

        AnimatedVisibility(show, Modifier.fillMaxSize(), enter = fadeIn(), exit = fadeOut()) {
            Box(Modifier.fillMaxSize()) {
                // Top bar.
                Row(Modifier.fillMaxWidth().background(Brush.verticalGradient(listOf(Color.Black.copy(alpha = 0.75f), Color.Transparent))).padding(20.dp),
                    verticalAlignment = Alignment.CenterVertically) {
                    IconButton({ p.close() }) { Icon(Icons.Filled.Close, "Close (Esc)") }
                    Column(Modifier.weight(1f).padding(start = 8.dp)) {
                        Text(p.item.displayTitle, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
                        (p.item.episodeLabel ?: p.item.artistLine)?.let { Text(it, color = Hue.secondaryText) }
                    }
                    Column(Modifier.padding(end = 12.dp), horizontalAlignment = Alignment.End) {
                        Text(p.method, style = MaterialTheme.typography.labelMedium, color = Hue.secondaryText)
                        if (p.pictureInfo.isNotEmpty()) Text(p.pictureInfo, style = MaterialTheme.typography.labelSmall, color = Hue.secondaryText)
                    }
                    TrackMenu(p) { menuOpen = it }
                    IconButton({ Nav.toggleFullscreen() }) { Icon(Icons.Filled.Fullscreen, "Full screen (F)") }
                }
                // Bottom controls.
                Column(Modifier.align(Alignment.BottomCenter).fillMaxWidth().background(Brush.verticalGradient(listOf(Color.Transparent, Color.Black.copy(alpha = 0.8f))))
                    .padding(horizontal = 28.dp, vertical = 18.dp)) {
                    if (!p.isLive) {
                        var drag by remember { mutableStateOf<Float?>(null) }
                        val len = p.lengthMs.coerceAtLeast(1)
                        // Scrubbing previews from the server's trickplay images.
                        var thumbs by remember(p.item.id) { mutableStateOf<TrickplayThumbs?>(null) }
                        LaunchedEffect(p.item.id) { thumbs = AppState.client?.let { TrickplayThumbs.load(it, p.item.id) } }
                        var thumb by remember { mutableStateOf<androidx.compose.ui.graphics.ImageBitmap?>(null) }
                        val dragMs = drag?.let { (it * len).toLong() }
                        LaunchedEffect(dragMs?.div(2000), thumbs) { thumb = if (dragMs != null) thumbs?.thumbnail(dragMs) else null }
                        BoxWithConstraints(Modifier.fillMaxWidth()) {
                            if (drag != null && dragMs != null) {
                                val bubbleW = 240.dp
                                val x = (maxWidth * drag!! - bubbleW / 2).coerceIn(0.dp, (maxWidth - bubbleW).coerceAtLeast(0.dp))
                                TrickplayBubble(thumb, clock(dragMs), Modifier.width(bubbleW).offset(x = x, y = if (thumb != null) (-170).dp else (-36).dp))
                            }
                            Slider(drag ?: (p.positionMs.toFloat() / len), { drag = it }, onValueChangeFinished = { drag?.let { p.seekTo((it * len).toLong()) }; drag = null },
                                colors = SliderDefaults.colors(thumbColor = Color.White, activeTrackColor = Hue.coral, inactiveTrackColor = Color.White.copy(alpha = 0.25f)))
                        }
                    }
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        if (!p.isLive) IconButton({ p.seekBy(-10) }) { Icon(Icons.Filled.Replay10, "Back 10 seconds") }
                        Box(Modifier.size(56.dp).clip(CircleShape).background(Hue.paper).clickable { p.togglePlay() }, Alignment.Center) {
                            Icon(if (p.playing) Icons.Filled.Pause else Icons.Filled.PlayArrow, if (p.playing) "Pause" else "Play", Modifier.size(32.dp), tint = Hue.ink)
                        }
                        if (!p.isLive) IconButton({ p.seekBy(30) }) { Icon(Icons.Filled.Forward30, "Forward 30 seconds") }
                        if (p.nextEpisode != null) IconButton({ p.playNext() }) { Icon(Icons.Filled.SkipNext, "Next episode") }
                        Spacer(Modifier.width(12.dp))
                        if (p.isLive) Text("LIVE", Modifier.clip(RoundedCornerShape(6.dp)).background(Hue.coral).padding(horizontal = 8.dp, vertical = 3.dp), color = Hue.ink, fontWeight = FontWeight.Black)
                        else Text("${clock(p.positionMs)} / ${clock(p.lengthMs)}", style = MaterialTheme.typography.bodyMedium)
                        Spacer(Modifier.weight(1f))
                        IconButton({ p.toggleMute() }) { Icon(if (p.muted || p.volume == 0) Icons.AutoMirrored.Filled.VolumeOff else Icons.AutoMirrored.Filled.VolumeUp, "Mute (M)") }
                        Slider(p.volume.toFloat(), { p.changeVolume(it.toInt()) }, Modifier.width(140.dp), valueRange = 0f..200f,
                            colors = SliderDefaults.colors(thumbColor = Color.White, activeTrackColor = Color.White, inactiveTrackColor = Color.White.copy(alpha = 0.25f)))
                        Text("${p.volume}%", style = MaterialTheme.typography.labelSmall, color = Hue.secondaryText, modifier = Modifier.width(44.dp))
                    }
                }
            }
        }
    }
}

@Composable
private fun TrackMenu(p: PlayerController, onOpen: (Boolean) -> Unit) {
    var open by remember { mutableStateOf(false) }
    Box {
        IconButton({ open = true; onOpen(true) }) { Icon(Icons.Filled.ClosedCaption, "Audio and subtitles") }
        DropdownMenu(open, { open = false; onOpen(false) }, Modifier.heightIn(max = 520.dp)) {
            Text("Audio", Modifier.padding(horizontal = 14.dp, vertical = 6.dp), style = MaterialTheme.typography.labelMedium, color = Hue.secondaryText)
            p.audioTracks.forEach { t -> DropdownMenuItem({ Text((if (t.id == p.audioTrack) "✓  " else "     ") + t.label) }, { p.selectAudio(t.id); open = false; onOpen(false) }) }
            HorizontalDivider()
            Text("Subtitles", Modifier.padding(horizontal = 14.dp, vertical = 6.dp), style = MaterialTheme.typography.labelMedium, color = Hue.secondaryText)
            DropdownMenuItem({ Text((if (p.subtitleTrack < 0) "✓  " else "     ") + "Off") }, { p.selectSubtitle(-1); open = false; onOpen(false) })
            p.subtitleTracks.forEach { t -> DropdownMenuItem({ Text((if (t.id == p.subtitleTrack) "✓  " else "     ") + t.label) }, { p.selectSubtitle(t.id); open = false; onOpen(false) }) }
        }
    }
}
