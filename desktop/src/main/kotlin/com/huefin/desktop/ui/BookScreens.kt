package com.huefin.desktop.ui

import androidx.compose.foundation.Image
import androidx.compose.foundation.clickable
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.toComposeImageBitmap
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.fromHtml
import androidx.compose.foundation.text.selection.SelectionContainer
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
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.huefin.desktop.HuefinApp
import com.huefin.desktop.core.AppState
import com.huefin.desktop.core.BaseItem
import com.huefin.desktop.core.Prefs
import com.huefin.desktop.downloads.DownloadManager
import com.huefin.desktop.player.AudioPlayer
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
                            DesktopDownloadButton(b)
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
    if (reading && f != null) run {
        Surface(Modifier.fillMaxSize(), color = Color(0xFF0D0D12)) {
            BookReader(b, f, onClose = { reading = false }) { scope.launch { runCatching { AppState.client?.markPlayed(b.id) } } }
        }
    }
}

private fun listen(ctx: Any?, book: BaseItem) {
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
    val doc = remember(file) { runCatching { org.apache.pdfbox.Loader.loadPDF(file) }.getOrNull() }
    DisposableEffect(doc) { onDispose { runCatching { doc?.close() } } }
    if (doc == null) { Text("This PDF couldn't be opened.", Modifier.padding(24.dp)); return }
    val renderer = remember(doc) { org.apache.pdfbox.rendering.PDFRenderer(doc) }
    val count = doc.numberOfPages
    val state = rememberLazyListState(ReadingPosition.index(book.id).coerceIn(0, (count - 1).coerceAtLeast(0)))
    LaunchedEffect(state.firstVisibleItemIndex) {
        ReadingPosition.set(book.id, state.firstVisibleItemIndex)
        if (state.firstVisibleItemIndex >= count - 1) onFinished()
    }
    LazyColumn(state = state, modifier = Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(10.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        items(count) { i ->
            var bmp by remember { mutableStateOf<ImageBitmap?>(null) }
            LaunchedEffect(i) { bmp = withContext(Dispatchers.IO) { synchronized(renderer) { runCatching { renderer.renderImageWithDPI(i, 130f).toComposeImageBitmap() }.getOrNull() } } }
            bmp?.let { Image(it, "Page ${i + 1}", Modifier.widthIn(max = 1000.dp).fillMaxWidth(), contentScale = ContentScale.FillWidth) }
                ?: Box(Modifier.widthIn(max = 1000.dp).fillMaxWidth().aspectRatio(0.7f).background(Hue.card))
        }
    }
}

@Composable
private fun ComicReader(book: BaseItem, file: File, onFinished: () -> Unit) {
    val pages = remember(file) { runCatching { ZipFile(file).use { z -> z.entries().toList().filter { !it.isDirectory && it.name.substringAfterLast('.').lowercase() in setOf("jpg", "jpeg", "png", "webp", "gif") }.map { it.name }.sorted() } }.getOrDefault(emptyList()) }
    if (pages.isEmpty()) { Text("No pages found in this comic.", Modifier.padding(24.dp)); return }
    var page by remember { mutableIntStateOf(ReadingPosition.index(book.id).coerceIn(0, pages.size - 1)) }
    LaunchedEffect(page) { ReadingPosition.set(book.id, page); if (page == pages.size - 1) onFinished() }
    var bmp by remember { mutableStateOf<ImageBitmap?>(null) }
    LaunchedEffect(page) { bmp = withContext(Dispatchers.IO) { runCatching { ZipFile(file).use { z -> org.jetbrains.skia.Image.makeFromEncoded(z.getInputStream(z.getEntry(pages[page])).readBytes()).toComposeImageBitmap() } }.getOrNull() } }
    Box(Modifier.fillMaxSize()) {
        bmp?.let { Image(it, "Page ${page + 1}", Modifier.fillMaxSize(), contentScale = ContentScale.Fit) } ?: CircularProgressIndicator(Modifier.align(Alignment.Center))
        Row(Modifier.fillMaxSize()) {
            Box(Modifier.weight(1f).fillMaxHeight().clickable { if (page > 0) page-- })
            Box(Modifier.weight(1f).fillMaxHeight().clickable { if (page < pages.size - 1) page++ })
        }
        Text("${page + 1} / ${pages.size} · click the left or right side to turn", Modifier.align(Alignment.BottomCenter).padding(12.dp).clip(RoundedCornerShape(50)).background(Hue.ink.copy(alpha = 0.8f)).padding(horizontal = 12.dp, vertical = 6.dp),
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

@Composable
private fun EpubReader(book: BaseItem, file: File, onFinished: () -> Unit) {
    var chapters by remember { mutableStateOf<List<File>>(emptyList()) }
    var error by remember { mutableStateOf<String?>(null) }
    var index by remember { mutableIntStateOf(0) }
    var font by remember { mutableFloatStateOf(Prefs.sp.getFloat("reader.fontScale", 1f)) }
    var text by remember { mutableStateOf<AnnotatedString?>(null) }
    val scroll = rememberScrollState()
    LaunchedEffect(file) {
        runCatching { withContext(Dispatchers.IO) { val d = File(HuefinApp.instance.cacheDir, "epub/${book.id}"); unzipTo(file, d); epubChapters(d) } }
            .onSuccess { if (it.isEmpty()) error = "No chapters found." else { chapters = it; index = ReadingPosition.index(book.id).coerceIn(0, it.size - 1) } }
            .onFailure { error = "This EPUB couldn't be read (${it.message})." }
    }
    LaunchedEffect(chapters, index) {
        val f = chapters.getOrNull(index) ?: return@LaunchedEffect
        text = withContext(Dispatchers.IO) {
            val raw = runCatching { f.readText() }.getOrDefault("")
            val body = raw.substringAfter("<body", raw).substringAfter(">").substringBeforeLast("</body>")
                .replace(Regex("<img[^>]*>|<image[^>]*>|<svg[\\s\\S]*?</svg>", RegexOption.IGNORE_CASE), "")
            runCatching { AnnotatedString.fromHtml(body) }.getOrElse { AnnotatedString(body.replace(Regex("<[^>]+>"), " ")) }
        }
        val saved = ReadingPosition.fraction(book.id)
        kotlinx.coroutines.delay(50)
        scroll.scrollTo(if (index == ReadingPosition.index(book.id) && saved > 0) (scroll.maxValue * saved).toInt() else 0)
    }
    LaunchedEffect(scroll.value) { if (scroll.maxValue > 0) ReadingPosition.set(book.id, index, scroll.value.toFloat() / scroll.maxValue) }
    error?.let { Text(it, Modifier.padding(24.dp)); return }
    if (chapters.isEmpty()) { Box(Modifier.fillMaxSize(), Alignment.Center) { CircularProgressIndicator() }; return }
    fun go(i: Int) { if (i in chapters.indices) { index = i; ReadingPosition.set(book.id, i); if (i == chapters.size - 1) onFinished() } }
    Column(Modifier.fillMaxSize()) {
        Box(Modifier.weight(1f).fillMaxWidth().verticalScroll(scroll), contentAlignment = Alignment.TopCenter) {
            SelectionContainer {
                Text(text ?: AnnotatedString(""), Modifier.widthIn(max = 760.dp).padding(horizontal = 28.dp, vertical = 24.dp),
                    fontSize = (17 * font).sp, lineHeight = (17 * font * 1.65f).sp, fontFamily = androidx.compose.ui.text.font.FontFamily.Serif, color = Color(0xFFE9E7EF))
            }
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
