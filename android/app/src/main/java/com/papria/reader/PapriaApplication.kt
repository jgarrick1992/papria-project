package com.papria.reader

import android.app.Application
import com.papria.reader.core.sync.BookOrbitSyncWorker

class PapriaApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        // Register both the periodic and the immediate, network-constrained
        // work at process start.  The one-time request is harmless when the
        // outbox is empty, and gives a freshly launched process a chance to
        // flush progress without waiting for the first 15-minute period.
        BookOrbitSyncWorker.enqueue(this)
        BookOrbitSyncWorker.enqueuePeriodic(this)
    }
}
