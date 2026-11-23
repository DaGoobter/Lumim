package com.huefin.desktop.player

import com.huefin.desktop.HuefinApp
import com.huefin.desktop.core.Prefs
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.File
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume

/** The DJ's voice: Kokoro on your PC, OpenAI or ElevenLabs (human-sounding), or the phone's own voice. */
object DJVoice {
    enum class Engine(val key: String, val label: String) {
        Kokoro("kokoro", "Kokoro on my PC (free)"), OpenAI("openAI", "OpenAI"), ElevenLabs("elevenLabs", "ElevenLabs"), Phone("iPhone", "Windows voice")
    }
    var engine: Engine
        get() = Engine.entries.firstOrNull { it.key == Prefs.string("dj.engine") } ?: Engine.Phone
        set(v) { Prefs.set("dj.engine", v.key); cache.clear() }
    var kokoroURL: String get() = Prefs.string("dj.kokoroURL") ?: ""; set(v) { Prefs.set("dj.kokoroURL", v); cache.clear() }
    var kokoroRemoteURL: String get() = Prefs.string("dj.kokoroRemoteURL") ?: ""; set(v) { Prefs.set("dj.kokoroRemoteURL", v); cache.clear() }
    var kokoroVoice: String get() = Prefs.string("dj.kokoroVoice") ?: "af_heart"; set(v) { Prefs.set("dj.kokoroVoice", v); cache.clear() }
    var kokoroSpeed: Float get() = Prefs.sp.getFloat("dj.kokoroSpeed", 1.1f); set(v) { Prefs.set("dj.kokoroSpeed", v); cache.clear() }
    var openAIVoice: String get() = Prefs.string("dj.openAIVoice") ?: "coral"; set(v) { Prefs.set("dj.openAIVoice", v); cache.clear() }
    var elevenVoice: String get() = Prefs.string("dj.elevenVoice") ?: "21m00Tcm4TlvDq8Ikz7M"; set(v) { Prefs.set("dj.elevenVoice", v); cache.clear() }
    var openAIKey: String get() = Prefs.string("dj.openAIKey") ?: ""; set(v) { Prefs.set("dj.openAIKey", v); cache.clear() }
    var elevenKey: String get() = Prefs.string("dj.elevenKey") ?: ""; set(v) { Prefs.set("dj.elevenKey", v); cache.clear() }
    var lastError: String? = null; private set

    private val pauseTag = Regex("""\s*\[pause:(\d+(?:\.\d+)?)s]\s*""", RegexOption.IGNORE_CASE)
    fun display(text: String) = pauseTag.replace(text, " ").replace("  ", " ").trim()
    private fun spoken(text: String) = when (engine) {
        Engine.Kokoro -> text
        Engine.ElevenLabs -> pauseTag.replace(text) { " <break time=\"${it.groupValues[1]}s\" /> " }
        Engine.OpenAI -> pauseTag.replace(text) { if ((it.groupValues[1].toDoubleOrNull() ?: 0.0) >= 0.35) " ... " else " " }
        Engine.Phone -> display(text)
    }

    private val cache = ConcurrentHashMap<String, File>()
    private var preferredKokoro: String? = null
    private var player: uk.co.caprica.vlcj.player.base.MediaPlayer? = null
    private var tts: Process? = null

    private fun normalize(raw: String): String {
        var s = raw.trim(); if (s.isEmpty()) return ""
        if (!s.contains("://")) s = "http://$s"
        s = s.trimEnd('/'); if (!s.endsWith("/v1")) s += "/v1"
        return s
    }

    suspend fun prefetch(text: String) { if (engine != Engine.Phone && cache[text] == null) audio(text) }

    private suspend fun audio(text: String): File? = withContext(Dispatchers.IO) {
        cache[text]?.let { return@withContext it }
        val bases: List<String?> = if (engine == Engine.Kokoro) {
            val list = listOf(normalize(kokoroURL), normalize(kokoroRemoteURL)).filter { it.isNotEmpty() }.toMutableList()
            preferredKokoro?.let { p -> if (list.remove(p)) list.add(0, p) }
            list.ifEmpty { listOf("") }
        } else listOf(null)
        for ((i, base) in bases.withIndex()) {
            val req = request(text, base) ?: return@withContext null
            val http = OkHttpClient.Builder().callTimeout(if (i < bases.size - 1) 4 else 15, TimeUnit.SECONDS).build()
            try {
                http.newCall(req).execute().use { r ->
                    val bytes = r.body?.bytes()
                    if (!r.isSuccessful || bytes == null || bytes.size < 500) { lastError = "The voice service answered with an error (${r.code})."; return@use }
                    val f = File.createTempFile("dj", ".mp3", HuefinApp.instance.cacheDir).apply { writeBytes(bytes) }
                    lastError = null
                    if (base != null) preferredKokoro = base
                    cache[text] = f
                    return@withContext f
                }
            } catch (e: Exception) { lastError = e.message }
        }
        null
    }

    private fun request(text: String, kokoroBase: String?): Request? {
        val json = "application/json".toMediaType()
        return when (engine) {
            Engine.Phone -> null
            Engine.Kokoro, Engine.OpenAI -> {
                val base = if (engine == Engine.OpenAI) "https://api.openai.com/v1" else kokoroBase ?: ""
                if (base.isEmpty()) return null
                val b = Request.Builder().url("$base/audio/speech")
                val body = buildJsonObject {
                    put("input", spoken(text)); put("response_format", "mp3")
                    if (engine == Engine.OpenAI) {
                        put("model", "gpt-4o-mini-tts"); put("voice", openAIVoice)
                        put("instructions", "You're a charismatic radio DJ talking to one friend, not reading a script. Loose, warm and playful, with a smile in your voice. Vary your pace: breeze through the chatty bits, then slow down slightly and land the song title and artist like a reveal. Natural breaths, a little laugh where it fits. Never monotone, never announcer-stiff.")
                    } else { put("model", "kokoro"); put("voice", kokoroVoice); put("speed", kokoroSpeed) }
                }
                if (engine == Engine.OpenAI) { if (openAIKey.isEmpty()) { lastError = "Add your OpenAI API key."; return null }; b.header("Authorization", "Bearer $openAIKey") }
                b.post(body.toString().toRequestBody(json)).build()
            }
            Engine.ElevenLabs -> {
                if (elevenKey.isEmpty()) { lastError = "Add your ElevenLabs API key."; return null }
                Request.Builder().url("https://api.elevenlabs.io/v1/text-to-speech/$elevenVoice?output_format=mp3_44100_128").header("xi-api-key", elevenKey)
                    .post(buildJsonObject { put("text", spoken(text)); put("model_id", "eleven_flash_v2_5")
                        put("voice_settings", buildJsonObject { put("stability", 0.4); put("similarity_boost", 0.8); put("style", 0.35) }) }
                        .toString().toRequestBody(json)).build()
            }
        }
    }

    /** Speak, returning when finished. Falls back to Windows' own voice if the service can't be reached. */
    suspend fun say(text: String) {
        val f = if (engine == Engine.Phone) null else audio(text)
        if (f != null) {
            val factory = Vlc.factory() ?: return speakSystem(display(text))
            suspendCancellableCoroutine { cont ->
                val mp = factory.mediaPlayers().newMediaPlayer()
                player = mp
                mp.events().addMediaPlayerEventListener(object : uk.co.caprica.vlcj.player.base.MediaPlayerEventAdapter() {
                    override fun finished(mediaPlayer: uk.co.caprica.vlcj.player.base.MediaPlayer) { done() }
                    override fun error(mediaPlayer: uk.co.caprica.vlcj.player.base.MediaPlayer) { done() }
                    override fun stopped(mediaPlayer: uk.co.caprica.vlcj.player.base.MediaPlayer) { done() }
                    fun done() {
                        if (cont.isActive) cont.resume(Unit)
                        Thread { runCatching { mp.release() } }.start()
                        if (player === mp) player = null
                    }
                })
                if (!mp.media().play(f.absolutePath)) { if (cont.isActive) cont.resume(Unit) }
                cont.invokeOnCancellation { Thread { runCatching { mp.controls().stop() } }.start() }
            }
        } else speakSystem(display(text))
    }

    /** Windows' built-in speech (System.Speech), run through PowerShell. */
    private suspend fun speakSystem(text: String) = withContext(Dispatchers.IO) {
        runCatching {
            val safe = text.replace("'", "''")
            val script = "Add-Type -AssemblyName System.Speech; \$s = New-Object System.Speech.Synthesis.SpeechSynthesizer; \$s.Rate = 1; \$s.Speak('$safe')"
            val proc = ProcessBuilder("powershell", "-NoProfile", "-NonInteractive", "-Command", script).redirectErrorStream(true).start()
            tts = proc
            proc.inputStream.readAllBytes()
            proc.waitFor()
        }
        Unit
    }

    fun stop() {
        val p = player; player = null
        if (p != null) Thread { runCatching { p.controls().stop() } }.start()
        tts?.destroy(); tts = null
    }
}
