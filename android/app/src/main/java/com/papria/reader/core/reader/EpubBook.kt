package com.papria.reader.core.reader

import java.io.File
import java.io.InputStream
import java.net.URLDecoder
import java.util.zip.ZipFile

/** A text run whose CFI path points to an XHTML text node. */
data class EpubCfiTextRun(
    val path: String,
    val sourceStart: Int,
    val renderedStart: Int,
    val length: Int,
)

/** The explicit result of resolving a stored EPUB CFI. */
sealed interface EpubCfiResolution {
    data class Resolved(val chapterIndex: Int, val textOffset: Int) : EpubCfiResolution
    data class Unresolved(val cfi: String, val reason: String) : EpubCfiResolution
    data object NotEpubCfi : EpubCfiResolution
}

/** A bounded EPUB/KEPUB spine and navigation reader. */
class EpubBook private constructor(
    private val file: File,
    val title: String,
    val chapters: List<Chapter>,
    val tableOfContents: List<TocItem>,
) {
    /**
     * A spine item contains plain text for the dependency-free renderer and a
     * map of XHTML anchors to text offsets.  Keeping offsets (rather than only
     * chapter/page numbers) lets a locator survive a font-size or margin
     * change and is also useful for EPUB2 NCX links.
     */
    data class Chapter(
        val id: String,
        val href: String,
        val title: String,
        val text: String,
        val anchors: Map<String, Int> = emptyMap(),
        /** The actual OPF itemref id used by the package-document CFI step. */
        internal val spineItemId: String? = null,
        /** Manifest id accepted for CFI assertions emitted by other readers. */
        internal val manifestItemId: String? = null,
        /** Zero-based position among all OPF spine itemref children. */
        internal val spineIndex: Int = 0,
        /** Mapping between rendered text offsets and XHTML text-node CFI paths. */
        internal val cfiTextRuns: List<EpubCfiTextRun> = emptyList(),
    )

    data class TocItem(val title: String, val href: String, val depth: Int = 0)

    internal data class PageSpan(val startOffset: Int, val text: String)

    fun pages(
        chapterIndex: Int,
        fontSizeSp: Int,
        lineSpacing: Int = 8,
        paragraphSpacing: Int = 0,
        margin: Int = 10,
    ): List<String> {
        return pageSpansInternal(chapterIndex, fontSizeSp, lineSpacing, paragraphSpacing, margin).map { it.text }
    }

    /** Return the page containing a text/anchor offset under the current style. */
    fun pageForOffset(
        chapterIndex: Int,
        offset: Int,
        fontSizeSp: Int,
        lineSpacing: Int = 8,
        paragraphSpacing: Int = 0,
        margin: Int = 10,
    ): Int {
        val spans = pageSpansInternal(chapterIndex, fontSizeSp, lineSpacing, paragraphSpacing, margin)
        if (spans.isEmpty()) return 0
        val target = offset.coerceAtLeast(0)
        return spans.indexOfLast { it.startOffset <= target }.coerceIn(0, spans.lastIndex)
    }

    /** Return the stable text offset at the beginning of a rendered page. */
    fun offsetForPage(
        chapterIndex: Int,
        pageIndex: Int,
        fontSizeSp: Int,
        lineSpacing: Int = 8,
        paragraphSpacing: Int = 0,
        margin: Int = 10,
    ): Int = pageSpansInternal(chapterIndex, fontSizeSp, lineSpacing, paragraphSpacing, margin)
        .getOrNull(pageIndex.coerceAtLeast(0))?.startOffset ?: 0

    /** Locate a navigation href, including a fragment within a chapter. */
    fun chapterIndexForHref(href: String): Int {
        val path = href.substringBefore('#').substringBefore('?')
        return chapters.indexOfFirst { it.href.substringBefore('#').substringBefore('?') == path }
    }

    fun pageIndexForHref(
        href: String,
        fontSizeSp: Int,
        lineSpacing: Int = 8,
        paragraphSpacing: Int = 0,
        margin: Int = 10,
    ): Pair<Int, Int>? {
        val chapterIndex = chapterIndexForHref(href)
        if (chapterIndex < 0) return null
        val fragment = href.substringAfter('#', "").substringBefore('?')
        val offset = chapters[chapterIndex].anchors[fragment] ?: 0
        return chapterIndex to pageForOffset(chapterIndex, offset, fontSizeSp, lineSpacing, paragraphSpacing, margin)
    }

    /** Return a standard EPUB CFI for the first text character on a rendered page. */
    fun cfiForPage(
        chapterIndex: Int,
        pageIndex: Int,
        fontSizeSp: Int,
        lineSpacing: Int = 8,
        paragraphSpacing: Int = 0,
        margin: Int = 10,
    ): String {
        val offset = offsetForPage(chapterIndex, pageIndex, fontSizeSp, lineSpacing, paragraphSpacing, margin)
        return cfiForOffset(chapterIndex, offset)
    }

    /**
     * Builds an EPUB CFI from the OPF spine position plus the XHTML text node
     * that contains this renderer's text offset.  No page or display-setting
     * data is embedded, so the location survives reflow.
     */
    fun cfiForOffset(chapterIndex: Int, textOffset: Int): String {
        val chapter = chapters.getOrNull(chapterIndex) ?: return "epubcfi(/6/4!/4/2/1:0)"
        val position = chapter.cfiPositionForRenderedOffset(textOffset)
            ?: return EpubCfi.format(chapter.spineIndex, chapter.spineItemId, "/4/2/1", 0)
        return EpubCfi.format(chapter.spineIndex, chapter.spineItemId, position.path, position.sourceOffset)
    }

    /**
     * Resolves an EPUB CFI into this reader's chapter and rendered-text offset.
     * Unsupported or stale external CFI values are reported explicitly rather
     * than being mistaken for a successful percentage-only restore.
     */
    fun resolveCfi(cfi: String?): EpubCfiResolution {
        val raw = cfi?.trim().orEmpty()
        if (!raw.startsWith("epubcfi(")) return EpubCfiResolution.NotEpubCfi
        val parsed = EpubCfi.parse(raw)
            ?: return EpubCfiResolution.Unresolved(raw, "EPUB CFI 语法不受支持")
        val assertedChapter = parsed.spineItemId?.let { itemId ->
            chapters.indexOfFirst { it.spineItemId == itemId || it.manifestItemId == itemId }.takeIf { it >= 0 }
        }
        if (parsed.spineItemId != null && assertedChapter == null) {
            return EpubCfiResolution.Unresolved(raw, "EPUB CFI 的 spine item 不属于当前书籍")
        }
        val chapterIndex = assertedChapter ?: chapters.indexOfFirst { it.spineIndex == parsed.spineIndex }
        val chapter = chapters.getOrNull(chapterIndex)
            ?: return EpubCfiResolution.Unresolved(raw, "EPUB CFI 的 spine 位置超出当前书籍")
        val offset = chapter.renderedOffsetForCfi(parsed.contentPath, parsed.characterOffset)
            ?: return EpubCfiResolution.Unresolved(raw, "EPUB CFI 的 XHTML 节点无法定位")
        return EpubCfiResolution.Resolved(chapterIndex, offset)
    }

    private fun pageSpansInternal(
        chapterIndex: Int,
        fontSizeSp: Int,
        lineSpacing: Int,
        paragraphSpacing: Int,
        margin: Int,
    ): List<PageSpan> {
        val chapter = chapters.getOrNull(chapterIndex) ?: return listOf(PageSpan(0, ""))
        // This is a bounded text paginator rather than a full browser layout
        // engine. Reading settings still affect the page budget so changing
        // line/paragraph spacing or margins reflows at the same locator.
        val chars = (2600 - fontSizeSp * 65 - lineSpacing * 12 - paragraphSpacing * 24 - margin * 8)
            .coerceIn(600, 1800)
        return chapter.text.chunkPreservingWordsWithOffsets(chars).ifEmpty { listOf(PageSpan(0, "")) }
    }

    fun close() = Unit

    companion object {
        private const val MAX_ARCHIVE_BYTES = 2L * 1024 * 1024 * 1024
        private const val MAX_CHAPTER_BYTES = 8L * 1024 * 1024
        private const val MAX_CHAPTERS = 2_000
        private const val MAX_ARCHIVE_ENTRIES = 10_000
        private const val MAX_ENTRY_UNCOMPRESSED_BYTES = 256L * 1024 * 1024
        private const val MAX_TOTAL_UNCOMPRESSED_BYTES = 1024L * 1024 * 1024
        private const val MAX_COMPRESSION_RATIO = 100L

        private fun validateArchiveEntries(zip: ZipFile) {
            val names = HashSet<String>()
            var count = 0
            var total = 0L
            zip.entries().asSequence().forEach { entry ->
                require(++count <= MAX_ARCHIVE_ENTRIES) { "EPUB has too many archive entries" }
                require(names.add(entry.name) && safeArchiveEntryPath(entry.name)) { "unsafe or duplicate EPUB entry" }
                val uncompressed = entry.size
                val compressed = entry.compressedSize
                require(uncompressed >= 0L && uncompressed <= MAX_ENTRY_UNCOMPRESSED_BYTES) { "EPUB entry exceeds safety limit" }
                total = Math.addExact(total, uncompressed)
                require(total <= MAX_TOTAL_UNCOMPRESSED_BYTES) { "EPUB archive exceeds aggregate safety limit" }
                if (!entry.isDirectory && uncompressed > 0L) {
                    require(compressed > 0L && compressed <= Long.MAX_VALUE / MAX_COMPRESSION_RATIO && uncompressed <= compressed * MAX_COMPRESSION_RATIO) { "EPUB compression ratio exceeds safety limit" }
                }
            }
        }

        private fun safeArchiveEntryPath(path: String): Boolean {
            if (path.isBlank() || path.startsWith('/') || path.contains('\\')) return false
            val components = path.split('/')
            val last = components.lastIndex
            return components.withIndex().all { (index, component) ->
                component.isNotEmpty() || (index == last && path.endsWith('/'))
            } && components.none { it == "." || it == ".." }
        }

        fun open(file: File): EpubBook {
            require(file.isFile && file.length() <= MAX_ARCHIVE_BYTES) { "EPUB file is invalid or too large" }
            ZipFile(file).use { zip ->
                validateArchiveEntries(zip)
                require(zip.getEntry("META-INF/rights.xml") == null && zip.getEntry("META-INF/encryption.xml") == null) {
                    "DRM-protected EPUB is not supported"
                }
                val container = zip.getEntry("META-INF/container.xml") ?: error("EPUB container.xml is missing")
                val containerXml = zip.getInputStream(container).use { it.readUtf8Bounded(256 * 1024) }
                val opfPath = Regex("full-path\\s*=\\s*(['\"])([^'\"]+)\\1").find(containerXml)?.groupValues?.get(2)
                    ?: error("EPUB rootfile is missing")
                val opf = zip.getEntry(safePath(opfPath)) ?: error("EPUB package is missing")
                val opfXml = zip.getInputStream(opf).use { it.readUtf8Bounded(MAX_CHAPTER_BYTES) }
                val packageDir = opfPath.substringBeforeLast('/', "")
                val manifest = parseManifest(opfXml, packageDir)
                val spineTag = Regex("<spine\\b([^>]*)>", RegexOption.IGNORE_CASE).find(opfXml)?.groupValues?.get(1).orEmpty()
                val spine = Regex("<itemref\\b([^>]*)/?>", RegexOption.IGNORE_CASE)
                    .findAll(opfXml)
                    .mapIndexedNotNull { spineIndex, match ->
                        val attributes = attrs(match.groupValues[1])
                        val manifestId = attributes["idref"] ?: return@mapIndexedNotNull null
                        manifest[manifestId]?.let { item -> SpineItem(item, attributes["id"], spineIndex) }
                    }
                    .filter { it.mediaType in CONTENT_MEDIA_TYPES }
                    .take(MAX_CHAPTERS)
                val chapters = spine.mapNotNull { spineItem ->
                    val item = spineItem.item
                    val entry = zip.getEntry(item.href) ?: return@mapNotNull null
                    if (entry.isDirectory || entry.size < 0 || entry.size > MAX_CHAPTER_BYTES) return@mapNotNull null
                    val markup = zip.getInputStream(entry).use { it.readUtf8Bounded(MAX_CHAPTER_BYTES) }
                    val projection = projectXhtmlText(markup)
                    Chapter(
                        id = item.id,
                        href = item.href,
                        title = extractTitle(markup).ifBlank { item.id },
                        text = projection.text,
                        anchors = parseAnchors(markup, projection.text),
                        spineItemId = spineItem.id,
                        manifestItemId = item.id,
                        spineIndex = spineItem.index,
                        cfiTextRuns = projection.runs,
                    )
                }.toList()
                val title = Regex("<dc:title\\b[^>]*>(.*?)</dc:title>", setOf(RegexOption.IGNORE_CASE, RegexOption.DOT_MATCHES_ALL))
                    .find(opfXml)?.groupValues?.get(1)?.let(::decodeEntities)?.trim().orEmpty().ifBlank { file.nameWithoutExtension }
                val toc = parseToc(zip, manifest, packageDir, attrs(spineTag)["toc"])
                return EpubBook(file, title, chapters, toc)
            }
        }

        private data class ManifestItem(val id: String, val href: String, val mediaType: String, val properties: Set<String> = emptySet())

        private data class SpineItem(val item: ManifestItem, val id: String?, val index: Int) {
            val mediaType: String get() = item.mediaType
        }

        private val CONTENT_MEDIA_TYPES = setOf("application/xhtml+xml", "text/html", "application/x-dtbook+xml")

        private fun parseManifest(xml: String, packageDir: String): Map<String, ManifestItem> =
            Regex("<item\\b([^>]*)/?>", RegexOption.IGNORE_CASE).findAll(xml).mapNotNull { match ->
                val attributes = attrs(match.groupValues[1])
                val id = attributes["id"] ?: return@mapNotNull null
                val href = attributes["href"] ?: return@mapNotNull null
                val media = attributes["media-type"].orEmpty()
                val properties = attributes["properties"].orEmpty().split(Regex("\\s+")).filter(String::isNotBlank).toSet()
                id to ManifestItem(id, safePath(resolve(packageDir, decodeHref(href))), media, properties)
            }.toMap()

        private fun parseToc(zip: ZipFile, manifest: Map<String, ManifestItem>, packageDir: String, ncxId: String?): List<TocItem> {
            val navItem = manifest.values.firstOrNull { "nav" in it.properties }
            if (navItem != null) {
                val entry = zip.getEntry(navItem.href)
                if (entry != null) {
                    val markup = zip.getInputStream(entry).use { it.readUtf8Bounded(MAX_CHAPTER_BYTES) }
                    val base = navItem.href.substringBeforeLast('/', "")
                    val navItems = Regex("<a\\b[^>]*href\\s*=\\s*(['\"])([^'\"]+)\\1[^>]*>(.*?)</a>", setOf(RegexOption.IGNORE_CASE, RegexOption.DOT_MATCHES_ALL)).findAll(markup).mapNotNull {
                        val href = it.groupValues[2]
                        val text = markupToText(it.groupValues[3]).trim()
                        if (href.isBlank() || text.isBlank()) null else TocItem(text, safePath(resolve(base, decodeHref(href))), navDepth(markup, it.range.first))
                    }.take(MAX_CHAPTERS).toList()
                    if (navItems.isNotEmpty()) return navItems
                }
            }
            val ncxItem = ncxId?.let { manifest[it] } ?: manifest.values.firstOrNull { it.mediaType == "application/x-dtbncx+xml" }
            if (ncxItem == null) return emptyList()
            val entry = zip.getEntry(ncxItem.href) ?: return emptyList()
            val markup = zip.getInputStream(entry).use { it.readUtf8Bounded(MAX_CHAPTER_BYTES) }
            val base = ncxItem.href.substringBeforeLast('/', "")
            return parseNcx(markup, base).take(MAX_CHAPTERS)
        }

        private fun parseNcx(markup: String, base: String): List<TocItem> {
            val result = mutableListOf<TocItem>()
            val tokens = Regex("(?is)</?navPoint\\b[^>]*>|<text\\b[^>]*>(.*?)</text>|<content\\b([^>]*)/?>").findAll(markup)
            var depth = 0
            var pendingTitle = ""
            tokens.forEach { token ->
                val value = token.value
                when {
                    value.startsWith("</", true) -> depth = (depth - 1).coerceAtLeast(0)
                    value.startsWith("<navPoint", true) -> depth++
                    value.startsWith("<text", true) -> pendingTitle = markupToText(token.groupValues.getOrNull(1).orEmpty()).trim()
                    value.startsWith("<content", true) -> {
                        val href = attrs(token.groupValues.getOrNull(2).orEmpty())["src"].orEmpty()
                        if (href.isNotBlank() && pendingTitle.isNotBlank()) {
                            result += TocItem(pendingTitle, safePath(resolve(base, decodeHref(href))), (depth - 1).coerceAtLeast(0))
                            pendingTitle = ""
                        }
                    }
                }
            }
            return result
        }

        private fun attrs(raw: String): Map<String, String> = Regex("([A-Za-z_:][-A-Za-z0-9_.:]*)\\s*=\\s*(['\"])(.*?)\\2").findAll(raw).associate { it.groupValues[1].lowercase() to decodeEntities(it.groupValues[3]) }

        private fun navDepth(markup: String, position: Int): Int = Regex("</?nav\\b|</?ol\\b", RegexOption.IGNORE_CASE).findAll(markup.substring(0, position)).count { !it.value.startsWith("</") }.minus(1).coerceAtLeast(0)

        private fun resolve(base: String, href: String): String {
            val fragment = href.substringAfter('#', "").takeIf { it.isNotBlank() }?.let { "#$it" }.orEmpty()
            val path = href.substringBefore('#').substringBefore('?')
            val parts = (if (base.isBlank()) path else "$base/$path").split('/')
            val out = ArrayDeque<String>()
            parts.forEach { part ->
                when {
                    part.isBlank() || part == "." -> Unit
                    part == ".." -> if (out.isNotEmpty()) out.removeLast() else error("unsafe EPUB path")
                    else -> out.addLast(part)
                }
            }
            return out.joinToString("/") + fragment
        }

        private fun safePath(path: String): String {
            require(!path.startsWith('/') && !path.contains('\\')) { "unsafe EPUB path" }
            require(path.split('/').none { it == ".." || it.isBlank() }) { "unsafe EPUB path" }
            return path
        }

        private fun extractTitle(markup: String): String = Regex("<title\\b[^>]*>(.*?)</title>", setOf(RegexOption.IGNORE_CASE, RegexOption.DOT_MATCHES_ALL)).find(markup)?.groupValues?.get(1)?.let(::markupToText).orEmpty()

        private fun markupToText(raw: String): String = projectXhtmlText(raw).text

        /**
         * Projects XHTML into the same bounded text surface used by the reader
         * while retaining a CFI path for every visible source-text run.  The
         * path starts below the document element (`html`): `/4` is normally
         * `body` after `head`, matching the EPUB CFI content-document model.
         */
        private fun projectXhtmlText(markup: String): XhtmlTextProjection {
            val output = ProjectedTextBuilder()
            val stack = ArrayDeque<XhtmlElement>().apply { addLast(XhtmlElement("#document", "", false)) }
            var hasDocumentElement = false
            var cursor = 0
            TAG_TOKEN.findAll(markup).forEach { token ->
                if (token.range.first > cursor) {
                    val parent = stack.last()
                    val nodeIndex = parent.nextChildIndex++
                    if (!parent.excluded) {
                        output.appendSource(decodeEntities(markup.substring(cursor, token.range.first)), "${parent.path}/${nodeIndex * 2 + 1}")
                    }
                }
                val rawTag = token.value
                when {
                    rawTag.startsWith("<!--") || rawTag.startsWith("<!") || rawTag.startsWith("<?") -> Unit
                    rawTag.startsWith("</") -> {
                        val closingName = TAG_NAME.find(rawTag)?.groupValues?.get(1)?.lowercase().orEmpty()
                        val element = stack.removeLastOrNull()?.takeIf { it.name != "#document" }
                        if (element == null) {
                            stack.addLast(XhtmlElement("#document", "", false))
                        } else if (!element.excluded) {
                            if (closingName in BLOCK_ELEMENTS) output.appendGenerated("\n\n") else output.appendGenerated(" ")
                        }
                    }
                    else -> {
                        val name = TAG_NAME.find(rawTag)?.groupValues?.get(1)?.lowercase()
                        if (name == null) {
                            output.appendGenerated(" ")
                        } else {
                            val parent = stack.last()
                            val selfClosing = rawTag.endsWith("/>") || name in VOID_ELEMENTS
                            val isDocumentElement = name == "html" && !hasDocumentElement && parent.name == "#document"
                            val path = if (isDocumentElement) {
                                hasDocumentElement = true
                                parent.path
                            } else {
                                val nodeIndex = parent.nextChildIndex++
                                val id = attrs(rawTag.removePrefix("<").removeSuffix(">"))["id"]
                                "${parent.path}/${(nodeIndex + 1) * 2}${id?.takeIf(String::isNotBlank)?.let { "[${escapeCfiAssertion(it)}]" }.orEmpty()}"
                            }
                            val excluded = parent.excluded || name in EXCLUDED_ELEMENTS
                            if (!excluded) {
                                if (name == "br") output.appendGenerated("\n") else output.appendGenerated(" ")
                            }
                            if (!selfClosing) stack.addLast(XhtmlElement(name, path, excluded))
                        }
                    }
                }
                cursor = token.range.last + 1
            }
            if (cursor < markup.length) {
                val parent = stack.last()
                val nodeIndex = parent.nextChildIndex++
                if (!parent.excluded) output.appendSource(decodeEntities(markup.substring(cursor)), "${parent.path}/${nodeIndex * 2 + 1}")
            }
            return output.finish()
        }

        private data class XhtmlElement(
            val name: String,
            val path: String,
            val excluded: Boolean,
            var nextChildIndex: Int = 0,
        )

        private data class XhtmlTextProjection(val text: String, val runs: List<EpubCfiTextRun>)

        private class ProjectedTextBuilder {
            private val text = StringBuilder()
            private val runs = mutableListOf<MutableCfiRun>()

            fun appendSource(value: String, path: String) {
                value.forEachIndexed { sourceOffset, character -> append(character, path, sourceOffset) }
            }

            fun appendGenerated(value: String) {
                value.forEach { character -> append(character, null, -1) }
            }

            private fun append(character: Char, path: String?, sourceOffset: Int) {
                val normalized = if (character == '\t') ' ' else character
                if (normalized == ' ' && text.lastOrNull() == ' ') return
                if (normalized == '\n' && text.length >= 2 && text[text.length - 1] == '\n' && text[text.length - 2] == '\n') return
                val renderedOffset = text.length
                text.append(normalized)
                if (path != null) appendRun(path, sourceOffset, renderedOffset)
            }

            private fun appendRun(path: String, sourceOffset: Int, renderedOffset: Int) {
                val last = runs.lastOrNull()
                if (last != null && last.path == path &&
                    last.sourceStart + last.length == sourceOffset &&
                    last.renderedStart + last.length == renderedOffset
                ) {
                    last.length++
                } else {
                    runs += MutableCfiRun(path, sourceOffset, renderedOffset, 1)
                }
            }

            fun finish(): XhtmlTextProjection {
                var start = 0
                var end = text.length
                while (start < end && text[start].isWhitespace()) start++
                while (end > start && text[end - 1].isWhitespace()) end--
                val trimmedRuns = runs.mapNotNull { run ->
                    val runStart = maxOf(run.renderedStart, start)
                    val runEnd = minOf(run.renderedStart + run.length, end)
                    if (runStart >= runEnd) null else EpubCfiTextRun(
                        path = run.path,
                        sourceStart = run.sourceStart + (runStart - run.renderedStart),
                        renderedStart = runStart - start,
                        length = runEnd - runStart,
                    )
                }
                return XhtmlTextProjection(text.substring(start, end), trimmedRuns)
            }

            private data class MutableCfiRun(
                val path: String,
                val sourceStart: Int,
                val renderedStart: Int,
                var length: Int,
            )
        }

        private val TAG_TOKEN = Regex("(?s)<!--.*?-->|<[^>]+>")
        private val TAG_NAME = Regex("^</?\\s*([A-Za-z][A-Za-z0-9:.-]*)\\b")
        private val EXCLUDED_ELEMENTS = setOf("script", "style", "svg", "head")
        private val BLOCK_ELEMENTS = setOf("p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "li", "section", "article", "tr", "title")
        private val VOID_ELEMENTS = setOf("area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr")

        private fun parseAnchors(markup: String, text: String): Map<String, Int> {
            if (markup.isBlank() || text.isBlank()) return emptyMap()
            val result = linkedMapOf<String, Int>()
            val element = Regex("(?is)<[A-Za-z][^>]*\\b(?:id|name)\\s*=\\s*(['\"])(.*?)\\1[^>]*>")
            element.findAll(markup).forEach { match ->
                val id = decodeEntities(match.groupValues[2]).trim()
                if (id.isNotBlank()) {
                    // Prefix conversion is intentionally bounded by the same
                    // markup-to-text rules as chapter parsing, so offsets are
                    // stable after changing the text layout.
                    val offset = markupToText(markup.substring(0, match.range.first)).length.coerceIn(0, text.length)
                    // HashMap.putIfAbsent was added in API 24; Papria supports
                    // API 23, so keep the equivalent operation explicit.
                    if (!result.containsKey(id)) result[id] = offset
                }
            }
            return result
        }

        private fun decodeEntities(value: String): String = value
            .replace("&amp;", "&").replace("&lt;", "<").replace("&gt;", ">")
            .replace("&quot;", "\"").replace("&apos;", "'")

        private fun decodeHref(value: String): String = runCatching { URLDecoder.decode(value, Charsets.UTF_8.name()) }.getOrDefault(value)

        private fun InputStream.readUtf8Bounded(maxBytes: Long): String {
            val output = java.io.ByteArrayOutputStream()
            val buffer = ByteArray(64 * 1024); var total = 0L
            while (true) {
                val count = read(buffer); if (count < 0) break
                total += count; require(total <= maxBytes) { "EPUB member exceeds safety limit" }
                output.write(buffer, 0, count)
            }
            return output.toString(Charsets.UTF_8.name())
        }
    }
}

private fun String.chunkPreservingWordsWithOffsets(maxChars: Int): List<EpubBook.PageSpan> {
    if (length <= maxChars) return listOf(EpubBook.PageSpan(0, this))
    val pages = mutableListOf<EpubBook.PageSpan>(); var start = 0
    while (start < length) {
        var end = minOf(start + maxChars, length)
        if (end < length) {
            val split = lastIndexOfAny(charArrayOf(' ', '\n', '\t'), end)
            if (split > start + maxChars / 2) end = split
        }
        pages += EpubBook.PageSpan(start, substring(start, end).trim())
        start = end
        while (start < length && this[start].isWhitespace()) start++
    }
    return pages
}

private data class EpubCfiTextPosition(val path: String, val sourceOffset: Int)

private fun EpubBook.Chapter.cfiPositionForRenderedOffset(renderedOffset: Int): EpubCfiTextPosition? {
    if (cfiTextRuns.isEmpty()) return null
    val target = renderedOffset.coerceIn(0, text.length.coerceAtLeast(1) - 1)
    val containing = cfiTextRuns.firstOrNull { target in it.renderedStart until (it.renderedStart + it.length) }
    if (containing != null) {
        return EpubCfiTextPosition(containing.path, containing.sourceStart + target - containing.renderedStart)
    }
    val after = cfiTextRuns.firstOrNull { it.renderedStart > target }
    if (after != null) return EpubCfiTextPosition(after.path, after.sourceStart)
    val before = cfiTextRuns.last()
    return EpubCfiTextPosition(before.path, before.sourceStart + before.length - 1)
}

private fun EpubBook.Chapter.renderedOffsetForCfi(contentPath: String, sourceOffset: Int): Int? {
    val normalizedPath = EpubCfi.normalizePath(contentPath)
    val matching = cfiTextRuns.filter { EpubCfi.normalizePath(it.path) == normalizedPath }
        .ifEmpty {
            // A valid CFI may identify an element instead of a text node. In
            // that case restore to its first visible descendant text node.
            cfiTextRuns.filter { EpubCfi.normalizePath(it.path).startsWith("$normalizedPath/") }
        }
    if (matching.isEmpty()) return null
    val run = matching.firstOrNull { sourceOffset in it.sourceStart until (it.sourceStart + it.length) }
        ?: matching.firstOrNull { sourceOffset < it.sourceStart }
        ?: matching.last()
    return when {
        sourceOffset <= run.sourceStart -> run.renderedStart
        sourceOffset >= run.sourceStart + run.length -> run.renderedStart + run.length - 1
        else -> run.renderedStart + sourceOffset - run.sourceStart
    }.coerceIn(0, text.length.coerceAtLeast(1) - 1)
}

private fun escapeCfiAssertion(value: String): String = buildString(value.length) {
    value.forEach { character ->
        if (character == '^' || character == '[' || character == ']' || character == ',') append('^')
        append(character)
    }
}

/** Minimal point-CFI parser/formatter for OPF spine and XHTML text-node routes. */
private object EpubCfi {
    private data class Step(val value: Int, val assertion: String?)

    data class Parsed(
        val spineIndex: Int,
        val spineItemId: String?,
        val contentPath: String,
        val characterOffset: Int,
    )

    fun format(chapterIndex: Int, spineItemId: String?, contentPath: String, characterOffset: Int): String {
        val packageAssertion = spineItemId?.takeIf(String::isNotBlank)?.let { "[${escapeCfiAssertion(it)}]" }.orEmpty()
        // `/6` is the package document's spine container. Its first
        // itemref is `/4`; `/2` is the package root's metadata child and is
        // therefore not a valid spine position.
        return "epubcfi(/6/${(chapterIndex + 2) * 2}$packageAssertion!$contentPath:${characterOffset.coerceAtLeast(0)})"
    }

    fun parse(cfi: String): Parsed? {
        if (!cfi.startsWith("epubcfi(") || !cfi.endsWith(")")) return null
        val inner = cfi.substring("epubcfi(".length, cfi.length - 1)
        // A range CFI has comma-separated components. A reader position must
        // be a point CFI; choosing a range endpoint would silently alter it.
        if (inner.contains(',')) return null
        val separator = inner.indexOf('!')
        if (separator <= 0 || separator == inner.lastIndex) return null
        val packageSteps = parseSteps(inner.substring(0, separator)) ?: return null
        if (packageSteps.size != 2 || packageSteps.first().value != 6) return null
        val spineStep = packageSteps[1]
        if (spineStep.value <= 0 || spineStep.value % 2 != 0) return null
        val content = parseContent(inner.substring(separator + 1)) ?: return null
        return Parsed(
            spineIndex = spineStep.value / 2 - 2,
            spineItemId = spineStep.assertion?.let(::unescapeAssertion),
            contentPath = content.first,
            characterOffset = content.second,
        )
    }

    fun normalizePath(path: String): String = parseSteps(path)
        ?.joinToString(separator = "") { "/${it.value}" }
        .orEmpty()

    private fun parseContent(value: String): Pair<String, Int>? {
        val colon = value.lastIndexOf(':')
        val path = if (colon < 0) value else value.substring(0, colon)
        val offset = if (colon < 0) 0 else {
            val suffix = value.substring(colon + 1)
            val match = Regex("^(\\d+)$").matchEntire(suffix) ?: return null
            match.groupValues[1].toIntOrNull() ?: return null
        }
        val normalized = normalizePath(path)
        return normalized.takeIf(String::isNotBlank)?.let { normalized to offset }
    }

    private fun parseSteps(value: String): List<Step>? {
        if (value.isEmpty()) return emptyList()
        val result = mutableListOf<Step>()
        var cursor = 0
        while (cursor < value.length) {
            if (value[cursor] != '/') return null
            cursor++
            val start = cursor
            while (cursor < value.length && value[cursor].isDigit()) cursor++
            val number = value.substring(start, cursor).toIntOrNull() ?: return null
            var assertion: String? = null
            if (cursor < value.length && value[cursor] == '[') {
                val end = findAssertionEnd(value, cursor + 1) ?: return null
                assertion = value.substring(cursor + 1, end)
                cursor = end + 1
            }
            result += Step(number, assertion)
        }
        return result
    }

    private fun findAssertionEnd(value: String, start: Int): Int? {
        var escaped = false
        for (index in start until value.length) {
            when {
                escaped -> escaped = false
                value[index] == '^' -> escaped = true
                value[index] == ']' -> return index
            }
        }
        return null
    }

    private fun unescapeAssertion(value: String): String = buildString(value.length) {
        var escaped = false
        value.forEach { character ->
            when {
                escaped -> {
                    append(character)
                    escaped = false
                }
                character == '^' -> escaped = true
                else -> append(character)
            }
        }
        if (escaped) append('^')
    }
}
