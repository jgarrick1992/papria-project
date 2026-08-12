package com.papria.reader.core.transfer

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * A state reached by an individual upload handled by [WifiTransferServer].
 *
 * These values describe receiver events, rather than browser-side estimates:
 * [RECEIVING] is emitted only while the receiver writes request bytes, and the
 * validation/import states are emitted immediately before those operations run.
 */
enum class WifiTransferUploadLifecycle {
    IDLE,
    RECEIVING,
    VALIDATING,
    IMPORTING,
    COMPLETED,
    FAILED,
    CANCELLED,
}

/**
 * A redacted, local-process-safe view of one Wi-Fi upload.
 *
 * It deliberately excludes the bearer credential, upload resume credential and
 * temporary file path. [uploadId] is included solely so the foreground owner
 * can request cancellation of this exact receiver-side upload.
 */
data class WifiTransferUploadSnapshot(
    val uploadId: String,
    val lifecycle: WifiTransferUploadLifecycle,
    val fileName: String,
    val receivedBytes: Long,
    val totalBytes: Long,
    val error: String? = null,
    val updatedAtEpochMillis: Long,
)

/**
 * Immutable snapshot emitted by a running [WifiTransferServer].
 *
 * [lifecycle] reports the most recently updated non-terminal upload, or
 * [WifiTransferUploadLifecycle.IDLE] when the receiver is stopped or has no
 * active upload.
 * Terminal entries remain in [uploads] for the lifetime of the receiver so the
 * foreground page can show a real completion, cancellation or failure result.
 */
data class WifiTransferServerSnapshot(
    val isRunning: Boolean = false,
    val uploads: List<WifiTransferUploadSnapshot> = emptyList(),
) {
    val lifecycle: WifiTransferUploadLifecycle
        get() = if (!isRunning) {
            WifiTransferUploadLifecycle.IDLE
        } else {
            uploads
                .asReversed()
                .firstOrNull { it.lifecycle.isActive() }
                ?.lifecycle
                ?: WifiTransferUploadLifecycle.IDLE
        }
}

private fun WifiTransferUploadLifecycle.isActive(): Boolean = when (this) {
    WifiTransferUploadLifecycle.RECEIVING,
    WifiTransferUploadLifecycle.VALIDATING,
    WifiTransferUploadLifecycle.IMPORTING -> true
    WifiTransferUploadLifecycle.IDLE,
    WifiTransferUploadLifecycle.COMPLETED,
    WifiTransferUploadLifecycle.FAILED,
    WifiTransferUploadLifecycle.CANCELLED -> false
}

/**
 * Synchronizes receiver events before publishing immutable [StateFlow] values.
 *
 * One instance belongs to one receiver. Keeping its mutation private prevents
 * presentation code from manufacturing progress, terminal states, or errors.
 */
internal class WifiTransferLiveState {
    private val lock = Any()
    private val uploads = linkedMapOf<String, WifiTransferUploadSnapshot>()
    private val mutableSnapshot = MutableStateFlow(WifiTransferServerSnapshot())

    val snapshot: StateFlow<WifiTransferServerSnapshot> = mutableSnapshot.asStateFlow()

    fun start() = synchronized(lock) {
        uploads.clear()
        publish(isRunning = true)
    }

    fun stop() = synchronized(lock) {
        // Closing the listener preserves partial uploads for the existing
        // resume protocol. Do not manufacture a cancellation event here.
        publish(isRunning = false)
    }

    fun containsCancellableUpload(uploadId: String): Boolean = synchronized(lock) {
        when (uploads[uploadId]?.lifecycle) {
            WifiTransferUploadLifecycle.RECEIVING,
            WifiTransferUploadLifecycle.VALIDATING,
            WifiTransferUploadLifecycle.FAILED -> true
            else -> false
        }
    }

    fun receiving(uploadId: String, fileName: String, receivedBytes: Long, totalBytes: Long) {
        update(
            uploadId = uploadId,
            lifecycle = WifiTransferUploadLifecycle.RECEIVING,
            fileName = fileName,
            receivedBytes = receivedBytes,
            totalBytes = totalBytes,
            error = null,
        )
    }

    fun validating(uploadId: String, fileName: String, receivedBytes: Long, totalBytes: Long) {
        update(uploadId, WifiTransferUploadLifecycle.VALIDATING, fileName, receivedBytes, totalBytes, null)
    }

    fun importing(uploadId: String, fileName: String, receivedBytes: Long, totalBytes: Long) {
        update(uploadId, WifiTransferUploadLifecycle.IMPORTING, fileName, receivedBytes, totalBytes, null)
    }

    fun completed(uploadId: String, fileName: String, receivedBytes: Long, totalBytes: Long) {
        update(uploadId, WifiTransferUploadLifecycle.COMPLETED, fileName, receivedBytes, totalBytes, null)
    }

    fun failed(uploadId: String, fileName: String, receivedBytes: Long, totalBytes: Long, error: String) {
        update(uploadId, WifiTransferUploadLifecycle.FAILED, fileName, receivedBytes, totalBytes, error)
    }

    fun cancelled(uploadId: String, fileName: String, receivedBytes: Long, totalBytes: Long) {
        update(uploadId, WifiTransferUploadLifecycle.CANCELLED, fileName, receivedBytes, totalBytes, null)
    }

    private fun update(
        uploadId: String,
        lifecycle: WifiTransferUploadLifecycle,
        fileName: String,
        receivedBytes: Long,
        totalBytes: Long,
        error: String?,
    ) = synchronized(lock) {
        uploads[uploadId] = WifiTransferUploadSnapshot(
            uploadId = uploadId,
            lifecycle = lifecycle,
            fileName = fileName,
            receivedBytes = receivedBytes.coerceIn(0, totalBytes),
            totalBytes = totalBytes,
            error = error,
            updatedAtEpochMillis = System.currentTimeMillis(),
        )
        publish(isRunning = mutableSnapshot.value.isRunning)
    }

    private fun publish(isRunning: Boolean) {
        mutableSnapshot.value = WifiTransferServerSnapshot(
            isRunning = isRunning,
            uploads = uploads.values.toList(),
        )
    }
}
