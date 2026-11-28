package com.huefin.app.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.foundation.clickable

/** Huefin: six hues on a warm night. Each part of the app owns one hue. */
object Hue {
    val coral = Color(0xFFFF4D6D)
    val amber = Color(0xFFFFA62B)
    val sun = Color(0xFFFFE45C)
    val mint = Color(0xFF3EF0A0)
    val sky = Color(0xFF3DA9FF)
    val violet = Color(0xFF9B5CFF)

    /** The Huefin look (paper, ink outlines, sticker buttons) — or Night, the dark option. */
    var light by mutableStateOf(com.huefin.app.core.Prefs.string("huefin.appearance") != "night")
    fun setLook(night: Boolean) { light = !night; com.huefin.app.core.Prefs.set("huefin.appearance", if (night) "night" else "huefin") }

    val ink = Color(0xFF1B1530)
    val paper = Color(0xFFFFF8EE)
    /** The page background: paper, or warm night. */
    val night get() = if (light) paper else Color(0xFF0E0D14)
    val card get() = if (light) Color.White else Color(0xFF191724)
    val hairline get() = if (light) ink.copy(alpha = 0.85f) else Color.White.copy(alpha = 0.09f)
    val secondaryText get() = if (light) Color(0xFF5C5670) else Color(0xFFA9A4BA)
    /** Main text on the page. */
    val text get() = if (light) ink else Color(0xFFF5F3FA)
    /** Quiet fills behind rows and chips. */
    val wash get() = if (light) ink.copy(alpha = 0.06f) else Color.White.copy(alpha = 0.07f)

    val home = coral; val library = sky; val live = amber; val downloads = mint; val search = violet

    val spectrum = Brush.horizontalGradient(listOf(coral, amber, sun, mint, sky, violet))
    val gradient = Brush.linearGradient(listOf(sky, violet, coral))
}

/** Night's colours, for screens that always stay dark (the video player). */
object HueNight {
    val night = Color(0xFF0E0D14)
    val card = Color(0xFF191724)
    val hairline = Color.White.copy(alpha = 0.09f)
    val secondaryText = Color(0xFFA9A4BA)
    val text = Color(0xFFF5F3FA)
    val wash = Color.White.copy(alpha = 0.07f)
}

/** The hue of the section you're in. */
val LocalHue = compositionLocalOf { Hue.coral }

@Composable
fun SectionHue(color: Color, content: @Composable () -> Unit) {
    CompositionLocalProvider(LocalHue provides color) {
        MaterialTheme(colorScheme = MaterialTheme.colorScheme.copy(primary = color, secondary = color), typography = MaterialTheme.typography) {
            content()
        }
    }
}

/** [dark] keeps a screen dark whatever the look (the video player). */
@Composable
fun HuefinTheme(dark: Boolean = false, content: @Composable () -> Unit) {
    val scheme = if (Hue.light && !dark) lightColorScheme(
        primary = Hue.coral, onPrimary = Hue.ink, secondary = Hue.coral,
        background = Hue.night, surface = Hue.night, surfaceVariant = Hue.card, surfaceContainer = Hue.card,
        surfaceContainerHigh = Color(0xFFF3EADB), onSurface = Hue.ink, onSurfaceVariant = Hue.secondaryText,
        onBackground = Hue.ink, outline = Hue.hairline,
    ) else darkColorScheme(
        primary = Hue.coral, onPrimary = Hue.ink, secondary = Hue.coral,
        background = Hue.night, surface = Hue.night, surfaceVariant = Hue.card, surfaceContainer = Hue.card,
        surfaceContainerHigh = Color(0xFF221F2F), onSurface = Color(0xFFF5F3FA), onSurfaceVariant = Hue.secondaryText,
        outline = Hue.hairline,
    )
    val context = androidx.compose.ui.platform.LocalContext.current
    val view = androidx.compose.ui.platform.LocalView.current
    val lightBars = Hue.light && !dark
    androidx.compose.runtime.SideEffect {
        (view.context as? android.app.Activity)?.window?.let { w ->
            androidx.core.view.WindowCompat.getInsetsController(w, view).apply {
                isAppearanceLightStatusBars = lightBars; isAppearanceLightNavigationBars = lightBars
            }
        }
    }
    val typography = remember { huefinTypography(context.assets) }
    MaterialTheme(colorScheme = scheme, typography = typography) {
        Surface(color = if (dark) HueNight.night else Hue.night, contentColor = if (dark) HueNight.text else Hue.text) { content() }
    }
}

private val ButtonShape = RoundedCornerShape(16.dp)

/** Filled with the section's hue, dark text, a small hard shadow in the hue. Huefin's signature button. */
@Composable
fun HueButton(
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    fill: Color? = null,
    enabled: Boolean = true,
    content: @Composable RowScope.() -> Unit,
) {
    val hue = LocalHue.current
    val interaction = remember { MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()
    val bg = fill ?: hue
    Box(modifier.defaultMinSize(minHeight = 48.dp)) {
        val shadow = if (Hue.light) Hue.ink.copy(alpha = if (enabled) 0.9f else 0.3f) else hue.copy(alpha = if (enabled) 0.55f else 0.2f)
        Box(Modifier.matchParentSize().offset(if (Hue.light) 2.dp else 3.dp, if (Hue.light) 2.dp else 3.dp).background(shadow, ButtonShape))
        Row(
            Modifier
                .offset(if (pressed) 2.dp else 0.dp, if (pressed) 2.dp else 0.dp)
                .background(if (enabled) bg else bg.copy(alpha = 0.4f), ButtonShape)
                .then(if (Hue.light) Modifier.border(1.75.dp, Hue.ink.copy(alpha = 0.9f), ButtonShape) else Modifier)
                .clickable(interaction, null, enabled = enabled, role = Role.Button, onClick = onClick)
                .padding(horizontal = 22.dp, vertical = 13.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            CompositionLocalProvider(androidx.compose.material3.LocalContentColor provides Hue.ink) {
                androidx.compose.material3.ProvideTextStyle(MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold)) { content() }
            }
        }
    }
}

@Composable
fun PlayButton(onClick: () -> Unit, modifier: Modifier = Modifier, content: @Composable RowScope.() -> Unit) =
    HueButton(onClick, modifier, fill = Hue.paper, content = content)

@Composable
fun SoftButton(onClick: () -> Unit, modifier: Modifier = Modifier, enabled: Boolean = true,
               padding: PaddingValues = PaddingValues(horizontal = 18.dp, vertical = 12.dp),
               content: @Composable RowScope.() -> Unit) {
    Row(
        modifier
            .defaultMinSize(minHeight = 48.dp)
            .sticker(16.dp, 2.dp)
            .background(Hue.card, ButtonShape)
            .border(if (Hue.light) 1.75.dp else 1.5.dp, if (Hue.light) Hue.ink.copy(alpha = 0.9f) else Hue.hairline, ButtonShape)
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
            .padding(padding),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        androidx.compose.material3.ProvideTextStyle(MaterialTheme.typography.titleSmall.copy(fontWeight = FontWeight.SemiBold)) { content() }
    }
}

@Composable
fun Eyebrow(text: String, color: Color = LocalHue.current) =
    Text(text.uppercase(), color = color, fontSize = 12.sp, fontWeight = FontWeight.ExtraBold, letterSpacing = 1.4.sp)


/** The Huefin look's button: a small, crisp ink offset under it (pair it with a fine ink border). Nothing at night. */
fun Modifier.sticker(radius: androidx.compose.ui.unit.Dp = 16.dp, depth: androidx.compose.ui.unit.Dp = 2.dp, outline: Boolean = false): Modifier =
    if (!Hue.light) this else this
        .drawBehind {
            drawRoundRect(Hue.ink.copy(alpha = 0.9f), topLeft = androidx.compose.ui.geometry.Offset(depth.toPx(), depth.toPx()), size = size,
                cornerRadius = androidx.compose.ui.geometry.CornerRadius(radius.toPx()))
        }
        .then(if (outline) Modifier.border(1.75.dp, Hue.ink.copy(alpha = 0.9f), RoundedCornerShape(radius)) else Modifier)

/** Cards and posters on the Huefin look: a fine ink line and a soft shadow. At night: the faint hairline. */
fun Modifier.outlined(radius: androidx.compose.ui.unit.Dp = 16.dp, line: androidx.compose.ui.unit.Dp = 1.5.dp): Modifier {
    val shape = RoundedCornerShape(radius)
    return if (!Hue.light) this.clip(shape).border(1.dp, Hue.hairline, shape)
    else this.shadow(10.dp, shape, ambientColor = Hue.ink.copy(alpha = 0.25f), spotColor = Hue.ink.copy(alpha = 0.25f))
        .clip(shape).border(line, Hue.ink.copy(alpha = 0.9f), shape)
}
