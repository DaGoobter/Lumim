package com.huefin.app.playback

import android.app.PendingIntent
import android.content.Intent
import android.net.Uri
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.session.LibraryResult
import androidx.media3.session.MediaLibraryService
import androidx.media3.session.MediaSession
import com.google.common.collect.ImmutableList
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture
import com.google.common.util.concurrent.SettableFuture
import com.huefin.app.MainActivity
import com.huefin.app.core.AppState
import kotlinx.coroutines.launch

/** Background music: notification, lock screen, Bluetooth controls and Android Auto. */
class AudioService : MediaLibraryService() {
    private var session: MediaLibrarySession? = null

    override fun onCreate() {
        super.onCreate()
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java).setAction("com.huefin.app.NOWPLAYING"),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        session = MediaLibrarySession.Builder(this, AudioPlayer.player(this), Callback()).setSessionActivity(open).build()
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo) = session

    override fun onTaskRemoved(rootIntent: Intent?) {
        val p = session?.player
        if (p == null || !p.playWhenReady || p.mediaItemCount == 0) stopSelf()
    }

    override fun onDestroy() {
        session?.run { release() }
        session = null
        super.onDestroy()
    }

    private fun folder(id: String, title: String) = MediaItem.Builder().setMediaId(id).setMediaMetadata(
        MediaMetadata.Builder().setTitle(title).setIsBrowsable(true).setIsPlayable(false)
            .setMediaType(MediaMetadata.MEDIA_TYPE_FOLDER_MIXED).build()).build()

    private fun playable(id: String, title: String, subtitle: String? = null, art: String? = null) = MediaItem.Builder().setMediaId(id)
        .setMediaMetadata(MediaMetadata.Builder().setTitle(title).setArtist(subtitle).setArtworkUri(art?.let(Uri::parse))
            .setIsBrowsable(false).setIsPlayable(true).build()).build()

    private inner class Callback : MediaLibrarySession.Callback {
        override fun onGetLibraryRoot(session: MediaLibrarySession, browser: MediaSession.ControllerInfo, params: LibraryParams?):
            ListenableFuture<LibraryResult<MediaItem>> = Futures.immediateFuture(LibraryResult.ofItem(folder("root", "Huefin"), params))

        override fun onGetChildren(session: MediaLibrarySession, browser: MediaSession.ControllerInfo, parentId: String, page: Int,
                                   pageSize: Int, params: LibraryParams?): ListenableFuture<LibraryResult<ImmutableList<MediaItem>>> {
            val f = SettableFuture.create<LibraryResult<ImmutableList<MediaItem>>>()
            AppState.scope.launch {
                val c = AppState.client
                val items: List<MediaItem> = when {
                    c == null -> emptyList()
                    parentId == "root" -> listOf(folder("stations", "Stations"), folder("albums", "Recently added albums"), folder("playlists", "Playlists"))
                    parentId == "stations" -> listOf("dj" to "Huefin DJ", "heavy" to "Heavy Rotation", "favorites" to "Favorites Mix",
                        "throwbacks" to "Throwbacks", "discover" to "Discover", "shuffle" to "Shuffle All").map { playable("station:${it.first}", it.second) }
                    parentId == "albums" -> runCatching {
                        val lib = c.userViews().firstOrNull { it.collectionType == "music" }?.id
                        c.browse(mapOf("parentId" to lib, "includeItemTypes" to "MusicAlbum", "recursive" to "true",
                            "sortBy" to "DateCreated", "sortOrder" to "Descending", "limit" to "40")).items
                    }.getOrDefault(emptyList()).map { playable("album:${it.id}", it.name ?: "Album", it.artistLine, c.albumArtURL(it, 300)) }
                    parentId == "playlists" -> runCatching {
                        c.browse(mapOf("includeItemTypes" to "Playlist", "recursive" to "true", "sortBy" to "SortName", "mediaTypes" to "Audio")).items
                    }.getOrDefault(emptyList()).map { playable("album:${it.id}", it.name ?: "Playlist", null, c.albumArtURL(it, 300)) }
                    else -> emptyList()
                }
                f.set(LibraryResult.ofItemList(ImmutableList.copyOf(items), params))
            }
            return f
        }

        override fun onSetMediaItems(mediaSession: MediaSession, controller: MediaSession.ControllerInfo, mediaItems: MutableList<MediaItem>,
                                     startIndex: Int, startPositionMs: Long): ListenableFuture<MediaSession.MediaItemsWithStartPosition> {
            val id = mediaItems.firstOrNull()?.mediaId ?: ""
            if (id.startsWith("station:") || id.startsWith("album:")) {
                // Android Auto picked a station or album: build the queue, then hand it to the session.
                val f = SettableFuture.create<MediaSession.MediaItemsWithStartPosition>()
                AppState.scope.launch {
                    val c = AppState.client
                    var entries = emptyList<QueueEntry>(); var station: Station? = null
                    if (c != null) {
                        if (id.startsWith("station:")) {
                            val lib = runCatching { c.userViews().firstOrNull { it.collectionType == "music" }?.id }.getOrNull()
                            station = Stations.byId(id.removePrefix("station:"), lib)
                            entries = station?.let { s -> runCatching { s.refill(c, emptySet()) }.getOrDefault(emptyList()) } ?: emptyList()
                        } else {
                            val pid = id.removePrefix("album:")
                            entries = runCatching { c.albumTracks(pid).ifEmpty { c.playlistItems(pid) } }.getOrDefault(emptyList()).map { QueueEntry(it) }
                        }
                    }
                    f.set(MediaSession.MediaItemsWithStartPosition(AudioPlayer.adopt(this@AudioService, entries, station), 0, 0))
                }
                return f
            }
            return super.onSetMediaItems(mediaSession, controller, mediaItems, startIndex, startPositionMs)
        }
    }
}
