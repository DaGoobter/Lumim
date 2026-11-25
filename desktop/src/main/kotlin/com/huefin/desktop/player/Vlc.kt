package com.huefin.desktop.player

import com.sun.jna.NativeLibrary
import uk.co.caprica.vlcj.binding.support.runtime.RuntimeUtil
import uk.co.caprica.vlcj.factory.MediaPlayerFactory
import uk.co.caprica.vlcj.factory.discovery.NativeDiscovery
import java.io.File

/** VLC (bundled with the app) for music and the DJ's voice. Video plays in the Huefin Engine (mpv, see Mpv.kt). */
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
