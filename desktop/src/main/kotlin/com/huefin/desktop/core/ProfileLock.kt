package com.huefin.desktop.core

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import java.security.MessageDigest

/** Optional 4-digit PINs on profiles, kept (hashed) on this device. What each profile may watch is set per user on the server. */
object ProfileLock {
    private fun hash(pin: String, key: String) =
        MessageDigest.getInstance("SHA-256").digest("huefin|$key|$pin".toByteArray()).joinToString("") { "%02x".format(it) }

    fun hasPIN(key: String) = Prefs.string("pin.$key") != null
    fun setPIN(pin: String, key: String) = Prefs.set("pin.$key", hash(pin, key))
    fun removePIN(key: String) = Prefs.set("pin.$key", null)
    fun check(pin: String, key: String) = Prefs.string("pin.$key")?.let { it == hash(pin, key) } ?: true

    /** A PIN prompt on screen: whose PIN, what it says, and what happens when it's right. */
    class Request(val account: StoredSession, val title: String, val onSuccess: () -> Unit)
    var request by mutableStateOf<Request?>(null)
    /** Setting a new PIN for this profile. */
    var setting by mutableStateOf<StoredSession?>(null)
    /** The "Who's watching?" screen is up (prompts show inside it). */
    var pickerOpen by mutableStateOf(false)

    /** Runs the action straight away, or after the profile's PIN when it has one. */
    fun ask(account: StoredSession, title: String = "Enter ${account.userName}'s PIN", onSuccess: () -> Unit) {
        if (hasPIN(account.key)) request = Request(account, title, onSuccess) else onSuccess()
    }

    /** Switch to a profile, asking for its PIN when it has one (the current profile only when [force]). */
    fun open(account: StoredSession, force: Boolean = false, then: () -> Unit = {}) {
        if (force || account.key != AppState.session?.key) ask(account) { AppState.switchTo(account); then() }
        else { AppState.switchTo(account); then() }
    }
}
