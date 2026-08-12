package com.papria.reader

import android.Manifest
import android.os.Bundle
import android.net.Uri
import android.content.Intent
import android.content.pm.PackageManager
import androidx.activity.ComponentActivity
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.compose.setContent
import androidx.activity.viewModels
import com.papria.reader.ui.PapriaApp
import com.papria.reader.ui.PapriaTheme
import com.papria.reader.ui.PapriaViewModel
import com.papria.reader.core.local.LocalPublication

class MainActivity : ComponentActivity() {
    private val viewModel: PapriaViewModel by viewModels()
    private val importLauncher = registerForActivityResult(ActivityResultContracts.OpenDocument()) { uri: Uri? -> uri?.let(viewModel::importFile) }
    private val notificationPermissionLauncher = registerForActivityResult(ActivityResultContracts.RequestPermission()) { }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (android.os.Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            notificationPermissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
        }
        setContent {
            PapriaTheme(displayMode = viewModel.selectedDisplayMode) {
                PapriaApp(viewModel, onImport = { importLauncher.launch(arrayOf("*/*")) }, onOpenPublication = ::openPublication)
            }
        }
    }

    private fun openPublication(publication: LocalPublication) {
        val path = publication.localPath ?: return
        startActivity(Intent(this, ReaderActivity::class.java).apply {
            putExtra(ReaderActivity.EXTRA_FILE_ID, publication.remoteFileId ?: -1L)
            putExtra(ReaderActivity.EXTRA_BOOK_ID, publication.remoteBookId ?: 0L)
            putExtra(ReaderActivity.EXTRA_PROGRESS_ID, publication.progressFileId)
            putExtra(ReaderActivity.EXTRA_PATH, path)
            putExtra(ReaderActivity.EXTRA_TITLE, publication.title)
            putExtra(ReaderActivity.EXTRA_FORMAT, publication.format)
        })
    }
}
