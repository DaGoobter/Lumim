package com.huefin.app.ui

import android.annotation.SuppressLint
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.pdf.PdfRenderer
import android.os.ParcelFileDescriptor
import android.webkit.JavascriptInterface
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.MenuBook
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.navigation.NavHostController
import com.huefin.app.HuefinApp
import com.huefin.app.core.AppState
import com.huefin.app.core.BaseItem
import com.huefin.app.core.Prefs
import com.huefin.app.downloads.DownloadManager
import com.huefin.app.playback.AudioPlayer
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import org.w3c.dom.Element
import java.io.File
import java.util.zip.ZipFile
import javax.xml.parsers.DocumentBuilderFactory

// MARK: Library

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun BooksLibraryScreen(library: BaseItem, nav: NavHostController) {
    val items = remember { mutableStateListOf<BaseItem>() }
    var total by remember { mutableIntStateOf(Int.MAX_VALUE) }
    var loading by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    fun loadMore() {
        val c = AppState.client ?: return
        if (loading || items.size >= total) return
        loading = true
        scope.launch {
            runCatching { c.browse(mapOf("parentId" to library.id, "includeItemTypes" to "Book,AudioBook", "recursive" to "true",
                "sortBy" to "SortName", "startIndex" to items.size.toString(), "limit" to "100")) }
                .onSuccess { items += it.items; total = it.totalRecordCount ?: items.size; error = null }.onFailure { error = it.message; total = items.size }
            loading = false
        }
    }
    LaunchedEffect(library.id) { loadMore() }
    Scaffold(containerColor = Color.Transparent, topBar = { HuefinTopBar(library.name ?: "Books", nav) }) { pad ->
        LazyVerticalGrid(gridColumns(110), Modifier.fillMaxSize().background(Brush.verticalGradient(listOf(Hue.amber.copy(alpha = 0.18f), Hue.night, Hue.night))),
            contentPadding = PaddingValues(16.dp, pad.calculateTopPadding(), 16.dp, 24.dp),
            horizontalArrangement = Arrangement.spacedBy(14.dp), verticalArrangement = Arrangement.spacedBy(18.dp)) {
            error?.let { item(span = { GridItemSpan(maxLineSpan) }) { ErrorBanner(it) } }
            itemsIndexed(items, key = { _, b -> b.id }) { i, b ->
                if (i == items.lastIndex) LaunchedEffect(i) { loadMore() }
                Box {
                    PosterCardFill(b) { nav.navigate("book/${b.id}") }
                    if (b.type == "AudioBook") Icon(Icons.Filled.Headphones, "Audiobook", Modifier.padding(6.dp).clip(CircleShape).background(Hue.gradient).padding(5.dp).size(14.dp))
                }
            }
            if (loading) item(span = { GridItemSpan(maxLineSpan) }) { Box(Modifier.fillMaxWidth().padding(16.dp), Alignment.Center) { CircularProgressIndicator() } }
        }
    }
}

// MARK: Detail

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun BookScreen(id: String, nav: NavHostController) {
    val ctx = LocalContext.current
    var book by remember { mutableStateOf<BaseItem?>(DownloadManager.records[id]?.item) }
    var file by remember { mutableStateOf<File?>(null) }
    var downloading by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var reading by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    LaunchedEffect(id) { runCatching { AppState.client?.item(id) }.getOrNull()?.let { book = it } }
    val b = book ?: return Box(Modifier.fillMaxSize(), Alignment.Center) { CircularProgressIndicator() }
    Scaffold(containerColor = Color.Transparent, topBar = { HuefinTopBar("", nav) }) { pad ->
        LazyColumn(Modifier.fillMaxSize().background(Brush.verticalGradient(listOf(Hue.amber.copy(alpha = 0.22f), Hue.night))),
            contentPadding = PaddingValues(20.dp, pad.calculateTopPadding(), 20.dp, 30.dp), horizontalAlignment = Alignment.CenterHorizontally) {
            item {
                Column(Modifier.widthIn(max = 700.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(14.dp)) {
                    RemoteImage(AppState.client?.posterURL(b, 700), Modifier.width(220.dp).aspectRatio(2f / 3f).clip(RoundedCornerShape(14.dp)))
                    Text(b.name ?: "", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold, textAlign = TextAlign.Center)
                    b.artistLine?.let { Text(it, color = Hue.amber, fontWeight = FontWeight.SemiBold) }
                    Text(listOfNotNull(b.productionYear?.toString(), b.runtimeText).joinToString(" · "), style = MaterialTheme.typography.bodySmall, color = Hue.secondaryText)
                    SectionHue(Hue.amber) {
                        Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                            if (b.type == "AudioBook") PlayButton({ listen(ctx, b) }) { Icon(Icons.Filled.Headphones, null); Text(if (b.progress != null) " Resume" else " Listen") }
                            else PlayButton({
                                if (downloading) return@PlayButton
                                downloading = true
                                scope.launch {
                                    runCatching { fetchBook(b) }.onSuccess { file = it; reading = true; error = null }.onFailure { error = "Couldn't get the book: ${it.message}" }
                                    downloading = false
                                }
                            }) {
                                if (downloading) CircularProgressIndicator(Modifier.size(18.dp), color = Hue.ink, strokeWidth = 2.dp) else Icon(Icons.AutoMirrored.Filled.MenuBook, null)
                                Text(" Read")
                            }
                            DownloadButton(b)
                        }
                    }
                    b.progress?.let { ProgressBar(it, Modifier.width(220.dp)) }
                    error?.let { Text(it, color = Hue.coral, style = MaterialTheme.typography.bodySmall) }
                    b.overview?.let { Text(it, color = Hue.text.copy(alpha = 0.85f), style = MaterialTheme.typography.bodyMedium) }
                }
            }
        }
    }
    val f = file
    if (reading && f != null) Dialog({ reading = false }, DialogProperties(usePlatformDefaultWidth = false)) {
        Surface(Modifier.fillMaxSize(), color = Color(0xFF0D0D12)) {
            BookReader(b, f, onClose = { reading = false }) { scope.launch { runCatching { AppState.client?.markPlayed(b.id) } } }
        }
    }
}

private fun listen(ctx: android.content.Context, book: BaseItem) {
    AppState.scope.launch {
        val c = AppState.client
        var parts = listOf(book)
        // Multi-file audiobooks: queue the other parts in the same folder, in order.
        if (c != null && book.parentId != null) runCatching { c.browse(mapOf("parentId" to book.parentId, "includeItemTypes" to "AudioBook", "sortBy" to "SortName")).items }
            .getOrNull()?.takeIf { it.size > 1 }?.let { parts = it }
        val start = parts.indexOfFirst { it.id == book.id }.coerceAtLeast(0)
        AudioPlayer.play(ctx, parts, start)
        if (book.resumeTicks > 0) AudioPlayer.seek(book.resumeTicks / 10_000)
        AudioPlayer.showNowPlaying = true
    }
}

/** The original file, from Downloads if it's there, otherwise fetched once into the cache. */
private suspend fun fetchBook(book: BaseItem): File = withContext(Dispatchers.IO) {
    DownloadManager.localFile(book.id)?.let { return@withContext it }
    val c = AppState.client ?: throw Exception("Not signed in.")
    val ext = book.path?.substringAfterLast('.', "")?.lowercase()?.takeIf { it.length in 2..5 } ?: "epub"
    val f = File(HuefinApp.instance.cacheDir, "books/${book.id}.$ext")
    if (f.exists() && f.length() > 0) return@withContext f
    f.parentFile?.mkdirs()
    OkHttpClient().newCall(Request.Builder().url(c.originalDownloadURL(book.id)).header("Authorization", c.authHeader).build()).execute().use { r ->
        if (!r.isSuccessful) throw Exception("The server said ${r.code}.")
        f.outputStream().use { out -> r.body!!.byteStream().copyTo(out) }
    }
    f
}

private object ReadingPosition {
    fun index(id: String) = Prefs.int("read.$id.index", 0)
    fun fraction(id: String) = Prefs.sp.getFloat("read.$id.fraction", 0f)
    fun set(id: String, index: Int, fraction: Float = 0f) { Prefs.set("read.$id.index", index); Prefs.set("read.$id.fraction", fraction) }
}

// MARK: Reader

@Composable
private fun BookReader(book: BaseItem, file: File, onClose: () -> Unit, onFinished: () -> Unit) {
    Column(Modifier.fillMaxSize().systemBarsPadding()) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClose) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Close") }
            Text(book.name ?: "", fontWeight = FontWeight.SemiBold, maxLines = 1)
        }
        Box(Modifier.weight(1f)) {
            when (file.extension.lowercase()) {
                "pdf" -> PdfReader(book, file, onFinished)
                "cbz", "zip" -> ComicReader(book, file, onFinished)
                "epub" -> EpubReader(book, file, onFinished)
                else -> Text("This format (.${file.extension}) can't be shown here.", Modifier.padding(24.dp))
            }
        }
    }
}

@Composable
private fun PdfReader(book: BaseItem, file: File, onFinished: () -> Unit) {
    val renderer = remember(file) { runCatching { PdfRenderer(ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)) }.getOrNull() }
    DisposableEffect(renderer) { onDispose { runCatching { renderer?.close() } } }
    if (renderer == null) { Text("This PDF couldn't be opened.", Modifier.padding(24.dp)); return }
    val count = renderer.pageCount
    val state = rememberLazyListState(ReadingPosition.index(book.id).coerceIn(0, (count - 1).coerceAtLeast(0)))
    LaunchedEffect(state.firstVisibleItemIndex) {
        ReadingPosition.set(book.id, state.firstVisibleItemIndex)
        if (state.firstVisibleItemIndex >= count - 1) onFinished()
    }
    BoxWithConstraints {
        val widthPx = constraints.maxWidth
        LazyColumn(state = state, verticalArrangement = Arrangement.spacedBy(8.dp)) {
            items(count) { i ->
                var bmp by remember { mutableStateOf<Bitmap?>(null) }
                LaunchedEffect(i) {
                    bmp = withContext(Dispatchers.IO) {
                        synchronized(renderer) {
                            runCatching {
                                renderer.openPage(i).use { p ->
                                    val w = widthPx.coerceAtMost(2000); val h = (w.toFloat() * p.height / p.width).toInt()
                                    Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888).also { it.eraseColor(android.graphics.Color.WHITE); p.render(it, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY) }
                                }
                            }.getOrNull()
                        }
                    }
                }
                bmp?.let { Image(it.asImageBitmap(), "Page ${i + 1}", Modifier.fillMaxWidth(), contentScale = ContentScale.FillWidth) }
                    ?: Box(Modifier.fillMaxWidth().aspectRatio(0.7f).background(Hue.card))
            }
        }
    }
}

@Composable
private fun ComicReader(book: BaseItem, file: File, onFinished: () -> Unit) {
    val pages = remember(file) { runCatching { ZipFile(file).use { z -> z.entries().toList().filter { !it.isDirectory && it.name.substringAfterLast('.').lowercase() in setOf("jpg", "jpeg", "png", "webp", "gif") }.map { it.name }.sorted() } }.getOrDefault(emptyList()) }
    if (pages.isEmpty()) { Text("No pages found in this comic.", Modifier.padding(24.dp)); return }
    val pager = rememberPagerState(ReadingPosition.index(book.id).coerceIn(0, pages.size - 1)) { pages.size }
    LaunchedEffect(pager.currentPage) { ReadingPosition.set(book.id, pager.currentPage); if (pager.currentPage == pages.size - 1) onFinished() }
    Box {
        HorizontalPager(pager, Modifier.fillMaxSize()) { i ->
            var bmp by remember { mutableStateOf<Bitmap?>(null) }
            LaunchedEffect(i) { bmp = withContext(Dispatchers.IO) { runCatching { ZipFile(file).use { z -> z.getInputStream(z.getEntry(pages[i])).use(BitmapFactory::decodeStream) } }.getOrNull() } }
            var scale by remember { mutableFloatStateOf(1f) }
            var offset by remember { mutableStateOf(androidx.compose.ui.geometry.Offset.Zero) }
            bmp?.let {
                Image(it.asImageBitmap(), "Page ${i + 1}", Modifier.fillMaxSize()
                    .pointerInput(Unit) { detectTransformGestures { _, pan, zoom, _ -> scale = (scale * zoom).coerceIn(1f, 4f); offset = if (scale == 1f) androidx.compose.ui.geometry.Offset.Zero else offset + pan } }
                    .graphicsLayer(scaleX = scale, scaleY = scale, translationX = offset.x, translationY = offset.y), contentScale = ContentScale.Fit)
            } ?: Box(Modifier.fillMaxSize(), Alignment.Center) { CircularProgressIndicator() }
        }
        Text("${pager.currentPage + 1} / ${pages.size}", Modifier.align(Alignment.BottomCenter).padding(12.dp).clip(RoundedCornerShape(50)).background(Hue.ink.copy(alpha = 0.8f)).padding(horizontal = 12.dp, vertical = 6.dp),
            style = MaterialTheme.typography.labelMedium)
    }
}

/** container.xml → OPF → spine order → chapter files. */
private fun epubChapters(dir: File): List<File> {
    val f = DocumentBuilderFactory.newInstance().apply { isNamespaceAware = true }
    val container = f.newDocumentBuilder().parse(File(dir, "META-INF/container.xml"))
    val rootPath = (container.getElementsByTagNameNS("*", "rootfile").item(0) as? Element)?.getAttribute("full-path")?.ifEmpty { null } ?: "content.opf"
    val opfFile = File(dir, rootPath)
    val opf = f.newDocumentBuilder().parse(opfFile)
    val manifest = mutableMapOf<String, String>()
    val items = opf.getElementsByTagNameNS("*", "item")
    for (i in 0 until items.length) (items.item(i) as Element).let { manifest[it.getAttribute("id")] = it.getAttribute("href") }
    val refs = opf.getElementsByTagNameNS("*", "itemref")
    val base = opfFile.parentFile ?: dir
    return (0 until refs.length).mapNotNull { i ->
        val e = refs.item(i) as Element
        if (e.getAttribute("linear") == "no") null else manifest[e.getAttribute("idref")]?.let { File(base, java.net.URLDecoder.decode(it, "UTF-8")) }
    }
}

private fun unzipTo(file: File, dir: File) {
    if (File(dir, ".done").exists()) return
    dir.deleteRecursively(); dir.mkdirs()
    ZipFile(file).use { z ->
        z.entries().asSequence().forEach { e ->
            val out = File(dir, e.name)
            if (!out.canonicalPath.startsWith(dir.canonicalPath)) return@forEach
            if (e.isDirectory) out.mkdirs() else { out.parentFile?.mkdirs(); z.getInputStream(e).use { i -> out.outputStream().use { i.copyTo(it) } } }
        }
    }
    File(dir, ".done").writeText("1")
}

@SuppressLint("SetJavaScriptEnabled")
@Composable
private fun EpubReader(book: BaseItem, file: File, onFinished: () -> Unit) {
    var chapters by remember { mutableStateOf<List<File>>(emptyList()) }
    var error by remember { mutableStateOf<String?>(null) }
    var index by remember { mutableIntStateOf(0) }
    var restore by remember { mutableFloatStateOf(0f) }
    var font by remember { mutableFloatStateOf(Prefs.sp.getFloat("reader.fontScale", 1f)) }
    LaunchedEffect(file) {
        runCatching { withContext(Dispatchers.IO) { val d = File(HuefinApp.instance.cacheDir, "epub/${book.id}"); unzipTo(file, d); epubChapters(d) } }
            .onSuccess { if (it.isEmpty()) error = "No chapters found." else { chapters = it; index = ReadingPosition.index(book.id).coerceIn(0, it.size - 1); restore = ReadingPosition.fraction(book.id) } }
            .onFailure { error = "This EPUB couldn't be read (${it.message})." }
    }
    error?.let { Text(it, Modifier.padding(24.dp)); return }
    if (chapters.isEmpty()) { Box(Modifier.fillMaxSize(), Alignment.Center) { CircularProgressIndicator() }; return }
    val css = "html{background:#0d0d12!important}body{background:#0d0d12!important;color:#e9e7ef!important;line-height:1.65;font-family:Georgia,serif;padding:12px 20px 60px;max-width:42em;margin:0 auto}a{color:#b8a6ff!important}img,svg{max-width:100%!important;height:auto!important}p{text-align:justify;hyphens:auto}"
    fun go(i: Int) { if (i in chapters.indices) { restore = 0f; index = i; ReadingPosition.set(book.id, i); if (i == chapters.size - 1) onFinished() } }
    Column(Modifier.fillMaxSize()) {
        key(index) {
            AndroidView({ ctx -> WebView(ctx).apply {
                setBackgroundColor(android.graphics.Color.rgb(13, 13, 18))
                settings.javaScriptEnabled = true
                settings.allowFileAccess = true
                addJavascriptInterface(object { @JavascriptInterface fun scroll(f: Float) { ReadingPosition.set(book.id, index, f) } }, "huefin")
                webViewClient = object : WebViewClient() {
                    override fun onPageFinished(view: WebView, url: String?) {
                        view.evaluateJavascript("var s=document.createElement('style');s.innerHTML='$css';document.head.appendChild(s);" +
                            "document.body.style.fontSize='${(font * 100).toInt()}%';" +
                            "window.addEventListener('scroll',function(){var h=document.documentElement.scrollHeight-window.innerHeight;huefin.scroll(h>0?window.scrollY/h:0)});" +
                            (if (restore > 0) "setTimeout(function(){window.scrollTo(0,(document.documentElement.scrollHeight-window.innerHeight)*$restore)},150);" else ""), null)
                    }
                }
                loadUrl("file://" + chapters[index].absolutePath)
            } }, Modifier.weight(1f).fillMaxWidth(), update = { it.evaluateJavascript("if(document.body)document.body.style.fontSize='${(font * 100).toInt()}%';", null) })
        }
        Row(Modifier.fillMaxWidth().background(Hue.card).padding(horizontal = 16.dp, vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            IconButton({ go(index - 1) }, enabled = index > 0) { Icon(Icons.Filled.ChevronLeft, "Previous chapter") }
            Spacer(Modifier.weight(1f))
            TextButton({ font = (font - 0.1f).coerceIn(0.7f, 2f); Prefs.set("reader.fontScale", font) }) { Text("A", fontSize = 13.sp, fontWeight = FontWeight.Bold) }
            Text("${index + 1} / ${chapters.size}", style = MaterialTheme.typography.labelMedium, color = Hue.secondaryText)
            TextButton({ font = (font + 0.1f).coerceIn(0.7f, 2f); Prefs.set("reader.fontScale", font) }) { Text("A", fontSize = 20.sp, fontWeight = FontWeight.Bold) }
            Spacer(Modifier.weight(1f))
            IconButton({ go(index + 1) }, enabled = index < chapters.size - 1) { Icon(Icons.Filled.ChevronRight, "Next chapter") }
        }
    }
}
