package com.papria.reader.core.local

import androidx.room.ColumnInfo
import androidx.room.Entity
import androidx.room.ForeignKey
import androidx.room.Index
import androidx.room.PrimaryKey

/** Local representation of a BookOrbit publication and its files. */
@Entity(tableName = "publications")
data class LocalPublication(
    @PrimaryKey @ColumnInfo(name = "local_id")
    val localId: String,
    val title: String,
    val author: String?,
    val format: String,
    @ColumnInfo(name = "local_path")
    val localPath: String?,
    @ColumnInfo(name = "content_hash")
    val contentHash: String?,
    @ColumnInfo(name = "remote_book_id")
    val remoteBookId: Long?,
    @ColumnInfo(name = "remote_file_id")
    val remoteFileId: Long?,
    val source: String,
    val downloaded: Boolean,
    @ColumnInfo(name = "updated_at")
    val updatedAt: Long,
    @ColumnInfo(name = "created_at")
    val createdAt: Long = 0L,
) {
    /** Stable negative scope for local-only progress; remote files use fileId. */
    val progressFileId: Long
        get() = remoteFileId ?: contentHash?.take(15)?.toLongOrNull(16)?.let { -kotlin.math.abs(it.coerceAtLeast(1)) }
            ?: -kotlin.math.abs(localId.hashCode().toLong().coerceAtLeast(1))
}

@Entity(tableName = "remote_books")
data class RemoteBookRecord(
    @PrimaryKey @ColumnInfo(name = "remote_book_id")
    val id: Long,
    val title: String,
    val author: String?,
    @ColumnInfo(name = "cover_url")
    val coverUrl: String?,
    @ColumnInfo(name = "updated_at")
    val updatedAt: Long,
)

@Entity(
    tableName = "remote_files",
    indices = [Index(value = ["remote_book_id"])],
    foreignKeys = [ForeignKey(
        entity = RemoteBookRecord::class,
        parentColumns = ["remote_book_id"],
        childColumns = ["remote_book_id"],
        onDelete = ForeignKey.CASCADE,
    )],
)
data class RemoteFileRecord(
    @PrimaryKey @ColumnInfo(name = "remote_file_id")
    val id: Long,
    @ColumnInfo(name = "remote_book_id")
    val bookId: Long,
    @ColumnInfo(name = "file_name")
    val fileName: String,
    val format: String,
    @ColumnInfo(name = "size_bytes")
    val sizeBytes: Long,
    @ColumnInfo(name = "content_hash")
    val contentHash: String?,
    @ColumnInfo(name = "local_path")
    val localPath: String?,
)

@Entity(tableName = "download_tasks")
data class DownloadTaskRecord(
    @PrimaryKey @ColumnInfo(name = "remote_file_id")
    val fileId: Long,
    @ColumnInfo(name = "offset_bytes")
    val offsetBytes: Long,
    @ColumnInfo(name = "total_bytes")
    val totalBytes: Long,
    val state: String,
    val error: String?,
    @ColumnInfo(name = "updated_at")
    val updatedAt: Long,
)

@Entity(tableName = "reading_progress")
data class ReadingProgressRecord(
    @PrimaryKey @ColumnInfo(name = "file_id")
    val fileId: Long,
    val percentage: Double,
    val cfi: String?,
    @ColumnInfo(name = "page_number")
    val pageNumber: Int?,
    @ColumnInfo(name = "position_seconds")
    val positionSeconds: Double?,
    @ColumnInfo(name = "local_updated_at")
    val localUpdatedAt: Long,
    @ColumnInfo(name = "remote_updated_at")
    val remoteUpdatedAt: Long?,
    val dirty: Boolean,
    @ColumnInfo(name = "local_only")
    val localOnly: Boolean,
    @ColumnInfo(name = "kobo_location_source")
    val koboLocationSource: String? = null,
    @ColumnInfo(name = "kobo_location_type")
    val koboLocationType: String? = null,
    @ColumnInfo(name = "kobo_location_value")
    val koboLocationValue: String? = null,
    @ColumnInfo(name = "kobo_content_source_progress_percent")
    val koboContentSourceProgressPercent: Double? = null,
    @ColumnInfo(name = "koreader_progress")
    val koreaderProgress: String? = null,
)

@Entity(tableName = "audio_progress")
data class AudioProgressRecord(
    @PrimaryKey @ColumnInfo(name = "book_id")
    val bookId: Long,
    val percentage: Double,
    @ColumnInfo(name = "current_file_id")
    val currentFileId: Long,
    @ColumnInfo(name = "position_seconds")
    val positionSeconds: Double,
    @ColumnInfo(name = "updated_at")
    val updatedAt: Long,
    val dirty: Boolean,
    @ColumnInfo(name = "playback_speed")
    val playbackSpeed: Float = 1.0f,
    @ColumnInfo(name = "sleep_until")
    val sleepUntil: Long? = null,
)

/**
 * Exact remote progress snapshot returned by the most recent successful GET.
 * A null payload is meaningful for audio progress: it records that the server
 * explicitly returned no progress, rather than that the client has not pulled.
 */
@Entity(tableName = "progress_sync_baselines", primaryKeys = ["kind", "item_key"])
data class ProgressSyncBaselineRecord(
    val kind: String,
    @ColumnInfo(name = "item_key")
    val key: String,
    @ColumnInfo(name = "remote_payload")
    val remotePayload: String?,
    @ColumnInfo(name = "pulled_at")
    val pulledAt: Long,
)

@Entity(tableName = "sync_outbox", indices = [Index(value = ["next_attempt_at"])])
data class SyncOutboxRecord(
    @PrimaryKey(autoGenerate = true)
    val id: Long,
    val kind: String,
    @ColumnInfo(name = "item_key")
    val key: String,
    val payload: String,
    val attempts: Int,
    @ColumnInfo(name = "next_attempt_at")
    val nextAttemptAt: Long,
    @ColumnInfo(name = "created_at")
    val createdAt: Long = nextAttemptAt,
)
