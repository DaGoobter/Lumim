package com.huefin.desktop

import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.type
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Window
import androidx.compose.ui.window.WindowPlacement
import androidx.compose.ui.window.WindowPosition
import androidx.compose.ui.window.application
import androidx.compose.ui.window.rememberWindowState
import coil3.ImageLoader
import coil3.SingletonImageLoader
import coil3.disk.DiskCache
import coil3.memory.MemoryCache
import coil3.request.crossfade
import com.huefin.desktop.core.AppState
import com.huefin.desktop.ui.HuefinRoot
import com.huefin.desktop.ui.Nav
import okio.Path.Companion.toOkioPath
import java.io.File

fun main() {
    AppState.init()
    SingletonImageLoader.setSafe { ctx ->
        ImageLoader.Builder(ctx)
            .memoryCache { MemoryCache.Builder().maxSizePercent(ctx, 0.25).build() }
            .diskCache { DiskCache.Builder().directory(File(System.getProperty("user.home"), ".huefin/images").toOkioPath()).maxSizeBytes(300L * 1024 * 1024).build() }
            .crossfade(true)
            .build()
    }
    application {
        val state = rememberWindowState(size = DpSize(1360.dp, 860.dp), position = WindowPosition.PlatformDefault)
        Nav.window = state
        Window(onCloseRequest = { Nav.player?.close(); exitApplication() }, state = state, title = "Huefin",
            icon = painterResource("huefin.png"),
            onPreviewKeyEvent = { e ->
                if (e.type != KeyEventType.KeyDown) return@Window false
                val p = Nav.player
                when {
                    p != null -> Nav.playerKey(e.key)
                    e.key == Key.Escape && Nav.canGoBack -> { Nav.back(); true }
                    else -> false
                }
            }) {
            window.minimumSize = java.awt.Dimension(900, 600)
            HuefinRoot()
        }
    }
}
