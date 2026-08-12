@file:OptIn(org.readium.r2.shared.ExperimentalReadiumApi::class)

package com.papria.reader.core.reader

import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.view.Gravity
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.viewinterop.AndroidView
import androidx.fragment.app.Fragment
import androidx.fragment.app.FragmentActivity
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import com.papria.reader.ReaderProgress
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.readium.adapter.pdfium.document.PdfiumDocumentFactory
import org.readium.adapter.pdfium.navigator.PdfiumEngineProvider
import org.readium.adapter.pdfium.navigator.PdfiumNavigatorFactory
import org.readium.adapter.pdfium.navigator.PdfiumPreferences
import org.readium.r2.navigator.Navigator
import org.readium.r2.navigator.epub.EpubNavigatorFactory
import org.readium.r2.navigator.epub.EpubNavigatorFragment
import org.readium.r2.navigator.epub.EpubPreferences
import org.readium.r2.navigator.preferences.FontFamily
import org.readium.r2.navigator.pdf.PdfNavigatorFragment
import org.readium.r2.shared.publication.Link
import org.readium.r2.shared.publication.Locator
import org.readium.r2.shared.publication.Publication
import org.readium.r2.shared.publication.html.partialCfi
import org.readium.r2.shared.publication.services.isRestricted
import org.readium.r2.shared.publication.services.locateProgression
import org.readium.r2.shared.util.AbsoluteUrl
import org.readium.r2.shared.util.ErrorException
import org.readium.r2.shared.util.Url
import org.readium.r2.shared.util.asset.AssetRetriever
import org.readium.r2.shared.util.data.ReadError
import org.readium.r2.shared.util.getOrElse
import org.readium.r2.shared.util.http.DefaultHttpClient
import org.readium.r2.streamer.PublicationOpener
import org.readium.r2.streamer.parser.DefaultPublicationParser
import java.io.File

/**
 * The existing reader activity owns database and BookOrbit state; this narrow
 * interface lets Readium publish its real locators without duplicating that
 * storage or inventing another progress payload.
 */
interface ReadiumProgressHost {
    fun saveReadiumProgress(progress: ReaderProgress)
}

/**
 * Compose entry point for the Readium EPUB and PDFium PDF renderers.
 *
 * A real Fragment is used because Readium's navigators own Android views,
 * lifecycle state and WebView/PDF renderer resources. Recreating only on the
 * parent reader's remote-progress key preserves an active navigator during
 * normal local progress writes.
 */
@Composable
fun ColumnScope.ReadiumReader(
    path: String,
    format: String,
    initialPercentage: Double,
    initialPageNumber: Int?,
    initialCfi: String?,
) {
    val context = LocalContext.current
    val activity = context as? FragmentActivity
    val containerId = remember(path, format) { View.generateViewId() }

    AndroidView(
        modifier = Modifier.weight(1f).fillMaxWidth(),
        factory = { viewContext ->
            FrameLayout(viewContext).apply { id = containerId }
        },
    )

    LaunchedEffect(path, format) {
        val host = activity ?: return@LaunchedEffect
        if (host.supportFragmentManager.isStateSaved) return@LaunchedEffect
        host.supportFragmentManager.beginTransaction().replace(
                containerId,
                ReadiumReaderFragment.newInstance(
                    path = path,
                    format = format,
                    percentage = initialPercentage,
                    pageNumber = initialPageNumber,
                    cfi = initialCfi,
                ),
                READER_FRAGMENT_TAG,
            ).commitNow()
    }
}

class ReadiumReaderFragment : Fragment(), EpubNavigatorFragment.Listener, PdfNavigatorFragment.Listener {
    private var publication: Publication? = null
    private var navigator: Navigator? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        // A Readium navigator has no ordinary empty constructor. Install the
        // matching dummy factory before FragmentManager can restore a child
        // after a process recreation; the real factory replaces it once the
        // publication opens below.
        childFragmentManager.fragmentFactory = when (format) {
            FORMAT_PDF -> PdfNavigatorFragment.createDummyFactory(PdfiumEngineProvider())
            else -> EpubNavigatorFragment.createDummyFactory()
        }
        super.onCreate(savedInstanceState)
    }

    override fun onCreateView(
        inflater: LayoutInflater,
        container: ViewGroup?,
        savedInstanceState: Bundle?,
    ): View = FrameLayout(requireContext()).apply { id = NAVIGATOR_CONTAINER_ID }

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        super.onViewCreated(view, savedInstanceState)
        openReader()
    }

    private fun openReader() {
        viewLifecycleOwner.lifecycleScope.launch {
            runCatching { openPublication() }
                .onSuccess { opened -> installNavigator(opened) }
                .onFailure { failure -> showFailure(failure.message ?: "Readium 无法打开此文件") }
        }
    }

    override fun onDestroy() {
        releaseNavigator()
        super.onDestroy()
    }

    private fun releaseNavigator() {
        publication?.close()
        publication = null
        navigator = null
    }

    private suspend fun openPublication(): Publication = withContext(Dispatchers.IO) {
        val file = File(requireArguments().getString(ARG_PATH).orEmpty())
        require(file.isFile) { "阅读文件不存在" }

        val httpClient = DefaultHttpClient()
        val assets = AssetRetriever(requireContext().contentResolver, httpClient)
        val opener = PublicationOpener(
            publicationParser = DefaultPublicationParser(
                context = requireContext(),
                httpClient = httpClient,
                assetRetriever = assets,
                pdfFactory = PdfiumDocumentFactory(requireContext()),
            ),
        )
        val asset = assets.retrieve(file).getOrElse { error ->
            throw IllegalArgumentException(error.message, ErrorException(error))
        }
        val opened = opener.open(asset, allowUserInteraction = false).getOrElse { error ->
            throw IllegalArgumentException(error.message, ErrorException(error))
        }
        if (opened.isRestricted) {
            opened.close()
            throw IllegalArgumentException("此文件受 DRM 保护，不受支持")
        }
        opened
    }

    private suspend fun installNavigator(opened: Publication) {
        if (!isAdded || childFragmentManager.isStateSaved) {
            opened.close()
            return
        }
        publication = opened
        val initial = initialLocator(opened)
        val fragmentFactory = when (format) {
            FORMAT_PDF -> PdfiumNavigatorFactory(opened, PdfiumEngineProvider())
                .createFragmentFactory(
                    initialLocator = initial,
                    initialPreferences = PdfiumPreferences(),
                    listener = this,
                )
            FORMAT_EPUB -> EpubNavigatorFactory(opened).createFragmentFactory(
                initialLocator = initial,
                // Keep the real Readium fallback aligned with the 0.1.0
                // reader baseline: serif, 1.75 leading and paged content.
                initialPreferences = EpubPreferences(
                    fontFamily = FontFamily.SERIF,
                    lineHeight = 1.75,
                    scroll = false,
                ),
                listener = this,
            )
            else -> error("Unsupported Readium format: $format")
        }
        childFragmentManager.fragmentFactory = fragmentFactory
        childFragmentManager.beginTransaction().replace(
                NAVIGATOR_CONTAINER_ID,
                if (format == FORMAT_PDF) PdfNavigatorFragment::class.java else EpubNavigatorFragment::class.java,
                Bundle(),
                NAVIGATOR_FRAGMENT_TAG,
            ).commitNow()
        navigator = childFragmentManager.findFragmentByTag(NAVIGATOR_FRAGMENT_TAG) as? Navigator
            ?: error("Readium navigator was not created")
        observeProgress()
    }

    private suspend fun initialLocator(opened: Publication): Locator? {
        if (format == FORMAT_EPUB) {
            initialEpubCfi(opened)?.let { return it }
        }
        if (format == FORMAT_PDF) {
            requireArguments().takeIf { arguments -> arguments.containsKey(ARG_PAGE_NUMBER) }
                ?.getInt(ARG_PAGE_NUMBER)
                ?.takeIf { it > 0 }
                ?.let { pageNumber ->
                    opened.readingOrder.firstOrNull()
                        ?.let(opened::locatorFromLink)
                        ?.copyWithLocations(position = pageNumber)
                        ?.let { return it }
                }
        }
        val progression = (requireArguments().getDouble(ARG_PERCENTAGE) / 100.0).coerceIn(0.0, 1.0)
        return opened.locateProgression(progression)
            ?: opened.readingOrder.firstOrNull()?.let(opened::locatorFromLink)
    }

    private fun initialEpubCfi(opened: Publication): Locator? {
        val cfi = requireArguments().getString(ARG_CFI) ?: return null
        val match = FULL_CFI.matchEntire(cfi) ?: return null
        val spineStep = match.groupValues[1].toIntOrNull() ?: return null
        val spineIndex = spineStep / 2 - 2
        val link = opened.readingOrder.getOrNull(spineIndex) ?: return null
        val base = opened.locatorFromLink(link) ?: return null
        return base.copyWithLocations(otherLocations = mapOf("partialCfi" to match.groupValues[2]))
    }

    private fun observeProgress() {
        val currentNavigator = navigator ?: return
        viewLifecycleOwner.lifecycleScope.launch {
            viewLifecycleOwner.repeatOnLifecycle(Lifecycle.State.STARTED) {
                currentNavigator.currentLocator.collect { locator ->
                    val percentage = ((locator.locations.totalProgression ?: locator.locations.progression ?: 0.0) * 100)
                        .coerceIn(0.0, 100.0)
                    (activity as? ReadiumProgressHost)?.saveReadiumProgress(
                        ReaderProgress(
                            percentage = percentage,
                            pageNumber = if (format == FORMAT_PDF) locator.locations.position else null,
                            cfi = if (format == FORMAT_EPUB) fullEpubCfi(locator) else null,
                        ),
                    )
                }
            }
        }
    }

    private fun fullEpubCfi(locator: Locator): String? {
        val opened = publication ?: return null
        val partial = locator.locations.partialCfi ?: return null
        val spineIndex = opened.readingOrder.indexOfFirst { link ->
            link.url().removeFragment() == locator.href.removeFragment()
        }
        if (spineIndex < 0 || !partial.startsWith('/')) return null
        val spineStep = 2 * (spineIndex + 2)
        return "epubcfi(/6/$spineStep!$partial)"
    }

    private fun showFailure(message: String) {
        val root = view as? FrameLayout ?: return
        // A resource may fail after a navigator has already been installed.
        // Release that renderer before presenting a retry so it cannot keep a
        // closed file or WebView alive behind the error page.
        releaseNavigator()
        root.removeAllViews()
        root.setBackgroundColor(PAPER_CANVAS)
        val context = requireContext()
        val fileName = File(requireArguments().getString(ARG_PATH).orEmpty())
            .name
            .ifBlank { "未知文件" }
        val content = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(24), dp(24), dp(24), dp(24))
            addView(failureText(context, "无法打开阅读文件", 20f, INK_PRIMARY))
            addView(failureText(context, "文件：$fileName", 16f, INK_SECONDARY).apply {
                setPadding(0, dp(16), 0, 0)
                maxLines = 2
            })
            addView(failureText(context, "原因：$message", 16f, INK_PRIMARY).apply {
                setPadding(0, dp(8), 0, dp(24))
            })
            addView(failureButton(context, "返回书库", outlined = true).apply {
                setOnClickListener { activity?.finish() }
            }, LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                dp(48),
            ).apply { bottomMargin = dp(12) })
            addView(failureButton(context, "重试", outlined = false).apply {
                setOnClickListener { openReader() }
            }, LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                dp(48),
            ))
        }
        root.addView(content, FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.MATCH_PARENT,
        ))
    }

    private fun failureText(context: android.content.Context, value: String, sizeSp: Float, color: Int): TextView =
        TextView(context).apply {
            text = value
            textSize = sizeSp
            setTextColor(color)
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_YES
        }

    private fun failureButton(context: android.content.Context, label: String, outlined: Boolean): Button =
        Button(context).apply {
            text = label
            contentDescription = label
            isAllCaps = false
            setTextColor(if (outlined) INK_PRIMARY else PAPER_RAISED)
            background = GradientDrawable().apply {
                shape = GradientDrawable.RECTANGLE
                cornerRadius = dp(6).toFloat()
                setColor(if (outlined) PAPER_RAISED else ACTION_PRIMARY)
                setStroke(dp(1), if (outlined) INK_PRIMARY else ACTION_PRIMARY)
            }
            minimumHeight = dp(48)
        }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()

    override fun onResourceLoadFailed(href: Url, error: ReadError) {
        showFailure(error.message)
    }

    override fun onJumpToLocator(locator: Locator) = Unit

    override fun shouldFollowInternalLink(link: Link, context: org.readium.r2.navigator.HyperlinkNavigator.LinkContext?): Boolean = true

    override fun onExternalLinkActivated(url: AbsoluteUrl) = Unit

    private val format: String
        get() = requireArguments().getString(ARG_FORMAT).orEmpty()

    companion object {
        private const val ARG_PATH = "path"
        private const val ARG_FORMAT = "format"
        private const val ARG_PERCENTAGE = "percentage"
        private const val ARG_PAGE_NUMBER = "pageNumber"
        private const val ARG_CFI = "cfi"
        private const val FORMAT_EPUB = "epub"
        private const val FORMAT_PDF = "pdf"
        private const val NAVIGATOR_CONTAINER_ID = 0x005A4D11
        private const val NAVIGATOR_FRAGMENT_TAG = "papria.readium.navigator"
        private val PAPER_CANVAS = 0xFFF7F2E8.toInt()
        private val PAPER_RAISED = 0xFFFFFCF6.toInt()
        private val INK_PRIMARY = 0xFF20221F.toInt()
        private val INK_SECONDARY = 0xFF6F6C63.toInt()
        private val ACTION_PRIMARY = 0xFFB74632.toInt()
        private val FULL_CFI = Regex("^epubcfi\\(/6/(\\d+)!(/.+)\\)$")

        fun newInstance(
            path: String,
            format: String,
            percentage: Double,
            pageNumber: Int?,
            cfi: String?,
        ) = ReadiumReaderFragment().apply {
            arguments = Bundle().apply {
                putString(ARG_PATH, path)
                putString(ARG_FORMAT, format)
                putDouble(ARG_PERCENTAGE, percentage)
                pageNumber?.let { putInt(ARG_PAGE_NUMBER, it) }
                cfi?.let { putString(ARG_CFI, it) }
            }
        }
    }
}

private const val READER_FRAGMENT_TAG = "papria.readium.host"
