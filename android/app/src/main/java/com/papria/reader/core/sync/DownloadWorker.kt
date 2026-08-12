package com.papria.reader.core.sync

import android.content.Context
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.papria.reader.core.bookorbit.BookOrbitClient
import com.papria.reader.core.bookorbit.BookOrbitRepository
import com.papria.reader.core.local.PapriaDatabase
import com.papria.reader.core.security.SecureSessionStore
import kotlinx.coroutines.CancellationException
import java.util.concurrent.TimeUnit

/** Resumable, foreground-triggered BookOrbit file download. */
class DownloadWorker(appContext: Context, params: WorkerParameters) : CoroutineWorker(appContext, params) {
    override suspend fun doWork(): Result {
        val fileId = inputData.getLong(KEY_FILE_ID, -1L)
        if (fileId <= 0) return Result.failure()
        val profile = PapriaDatabase.get(applicationContext).serverProfile() ?: return Result.failure()
        val client = BookOrbitClient.fromPersistedProfile(profile) ?: return Result.failure()
        return try {
            val secure = SecureSessionStore(applicationContext)
            client.setSession(secure.decrypt(profile.accessToken), secure.decrypt(profile.refreshCookie))
            BookOrbitRepository(applicationContext, client).also { repository ->
                repository.verifyServerVersion()
                repository.downloadFile(fileId)
            }
            Result.success()
        } catch (error: Exception) {
            // Cancellation is the user pressing Pause.  The repository has
            // already checkpointed the part file and marked it paused; let
            // WorkManager keep the cancellation terminal state.
            if (error is CancellationException) throw error
            val database = PapriaDatabase.get(applicationContext)
            database.downloadTask(fileId)?.let { task ->
                val terminal = runAttemptCount >= 5
                database.upsertDownload(task.copy(
                    state = if (terminal) "failed" else "queued",
                    error = error.message,
                    updatedAt = System.currentTimeMillis(),
                ))
            }
            if (runAttemptCount >= 5) Result.failure() else Result.retry()
        }
    }

    companion object {
        private const val KEY_FILE_ID = "fileId"

        fun enqueue(context: Context, fileId: Long, onlyWifi: Boolean = false) {
            enqueueInternal(context, fileId, onlyWifi, androidx.work.ExistingWorkPolicy.KEEP)
        }

        /** Mark a task paused and cancel its active WorkManager request. */
        fun pause(context: Context, fileId: Long) {
            cancel(context, fileId)
            val database = PapriaDatabase.get(context)
            database.downloadTask(fileId)?.let { task ->
                if (task.state == "running" || task.state == "queued") {
                    database.upsertDownload(task.copy(state = "paused", updatedAt = System.currentTimeMillis()))
                }
            }
        }

        /** Clear a terminal error and restart from the persisted Range offset. */
        fun retry(context: Context, fileId: Long, onlyWifi: Boolean = false) {
            val database = PapriaDatabase.get(context)
            database.downloadTask(fileId)?.let { task ->
                database.upsertDownload(task.copy(state = "queued", error = null, updatedAt = System.currentTimeMillis()))
            }
            enqueueInternal(context, fileId, onlyWifi, androidx.work.ExistingWorkPolicy.REPLACE)
        }

        private fun enqueueInternal(context: Context, fileId: Long, onlyWifi: Boolean, policy: androidx.work.ExistingWorkPolicy) {
            val network = if (onlyWifi) NetworkType.UNMETERED else NetworkType.CONNECTED
            val request = OneTimeWorkRequestBuilder<DownloadWorker>()
                .setInputData(androidx.work.workDataOf(KEY_FILE_ID to fileId))
                .setConstraints(Constraints.Builder().setRequiredNetworkType(network).build())
                .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 15, TimeUnit.SECONDS)
                .build()
            WorkManager.getInstance(context).enqueueUniqueWork("bookorbit-download-$fileId", policy, request)
        }

        fun cancel(context: Context, fileId: Long) {
            WorkManager.getInstance(context).cancelUniqueWork("bookorbit-download-$fileId")
        }
    }
}
