package com.huefin.desktop.player

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asComposeImageBitmap
import com.sun.jna.NativeLibrary
import org.jetbrains.skia.Bitmap
import org.jetbrains.skia.ColorAlphaType
import org.jetbrains.skia.ColorType
import org.jetbrains.skia.ImageInfo
import uk.co.caprica.vlcj.binding.support.runtime.RuntimeUtil
import uk.co.caprica.vlcj.factory.MediaPlayerFactory
import uk.co.caprica.vlcj.factory.discovery.NativeDiscovery
import uk.co.caprica.vlcj.player.base.MediaPlayer
import uk.co.caprica.vlcj.player.embedded.EmbeddedMediaPlayer
import uk.co.caprica.vlcj.player.embedded.videosurface.callback.BufferFormat
import uk.co.caprica.vlcj.player.embedded.videosurface.callback.BufferFormatCallback
import uk.co.caprica.vlcj.player.embedded.videosurface.callback.RenderCallback
import uk.co.caprica.vlcj.player.embedded.videosurface.callback.format.RV32BufferFormat
import java.io.File
import java.nio.ByteBuffer

/** The Huefin engine on Windows: VLC (bundled with the app) drawing frames straight into the Compose window. */
object Vlc {
    private var factory: MediaPlayerFactory? = null
    var loadError: String? = null; private set

    fun factory(): MediaPlayerFactory? {
        factory?.let { return it }
        return try {
            // The installer ships VLC next to the app; fall back to an installed VLC if it isn't there.
            val res = System.getProperty("compose.application.resources.dir")
            val bundled = res?.let { File(it, "vlc") }?.takeIf { File(it, if (RuntimeUtil.isWindows()) "libvlc.dll" else "libvlc.so").exists() }
            if (bundled != null) NativeLibrary.addSearchPath(RuntimeUtil.getLibVlcLibraryName(), bundled.absolutePath)
            else NativeDiscovery().discover()
            MediaPlayerFactory("--no-video-title-show", "--quiet", "--network-caching=1500", "--avcodec-hw=any").also { factory = it }
        } catch (t: Throwable) {
            loadError = "Couldn't start the video engine (${t.message}). Reinstall Huefin, or install VLC from videolan.org."
            null
        }
    }
}

/** One video surface: frames arrive on VLC's thread and are shown by [com.huefin.desktop.ui.PlayerScreen]. */
class VideoSurface {
    var frame by mutableIntStateOf(0); private set
    var image by mutableStateOf<ImageBitmap?>(null); private set
    var width = 0; private set
    var height = 0; private set
    private var bitmap: Bitmap? = null
    private var bytes = ByteArray(0)
    val lock = Any()

    fun attach(mp: EmbeddedMediaPlayer, f: MediaPlayerFactory) {
        val format = object : BufferFormatCallback {
            override fun getBufferFormat(sourceWidth: Int, sourceHeight: Int): BufferFormat {
                synchronized(lock) {
                    width = sourceWidth; height = sourceHeight
                    bytes = ByteArray(sourceWidth * sourceHeight * 4)
                    val b = Bitmap()
                    b.allocPixels(ImageInfo(sourceWidth, sourceHeight, ColorType.BGRA_8888, ColorAlphaType.OPAQUE))
                    bitmap = b
                    image = b.asComposeImageBitmap()
                }
                return RV32BufferFormat(sourceWidth, sourceHeight)
            }
            override fun allocatedBuffers(buffers: Array<out ByteBuffer>) {}
        }
        val render = object : RenderCallback {
            override fun display(mediaPlayer: MediaPlayer, nativeBuffers: Array<out ByteBuffer>, bufferFormat: BufferFormat) {
                synchronized(lock) {
                    val b = bitmap ?: return
                    val buf = nativeBuffers[0]
                    buf.rewind()
                    if (buf.remaining() < bytes.size) return
                    buf.get(bytes, 0, bytes.size)
                    b.installPixels(b.imageInfo, bytes, width * 4)
                    b.notifyPixelsChanged()
                }
                frame++
            }
        }
        mp.videoSurface().set(f.videoSurfaces().newVideoSurface(format, render, true))
    }
}
