package com.huefin.desktop.ui

import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.huefin.desktop.core.AppState
import com.huefin.desktop.core.BaseItem

/**
 * The screens shared with the Android app talk to a NavHostController; on Windows it's this small adapter
 * over [Nav], so the same screen code runs on both.
 */
class NavHostController {
    fun navigate(route: String) {
        when {
            route.startsWith("item/") -> Nav.push(Route.Item(route.removePrefix("item/")))
            route.startsWith("library/") -> Nav.push(Route.Item(route.removePrefix("library/")))
            else -> Nav.push(Route.Path(route))
        }
    }
    fun popBackStack(): Boolean { val had = Nav.stack.size > 1; Nav.back(); return had }
    val previousBackStackEntry: Any? get() = if (Nav.stack.size > 1) Unit else null
}

val nav = NavHostController()

fun NavHostController.openItem(item: BaseItem) = Nav.open(item)

/** Android's LocalContext, for shared code that passes a context along (unused on Windows). */
val LocalContext = staticCompositionLocalOf<Any> { Unit }

@Composable
fun HuefinTopBar(title: String, nav: NavHostController?, actions: @Composable RowScope.() -> Unit = {}) = PageHeader(title, actions)

@Composable
fun AccountButton(nav: NavHostController) {
    Box(Modifier.clip(CircleShape).clickable { nav.navigate("settings") }) { Avatar(AppState.session?.userName ?: "?", 36.dp) }
}

@Composable
fun gridColumns(min: Int): GridCells = GridCells.Adaptive(min.dp * 1.3f)

@Composable
fun PosterCardFill(item: BaseItem, onClick: () -> Unit) = PosterCard(item, onClick, androidx.compose.ui.unit.Dp.Unspecified)
