package com.huefin.app.downloads

import android.app.Notification
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.StatFs
import androidx.compose.runtime.mutableStateMapOf
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.huefin.app.MainActivity
import com.huefin.app.R
import com.huefin.app.core.BaseItem
import com.huefin.app.core.JellyfinClient
import com.huefin.app.core.JellyfinJson
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.TimeUnit

enum class DownloadState { Queued, Downloading, Paused, Completed, Failed }

@Serializable
data class DownloadRecord(
    val itemId: String,
    val item: BaseItem,
    val state: DownloadState = DownloadState.Queued,
    val progress: Float = 0f,
    val localPath: String? = null,
    val sizeBytes: Long? = null,
    val errorText: String? = null,
    val queuedAt: Long = System.currentTimeMillis(),
    /** Watch position from offline viewing, waiting to be sent to the server. */
    val positionTicks: Long? = null,
    val localPlayed: Boolean = false,
    val needsSync: Boolean = false,
) {
    val groupTitle: String get() = when (item.type) {
        "Episode" -> item.seriesName ?: "TV"; "Audio" -> item.album ?: "Music"; "AudioBook" -> "Audiobooks"; "Book" -> "Books"; else -> "Movies"
    }
}

@Serializable data class SmartRule(val seriesId: String, val name: String, val count: Int)

/**
 * Full-quality downloads: always the original file, byte for byte (Huefin's engine plays any format offline).
 * Two at a time, resumable, with a progress notification. Offline watch progress syncs back when online.
 */
object DownloadManager {
    private const val MAX_CONCURRENT = 2
    val records = mutableStateMapOf<String, DownloadRecord>()
    val smartRules = mutableStateMapOf<String, SmartRule>()
    private lateinit var app: Context
    private var client: JellyfinClient? = null
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val jobs = mutableMapOf<String, Job>()
    private var lastSmartRun = 0L
    private var smartRunning = false
    private var syncing = false
    private val http = OkHttpClient.Builder().readTimeout(60, TimeUnit.SECONDS).build()

    private val dir get() = File(app.getExternalFilesDir(null) ?: app.filesDir, "Downloads").apply { mkdirs() }
    private val store get() = File(app.filesDir, "downloads.json")

    fun init(context: Context) {
        app = context.applicationContext
        runCatching { JellyfinJson.decodeFromString(ListSerializer(DownloadRecord.serializer()), store.readText()) }.getOrNull()?.forEach {
            // Interrupted by the app closing: queue it again (the partial file resumes).
            records[it.itemId] = if (it.state == DownloadState.Downloading) it.copy(state = DownloadState.Queued) else it
        }
        val sp = app.getSharedPreferences("huefin", Context.MODE_PRIVATE)
        sp.getString("prism.smartRules", null)?.let { s ->
            runCatching { JellyfinJson.decodeFromString(ListSerializer(SmartRule.serializer()), s) }.getOrNull()?.forEach { smartRules[it.seriesId] = it }
        }
    }

    fun attach(c: JellyfinClient) {
        client = c
        pump()
        scope.launch { syncOfflineProgress(); runSmartNow(false) }
    }

    private fun save() {
        val list = records.values.toList()
        scope.launch(Dispatchers.IO) { runCatching { store.writeText(JellyfinJson.encodeToString(ListSerializer(DownloadRecord.serializer()), list)) } }
        DownloadService.refresh(app)
    }

    // MARK: Queue

    fun start(item: BaseItem) {
        val existing = records[item.id]
        if (existing != null && existing.state != DownloadState.Failed) return
        records[item.id] = DownloadRecord(item.id, item)
        save(); pump()
    }

    fun retry(id: String) { records[id]?.let { records.remove(id); start(it.item) } }

    fun pause(id: String) {
        val r = records[id] ?: return
        if (r.state != DownloadState.Downloading && r.state != DownloadState.Queued) return
        jobs.remove(id)?.cancel()
        records[id] = r.copy(state = DownloadState.Paused); save(); pump()
    }

    fun resume(id: String) {
        val r = records[id] ?: return
        if (r.state != DownloadState.Paused) return
        records[id] = r.copy(state = DownloadState.Queued); save(); pump()
    }

    fun delete(id: String) {
        jobs.remove(id)?.cancel()
        records.remove(id)?.let { r -> r.localPath?.let { File(it).delete() }; File(dir, "$id.part").delete() }
        save(); pump()
    }

    fun localFile(id: String): File? = records[id]?.takeIf { it.state == DownloadState.Completed }?.localPath?.let(::File)?.takeIf { it.exists() }

    private fun pump() {
        val c = client ?: return
        val active = records.values.count { it.state == DownloadState.Downloading }
        if (active >= MAX_CONCURRENT) return
        records.values.filter { it.state == DownloadState.Queued }.sortedBy { it.queuedAt }.take(MAX_CONCURRENT - active).forEach { r ->
            records[r.itemId] = r.copy(state = DownloadState.Downloading)
            jobs[r.itemId] = scope.launch { download(r.itemId, c) }
        }
        DownloadService.refresh(app)
    }

    private suspend fun download(id: String, c: JellyfinClient) {
        var rec = records[id] ?: return
        try {
            if (rec.item.mediaSources == null && (rec.item.isPlayable)) runCatching { c.item(id) }.getOrNull()?.let { rec = rec.copy(item = it); records[id] = rec }
            val ext = rec.item.mediaSources?.firstOrNull()?.container?.split(",")?.firstOrNull()?.takeIf { it.isNotBlank() }
                ?: rec.item.path?.substringAfterLast('.', "")?.takeIf { it.length in 2..5 } ?: if (rec.item.isAudio) "mp3" else "mkv"
            val part = File(dir, "$id.part")
            val final = File(dir, "$id.$ext")
            withContext(Dispatchers.IO) {
                var have = if (part.exists()) part.length() else 0L
                val req = Request.Builder().url(c.originalDownloadURL(id)).header("Authorization", c.authHeader)
                    .apply { if (have > 0) header("Range", "bytes=$have-") }.build()
                http.newCall(req).execute().use { resp ->
                    if (!resp.isSuccessful) throw Exception("The server said ${resp.code}.")
                    if (resp.code != 206) have = 0
                    val body = resp.body ?: throw Exception("Empty response.")
                    val total = (body.contentLength().takeIf { it > 0 } ?: 0) + have
                    FileOutputStream(part, have > 0).use { out ->
                        val buf = ByteArray(256 * 1024)
                        val input = body.byteStream()
                        var done = have
                        var lastUi = 0L
                        while (isActive) {
                            val n = input.read(buf); if (n < 0) break
                            out.write(buf, 0, n); done += n
                            val now = System.currentTimeMillis()
                            if (now - lastUi > 500 && total > 0) {
                                lastUi = now
                                val p = done.toFloat() / total
                                withContext(Dispatchers.Main) { records[id]?.let { records[id] = it.copy(progress = p, sizeBytes = total) }; DownloadService.refresh(app) }
                            }
                        }
                    }
                }
                if (!isActive) return@withContext
                final.delete(); part.renameTo(final)
            }
            records[id]?.let { records[id] = it.copy(state = DownloadState.Completed, progress = 1f, localPath = final.absolutePath, errorText = null, sizeBytes = final.length()) }
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            records[id]?.takeIf { it.state == DownloadState.Downloading }?.let { records[id] = it.copy(state = DownloadState.Failed, errorText = e.message) }
        } finally {
            jobs.remove(id)
            save(); pump()
        }
    }

    // MARK: Smart downloads

    fun setSmart(seriesId: String, name: String, count: Int) {
        if (count <= 0) smartRules.remove(seriesId) else smartRules[seriesId] = SmartRule(seriesId, name, count)
        app.getSharedPreferences("huefin", Context.MODE_PRIVATE).edit()
            .putString("prism.smartRules", JellyfinJson.encodeToString(ListSerializer(SmartRule.serializer()), smartRules.values.toList())).apply()
        runSmart(force = true)
    }

    fun runSmart(force: Boolean = false) { scope.launch { runSmartNow(force) } }

    /** Keeps the next unwatched episodes of each smart show on the device and removes ones you've finished. */
    private suspend fun runSmartNow(force: Boolean) {
        val c = client ?: return
        if (smartRules.isEmpty() || smartRunning) return
        if (!force && System.currentTimeMillis() - lastSmartRun < 300_000) return
        smartRunning = true; lastSmartRun = System.currentTimeMillis()
        try {
            for (rule in smartRules.values.toList()) {
                val base = mapOf("parentId" to rule.seriesId, "includeItemTypes" to "Episode", "recursive" to "true",
                    "sortBy" to "ParentIndexNumber,IndexNumber", "sortOrder" to "Ascending")
                val upcoming = runCatching { c.browse(base + mapOf("filters" to "IsUnplayed", "limit" to rule.count.toString())).items }.getOrNull() ?: continue
                val watched = runCatching { c.browse(base + mapOf("filters" to "IsPlayed", "fields" to "ParentId")).items }.getOrNull() ?: continue
                val watchedIds = watched.map { it.id }.toSet()
                records.values.filter { it.item.seriesId == rule.seriesId && it.state == DownloadState.Completed && !it.needsSync &&
                    (it.itemId in watchedIds || it.localPlayed) }.forEach { delete(it.itemId) }
                upcoming.filter { records[it.id] == null }.forEach { start(it) }
            }
        } finally { smartRunning = false }
    }

    // MARK: Offline progress

    fun recordOfflineProgress(id: String, ticks: Long) {
        val r = records[id] ?: return
        val total = r.item.runTimeTicks ?: 0
        records[id] = r.copy(positionTicks = ticks, localPlayed = total > 0 && ticks.toDouble() / total > 0.9, needsSync = true)
        save()
        scope.launch { syncOfflineProgress() }
    }

    private suspend fun syncOfflineProgress() {
        val c = client ?: return
        if (syncing) return
        syncing = true
        try {
            for (r in records.values.filter { it.needsSync }) {
                val ok = c.updateUserData(r.itemId, if (r.localPlayed) 0 else r.positionTicks ?: 0, r.localPlayed)
                if (ok) records[r.itemId]?.let { records[r.itemId] = it.copy(needsSync = false) }
            }
            save()
        } finally { syncing = false }
    }

    // MARK: Storage

    fun storageUsed(): Long = records.values.sumOf { r -> r.localPath?.let { File(it).length() } ?: 0L }
    fun freeSpace(): Long = runCatching { StatFs(dir.path).availableBytes }.getOrDefault(0L)

    val activeCount get() = records.values.count { it.state == DownloadState.Downloading || it.state == DownloadState.Queued }
}

/** Keeps downloads running with the screen off, showing overall progress (Android's version of the Live Activity). */
class DownloadService : Service() {
    companion object {
        private const val ID = 4242
        private var running = false
        fun refresh(context: Context) {
            val active = DownloadManager.activeCount
            if (active > 0 && !running) {
                running = true
                runCatching { androidx.core.content.ContextCompat.startForegroundService(context, Intent(context, DownloadService::class.java)) }
                    .onFailure { running = false }
            } else if (active > 0) {
                runCatching { NotificationManagerCompat.from(context).notify(ID, build(context)) }
            } else if (running) {
                running = false
                context.stopService(Intent(context, DownloadService::class.java))
                if (DownloadManager.records.values.any { it.state == DownloadState.Completed })
                    runCatching { NotificationManagerCompat.from(context).notify(ID + 1, NotificationCompat.Builder(context, "downloads")
                        .setSmallIcon(R.drawable.ic_stat_huefin).setContentTitle("Downloads finished").setContentText("Ready to watch offline.")
                        .setAutoCancel(true).setContentIntent(open(context)).build()) }
            }
        }
        private fun open(context: Context) = PendingIntent.getActivity(context, 1, Intent(context, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        fun build(context: Context): Notification {
            val active = DownloadManager.records.values.filter { it.state == DownloadState.Downloading || it.state == DownloadState.Queued }
            val current = active.firstOrNull { it.state == DownloadState.Downloading }
            val pct = if (active.isEmpty()) 0 else (active.sumOf { it.progress.toDouble() } / active.size * 100).toInt()
            return NotificationCompat.Builder(context, "downloads")
                .setSmallIcon(R.drawable.ic_stat_huefin)
                .setContentTitle(if (active.size == 1) "Downloading ${current?.item?.displayTitle ?: ""}" else "Downloading ${active.size} items")
                .setContentText(current?.let { listOfNotNull(it.item.displayTitle, it.item.episodeLabel).joinToString(" · ") } ?: "Waiting…")
                .setProgress(100, pct, current == null)
                .setOngoing(true).setOnlyAlertOnce(true).setSilent(true)
                .setColor(0xFF3EF0A0.toInt())
                .setContentIntent(open(context))
                .build()
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val n = build(this)
        if (Build.VERSION.SDK_INT >= 29) startForeground(ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC) else startForeground(ID, n)
        if (DownloadManager.activeCount == 0) { stopSelf(); running = false }
        return START_NOT_STICKY
    }
}
