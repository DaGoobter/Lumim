package com.huefin.desktop.ui

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

    val night = Color(0xFF0E0D14)
    val card = Color(0xFF191724)
    val ink = Color(0xFF14111F)
    val paper = Color(0xFFFFF8EE)
    val hairline = Color.White.copy(alpha = 0.09f)
    val secondaryText = Color(0xFFA9A4BA)

    val home = coral; val library = sky; val live = amber; val downloads = mint; val search = violet

    val spectrum = Brush.horizontalGradient(listOf(coral, amber, sun, mint, sky, violet))
    val gradient = Brush.linearGradient(listOf(sky, violet, coral))
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

@Composable
fun HuefinTheme(content: @Composable () -> Unit) {
    val scheme = darkColorScheme(
        primary = Hue.coral, onPrimary = Hue.ink, secondary = Hue.coral,
        background = Hue.night, surface = Hue.night, surfaceVariant = Hue.card, surfaceContainer = Hue.card,
        surfaceContainerHigh = Color(0xFF221F2F), onSurface = Color(0xFFF5F3FA), onSurfaceVariant = Hue.secondaryText,
        outline = Hue.hairline,
    )
    MaterialTheme(colorScheme = scheme, typography = windowsTypography()) {
        Surface(color = Hue.night, contentColor = Color(0xFFF5F3FA)) { content() }
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
        Box(Modifier.matchParentSize().offset(3.dp, 3.dp).background(hue.copy(alpha = if (enabled) 0.55f else 0.2f), ButtonShape))
        Row(
            Modifier
                .offset(if (pressed) 2.dp else 0.dp, if (pressed) 2.dp else 0.dp)
                .background(if (enabled) bg else bg.copy(alpha = 0.4f), ButtonShape)
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
            .background(Hue.card, ButtonShape)
            .border(1.5.dp, Hue.hairline, ButtonShape)
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

/** Windows' own UI font (Segoe UI), so text is as crisp as the rest of the system. */
@OptIn(androidx.compose.ui.text.ExperimentalTextApi::class)
private val Segoe = androidx.compose.ui.text.font.FontFamily(
    listOf(FontWeight.Light, FontWeight.Normal, FontWeight.Medium, FontWeight.SemiBold, FontWeight.Bold, FontWeight.ExtraBold, FontWeight.Black).map {
        androidx.compose.ui.text.platform.SystemFont("Segoe UI", it)
    })

@Composable
private fun windowsTypography(): androidx.compose.material3.Typography {
    val t = androidx.compose.material3.Typography()
    fun f(s: androidx.compose.ui.text.TextStyle) = s.copy(fontFamily = Segoe)
    return t.copy(displayLarge = f(t.displayLarge), displayMedium = f(t.displayMedium), displaySmall = f(t.displaySmall),
        headlineLarge = f(t.headlineLarge), headlineMedium = f(t.headlineMedium), headlineSmall = f(t.headlineSmall),
        titleLarge = f(t.titleLarge), titleMedium = f(t.titleMedium), titleSmall = f(t.titleSmall),
        bodyLarge = f(t.bodyLarge), bodyMedium = f(t.bodyMedium), bodySmall = f(t.bodySmall),
        labelLarge = f(t.labelLarge), labelMedium = f(t.labelMedium), labelSmall = f(t.labelSmall))
}
