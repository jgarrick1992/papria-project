package com.papria.reader.core.sync

import android.content.Context
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.papria.reader.core.bookorbit.BookOrbitClient
import com.papria.reader.core.bookorbit.BookOrbitRepository
import com.papria.reader.core.local.PapriaDatabase
import com.papria.reader.core.security.SecureSessionStore
import java.util.concurrent.TimeUnit

/** Uploads progress outbox entries whenever an authenticated network is available. */
class BookOrbitSyncWorker(appContext: Context, params: WorkerParameters) : CoroutineWorker(appContext, params) {
    override suspend fun doWork(): Result {
        val profile = PapriaDatabase.get(applicationContext).serverProfile() ?: return Result.success()
        val client = BookOrbitClient.fromPersistedProfile(profile) ?: return Result.failure()
        return try {
            val secure = SecureSessionStore(applicationContext)
            client.setSession(secure.decrypt(profile.accessToken), secure.decrypt(profile.refreshCookie))
            val repository = BookOrbitRepository(applicationContext, client)
            repository.verifyServerVersion()
            val summary = repository.uploadOutbox()
            if (summary.failed == 0) Result.success() else Result.retry()
        } catch (_: Exception) {
            Result.retry()
        }
    }

    companion object {
        const val UNIQUE_NAME = "bookorbit-progress-sync"
        const val PERIODIC_UNIQUE_NAME = "bookorbit-progress-sync-periodic"

        fun enqueue(context: Context) {
            val request = OneTimeWorkRequestBuilder<BookOrbitSyncWorker>()
                .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
                .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 15, TimeUnit.SECONDS)
                .build()
            WorkManager.getInstance(context).enqueueUniqueWork(UNIQUE_NAME, androidx.work.ExistingWorkPolicy.KEEP, request)
        }

        fun enqueuePeriodic(context: Context) {
            val request = PeriodicWorkRequestBuilder<BookOrbitSyncWorker>(15, TimeUnit.MINUTES)
                .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
                .build()
            // Keep the periodic chain separate from the immediate network
            // trigger.  WorkManager treats both as unfinished unique work;
            // sharing a name would allow a pending one-time request to
            // suppress registration of the periodic request at startup.
            WorkManager.getInstance(context).enqueueUniquePeriodicWork(PERIODIC_UNIQUE_NAME, androidx.work.ExistingPeriodicWorkPolicy.KEEP, request)
        }
    }
}
