package com.huefin.desktop.ui

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.toComposeImageBitmap
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.huefin.desktop.core.JellyfinClient
import com.huefin.desktop.core.TrickplayInfo
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.Request
import java.awt.image.BufferedImage
import javax.imageio.ImageIO

/** Scrubbing preview pictures from the server's trickplay images (sheets of small frames, one every few seconds). */
class TrickplayThumbs private constructor(
    private val info: TrickplayInfo, private val sourceId: String, private val itemId: String, private val client: JellyfinClient,
) {
    private val tiles = mutableMapOf<Int, BufferedImage>()

    companion object {
        /** This file's thumbnails, preferring a width that looks sharp; null when the server has none. */
        suspend fun load(client: JellyfinClient, itemId: String): TrickplayThumbs? {
            val extras = runCatching { client.playbackExtras(itemId) }.getOrNull() ?: return null
            val (sid, sizes) = extras.trickplay?.entries?.firstOrNull()?.let { it.key to it.value } ?: return null
            val sorted = sizes.values.sortedBy { it.width ?: 0 }
            val best = sorted.firstOrNull { (it.width ?: 0) >= 320 } ?: sorted.lastOrNull() ?: return null
            return TrickplayThumbs(best, sid, itemId, client)
        }
    }

    /** The thumbnail for a time, cut out of its sheet (sheets are downloaded once and kept). */
    suspend fun thumbnail(ms: Long): ImageBitmap? = withContext(Dispatchers.IO) {
        val width = info.width ?: return@withContext null
        val interval = info.interval?.takeIf { it > 0 } ?: return@withContext null
        val tw = info.tileWidth?.takeIf { it > 0 } ?: return@withContext null
        val th = info.tileHeight?.takeIf { it > 0 } ?: return@withContext null
        val perTile = tw * th
        val frame = (ms / interval).toInt().coerceIn(0, maxOf(0, (info.thumbnailCount ?: Int.MAX_VALUE) - 1))
        val tileIndex = frame / perTile
        val tile = synchronized(tiles) { tiles[tileIndex] } ?: runCatching {
            val req = Request.Builder().url(client.trickplayTileURL(itemId, width, tileIndex, sourceId))
                .header("Authorization", client.authHeader).build()
            JellyfinClient.http.newCall(req).execute().use { r -> r.body?.byteStream()?.let { ImageIO.read(it) } }
        }.getOrNull()?.also { synchronized(tiles) { tiles[tileIndex] = it } } ?: return@withContext null
        val cw = tile.width / tw; val ch = tile.height / th
        val inTile = frame % perTile
        runCatching { tile.getSubimage((inTile % tw) * cw, (inTile / tw) * ch, cw, ch).toComposeImageBitmap() }.getOrNull()
    }
}

/** The picture and time shown above the progress bar while dragging. */
@Composable
fun TrickplayBubble(image: ImageBitmap?, timeText: String, modifier: Modifier = Modifier) {
    Column(modifier, horizontalAlignment = Alignment.CenterHorizontally) {
        if (image != null) {
            Image(image, null, Modifier.width(240.dp).aspectRatio(16f / 9f).clip(RoundedCornerShape(10.dp)).background(Color.Black)
                .border(1.5.dp, Color.White.copy(alpha = 0.6f), RoundedCornerShape(10.dp)))
            Spacer(Modifier.height(6.dp))
        }
        Text(timeText, Modifier.clip(RoundedCornerShape(50)).background(Color.Black.copy(alpha = 0.7f)).padding(horizontal = 10.dp, vertical = 4.dp),
            color = Color.White, fontWeight = FontWeight.Bold, fontSize = 13.sp)
    }
}
