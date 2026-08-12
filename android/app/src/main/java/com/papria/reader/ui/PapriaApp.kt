package com.papria.reader.ui

import android.app.Activity
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.view.WindowManager
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.sizeIn
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.wrapContentHeight
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.CloudQueue
import androidx.compose.material.icons.rounded.Delete
import androidx.compose.material.icons.rounded.Download
import androidx.compose.material.icons.rounded.LibraryBooks
import androidx.compose.material.icons.rounded.MoreVert
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material.icons.rounded.Settings
import androidx.compose.material.icons.rounded.Tune
import androidx.compose.material.icons.rounded.WifiTethering
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.google.zxing.BarcodeFormat
import com.google.zxing.EncodeHintType
import com.google.zxing.MultiFormatWriter
import com.papria.reader.core.bookorbit.BookOrbitClient
import com.papria.reader.core.bookorbit.RemoteBookPayload
import com.papria.reader.core.bookorbit.RemoteFilePayload
import com.papria.reader.core.display.DisplayMode
import com.papria.reader.core.local.DownloadTaskRecord
import com.papria.reader.core.local.LocalPublication
import com.papria.reader.core.local.ReadingProgressRecord
import com.papria.reader.core.local.SyncConflictRecord
import com.papria.reader.core.sync.DownloadWorker
import com.papria.reader.core.transfer.WifiTransferUploadLifecycle
import com.papria.reader.core.transfer.WifiTransferUploadSnapshot
import java.text.DateFormat
import java.util.Date
import java.util.Locale

private const val NORMAL_TOOLBAR_HEIGHT = 64
private const val EINK_TOOLBAR_HEIGHT = 48
private const val NORMAL_TABBAR_HEIGHT = 72
private const val EINK_TABBAR_HEIGHT = 52

/** E-ink layouts are specified in physical pixels by the 0.1.0 design. */
@Composable
private fun einkLength(px: Float) = with(androidx.compose.ui.platform.LocalDensity.current) {
    (px.coerceAtLeast(0f) / density.coerceAtLeast(0.001f)).dp
}

/** Android's four stable 0.1.0 entry points. Download tasks remain inside BookOrbit. */
@Composable
fun PapriaApp(
    viewModel: PapriaViewModel,
    onImport: () -> Unit = {},
    onOpenPublication: (LocalPublication) -> Unit = {},
) {
    val publications by viewModel.publications.collectAsState(initial = emptyList())
    val downloads by viewModel.downloads.collectAsState(initial = emptyList())
    val context = LocalContext.current
    val palette = LocalPapriaPalette.current
    val showRootTabBar = palette.isEink ||
        viewModel.selectedTab != AppTab.BOOKORBIT ||
        viewModel.bookOrbitDestination == BookOrbitDestination.CATALOG

    Scaffold(
        containerColor = palette.canvas,
        bottomBar = {
            if (showRootTabBar) {
                PapriaBottomNavigation(
                    selected = viewModel.selectedTab,
                    onSelect = viewModel::setTab,
                )
            }
        },
    ) { innerPadding ->
        Box(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding)
                .background(palette.canvas),
        ) {
            when (viewModel.selectedTab) {
                AppTab.LIBRARY -> LibraryScreen(
                    viewModel = viewModel,
                    publications = publications,
                    onImport = onImport,
                    onOpenPublication = onOpenPublication,
                )

                AppTab.BOOKORBIT -> BookOrbitScreen(
                    viewModel = viewModel,
                    downloads = downloads,
                    publications = publications,
                    context = context,
                    onOpenPublication = onOpenPublication,
                )

                AppTab.TRANSFER -> TransferScreen(
                    viewModel = viewModel,
                    publications = publications,
                    context = context,
                )

                AppTab.SETTINGS -> SettingsScreen(viewModel = viewModel, context = context)
            }
        }
    }
}

@Composable
private fun PapriaBottomNavigation(selected: AppTab, onSelect: (AppTab) -> Unit) {
    val palette = LocalPapriaPalette.current
    Surface(
        color = palette.raised,
        contentColor = palette.ink,
        shadowElevation = 0.dp,
        tonalElevation = 0.dp,
        border = BorderStroke(1.dp, palette.line),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .height(if (palette.isEink) einkLength(EINK_TABBAR_HEIGHT.toFloat()) else NORMAL_TABBAR_HEIGHT.dp)
                .navigationBarsPadding(),
        ) {
            AppTab.values().forEach { tab ->
                val isSelected = tab == selected
                val foreground = when {
                    palette.isEink && isSelected -> Color.White
                    palette.isEink -> palette.ink
                    isSelected -> palette.primaryAction
                    else -> palette.secondaryInk
                }
                val background = if (palette.isEink && isSelected) palette.ink else Color.Transparent
                Column(
                    modifier = Modifier
                        .weight(1f)
                        .fillMaxHeight()
                        .background(background)
                        .clickable { onSelect(tab) }
                        .semantics {
                            contentDescription = "${tab.label}${if (isSelected) "，当前入口" else ""}"
                        }
                        .padding(vertical = 6.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.Center,
                ) {
                    Icon(
                        tab.materialIcon,
                        contentDescription = null,
                        tint = foreground,
                        modifier = Modifier.size(18.dp),
                    )
                    Spacer(Modifier.height(2.dp))
                    Text(
                        tab.label,
                        color = foreground,
                        style = MaterialTheme.typography.labelMedium,
                        maxLines = 1,
                    )
                }
            }
        }
    }
}

private val AppTab.label: String
    get() = when (this) {
        AppTab.LIBRARY -> "书库"
        AppTab.BOOKORBIT -> "BookOrbit"
        AppTab.TRANSFER -> "传书"
        AppTab.SETTINGS -> "设置"
    }

private val AppTab.materialIcon: ImageVector
    get() = when (this) {
        AppTab.LIBRARY -> Icons.Rounded.LibraryBooks
        AppTab.BOOKORBIT -> Icons.Rounded.CloudQueue
        AppTab.TRANSFER -> Icons.Rounded.WifiTethering
        AppTab.SETTINGS -> Icons.Rounded.Settings
    }

private data class TopAction(
    val icon: ImageVector,
    val label: String,
    val badge: Int = 0,
    val onClick: () -> Unit,
)

@Composable
private fun PapriaTopBar(title: String, actions: List<TopAction> = emptyList(), onBack: (() -> Unit)? = null) {
    val palette = LocalPapriaPalette.current
    Surface(
        color = palette.raised,
        contentColor = palette.ink,
        shadowElevation = 0.dp,
        tonalElevation = 0.dp,
        border = BorderStroke(1.dp, palette.line),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .height(if (palette.isEink) einkLength(EINK_TOOLBAR_HEIGHT.toFloat()) else NORMAL_TOOLBAR_HEIGHT.dp)
                .padding(horizontal = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (onBack != null) {
                PapriaIconButton(Icons.AutoMirrored.Rounded.ArrowBack, "返回", onBack)
            }
            Text(
                text = title,
                modifier = Modifier
                    .weight(1f)
                    .padding(start = if (onBack == null) 8.dp else 0.dp),
                color = palette.ink,
                style = MaterialTheme.typography.headlineSmall,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            actions.forEach { action ->
                Box(contentAlignment = Alignment.TopEnd) {
                    PapriaIconButton(action.icon, action.label, action.onClick)
                    if (action.badge > 0) {
                        Text(
                            text = action.badge.coerceAtMost(99).toString(),
                            modifier = Modifier
                                .padding(top = 3.dp, end = 2.dp)
                                .clip(CircleShape)
                                .background(palette.primaryAction)
                                .padding(horizontal = 4.dp, vertical = 1.dp),
                            color = Color.White,
                            style = MaterialTheme.typography.labelMedium,
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun PapriaIconButton(icon: ImageVector, label: String, onClick: () -> Unit, enabled: Boolean = true) {
    val palette = LocalPapriaPalette.current
    IconButton(
        onClick = onClick,
        enabled = enabled,
        modifier = Modifier
            .sizeIn(minWidth = 48.dp, minHeight = 48.dp)
            .semantics { contentDescription = label },
    ) {
        val tint = if (enabled) palette.ink else palette.disabledInk
        Icon(icon, contentDescription = null, tint = tint)
    }
}

@Composable
private fun LibraryScreen(
    viewModel: PapriaViewModel,
    publications: List<LocalPublication>,
    onImport: () -> Unit,
    onOpenPublication: (LocalPublication) -> Unit,
) {
    val palette = LocalPapriaPalette.current
    var searching by rememberSaveable { mutableStateOf(false) }
    var query by rememberSaveable { mutableStateOf("") }
    var readableOnly by rememberSaveable { mutableStateOf(false) }
    var deleteCandidate by remember { mutableStateOf<LocalPublication?>(null) }
    val visibleBooks = publications.filter { publication ->
        val matchesQuery = query.isBlank() || publication.title.contains(query, ignoreCase = true) ||
            publication.author.orEmpty().contains(query, ignoreCase = true)
        matchesQuery && (!readableOnly || publication.localPath != null)
    }
    val continueReading = publications.firstOrNull { it.localPath != null }
    val listState = rememberLazyListState()

    Column(Modifier.fillMaxSize()) {
        PapriaTopBar(
            title = "书库",
            actions = buildList {
                add(TopAction(if (searching) Icons.Rounded.Close else Icons.Rounded.Search, if (searching) "关闭搜索" else "搜索") {
                    if (searching) {
                        query = ""
                        searching = false
                    } else {
                        searching = true
                    }
                })
                if (!palette.isEink) add(TopAction(Icons.Rounded.Tune, "筛选") { readableOnly = !readableOnly })
            },
        )
        if (searching) {
            OutlinedTextField(
                value = query,
                onValueChange = { query = it },
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 8.dp),
                label = { Text("搜索书名或作者") },
                singleLine = true,
                shape = PapriaShape(),
            )
        }
        if (query.isNotBlank() || readableOnly) {
            Column(
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp),
                verticalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                if (query.isNotBlank()) {
                    StatusLabel("搜索结果：${visibleBooks.size} 本", StatusTone.REMOTE)
                }
                if (readableOnly) {
                    Row(
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        StatusLabel("筛选：可阅读文件 · ${visibleBooks.size} 本", StatusTone.REMOTE)
                        TextButton(onClick = { readableOnly = false }, modifier = Modifier.heightIn(min = 48.dp)) { Text("清除") }
                    }
                }
            }
        }
        if (viewModel.connectionMessage.startsWith("导入") || viewModel.connectionMessage.startsWith("文件已导入")) {
            StatusLabel(
                viewModel.connectionMessage,
                if (viewModel.connectionMessage.contains("失败")) StatusTone.ERROR else StatusTone.SUCCESS,
            )
        }
        if (viewModel.bookOrbitOffline) {
            StatusLabel(
                "离线：本地书库仍可使用，远程同步将延后处理。",
                StatusTone.WARNING,
            )
        }
        LazyColumn(
            state = listState,
            modifier = Modifier.fillMaxSize(),
            contentPadding = androidx.compose.foundation.layout.PaddingValues(bottom = 24.dp),
        ) {
            if (continueReading != null && query.isBlank() && !readableOnly) {
                item(key = "continue-reading") {
                    Column {
                        Text(
                            "继续阅读",
                            modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = 20.dp, bottom = 0.dp),
                            color = palette.ink,
                            style = MaterialTheme.typography.titleLarge,
                        )
                        ContinueReadingPanel(
                            publication = continueReading,
                            progress = viewModel.readingProgressFor(continueReading)?.percentage ?: 0.0,
                            page = viewModel.readingProgressFor(continueReading)?.pageNumber,
                            onOpen = { onOpenPublication(continueReading) },
                        )
                    }
                }
            }
            item(key = "library-title") {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(start = 16.dp, end = 16.dp, top = 20.dp, bottom = 8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        when {
                            publications.isEmpty() -> "本地书库"
                            query.isNotBlank() || readableOnly -> "搜索结果"
                            else -> "最近导入"
                        },
                        modifier = Modifier.weight(1f),
                        color = palette.ink,
                        style = MaterialTheme.typography.titleLarge,
                    )
                    Text("${visibleBooks.size} 本", color = palette.secondaryInk, style = MaterialTheme.typography.bodyMedium)
                }
            }
            when {
                publications.isEmpty() -> item(key = "empty-library") {
                    EmptyLibrary(onImport = onImport, onTransfer = { viewModel.setTab(AppTab.TRANSFER) })
                }

                visibleBooks.isEmpty() -> item(key = "empty-search") {
                    Column(Modifier.padding(horizontal = 16.dp, vertical = 32.dp)) {
                        Text("未找到匹配书籍", color = palette.ink, style = MaterialTheme.typography.titleLarge)
                        Spacer(Modifier.height(8.dp))
                        Text("保留搜索词以便调整；可清除搜索或筛选后继续查看。", color = palette.secondaryInk, style = MaterialTheme.typography.bodyMedium)
                        TextButton(onClick = { query = ""; readableOnly = false }, modifier = Modifier.heightIn(min = 48.dp)) { Text("清除搜索与筛选") }
                    }
                }

                else -> items(visibleBooks, key = { it.localId }) { publication ->
                    val readingProgress = viewModel.readingProgressFor(publication)
                    LibraryBookRow(
                        publication = publication,
                        progress = readingProgress?.percentage ?: 0.0,
                        page = readingProgress?.pageNumber,
                        readingProgress = readingProgress,
                        onOpen = { onOpenPublication(publication) },
                        onMore = { deleteCandidate = publication },
                    )
                }
            }
        }
    }

    deleteCandidate?.let { publication ->
        DeletePublicationConfirmation(
            publication = publication,
            onDismiss = { deleteCandidate = null },
            onDelete = {
                viewModel.deletePublication(publication)
                deleteCandidate = null
            },
        )
    }
}

@Composable
private fun ContinueReadingPanel(publication: LocalPublication, progress: Double, page: Int?, onOpen: () -> Unit) {
    val palette = LocalPapriaPalette.current
    Surface(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 8.dp),
        color = palette.raised,
        shadowElevation = 0.dp,
        tonalElevation = 0.dp,
        shape = PapriaShape(),
        border = BorderStroke(if (palette.isEink) 2.dp else 1.dp, if (palette.isEink) palette.ink else palette.line),
    ) {
        Row(
            modifier = Modifier.padding(12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            BookCover(title = publication.title, format = publication.format, modifier = Modifier.size(width = 58.dp, height = 80.dp))
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(publication.title, color = palette.ink, style = MaterialTheme.typography.titleLarge, maxLines = 2, overflow = TextOverflow.Ellipsis)
                Text(publication.author ?: "未知作者", color = palette.secondaryInk, style = MaterialTheme.typography.bodyMedium, maxLines = 1, overflow = TextOverflow.Ellipsis)
                ProgressLine(progress)
                Text(progressText(progress, page), color = palette.secondaryInk, style = MaterialTheme.typography.labelMedium)
            }
            Spacer(Modifier.width(8.dp))
            PapriaPrimaryButton("继续阅读", onOpen, modifier = Modifier.wrapContentHeight())
        }
    }
}

@Composable
private fun EmptyLibrary(onImport: () -> Unit, onTransfer: () -> Unit) {
    val palette = LocalPapriaPalette.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 32.dp, vertical = 36.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Icon(
            Icons.Rounded.LibraryBooks,
            contentDescription = "空书库",
            tint = palette.secondaryInk,
            modifier = Modifier.size(40.dp),
        )
        Text("还没有书籍", color = palette.ink, style = MaterialTheme.typography.titleLarge)
        Text("从文件导入，或使用局域网传书加入本地书库。", color = palette.secondaryInk, style = MaterialTheme.typography.bodyMedium, textAlign = TextAlign.Center)
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            PapriaPrimaryButton("从文件导入", onImport)
            PapriaSecondaryButton("传书", onTransfer)
        }
    }
}

@Composable
private fun LibraryBookRow(
    publication: LocalPublication,
    progress: Double,
    page: Int?,
    readingProgress: ReadingProgressRecord?,
    onOpen: () -> Unit,
    onMore: () -> Unit,
) {
    val palette = LocalPapriaPalette.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(enabled = publication.localPath != null, onClick = onOpen)
            .padding(horizontal = 16.dp, vertical = if (palette.isEink) 8.dp else 12.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            BookCover(title = publication.title, format = publication.format, modifier = Modifier.size(width = 52.dp, height = 72.dp))
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Text(publication.title, color = palette.ink, style = MaterialTheme.typography.bodyLarge, maxLines = 2, overflow = TextOverflow.Ellipsis)
                Text(publication.author ?: "未知作者", color = palette.secondaryInk, style = MaterialTheme.typography.bodyMedium, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(
                    "${publication.format.uppercase(Locale.ROOT)} · ${librarySourceLabel(publication)}",
                    color = palette.secondaryInk,
                    style = MaterialTheme.typography.labelMedium,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
                if (publication.localPath == null) {
                    StatusLabel("文件不可用：未找到本地副本", StatusTone.ERROR)
                } else {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        ProgressLine(progress, Modifier.weight(1f))
                        Text(progressText(progress, page), color = palette.secondaryInk, style = MaterialTheme.typography.labelMedium)
                    }
                    librarySyncStatus(readingProgress)?.let { (label, tone) ->
                        StatusLabel(label, tone)
                    }
                }
            }
            if (palette.isEink) {
                PapriaSecondaryButton("操作", onMore)
            } else {
                PapriaIconButton(Icons.Rounded.MoreVert, "书籍操作", onMore)
            }
        }
        Spacer(Modifier.height(if (palette.isEink) 8.dp else 12.dp))
        PapriaDivider()
    }
}

@Composable
private fun DeletePublicationConfirmation(publication: LocalPublication, onDismiss: () -> Unit, onDelete: () -> Unit) {
    val palette = LocalPapriaPalette.current
    if (palette.isEink) {
        Surface(
            modifier = Modifier.fillMaxWidth().padding(16.dp),
            color = palette.raised,
            border = BorderStroke(2.dp, palette.ink),
            shape = PapriaShape(),
        ) {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text("删除本地副本？", color = palette.ink, style = MaterialTheme.typography.titleLarge)
                Text("将移除《${publication.title}》的本地文件；BookOrbit 远程副本不会被删除。", color = palette.secondaryInk, style = MaterialTheme.typography.bodyMedium)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    PapriaPrimaryButton("确认删除", onDelete)
                    PapriaSecondaryButton("取消", onDismiss)
                }
            }
        }
    } else {
        AlertDialog(
            onDismissRequest = onDismiss,
            title = { Text("删除本地副本？") },
            text = { Text("将移除《${publication.title}》的本地文件；BookOrbit 远程副本不会被删除。") },
            confirmButton = { TextButton(onClick = onDelete) { Text("确认删除") } },
            dismissButton = { TextButton(onClick = onDismiss) { Text("取消") } },
            containerColor = palette.raised,
        )
    }
}

@Composable
private fun BookOrbitScreen(
    viewModel: PapriaViewModel,
    downloads: List<DownloadTaskRecord>,
    publications: List<LocalPublication>,
    context: Context,
    onOpenPublication: (LocalPublication) -> Unit,
) {
    when (viewModel.bookOrbitDestination) {
        BookOrbitDestination.CATALOG -> BookOrbitCatalog(viewModel, downloads, context)
        BookOrbitDestination.DETAIL -> {
            val selected = viewModel.selectedRemoteBook
            if (selected == null) {
                LaunchedEffect(Unit) { viewModel.returnToBookOrbitCatalog() }
            } else {
                BookOrbitDetail(
                    viewModel = viewModel,
                    book = selected,
                    downloads = downloads,
                    publications = publications,
                    context = context,
                    onOpenPublication = onOpenPublication,
                )
            }
        }

        BookOrbitDestination.TASKS -> DownloadTaskCenter(
            viewModel = viewModel,
            downloads = downloads,
            publications = publications,
            context = context,
            onOpenPublication = onOpenPublication,
        )
    }
}

@Composable
private fun BookOrbitCatalog(viewModel: PapriaViewModel, downloads: List<DownloadTaskRecord>, context: Context) {
    val palette = LocalPapriaPalette.current
    var searching by rememberSaveable { mutableStateOf(false) }
    var query by rememberSaveable { mutableStateOf("") }
    var server by rememberSaveable(viewModel.serverAddress) { mutableStateOf(viewModel.serverAddress) }
    var username by rememberSaveable { mutableStateOf("") }
    var password by rememberSaveable { mutableStateOf("") }
    var fingerprint by rememberSaveable { mutableStateOf("") }
    var cleartextConfirmed by rememberSaveable { mutableStateOf(false) }
    val catalogListState = rememberSaveable(saver = androidx.compose.foundation.lazy.LazyListState.Saver) {
        androidx.compose.foundation.lazy.LazyListState()
    }
    val visibleBooks = viewModel.remoteBooks.filter { book ->
        query.isBlank() || book.title.contains(query, ignoreCase = true) || book.author.orEmpty().contains(query, ignoreCase = true)
    }
    val outstanding = downloads.count { it.state != "completed" }
    val isCleartext = remember(server) {
        runCatching { BookOrbitClient(server.trim()).isCleartextHttp() }.getOrDefault(false)
    }

    Column(Modifier.fillMaxSize()) {
        PapriaTopBar(
            title = "BookOrbit",
            actions = listOf(
                TopAction(Icons.Rounded.Download, "下载任务", outstanding) { viewModel.openDownloadTasks() },
                TopAction(if (searching) Icons.Rounded.Close else Icons.Rounded.Search, if (searching) "关闭搜索" else "搜索") {
                    if (searching) {
                        query = ""
                        searching = false
                    } else {
                        searching = true
                    }
                },
            ),
        )
        if (viewModel.bookOrbitOffline) OfflineBanner()
        if (searching && viewModel.remoteBooks.isNotEmpty()) {
            OutlinedTextField(
                value = query,
                onValueChange = { query = it },
                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
                label = { Text("搜索 BookOrbit 书目") },
                singleLine = true,
                shape = PapriaShape(),
            )
        }
        if (viewModel.remoteBooks.isEmpty()) {
            BookOrbitConnectionForm(
                server = server,
                onServerChange = { server = it; cleartextConfirmed = false },
                username = username,
                onUsernameChange = { username = it },
                password = password,
                onPasswordChange = { password = it },
                fingerprint = fingerprint,
                onFingerprintChange = { fingerprint = it },
                isCleartext = isCleartext,
                cleartextConfirmed = cleartextConfirmed,
                onCleartextChange = { cleartextConfirmed = it },
                loading = viewModel.bookOrbitLoading,
                message = viewModel.connectionMessage,
                onConnect = {
                    viewModel.connectBookOrbit(server, username, password, fingerprint, cleartextConfirmed)
                },
            )
        } else {
            Column(Modifier.padding(horizontal = 16.dp, vertical = 10.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                StatusLabel("${serverHost(viewModel.serverAddress)} · ${if (viewModel.bookOrbitOffline) "离线" else if (viewModel.bookOrbitLoading) "正在连接" else "已连接"}", if (viewModel.bookOrbitOffline) StatusTone.WARNING else StatusTone.REMOTE)
                if (viewModel.connectionMessage.isNotBlank()) Text(viewModel.connectionMessage, color = palette.secondaryInk, style = MaterialTheme.typography.bodyMedium)
            }
            LazyColumn(
                state = catalogListState,
                modifier = Modifier.fillMaxSize(),
                contentPadding = androidx.compose.foundation.layout.PaddingValues(bottom = 24.dp),
            ) {
                if (visibleBooks.isEmpty()) {
                    item {
                        Column(Modifier.padding(16.dp)) {
                            Text("未找到匹配书籍", color = palette.ink, style = MaterialTheme.typography.titleLarge)
                            TextButton(onClick = { query = "" }, modifier = Modifier.heightIn(min = 48.dp)) { Text("清除搜索") }
                        }
                    }
                }
                items(visibleBooks, key = { it.id }) { book ->
                    RemoteBookRow(book, viewModel, onOpen = { viewModel.openBookOrbitBook(book) })
                }
            }
        }
    }
}

@Composable
private fun BookOrbitConnectionForm(
    server: String,
    onServerChange: (String) -> Unit,
    username: String,
    onUsernameChange: (String) -> Unit,
    password: String,
    onPasswordChange: (String) -> Unit,
    fingerprint: String,
    onFingerprintChange: (String) -> Unit,
    isCleartext: Boolean,
    cleartextConfirmed: Boolean,
    onCleartextChange: (Boolean) -> Unit,
    loading: Boolean,
    message: String,
    onConnect: () -> Unit,
) {
    val palette = LocalPapriaPalette.current
    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = androidx.compose.foundation.layout.PaddingValues(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        item {
            Text("连接你的 BookOrbit 书库", color = palette.ink, style = MaterialTheme.typography.titleLarge)
            Spacer(Modifier.height(4.dp))
            Text("连接失败不会清空已输入的信息；离线时仅显示已缓存内容。", color = palette.secondaryInk, style = MaterialTheme.typography.bodyMedium)
        }
        item {
            OutlinedTextField(server, onServerChange, Modifier.fillMaxWidth(), label = { Text("服务器 URL") }, singleLine = true, shape = PapriaShape())
        }
        if (isCleartext) item {
            Row(verticalAlignment = Alignment.CenterVertically) {
                PapriaStaticCheckbox(checked = cleartextConfirmed, onCheckedChange = onCleartextChange)
                Text("我已核对当前局域网 HTTP 主机及端口，并明确允许明文连接。", color = palette.secondaryInk, style = MaterialTheme.typography.bodyMedium)
            }
        }
        item {
            OutlinedTextField(username, onUsernameChange, Modifier.fillMaxWidth(), label = { Text("用户名") }, singleLine = true, shape = PapriaShape())
        }
        item {
            OutlinedTextField(password, onPasswordChange, Modifier.fillMaxWidth(), label = { Text("密码") }, singleLine = true, visualTransformation = PasswordVisualTransformation(), shape = PapriaShape())
        }
        item {
            OutlinedTextField(
                fingerprint,
                onFingerprintChange,
                Modifier.fillMaxWidth(),
                label = { Text("已确认的证书 SHA-256 指纹（可选）") },
                supportingText = { Text("仅在你已核对当前主机证书时填写。") },
                singleLine = true,
                shape = PapriaShape(),
            )
        }
        item {
            PapriaPrimaryButton(
                label = if (loading) "正在连接" else "连接并登录",
                onClick = onConnect,
                enabled = !loading && server.isNotBlank() && username.isNotBlank() && password.isNotBlank() && (!isCleartext || cleartextConfirmed),
            )
        }
        if (message.isNotBlank()) item {
            StatusLabel(message, if (message.startsWith("连接失败")) StatusTone.ERROR else StatusTone.REMOTE)
        }
    }
}

@Composable
private fun RemoteBookRow(book: RemoteBookPayload, viewModel: PapriaViewModel, onOpen: () -> Unit) {
    val palette = LocalPapriaPalette.current
    LaunchedEffect(book.id) { viewModel.loadCover(book.id) }
    val cachedCover = viewModel.cover(book.id)
    val coverFile = if (palette.isEink) cachedCover?.binary ?: cachedCover?.gray else cachedCover?.color
    val coverBitmap = remember(coverFile?.absolutePath) { coverFile?.let { BitmapFactory.decodeFile(it.absolutePath) } }
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onOpen)
            .padding(horizontal = 16.dp, vertical = 12.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            BookCover(book.title, "BookOrbit", Modifier.size(width = 56.dp, height = 78.dp), coverBitmap)
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(book.title, color = palette.ink, style = MaterialTheme.typography.bodyLarge, maxLines = 2, overflow = TextOverflow.Ellipsis)
                Text(book.author ?: "未知作者", color = palette.secondaryInk, style = MaterialTheme.typography.bodyMedium, maxLines = 1, overflow = TextOverflow.Ellipsis)
                StatusLabel(if (book.files.isEmpty()) "远程书籍 · 读取文件详情" else "远程书籍 · ${book.files.size} 个文件", StatusTone.REMOTE)
            }
            Text("›", color = palette.secondaryInk, fontSize = 28.sp)
        }
        Spacer(Modifier.height(12.dp))
        PapriaDivider()
    }
}

@Composable
private fun BookOrbitDetail(
    viewModel: PapriaViewModel,
    book: RemoteBookPayload,
    downloads: List<DownloadTaskRecord>,
    publications: List<LocalPublication>,
    context: Context,
    onOpenPublication: (LocalPublication) -> Unit,
) {
    val palette = LocalPapriaPalette.current
    val outstanding = downloads.count { it.state != "completed" }
    val queuedPositions = queuedTaskPositions(downloads)
    var pendingDeviceRemoval by remember { mutableStateOf<RemoteFilePayload?>(null) }
    val cachedCover = viewModel.cover(book.id)
    val coverFile = if (palette.isEink) cachedCover?.binary ?: cachedCover?.gray else cachedCover?.color
    val coverBitmap = remember(coverFile?.absolutePath) { coverFile?.let { BitmapFactory.decodeFile(it.absolutePath) } }
    LaunchedEffect(book.id) { viewModel.loadCover(book.id) }

    Column(Modifier.fillMaxSize()) {
        PapriaTopBar(
            title = "BookOrbit",
            onBack = viewModel::returnToBookOrbitCatalog,
            actions = listOf(TopAction(Icons.Rounded.Download, "下载任务", outstanding) { viewModel.openDownloadTasks() }),
        )
        if (viewModel.bookOrbitOffline) OfflineBanner()
        LazyColumn(
            modifier = Modifier.fillMaxSize(),
            contentPadding = androidx.compose.foundation.layout.PaddingValues(bottom = 16.dp),
        ) {
            item {
                Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    StatusLabel("${serverHost(viewModel.serverAddress)} · ${if (viewModel.bookOrbitOffline) "离线" else if (viewModel.bookOrbitLoading) "正在连接" else "已连接"}", if (viewModel.bookOrbitOffline) StatusTone.WARNING else StatusTone.REMOTE)
                    Row(verticalAlignment = Alignment.Top) {
                        BookCover(book.title, "BookOrbit", Modifier.size(width = 108.dp, height = 150.dp), coverBitmap)
                        Spacer(Modifier.width(16.dp))
                        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                            Text(book.title, color = palette.ink, style = MaterialTheme.typography.titleLarge, maxLines = 2, overflow = TextOverflow.Ellipsis)
                            Text(book.author ?: "未知作者", color = palette.secondaryInk, style = MaterialTheme.typography.bodyMedium)
                            StatusLabel(if (viewModel.bookOrbitOffline) "已缓存书目" else "远程书籍", StatusTone.REMOTE)
                        }
                    }
                }
                PapriaDivider()
            }
            if (viewModel.bookOrbitLoading && book.files.isEmpty()) {
                item { StaticLoading("正在载入文件列表") }
            } else if (book.files.isEmpty()) {
                item {
                    Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text(
                            if (viewModel.bookOrbitOffline) "离线：未缓存文件详情" else "暂无可下载文件",
                            color = palette.ink,
                            style = MaterialTheme.typography.titleLarge,
                        )
                        if (viewModel.bookOrbitOffline) {
                            Text(
                                "恢复连接后可读取该书的文件列表；已缓存的本地书籍仍可在书库中打开。",
                                color = palette.secondaryInk,
                                style = MaterialTheme.typography.bodyMedium,
                            )
                        }
                        if (!viewModel.bookOrbitOffline) PapriaPrimaryButton("读取文件列表", onClick = { viewModel.loadBook(book.id) })
                    }
                }
            } else {
                item { Text("文件", Modifier.padding(horizontal = 16.dp, vertical = 12.dp), color = palette.ink, style = MaterialTheme.typography.titleLarge) }
                items(book.files, key = { it.id }) { file ->
                    val task = downloads.firstOrNull { it.fileId == file.id }
                    BookOrbitFileRow(
                        file = file,
                        task = task,
                        offline = viewModel.bookOrbitOffline,
                        onlyWifi = task?.let { viewModel.waitsForWifi(it.fileId) } ?: viewModel.onlyWifiDownloads,
                        queuePosition = task?.let { queuedPositions[it.fileId] },
                        speedBytesPerSecond = task?.let { viewModel.downloadRate(it.fileId) },
                        onDownload = { viewModel.enqueueDownload(context, file.id) },
                        onPause = { viewModel.pauseDownload(context, file.id) },
                        onRetry = { viewModel.retryDownload(context, file.id) },
                        onRemove = { viewModel.removeDownload(file.id) },
                        onOpen = { publications.firstOrNull { it.remoteFileId == file.id }?.let(onOpenPublication) },
                        onRemoveDevice = publications.firstOrNull { it.remoteFileId == file.id }?.let {
                            { pendingDeviceRemoval = file }
                        },
                        onAudio = if (isAudioFile(file)) ({ viewModel.playRemoteAudio(context, book.id, file, book.files) }) else null,
                    )
                }
            }
            item {
                val running = downloads.count { it.state == "running" }
                val waiting = downloads.count { it.state == "queued" }
                val waitingWifi = downloads.count { it.state == "queued" && viewModel.waitsForWifi(it.fileId) }
                if (running > 0 || waiting > 0) {
                    Text(
                        taskSummary(running, waiting, waitingWifi),
                        modifier = Modifier.padding(16.dp),
                        color = palette.secondaryInk,
                        style = MaterialTheme.typography.bodyMedium,
                    )
                }
            }
        }
    }
    pendingDeviceRemoval?.let { file ->
        RemoveDownloadedFileConfirmation(
            fileName = file.fileName,
            onDismiss = { pendingDeviceRemoval = null },
            onConfirm = {
                viewModel.removeDownloadedFile(context, file.id)
                pendingDeviceRemoval = null
            },
        )
    }
}

@Composable
private fun BookOrbitFileRow(
    file: RemoteFilePayload,
    task: DownloadTaskRecord?,
    offline: Boolean,
    onlyWifi: Boolean,
    queuePosition: Int?,
    speedBytesPerSecond: Long?,
    onDownload: () -> Unit,
    onPause: () -> Unit,
    onRetry: () -> Unit,
    onRemove: () -> Unit,
    onOpen: () -> Unit,
    onRemoveDevice: (() -> Unit)?,
    onAudio: (() -> Unit)?,
) {
    val palette = LocalPapriaPalette.current
    val progress = task?.let { downloadProgress(it) } ?: 0.0
    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(file.fileName, color = palette.ink, style = MaterialTheme.typography.bodyLarge, maxLines = 2, overflow = TextOverflow.Ellipsis)
        Text("${file.format.uppercase(Locale.ROOT)} · ${formatBytes(file.sizeBytes)}", color = palette.secondaryInk, style = MaterialTheme.typography.bodyMedium)
        when (task?.state) {
            "running" -> {
                StatusLabel("下载中 ${percent(progress)} · ${formatBytes(task.offsetBytes)} / ${formatBytes(task.totalBytes)} · ${formatDownloadRate(speedBytesPerSecond)}", StatusTone.REMOTE)
                ProgressLine(progress)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    PapriaSecondaryButton("暂停", onPause)
                    PapriaSecondaryButton("取消", onRemove)
                }
            }

            "queued" -> {
                StatusLabel(queueStatusLabel(queuePosition, onlyWifi), StatusTone.WARNING)
                Text("${formatBytes(task.offsetBytes)} / ${formatBytes(task.totalBytes)}", color = palette.secondaryInk, style = MaterialTheme.typography.bodyMedium)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) { PapriaSecondaryButton("取消", onRemove) }
            }

            "paused" -> {
                StatusLabel("已暂停", StatusTone.WARNING)
                Text("${formatBytes(task.offsetBytes)} / ${formatBytes(task.totalBytes)}", color = palette.secondaryInk, style = MaterialTheme.typography.bodyMedium)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    PapriaPrimaryButton("继续", onRetry)
                    PapriaSecondaryButton("取消", onRemove)
                }
            }

            "failed" -> {
                StatusLabel("失败：${task.error ?: "下载未完成"}", StatusTone.ERROR)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    PapriaPrimaryButton("重试", onRetry)
                    PapriaSecondaryButton("删除", onRemove)
                }
            }

            "completed" -> {
                StatusLabel("已下载", StatusTone.SUCCESS)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    PapriaPrimaryButton("打开", onOpen)
                    onRemoveDevice?.let { PapriaSecondaryButton("从设备移除", it) }
                }
            }

            else -> {
                StatusLabel(
                    if (offline) "等待网络" else if (onlyWifi) "可加入仅 Wi-Fi 队列" else "可下载",
                    if (offline || onlyWifi) StatusTone.WARNING else StatusTone.REMOTE,
                )
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    PapriaPrimaryButton(if (offline) "等待网络" else "下载", onDownload, enabled = !offline)
                    onAudio?.let { PapriaSecondaryButton("播放", it) }
                }
            }
        }
        Spacer(Modifier.height(6.dp))
        PapriaDivider()
    }
}

@Composable
private fun DownloadTaskCenter(
    viewModel: PapriaViewModel,
    downloads: List<DownloadTaskRecord>,
    publications: List<LocalPublication>,
    context: Context,
    onOpenPublication: (LocalPublication) -> Unit,
) {
    val palette = LocalPapriaPalette.current
    var pendingDeviceRemoval by remember { mutableStateOf<Pair<Long, String>?>(null) }
    var showClearCompletedConfirmation by remember { mutableStateOf(false) }
    val hasUnfinishedDownloads = downloads.any { it.state != "completed" }
    val queuedPositions = queuedTaskPositions(downloads)
    Column(Modifier.fillMaxSize()) {
        PapriaTopBar(
            title = "下载任务",
            onBack = viewModel::returnFromDownloadTasks,
            actions = if (palette.isEink) {
                emptyList()
            } else {
                listOf(TopAction(Icons.Rounded.Delete, "清除已完成") {
                    if (hasUnfinishedDownloads) showClearCompletedConfirmation = true else viewModel.clearCompletedDownloads()
                })
            },
        )
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(Modifier.weight(1f)) {
                Text("仅 Wi-Fi 下载", color = palette.ink, style = MaterialTheme.typography.bodyLarge)
                Text("无 Wi-Fi 时任务会显示为等待状态。", color = palette.secondaryInk, style = MaterialTheme.typography.bodyMedium)
            }
            PapriaDownloadToggle(viewModel.onlyWifiDownloads, viewModel::updateOnlyWifiDownloads)
        }
        PapriaDivider()
        LazyColumn(
            modifier = Modifier.fillMaxSize(),
            contentPadding = androidx.compose.foundation.layout.PaddingValues(bottom = 16.dp),
        ) {
            if (downloads.isEmpty()) item {
                Column(Modifier.fillMaxWidth().padding(32.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                    Text("暂无下载任务", color = palette.ink, style = MaterialTheme.typography.titleLarge)
                    Text("从 BookOrbit 书籍详情加入下载任务。", color = palette.secondaryInk, style = MaterialTheme.typography.bodyMedium)
                }
            }
            items(downloads, key = { it.fileId }) { task ->
                val remoteFile = viewModel.remoteBooks.flatMap { it.files }.firstOrNull { it.id == task.fileId }
                DownloadTaskRow(
                    task = task,
                    filename = remoteFile?.fileName ?: "文件 ${task.fileId}",
                    format = remoteFile?.format,
                    onlyWifi = viewModel.waitsForWifi(task.fileId),
                    queuePosition = queuedPositions[task.fileId],
                    speedBytesPerSecond = viewModel.downloadRate(task.fileId),
                    onPause = { viewModel.pauseDownload(context, task.fileId) },
                    onRetry = { viewModel.retryDownload(context, task.fileId) },
                    onDelete = { viewModel.removeDownload(task.fileId) },
                    onOpen = { publications.firstOrNull { it.remoteFileId == task.fileId }?.let(onOpenPublication) },
                    onRemoveDevice = {
                        val fileName = remoteFile?.fileName ?: "文件 ${task.fileId}"
                        pendingDeviceRemoval = task.fileId to fileName
                    },
                )
            }
        }
    }
    pendingDeviceRemoval?.let { (fileId, filename) ->
        RemoveDownloadedFileConfirmation(
            fileName = filename,
            onDismiss = { pendingDeviceRemoval = null },
            onConfirm = {
                viewModel.removeDownloadedFile(context, fileId)
                pendingDeviceRemoval = null
            },
        )
    }
    if (showClearCompletedConfirmation) {
        ClearCompletedDownloadsConfirmation(
            onDismiss = { showClearCompletedConfirmation = false },
            onConfirm = {
                viewModel.clearCompletedDownloads()
                showClearCompletedConfirmation = false
            },
        )
    }
}

@Composable
private fun DownloadTaskRow(
    task: DownloadTaskRecord,
    filename: String,
    format: String?,
    onlyWifi: Boolean,
    queuePosition: Int?,
    speedBytesPerSecond: Long?,
    onPause: () -> Unit,
    onRetry: () -> Unit,
    onDelete: () -> Unit,
    onOpen: () -> Unit,
    onRemoveDevice: () -> Unit,
) {
    val palette = LocalPapriaPalette.current
    val progress = downloadProgress(task)
    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 14.dp), verticalArrangement = Arrangement.spacedBy(7.dp)) {
        Text(filename, color = palette.ink, style = MaterialTheme.typography.bodyLarge, maxLines = 2, overflow = TextOverflow.Ellipsis)
        Text(
            "${format?.uppercase(Locale.ROOT) ?: "格式未缓存"} · ${formatBytes(task.totalBytes)}",
            color = palette.secondaryInk,
            style = MaterialTheme.typography.bodyMedium,
        )
        when (task.state) {
            "running" -> {
                StatusLabel("下载中 ${percent(progress)}", StatusTone.REMOTE)
                Text("${formatBytes(task.offsetBytes)} / ${formatBytes(task.totalBytes)} · ${formatDownloadRate(speedBytesPerSecond)}", color = palette.secondaryInk, style = MaterialTheme.typography.bodyMedium)
                ProgressLine(progress)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    PapriaSecondaryButton("暂停", onPause)
                    PapriaSecondaryButton("取消", onDelete)
                }
            }

            "queued" -> {
                StatusLabel(queueStatusLabel(queuePosition, onlyWifi), StatusTone.WARNING)
                Text("${formatBytes(task.offsetBytes)} / ${formatBytes(task.totalBytes)}", color = palette.secondaryInk, style = MaterialTheme.typography.bodyMedium)
                PapriaSecondaryButton("取消", onDelete)
            }

            "paused" -> {
                StatusLabel("已暂停", StatusTone.WARNING)
                Text("已下载 ${formatBytes(task.offsetBytes)}", color = palette.secondaryInk, style = MaterialTheme.typography.bodyMedium)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    PapriaPrimaryButton("继续", onRetry)
                    PapriaSecondaryButton("取消", onDelete)
                }
            }

            "failed" -> {
                StatusLabel("失败：${task.error ?: "网络或存储空间不可用"}", StatusTone.ERROR)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    PapriaPrimaryButton("重试", onRetry)
                    PapriaSecondaryButton("删除", onDelete)
                }
            }

            "completed" -> {
                StatusLabel("已完成${format?.let { " · ${it.uppercase(Locale.ROOT)}" } ?: ""}", StatusTone.SUCCESS)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    PapriaPrimaryButton("打开", onOpen)
                    PapriaSecondaryButton("从设备移除", onRemoveDevice)
                }
            }

            else -> StatusLabel("等待网络", StatusTone.WARNING)
        }
        PapriaDivider()
    }
}

@Composable
private fun TransferScreen(viewModel: PapriaViewModel, publications: List<LocalPublication>, context: Context) {
    val palette = LocalPapriaPalette.current
    val view = LocalView.current
    val activity = view.context as? Activity
    var showStopConfirmation by remember { mutableStateOf(false) }
    DisposableEffect(viewModel.wifiRunning) {
        if (viewModel.wifiRunning) activity?.window?.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        onDispose { activity?.window?.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON) }
    }
    val activeUpload = viewModel.wifiUploads.any { upload ->
        upload.lifecycle in setOf(
            WifiTransferUploadLifecycle.RECEIVING,
            WifiTransferUploadLifecycle.VALIDATING,
            WifiTransferUploadLifecycle.IMPORTING,
        )
    }

    Column(Modifier.fillMaxSize()) {
        PapriaTopBar(title = "传书")
        LazyColumn(
            modifier = Modifier.fillMaxSize(),
            contentPadding = androidx.compose.foundation.layout.PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            item {
                Text(if (viewModel.wifiRunning) "传书服务运行中" else "Wi-Fi 传书", color = palette.ink, style = MaterialTheme.typography.titleLarge)
                Spacer(Modifier.height(4.dp))
                Text(if (viewModel.wifiRunning) "${wifiName(context)} · 保持此页面打开" else "启动临时局域网接收服务，地址只在当前会话有效。", color = palette.secondaryInk, style = MaterialTheme.typography.bodyMedium)
            }
            if (!viewModel.wifiRunning) {
                item { PapriaPrimaryButton("启动传书", onClick = { viewModel.startWifiTransfer(context) }) }
            } else {
                val address = viewModel.wifiUrl
                if (address != null) {
                    item {
                        createQrCode(address)?.let { bitmap ->
                            Surface(
                                modifier = Modifier.fillMaxWidth(),
                                color = Color.White,
                                shape = PapriaShape(),
                                border = BorderStroke(if (palette.isEink) 1.dp else 1.dp, palette.line),
                            ) {
                                Image(
                                    bitmap = bitmap.asImageBitmap(),
                                    contentDescription = "Wi-Fi 传书二维码",
                                    modifier = Modifier.fillMaxWidth().height(if (palette.isEink) 260.dp else 220.dp).padding(16.dp),
                                    contentScale = ContentScale.Fit,
                                )
                            }
                        }
                    }
                    item {
                        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            Text("局域网地址", color = palette.ink, style = MaterialTheme.typography.titleLarge)
                            SelectionContainer {
                                Text(
                                    address,
                                    modifier = Modifier.semantics {
                                        contentDescription = "局域网地址：$address。可长按选择或复制。"
                                    },
                                    color = palette.ink,
                                    style = if (palette.isEink) MaterialTheme.typography.bodyLarge else MaterialTheme.typography.bodyMedium,
                                    fontFamily = FontFamily.Monospace,
                                )
                            }
                            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                PapriaSecondaryButton("复制地址", onClick = { copyAddress(context, address) })
                                PapriaSecondaryButton("朗读地址", onClick = {
                                    view.announceForAccessibility("局域网地址：$address")
                                })
                            }
                        }
                    }
                } else {
                    item { StaticLoading("正在生成局域网地址") }
                }
                item { PapriaSecondaryButton("停止服务", onClick = { showStopConfirmation = true }) }
            }
            item {
                Text("传输列表", color = palette.ink, style = MaterialTheme.typography.titleLarge)
                Spacer(Modifier.height(6.dp))
                when {
                    !viewModel.wifiRunning -> Text("启动服务后会显示当前会话的真实上传状态。", color = palette.secondaryInk, style = MaterialTheme.typography.bodyMedium)
                    viewModel.wifiUploads.isEmpty() -> StatusLabel("等待上传", StatusTone.REMOTE)
                }
            }
            items(viewModel.wifiUploads, key = { it.uploadId }) { upload ->
                WifiTransferUploadRow(
                    upload = upload,
                    onCancel = { viewModel.cancelWifiUpload(upload.uploadId) },
                    onOpenLibrary = { viewModel.setTab(AppTab.LIBRARY) },
                )
            }
            if (viewModel.wifiMessage.isNotBlank()) item {
                StatusLabel(viewModel.wifiMessage, if (viewModel.wifiMessage.contains("失败")) StatusTone.ERROR else StatusTone.REMOTE)
            }
        }
    }

    if (showStopConfirmation) {
        StopTransferConfirmation(
            hasActiveUpload = activeUpload,
            onDismiss = { showStopConfirmation = false },
            onStop = {
                viewModel.stopWifiTransfer(context)
                showStopConfirmation = false
            },
        )
    }
}

@Composable
private fun StopTransferConfirmation(hasActiveUpload: Boolean, onDismiss: () -> Unit, onStop: () -> Unit) {
    val palette = LocalPapriaPalette.current
    val message = if (hasActiveUpload) {
        "当前有上传正在进行，停止后将中断传输。"
    } else {
        "停止后，当前局域网地址将失效。"
    }
    if (palette.isEink) {
        Surface(
            modifier = Modifier.fillMaxWidth().padding(16.dp),
            color = palette.raised,
            border = BorderStroke(2.dp, palette.ink),
            shape = PapriaShape(),
        ) {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text("停止传书服务？", color = palette.ink, style = MaterialTheme.typography.titleLarge)
                Text(message, color = palette.secondaryInk, style = MaterialTheme.typography.bodyMedium)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    PapriaPrimaryButton("确认停止", onStop)
                    PapriaSecondaryButton("取消", onDismiss)
                }
            }
        }
    } else {
        AlertDialog(
            onDismissRequest = onDismiss,
            title = { Text("停止传书服务？") },
            text = { Text(message) },
            confirmButton = { TextButton(onClick = onStop) { Text("确认停止") } },
            dismissButton = { TextButton(onClick = onDismiss) { Text("取消") } },
            containerColor = palette.raised,
        )
    }
}

@Composable
private fun WifiTransferUploadRow(
    upload: WifiTransferUploadSnapshot,
    onCancel: () -> Unit,
    onOpenLibrary: () -> Unit,
) {
    val palette = LocalPapriaPalette.current
    val progress = if (upload.totalBytes > 0) upload.receivedBytes.toDouble() / upload.totalBytes else 0.0
    Column(
        modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Text(upload.fileName, color = palette.ink, style = MaterialTheme.typography.bodyLarge, maxLines = 2, overflow = TextOverflow.Ellipsis)
        when (upload.lifecycle) {
            WifiTransferUploadLifecycle.RECEIVING -> {
                StatusLabel("上传中 ${percent(progress)}", StatusTone.REMOTE)
                Text("${formatBytes(upload.receivedBytes)} / ${formatBytes(upload.totalBytes)}", color = palette.secondaryInk, style = MaterialTheme.typography.bodyMedium)
                ProgressLine(progress)
                PapriaSecondaryButton("取消", onCancel)
            }
            WifiTransferUploadLifecycle.VALIDATING,
            WifiTransferUploadLifecycle.IMPORTING -> {
                StatusLabel("正在导入", StatusTone.REMOTE)
                Text("${formatBytes(upload.receivedBytes)} / ${formatBytes(upload.totalBytes)}", color = palette.secondaryInk, style = MaterialTheme.typography.bodyMedium)
                ProgressLine(progress)
                if (upload.lifecycle == WifiTransferUploadLifecycle.VALIDATING) PapriaSecondaryButton("取消", onCancel)
            }
            WifiTransferUploadLifecycle.COMPLETED -> {
                StatusLabel("已加入书库", StatusTone.SUCCESS)
                Text("${formatBytes(upload.totalBytes)}", color = palette.secondaryInk, style = MaterialTheme.typography.bodyMedium)
                PapriaPrimaryButton("查看书库", onOpenLibrary)
            }
            WifiTransferUploadLifecycle.FAILED -> {
                StatusLabel("失败：${upload.error ?: "导入未完成"}", StatusTone.ERROR)
                Text("请在传书浏览器中重新选择文件后重试。", color = palette.secondaryInk, style = MaterialTheme.typography.bodyMedium)
                PapriaSecondaryButton("移除", onCancel)
            }
            WifiTransferUploadLifecycle.CANCELLED -> StatusLabel("已取消", StatusTone.WARNING)
            WifiTransferUploadLifecycle.IDLE -> StatusLabel("等待上传", StatusTone.REMOTE)
        }
        PapriaDivider()
    }
}

@Composable
private fun RemoveDownloadedFileConfirmation(fileName: String, onDismiss: () -> Unit, onConfirm: () -> Unit) {
    val palette = LocalPapriaPalette.current
    val body = "将从此设备移除“$fileName”的本地副本。BookOrbit 中的远程文件不会受影响。"
    if (palette.isEink) {
        Surface(
            modifier = Modifier.fillMaxWidth().padding(16.dp),
            color = palette.raised,
            border = BorderStroke(2.dp, palette.ink),
            shape = PapriaShape(),
        ) {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text("从设备移除？", color = palette.ink, style = MaterialTheme.typography.titleLarge)
                Text(body, color = palette.secondaryInk, style = MaterialTheme.typography.bodyMedium)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    PapriaPrimaryButton("确认移除", onConfirm)
                    PapriaSecondaryButton("取消", onDismiss)
                }
            }
        }
    } else {
        AlertDialog(
            onDismissRequest = onDismiss,
            title = { Text("从设备移除？") },
            text = { Text(body) },
            confirmButton = { TextButton(onClick = onConfirm) { Text("确认移除") } },
            dismissButton = { TextButton(onClick = onDismiss) { Text("取消") } },
            containerColor = palette.raised,
        )
    }
}

@Composable
private fun ClearCompletedDownloadsConfirmation(onDismiss: () -> Unit, onConfirm: () -> Unit) {
    val palette = LocalPapriaPalette.current
    val message = "队列中仍有未完成下载。清除已完成任务不会取消这些下载。"
    if (palette.isEink) {
        Column(Modifier.fillMaxWidth().padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text("清除已完成任务？", color = palette.ink, style = MaterialTheme.typography.titleLarge)
            Text(message, color = palette.secondaryInk, style = MaterialTheme.typography.bodyMedium)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                PapriaPrimaryButton("确认清除", onConfirm)
                PapriaSecondaryButton("取消", onDismiss)
            }
        }
    } else {
        AlertDialog(
            onDismissRequest = onDismiss,
            title = { Text("清除已完成任务？") },
            text = { Text(message) },
            confirmButton = { TextButton(onClick = onConfirm) { Text("确认清除") } },
            dismissButton = { TextButton(onClick = onDismiss) { Text("取消") } },
            containerColor = palette.raised,
        )
    }
}

@Composable
private fun SettingsScreen(viewModel: PapriaViewModel, context: Context) {
    val palette = LocalPapriaPalette.current
    var pendingResolution by remember { mutableStateOf<ConflictResolution?>(null) }
    var resolutionMessage by rememberSaveable { mutableStateOf("") }
    var editingServer by rememberSaveable { mutableStateOf(false) }
    var showingDisconnectConfirmation by rememberSaveable { mutableStateOf(false) }
    val visibleResolutionMessage = viewModel.conflictResolutionMessage ?: resolutionMessage
    Column(Modifier.fillMaxSize()) {
        PapriaTopBar(title = "设置")
        if (viewModel.bookOrbitOffline) OfflineBanner()
        LazyColumn(
            modifier = Modifier.fillMaxSize(),
            contentPadding = androidx.compose.foundation.layout.PaddingValues(bottom = 24.dp),
        ) {
            item { SettingsHeader("BookOrbit 服务器") }
            item {
                SettingsRow(
                    title = if (viewModel.serverAddress.isBlank()) "尚未连接服务器" else serverHost(viewModel.serverAddress),
                    detail = when {
                        viewModel.bookOrbitOffline -> "账号：${viewModel.serverUsername ?: "未记录"} · 离线：仅显示已缓存内容"
                        viewModel.serverAddress.isBlank() -> "前往 BookOrbit 登录"
                        else -> "账号：${viewModel.serverUsername ?: "未记录"} · 已连接"
                    },
                    action = if (viewModel.serverAddress.isBlank()) "登录" else "编辑",
                    onAction = { editingServer = true },
                )
            }
            if (viewModel.serverAddress.isNotBlank() || viewModel.remoteBooks.isNotEmpty()) {
                item {
                    Column(
                        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
                        verticalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        Text(
                            if (viewModel.bookOrbitOffline) "已保存离线书目；需要网络的操作会等待连接。" else "登录信息已保存，可重新登录或退出当前服务器。",
                            color = palette.secondaryInk,
                            style = MaterialTheme.typography.bodyMedium,
                        )
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            PapriaSecondaryButton("重新登录", { editingServer = true })
                            PapriaSecondaryButton("退出 BookOrbit", { showingDisconnectConfirmation = true })
                        }
                    }
                }
            }
            if (editingServer) {
                item {
                    BookOrbitServerEditor(
                        viewModel = viewModel,
                        onDismiss = { editingServer = false },
                        onConnected = { editingServer = false },
                    )
                }
            }
            item { PapriaDivider() }
            item { SettingsHeader("阅读显示") }
            item {
                Column(Modifier.padding(horizontal = 16.dp, vertical = 10.dp)) {
                    Text("显示模式", color = palette.ink, style = MaterialTheme.typography.bodyLarge)
                    Text("水墨屏模式采用静态黑白界面、单列列表与分页阅读。", color = palette.secondaryInk, style = MaterialTheme.typography.bodyMedium)
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        DisplayModeOption("普通", DisplayMode.NORMAL, viewModel.selectedDisplayMode, viewModel::setDisplayMode)
                        DisplayModeOption("水墨屏", DisplayMode.EINK, viewModel.selectedDisplayMode, viewModel::setDisplayMode)
                    }
                }
            }
            item { PapriaDivider() }
            item { SettingsHeader("下载与存储") }
            item {
                Row(
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(Modifier.weight(1f)) {
                        Text("仅 Wi-Fi 下载", color = palette.ink, style = MaterialTheme.typography.bodyLarge)
                        Text(
                            viewModel.storageSummary?.let { summary ->
                                "已用 ${formatBytes(summary.usedBytes)} · 可用 ${formatBytes(summary.freeBytes)}"
                            } ?: "正在读取存储信息",
                            color = palette.secondaryInk,
                            style = MaterialTheme.typography.bodyMedium,
                        )
                    }
                    PapriaDownloadToggle(viewModel.onlyWifiDownloads, viewModel::updateOnlyWifiDownloads)
                }
            }
            item { PapriaDivider() }
            item { SettingsHeader("同步") }
            item {
                val successfulSyncTime = viewModel.lastSuccessfulSyncAt?.let { timestamp ->
                    "成功同步时间：${formatTime(timestamp)}"
                } ?: "成功同步时间：未提供（当前设备没有已记录的成功同步结果）"
                SettingsRow(
                    title = "阅读进度同步",
                    detail = if (viewModel.conflicts.isEmpty()) {
                        "没有待处理的本地/服务器进度冲突 · $successfulSyncTime"
                    } else {
                        "${viewModel.conflicts.size} 个未处理冲突 · $successfulSyncTime"
                    },
                    action = "立即同步",
                    onAction = { viewModel.scheduleSync(context) },
                )
            }
            if (viewModel.conflicts.isNotEmpty()) {
                items(viewModel.conflicts, key = { "${it.kind}-${it.key}" }) { conflict ->
                    SyncConflictPanel(
                        conflict = conflict,
                        onKeepLocal = { pendingResolution = ConflictResolution(conflict, true) },
                        onUseServer = { pendingResolution = ConflictResolution(conflict, false) },
                        onLater = { resolutionMessage = "已保留冲突，稍后可继续处理。" },
                    )
                }
            }
            item { PapriaDivider() }
            item { SettingsHeader("关于") }
            item {
                SettingsRow(
                    title = "Papria 0.1.0",
                    detail = "阅读、下载、同步与传书的业务协议保持不变。",
                    action = null,
                    onAction = {},
                )
            }
            if (visibleResolutionMessage.isNotBlank()) item {
                Column(Modifier.padding(horizontal = 16.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    StatusLabel(
                        visibleResolutionMessage,
                        if (visibleResolutionMessage.startsWith("处理冲突失败") || visibleResolutionMessage.startsWith("撤销失败")) StatusTone.ERROR else StatusTone.SUCCESS,
                    )
                    if (viewModel.lastResolvedConflict != null) PapriaSecondaryButton("撤销", viewModel::undoConflictResolution)
                }
            }
        }
    }
    pendingResolution?.let { resolution ->
        ConflictResolutionConfirmation(
            resolution = resolution,
            onDismiss = { pendingResolution = null },
            onConfirm = {
                viewModel.resolveConflict(resolution.conflict, resolution.keepLocal)
                resolutionMessage = ""
                pendingResolution = null
            },
        )
    }
    if (showingDisconnectConfirmation) {
        BookOrbitDisconnectConfirmation(
            onDismiss = { showingDisconnectConfirmation = false },
            onConfirm = { retain ->
                showingDisconnectConfirmation = false
                viewModel.disconnectBookOrbit(retain)
            },
        )
    }
}

@Composable
private fun BookOrbitServerEditor(
    viewModel: PapriaViewModel,
    onDismiss: () -> Unit,
    onConnected: () -> Unit,
) {
    val palette = LocalPapriaPalette.current
    var server by rememberSaveable(viewModel.serverAddress) { mutableStateOf(viewModel.serverAddress) }
    var username by rememberSaveable(viewModel.serverUsername) { mutableStateOf(viewModel.serverUsername.orEmpty()) }
    var password by rememberSaveable { mutableStateOf("") }
    var fingerprint by rememberSaveable(viewModel.serverCertificateSha256) { mutableStateOf(viewModel.serverCertificateSha256.orEmpty()) }
    var cleartextConfirmed by rememberSaveable { mutableStateOf(false) }
    val isCleartext = remember(server) { runCatching { BookOrbitClient(server.trim()).isCleartextHttp() }.getOrDefault(false) }
    Surface(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
        color = palette.raised,
        border = BorderStroke(if (palette.isEink) 2.dp else 1.dp, palette.line),
        shape = PapriaShape(),
        shadowElevation = 0.dp,
    ) {
        Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("编辑 BookOrbit 服务器", color = palette.ink, style = MaterialTheme.typography.titleLarge)
            Text("重新登录需要输入密码；密码不会保存到本地。", color = palette.secondaryInk, style = MaterialTheme.typography.bodyMedium)
            OutlinedTextField(server, { server = it; cleartextConfirmed = false }, Modifier.fillMaxWidth(), label = { Text("服务器 URL") }, singleLine = true, shape = PapriaShape())
            OutlinedTextField(username, { username = it }, Modifier.fillMaxWidth(), label = { Text("用户名") }, singleLine = true, shape = PapriaShape())
            OutlinedTextField(password, { password = it }, Modifier.fillMaxWidth(), label = { Text("密码") }, singleLine = true, visualTransformation = PasswordVisualTransformation(), shape = PapriaShape())
            OutlinedTextField(fingerprint, { fingerprint = it }, Modifier.fillMaxWidth(), label = { Text("已确认的证书 SHA-256 指纹（可选）") }, singleLine = true, shape = PapriaShape())
            if (isCleartext) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    PapriaStaticCheckbox(cleartextConfirmed, { cleartextConfirmed = it })
                    Text("我已核对当前局域网 HTTP 主机及端口，并明确允许明文连接。", color = palette.secondaryInk, style = MaterialTheme.typography.bodyMedium)
                }
            }
            if (viewModel.connectionMessage.isNotBlank()) {
                StatusLabel(viewModel.connectionMessage, if (viewModel.connectionMessage.contains("失败")) StatusTone.ERROR else StatusTone.REMOTE)
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                PapriaPrimaryButton(
                    if (viewModel.bookOrbitLoading) "正在连接" else "保存并登录",
                    onClick = {
                        viewModel.connectBookOrbit(server, username, password, fingerprint, cleartextConfirmed, onConnected)
                    },
                    enabled = !viewModel.bookOrbitLoading && server.isNotBlank() && username.isNotBlank() && password.isNotBlank() && (!isCleartext || cleartextConfirmed),
                )
                PapriaSecondaryButton("取消", onDismiss)
            }
        }
    }
}

@Composable
private fun BookOrbitDisconnectConfirmation(onDismiss: () -> Unit, onConfirm: (Boolean) -> Unit) {
    val palette = LocalPapriaPalette.current
    val message = "将退出当前 BookOrbit 服务器。已下载的本地书籍可继续阅读；请选择是否保留离线书目和详情缓存。"
    if (palette.isEink) {
        Surface(
            Modifier.fillMaxWidth().padding(16.dp),
            color = palette.raised,
            border = BorderStroke(2.dp, palette.ink),
            shape = PapriaShape(),
            shadowElevation = 0.dp,
        ) {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text("退出 BookOrbit？", color = palette.ink, style = MaterialTheme.typography.titleLarge)
                Text(message, color = palette.secondaryInk, style = MaterialTheme.typography.bodyMedium)
                PapriaPrimaryButton("退出并保留离线缓存", { onConfirm(true) })
                PapriaSecondaryButton("退出并清除离线缓存", { onConfirm(false) })
                TextButton(onClick = onDismiss, modifier = Modifier.heightIn(min = 48.dp)) { Text("取消") }
            }
        }
    } else {
        AlertDialog(
            onDismissRequest = onDismiss,
            title = { Text("退出 BookOrbit？") },
            text = { Text(message) },
            confirmButton = { TextButton(onClick = { onConfirm(true) }) { Text("保留离线缓存") } },
            dismissButton = {
                Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    TextButton(onClick = { onConfirm(false) }) { Text("清除缓存") }
                    TextButton(onClick = onDismiss) { Text("取消") }
                }
            },
            containerColor = palette.raised,
        )
    }
}

@Composable
private fun SettingsHeader(title: String) {
    val palette = LocalPapriaPalette.current
    Text(
        title,
        modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = 20.dp, bottom = 6.dp),
        color = palette.ink,
        style = MaterialTheme.typography.titleLarge,
    )
}

@Composable
private fun SettingsRow(title: String, detail: String, action: String?, onAction: () -> Unit) {
    val palette = LocalPapriaPalette.current
    Row(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(title, color = palette.ink, style = MaterialTheme.typography.bodyLarge, maxLines = 2, overflow = TextOverflow.Ellipsis)
            Text(detail, color = palette.secondaryInk, style = MaterialTheme.typography.bodyMedium, maxLines = 2, overflow = TextOverflow.Ellipsis)
        }
        if (action != null) {
            Spacer(Modifier.width(8.dp))
            PapriaSecondaryButton(action, onAction)
        }
    }
}

@Composable
private fun DisplayModeOption(label: String, mode: DisplayMode, selected: DisplayMode, onChange: (DisplayMode) -> Unit) {
    val palette = LocalPapriaPalette.current
    if (palette.isEink) {
        Surface(
            modifier = Modifier
                .heightIn(min = 48.dp)
                .clickable { onChange(mode) },
            color = if (selected == mode) palette.ink else palette.raised,
            contentColor = if (selected == mode) Color.White else palette.ink,
            shape = PapriaShape(),
            border = BorderStroke(2.dp, palette.ink),
            shadowElevation = 0.dp,
        ) {
            Text(label, Modifier.padding(horizontal = 12.dp, vertical = 14.dp), style = MaterialTheme.typography.labelMedium)
        }
        return
    }
    Row(
        modifier = Modifier
            .heightIn(min = 48.dp)
            .clickable { onChange(mode) },
        verticalAlignment = Alignment.CenterVertically,
    ) {
        RadioButton(selected = selected == mode, onClick = { onChange(mode) })
        Text(label, color = palette.ink, style = MaterialTheme.typography.bodyMedium)
    }
}

@Composable
private fun PapriaStaticCheckbox(checked: Boolean, onCheckedChange: (Boolean) -> Unit) {
    val palette = LocalPapriaPalette.current
    if (!palette.isEink) {
        Checkbox(checked = checked, onCheckedChange = onCheckedChange)
    } else {
        Surface(
            modifier = Modifier
                .heightIn(min = 48.dp)
                .clickable { onCheckedChange(!checked) },
            color = if (checked) palette.ink else palette.raised,
            contentColor = if (checked) Color.White else palette.ink,
            shape = PapriaShape(),
            border = BorderStroke(2.dp, palette.ink),
            shadowElevation = 0.dp,
        ) {
            Text(if (checked) "已确认" else "未确认", Modifier.padding(horizontal = 8.dp, vertical = 14.dp), style = MaterialTheme.typography.labelMedium)
        }
    }
}

@Composable
private fun PapriaDownloadToggle(checked: Boolean, onCheckedChange: (Boolean) -> Unit) {
    val palette = LocalPapriaPalette.current
    if (!palette.isEink) {
        Switch(checked = checked, onCheckedChange = onCheckedChange)
    } else {
        Surface(
            modifier = Modifier
                .heightIn(min = 48.dp)
                .clickable { onCheckedChange(!checked) },
            color = if (checked) palette.ink else palette.raised,
            contentColor = if (checked) Color.White else palette.ink,
            shape = PapriaShape(),
            border = BorderStroke(2.dp, palette.ink),
            shadowElevation = 0.dp,
        ) {
            Text(
                if (checked) "已开启" else "已关闭",
                modifier = Modifier.padding(horizontal = 12.dp, vertical = 14.dp),
                style = MaterialTheme.typography.labelMedium,
            )
        }
    }
}

private data class ConflictResolution(val conflict: SyncConflictRecord, val keepLocal: Boolean)

@Composable
private fun SyncConflictPanel(
    conflict: SyncConflictRecord,
    onKeepLocal: () -> Unit,
    onUseServer: () -> Unit,
    onLater: () -> Unit,
) {
    val palette = LocalPapriaPalette.current
    @Composable
    fun ConflictContent(modifier: Modifier = Modifier) {
        Column(modifier, verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("阅读位置冲突", color = palette.ink, style = MaterialTheme.typography.titleLarge)
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                ConflictValue("本地版本", conflict.localPayload, conflict.kind, Modifier.weight(1f))
                ConflictValue("服务器版本", conflict.remotePayload, conflict.kind, Modifier.weight(1f))
            }
            Text("冲突记录时间：${formatTime(conflict.createdAt)}", color = palette.secondaryInk, style = MaterialTheme.typography.labelMedium)
            Text("当前冲突记录未提供两端设备名称或更新时间。", color = palette.secondaryInk, style = MaterialTheme.typography.labelMedium)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                PapriaPrimaryButton("保留本地进度", onKeepLocal)
                PapriaSecondaryButton("使用服务器进度", onUseServer)
            }
            TextButton(onClick = onLater, modifier = Modifier.heightIn(min = 48.dp)) { Text("稍后处理") }
        }
    }
    if (palette.isEink) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp)) {
            ConflictContent(Modifier.fillMaxWidth())
            Spacer(Modifier.height(12.dp))
            PapriaDivider()
        }
    } else {
        Surface(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
            color = palette.raised,
            shape = PapriaShape(),
            border = BorderStroke(1.dp, palette.line),
            shadowElevation = 0.dp,
        ) {
            ConflictContent(Modifier.padding(12.dp))
        }
    }
}

@Composable
private fun ConflictValue(title: String, payload: String, kind: String, modifier: Modifier = Modifier) {
    val palette = LocalPapriaPalette.current
    Column(modifier, verticalArrangement = Arrangement.spacedBy(3.dp)) {
        Text(title, color = palette.ink, style = MaterialTheme.typography.labelMedium)
        Text(progressPayloadSummary(payload, kind), color = palette.secondaryInk, style = MaterialTheme.typography.bodyMedium)
    }
}

@Composable
private fun ConflictResolutionConfirmation(resolution: ConflictResolution, onDismiss: () -> Unit, onConfirm: () -> Unit) {
    val palette = LocalPapriaPalette.current
    val retained = if (resolution.keepLocal) "本地进度" else "服务器进度"
    val overwritten = if (resolution.keepLocal) "服务器进度" else "本地进度"
    val message = "将保留$retained，并覆盖${overwritten}的阅读位置。"
    if (palette.isEink) {
        Surface(
            modifier = Modifier.fillMaxWidth().padding(16.dp),
            color = palette.raised,
            border = BorderStroke(2.dp, palette.ink),
            shape = PapriaShape(),
        ) {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text("确认覆盖进度？", color = palette.ink, style = MaterialTheme.typography.titleLarge)
                Text(message, color = palette.secondaryInk, style = MaterialTheme.typography.bodyMedium)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    PapriaPrimaryButton("确认", onConfirm)
                    PapriaSecondaryButton("取消", onDismiss)
                }
            }
        }
    } else {
        AlertDialog(
            onDismissRequest = onDismiss,
            title = { Text("确认覆盖进度？") },
            text = { Text(message) },
            confirmButton = { TextButton(onClick = onConfirm) { Text("确认") } },
            dismissButton = { TextButton(onClick = onDismiss) { Text("取消") } },
            containerColor = palette.raised,
        )
    }
}

@Composable
private fun OfflineBanner() {
    val palette = LocalPapriaPalette.current
    Surface(
        modifier = Modifier.fillMaxWidth(),
        color = if (palette.isEink) palette.raised else Color(0xFFF0E7D7),
        shape = PapriaShape(),
        border = BorderStroke(if (palette.isEink) 2.dp else 1.dp, if (palette.isEink) palette.ink else palette.line),
    ) {
        Text(
            "离线：仅显示已缓存内容",
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
            color = palette.ink,
            style = MaterialTheme.typography.bodyMedium,
        )
    }
}

@Composable
private fun StaticLoading(label: String) {
    val palette = LocalPapriaPalette.current
    Text(label, Modifier.padding(16.dp), color = palette.secondaryInk, style = MaterialTheme.typography.bodyMedium)
}

private enum class StatusTone { REMOTE, SUCCESS, WARNING, ERROR }

@Composable
private fun StatusLabel(label: String, tone: StatusTone) {
    val palette = LocalPapriaPalette.current
    val color = if (palette.isEink) {
        if (tone == StatusTone.ERROR) palette.ink else palette.secondaryInk
    } else {
        when (tone) {
            StatusTone.REMOTE -> palette.remote
            StatusTone.SUCCESS -> palette.success
            StatusTone.WARNING -> palette.warning
            StatusTone.ERROR -> palette.error
        }
    }
    Text(label, color = color, style = MaterialTheme.typography.labelMedium, maxLines = 2, overflow = TextOverflow.Ellipsis)
}

@Composable
private fun ProgressLine(progress: Double, modifier: Modifier = Modifier) {
    val palette = LocalPapriaPalette.current
    val value = progress.coerceIn(0.0, 1.0).toFloat()
    Box(
        modifier = modifier
            .fillMaxWidth()
            .height(if (palette.isEink) 4.dp else 4.dp)
            .background(palette.line),
    ) {
        Box(
            modifier = Modifier
                .fillMaxWidth(value)
                .fillMaxHeight()
                .background(if (palette.isEink) palette.ink else palette.primaryAction),
        )
    }
}

@Composable
private fun BookCover(title: String, format: String, modifier: Modifier, bitmap: Bitmap? = null) {
    val palette = LocalPapriaPalette.current
    Box(
        modifier = modifier
            .background(if (palette.isEink) palette.raised else Color(0xFFE8DED0))
            .border(1.dp, if (palette.isEink) palette.ink else palette.line),
        contentAlignment = Alignment.Center,
    ) {
        if (bitmap != null) {
            Image(bitmap.asImageBitmap(), contentDescription = title, modifier = Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
        } else {
            Text(
                format.uppercase(Locale.ROOT).take(5),
                modifier = Modifier.padding(4.dp),
                color = palette.secondaryInk,
                style = MaterialTheme.typography.labelMedium,
                textAlign = TextAlign.Center,
                maxLines = 2,
            )
        }
    }
}

@Composable
private fun PapriaPrimaryButton(label: String, onClick: () -> Unit, modifier: Modifier = Modifier, enabled: Boolean = true) {
    val palette = LocalPapriaPalette.current
    Button(
        onClick = onClick,
        modifier = modifier.sizeIn(minWidth = 48.dp, minHeight = 48.dp),
        enabled = enabled,
        shape = PapriaShape(),
        border = if (palette.isEink) BorderStroke(1.dp, palette.ink) else null,
        colors = ButtonDefaults.buttonColors(
            containerColor = palette.primaryAction,
            contentColor = Color.White,
            disabledContainerColor = palette.line,
            disabledContentColor = palette.disabledInk,
        ),
        elevation = ButtonDefaults.buttonElevation(defaultElevation = 0.dp, pressedElevation = 0.dp, focusedElevation = 0.dp, hoveredElevation = 0.dp, disabledElevation = 0.dp),
    ) {
        Text(label, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

@Composable
private fun PapriaSecondaryButton(label: String, onClick: () -> Unit, modifier: Modifier = Modifier, enabled: Boolean = true) {
    val palette = LocalPapriaPalette.current
    OutlinedButton(
        onClick = onClick,
        modifier = modifier.sizeIn(minWidth = 48.dp, minHeight = 48.dp),
        enabled = enabled,
        shape = PapriaShape(),
        border = BorderStroke(if (palette.isEink) 1.dp else 1.dp, if (enabled) if (palette.isEink) palette.ink else palette.line else palette.disabledInk),
        colors = ButtonDefaults.outlinedButtonColors(
            contentColor = if (enabled) palette.ink else palette.disabledInk,
            disabledContentColor = palette.disabledInk,
        ),
    ) {
        Text(label, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

@Composable
private fun PapriaDivider() {
    val palette = LocalPapriaPalette.current
    HorizontalDivider(thickness = 1.dp, color = palette.line)
}

@Composable
private fun PapriaShape() = if (LocalPapriaPalette.current.isEink) RoundedCornerShape(0.dp) else RoundedCornerShape(6.dp)

private fun downloadProgress(task: DownloadTaskRecord): Double =
    if (task.totalBytes <= 0L) 0.0 else task.offsetBytes.toDouble() / task.totalBytes.toDouble()

/**
 * Download tasks do not persist a separate queue ordinal.  The current
 * Room-provided task list is the authoritative visible queue, so derive the
 * ordinal from that list without introducing another stored field.
 */
private fun queuedTaskPositions(downloads: List<DownloadTaskRecord>): Map<Long, Int> =
    downloads.filter { it.state == "queued" }
        .mapIndexed { index, task -> task.fileId to index + 1 }
        .toMap()

private fun queueStatusLabel(position: Int?, onlyWifi: Boolean): String {
    val waitingFor = if (onlyWifi) "等待 Wi-Fi" else "等待网络"
    return position?.let { "队列 #$it · $waitingFor" } ?: waitingFor
}

private fun progressText(progress: Double, page: Int?): String =
    "${percent(progress)}${page?.let { " · 第 $it 页" } ?: " · 第 1 页"}"

private fun percent(progress: Double): String = "${(progress.coerceIn(0.0, 1.0) * 100).toInt()}%"

private fun formatBytes(bytes: Long): String = when {
    bytes < 1024L -> "$bytes B"
    bytes < 1024L * 1024L -> String.format(Locale.US, "%.1f KB", bytes / 1024.0)
    bytes < 1024L * 1024L * 1024L -> String.format(Locale.US, "%.1f MB", bytes / (1024.0 * 1024.0))
    else -> String.format(Locale.US, "%.1f GB", bytes / (1024.0 * 1024.0 * 1024.0))
}

private fun formatDownloadRate(bytesPerSecond: Long?): String = if (bytesPerSecond == null) {
    "速度：正在测量"
} else {
    "速度：${formatBytes(bytesPerSecond)}/秒"
}

private fun librarySourceLabel(publication: LocalPublication): String = when (publication.source) {
    "bookorbit" -> if (publication.downloaded) "BookOrbit · 已下载" else "BookOrbit"
    "wifi" -> "Wi-Fi 传书"
    "local" -> "本地导入"
    else -> "来源：${publication.source}"
}

private fun librarySyncStatus(progress: ReadingProgressRecord?): Pair<String, StatusTone>? = when {
    progress == null -> null
    progress.localOnly -> "仅本地进度" to StatusTone.REMOTE
    progress.dirty -> "等待同步" to StatusTone.WARNING
    progress.remoteUpdatedAt != null -> "已同步" to StatusTone.SUCCESS
    else -> "尚未同步" to StatusTone.WARNING
}

private fun taskSummary(running: Int, waiting: Int, waitingWifi: Int): String = buildList {
    if (running > 0) add("$running 项下载中")
    if (waitingWifi > 0) add("$waitingWifi 项等待 Wi-Fi")
    if (waiting - waitingWifi > 0) add("${waiting - waitingWifi} 项等待网络")
}.joinToString("，")

private fun serverHost(address: String): String = runCatching {
    java.net.URI(address).host ?: address
}.getOrDefault(address).ifBlank { "BookOrbit" }

private fun isAudioFile(file: RemoteFilePayload): Boolean =
    file.format.lowercase(Locale.ROOT) in setOf("m4b", "m4a", "mp3", "opus", "ogg", "flac")

private fun progressPayloadSummary(payload: String, kind: String): String = runCatching {
    if (payload == "null") {
        if (kind == "audio-progress") "无音频进度" else "无阅读记录"
    } else {
        val json = org.json.JSONObject(payload)
        when (kind) {
            "audio-progress" -> {
                val value = json.getDouble("percentage")
                val currentFileId = json.getLong("currentFileId")
                val positionSeconds = json.getDouble("positionSeconds")
                "${percent(value)} · 文件 $currentFileId · ${formatDuration(positionSeconds)}"
            }

            else -> {
                val value = json.getDouble("percentage")
                val page = if (json.has("pageNumber")) " · 第 ${json.getInt("pageNumber")} 页" else ""
                "${percent(value)}$page"
            }
        }
    }
}.getOrDefault(if (kind == "audio-progress") "无法读取音频进度" else "无法读取阅读位置")

private fun formatDuration(seconds: Double): String {
    if (!seconds.isFinite() || seconds < 0.0) return "未知位置"
    val totalSeconds = seconds.toLong()
    val hours = totalSeconds / 3_600
    val minutes = (totalSeconds % 3_600) / 60
    val remainder = totalSeconds % 60
    return if (hours > 0L) {
        String.format(Locale.ROOT, "%d:%02d:%02d", hours, minutes, remainder)
    } else {
        String.format(Locale.ROOT, "%02d:%02d", minutes, remainder)
    }
}

private fun formatTime(epochMillis: Long): String =
    DateFormat.getDateTimeInstance(DateFormat.SHORT, DateFormat.SHORT, Locale.getDefault()).format(Date(epochMillis))

private fun wifiName(context: Context): String = runCatching {
    context.applicationContext.getSystemService(android.net.wifi.WifiManager::class.java)
        ?.connectionInfo
        ?.ssid
        ?.trim('"')
        ?.takeIf { it.isNotBlank() && it != "<unknown ssid>" }
}.getOrNull() ?: "当前 Wi-Fi"

private fun copyAddress(context: Context, address: String) {
    val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
    clipboard.setPrimaryClip(ClipData.newPlainText("Papria 传书地址", address))
}

private fun createQrCode(value: String): Bitmap? = runCatching {
    val matrix = MultiFormatWriter().encode(value, BarcodeFormat.QR_CODE, 512, 512, mapOf(EncodeHintType.MARGIN to 1))
    Bitmap.createBitmap(matrix.width, matrix.height, Bitmap.Config.ARGB_8888).also { bitmap ->
        for (x in 0 until matrix.width) for (y in 0 until matrix.height) {
            bitmap.setPixel(x, y, if (matrix[x, y]) android.graphics.Color.BLACK else android.graphics.Color.WHITE)
        }
    }
}.getOrNull()
