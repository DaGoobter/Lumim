package com.huefin.app.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.WifiOff
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil.compose.AsyncImage
import com.huefin.app.core.AppState
import com.huefin.app.core.BaseItem

/** Window width class: compact (phones, Flip/Razr outer screens), medium (unfolded Flip, small tablets), expanded (Fold inner screens). */
enum class WidthClass { Compact, Medium, Expanded }
val LocalWidthClass = compositionLocalOf { WidthClass.Compact }

@Composable
fun cardScale(): Float = when (LocalWidthClass.current) { WidthClass.Compact -> 1f; WidthClass.Medium -> 1.15f; WidthClass.Expanded -> 1.3f }

@Composable
fun RemoteImage(url: String?, modifier: Modifier = Modifier, contentScale: ContentScale = ContentScale.Crop) {
    Box(modifier.background(Color.White.copy(alpha = 0.06f))) {
        if (url != null) AsyncImage(model = url, contentDescription = null, contentScale = contentScale, modifier = Modifier.fillMaxSize())
    }
}

@Composable
fun ProgressBar(value: Double, modifier: Modifier = Modifier, height: Dp = 4.dp) {
    Box(modifier.height(height).clip(CircleShape).background(Color.White.copy(alpha = 0.18f))) {
        Box(Modifier.fillMaxHeight().fillMaxWidth(value.toFloat().coerceIn(0f, 1f)).clip(CircleShape).background(Hue.spectrum))
    }
}

private val CardShape = RoundedCornerShape(16.dp)

@Composable
fun WatchedBadge(item: BaseItem, modifier: Modifier = Modifier) {
    val hue = LocalHue.current
    val played = item.userData?.played == true
    val unplayed = item.userData?.unplayedItemCount ?: 0
    if (played) Icon(Icons.Filled.CheckCircle, "Watched", tint = hue, modifier = modifier.padding(6.dp).size(20.dp).background(Hue.ink, CircleShape))
    else if (unplayed > 0) Text("$unplayed", fontSize = 11.sp, fontWeight = FontWeight.Bold, color = Hue.ink,
        modifier = modifier.padding(6.dp).background(hue, CircleShape).padding(horizontal = 7.dp, vertical = 2.dp))
}

@Composable
fun PosterCard(item: BaseItem, onClick: () -> Unit, width: Dp = 120.dp) {
    val c = AppState.client
    val w = width * cardScale()
    Column(Modifier.width(w).clickable(onClick = onClick), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Box(Modifier.fillMaxWidth().aspectRatio(2f / 3f).clip(CardShape).border(1.dp, Hue.hairline, CardShape)) {
            RemoteImage(c?.posterURL(item, 400), Modifier.fillMaxSize())
            WatchedBadge(item, Modifier.align(Alignment.TopEnd))
            item.progress?.let { ProgressBar(it, Modifier.align(Alignment.BottomCenter).fillMaxWidth().padding(8.dp)) }
        }
        Text(item.displayTitle, style = MaterialTheme.typography.bodySmall, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
        item.productionYear?.let { Text("$it", style = MaterialTheme.typography.labelSmall, color = Hue.secondaryText) }
    }
}

@Composable
fun LandscapeCard(item: BaseItem, onClick: () -> Unit, width: Dp = 240.dp, subtitle: String? = null) {
    val c = AppState.client
    val w = width * cardScale()
    Column(Modifier.width(w).clickable(onClick = onClick), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Box(Modifier.fillMaxWidth().aspectRatio(16f / 9f).clip(CardShape).border(1.dp, Hue.hairline, CardShape)) {
            RemoteImage(c?.landscapeURL(item), Modifier.fillMaxSize())
            item.progress?.let { ProgressBar(it, Modifier.align(Alignment.BottomCenter).fillMaxWidth().padding(10.dp)) }
        }
        Text(item.displayTitle, style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
        (subtitle ?: item.episodeLabel ?: item.productionYear?.toString())?.let {
            Text(it, style = MaterialTheme.typography.labelSmall, color = Hue.secondaryText, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}

@Composable
fun SquareCard(item: BaseItem, onClick: () -> Unit, width: Dp = 130.dp, circle: Boolean = false) {
    val c = AppState.client
    val w = width * cardScale()
    val shape = if (circle) CircleShape else CardShape
    Column(Modifier.width(w).clickable(onClick = onClick), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Box(Modifier.fillMaxWidth().aspectRatio(1f).clip(shape).border(1.dp, Hue.hairline, shape)) {
            if (item.isLiveChannel) RemoteImage(c?.imageURL(item.id, maxWidth = 300, tag = item.imageTag("Primary")),
                Modifier.fillMaxSize().padding(14.dp), ContentScale.Fit)
            else RemoteImage(c?.albumArtURL(item, 300), Modifier.fillMaxSize())
        }
        Text(item.name ?: "", style = MaterialTheme.typography.bodySmall, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
        Text(item.artistLine ?: item.channelNumber ?: " ", style = MaterialTheme.typography.labelSmall, color = Hue.secondaryText, maxLines = 1)
    }
}

@Composable
fun ShelfTitle(title: String, modifier: Modifier = Modifier) {
    Row(modifier, verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(9.dp)) {
        Box(Modifier.size(10.dp).background(LocalHue.current, RoundedCornerShape(3.dp)))
        Text(title, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
    }
}

@Composable
fun Shelf(title: String, content: LazyListScope.() -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        ShelfTitle(title, Modifier.padding(horizontal = 20.dp))
        LazyRow(contentPadding = PaddingValues(horizontal = 20.dp), horizontalArrangement = Arrangement.spacedBy(14.dp), content = content)
    }
}

@Composable
fun ErrorBanner(message: String, retry: (() -> Unit)? = null) {
    Column(Modifier.fillMaxWidth().padding(16.dp).background(Hue.card, RoundedCornerShape(14.dp)).padding(16.dp),
        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Icon(Icons.Filled.WifiOff, null, Modifier.size(18.dp)); Text(message, style = MaterialTheme.typography.bodySmall)
        }
        if (retry != null) SoftButton(retry) { Text("Try again") }
    }
}

@Composable
fun Chip(text: String, color: Color = Color.White.copy(alpha = 0.12f), textColor: Color = Color.White) {
    Text(text, fontSize = 11.sp, fontWeight = FontWeight.Bold, color = textColor,
        modifier = Modifier.background(color, RoundedCornerShape(8.dp)).padding(horizontal = 8.dp, vertical = 4.dp))
}

@Composable
fun Avatar(name: String, size: Dp = 36.dp, color: Color = LocalHue.current) {
    Box(Modifier.size(size).background(color, CircleShape), contentAlignment = Alignment.Center) {
        Text(name.take(1).uppercase(), color = Hue.ink, fontWeight = FontWeight.ExtraBold, fontSize = (size.value * 0.42f).sp)
    }
}

@Composable
fun VSpace(h: Dp) = Spacer(Modifier.height(h))
