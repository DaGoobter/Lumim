package com.huefin.app.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.UnfoldMore
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.navigation.NavHostController

/** A settings-style page: a tinted background and a centered column that stays readable on unfolded screens. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FormScreen(title: String, nav: NavHostController?, actions: @Composable RowScope.() -> Unit = {}, content: LazyListScope.() -> Unit) {
    Scaffold(containerColor = Color.Transparent, topBar = { HuefinTopBar(title, nav, actions) }) { pad ->
        LazyColumn(Modifier.fillMaxSize().background(Brush.verticalGradient(listOf(LocalHue.current.copy(alpha = 0.16f), Hue.night, Hue.night))),
            contentPadding = PaddingValues(16.dp, pad.calculateTopPadding(), 16.dp, 32.dp), horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(6.dp), content = content)
    }
}

@Composable
fun FormSection(title: String? = null, footer: String? = null, content: @Composable ColumnScope.() -> Unit) {
    Column(Modifier.widthIn(max = 720.dp).fillMaxWidth().padding(top = 14.dp)) {
        title?.let { Eyebrow(it, Hue.secondaryText); Spacer(Modifier.height(8.dp)) }
        Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(18.dp)).background(Hue.card), content = content)
        footer?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = Hue.secondaryText, modifier = Modifier.padding(horizontal = 6.dp, vertical = 8.dp)) }
    }
}

@Composable
fun FormRow(title: String, subtitle: String? = null, icon: ImageVector? = null, iconTint: Color = LocalHue.current, value: String? = null,
            chevron: Boolean = false, titleColor: Color = Color.Unspecified, onClick: (() -> Unit)? = null, trailing: @Composable (() -> Unit)? = null) {
    Row(Modifier.fillMaxWidth().then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier).heightIn(min = 52.dp).padding(horizontal = 16.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically) {
        icon?.let { Box(Modifier.size(32.dp).clip(RoundedCornerShape(9.dp)).background(iconTint), Alignment.Center) { Icon(it, null, Modifier.size(18.dp), tint = Hue.ink) }; Spacer(Modifier.width(12.dp)) }
        Column(Modifier.weight(1f)) {
            Text(title, fontWeight = FontWeight.Medium, color = titleColor)
            subtitle?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = Hue.secondaryText) }
        }
        value?.let { Text(it, color = Hue.secondaryText, style = MaterialTheme.typography.bodyMedium) }
        trailing?.invoke()
        if (chevron) Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null, tint = Hue.secondaryText)
    }
}

@Composable
fun FormToggle(title: String, checked: Boolean, subtitle: String? = null, enabled: Boolean = true, onChange: (Boolean) -> Unit) {
    FormRow(title, subtitle, onClick = if (enabled) ({ onChange(!checked) }) else null) {
        Switch(checked, onChange, enabled = enabled, colors = SwitchDefaults.colors(checkedTrackColor = LocalHue.current, checkedThumbColor = Hue.ink))
    }
}

/** A row that opens a menu of choices. */
@Composable
fun <T> FormPicker(title: String, selected: T, options: List<Pair<T, String>>, onPick: (T) -> Unit) {
    var open by remember { mutableStateOf(false) }
    Box {
        FormRow(title, value = options.firstOrNull { it.first == selected }?.second ?: "", onClick = { open = true }) {
            Icon(Icons.Filled.UnfoldMore, null, Modifier.padding(start = 4.dp).size(18.dp), tint = Hue.secondaryText)
        }
        DropdownMenu(open, { open = false }, Modifier.align(Alignment.CenterEnd)) {
            options.forEach { (v, label) -> DropdownMenuItem({ Text((if (v == selected) "✓  " else "    ") + label) }, { onPick(v); open = false }) }
        }
    }
}

@Composable
fun FormDivider() = HorizontalDivider(Modifier.padding(start = 16.dp), color = Hue.hairline)

@Composable
fun FormField(label: String, value: String, onChange: (String) -> Unit, placeholder: String = "", password: Boolean = false) {
    Column(Modifier.padding(horizontal = 16.dp, vertical = 8.dp)) {
        Text(label, style = MaterialTheme.typography.labelMedium, color = Hue.secondaryText)
        OutlinedTextField(value, onChange, Modifier.fillMaxWidth(), placeholder = { Text(placeholder) }, singleLine = true, shape = RoundedCornerShape(12.dp),
            visualTransformation = if (password) androidx.compose.ui.text.input.PasswordVisualTransformation() else androidx.compose.ui.text.input.VisualTransformation.None)
    }
}
