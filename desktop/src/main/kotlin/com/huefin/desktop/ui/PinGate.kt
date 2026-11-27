package com.huefin.desktop.ui

import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import com.huefin.desktop.core.ProfileLock

/** PIN prompts and "choose a PIN". Put once at the root and once inside "Who's watching?". */
@Composable
fun PinGate(inPicker: Boolean) {
    if (inPicker != ProfileLock.pickerOpen) return
    ProfileLock.request?.let { r ->
        PinField(r.title, key = r.account.key, onCancel = { ProfileLock.request = null }) { pin ->
            if (ProfileLock.check(pin, r.account.key)) { ProfileLock.request = null; r.onSuccess(); true } else false
        }
    }
    ProfileLock.setting?.let { a ->
        var first by remember(a.key) { mutableStateOf<String?>(null) }
        val f = first
        PinField(if (f == null) "Choose a 4-digit PIN for ${a.userName}" else "Enter it again", key = a.key + (f ?: ""),
            onCancel = { ProfileLock.setting = null }) { pin ->
            when {
                f == null -> { first = pin; true }
                f == pin -> { ProfileLock.setPIN(pin, a.key); ProfileLock.setting = null; true }
                else -> { first = null; false }
            }
        }
    }
}

@Composable
private fun PinField(title: String, key: String, onCancel: () -> Unit, submit: (String) -> Boolean) {
    var pin by remember(key) { mutableStateOf("") }
    var wrong by remember(key) { mutableStateOf(false) }
    AlertDialog(
        onDismissRequest = onCancel,
        title = { Text(title) },
        text = {
            OutlinedTextField(pin, { v ->
                pin = v.filter(Char::isDigit).take(4); wrong = false
                if (pin.length == 4) { val ok = submit(pin); pin = ""; wrong = !ok }
            }, singleLine = true, isError = wrong,
                label = { Text(if (wrong) "That's not it, try again" else "4-digit PIN") },
                visualTransformation = PasswordVisualTransformation(),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.NumberPassword))
        },
        confirmButton = {},
        dismissButton = { TextButton(onCancel) { Text("Cancel") } })
}
