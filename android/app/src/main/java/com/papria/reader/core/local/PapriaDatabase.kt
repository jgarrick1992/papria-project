package com.papria.reader.core.local

import android.content.Context
import androidx.room.Dao
import androidx.room.Database
import androidx.room.Entity
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import androidx.room.Room
import androidx.room.RoomDatabase
import androidx.room.migration.Migration
import androidx.sqlite.db.SupportSQLiteDatabase
import com.papria.reader.core.bookorbit.RemoteBookPayload
import com.papria.reader.core.bookorbit.RemoteFilePayload
import kotlinx.coroutines.flow.Flow

/**
 * Room-backed local store.
 *
 * The public facade deliberately stays synchronous because the reader and
 * WorkManager code already perform all writes off the UI thread where needed.
 * Room is still the schema owner: entities, DAO queries, and the additive
 * 4 -> 5 -> 6 -> 7 -> 8 -> 9 -> 10 migrations are compile-time checked and can be replaced by suspend/Flow
 * methods without changing the domain API. Schema versions 5→6 through 9→10 are
 * additive; audio playback settings and progress baselines never enter the BookOrbit wire payload.
 */
class PapriaDatabase private constructor(private val room: PapriaRoomDatabase) {
    private val dao = room.dao()

    fun observePublications(): Flow<List<LocalPublication>> = dao.observePublications()
    fun observeDownloads(): Flow<List<DownloadTaskRecord>> = dao.observeDownloads()

    @Synchronized
    fun upsertPublication(publication: LocalPublication) = dao.upsertPublication(publication)

    @Synchronized
    fun deletePublication(localId: String) = dao.deletePublication(localId)

    @Synchronized
    fun deleteDownloadTask(fileId: Long) = dao.deleteDownloadTask(fileId)

    @Synchronized
    fun deleteAllDownloadTasks() = dao.deleteAllDownloadTasks()

    fun hasPublicationWithHash(hash: String, excludingLocalId: String? = null): Boolean =
        dao.hasPublicationWithHash(hash, excludingLocalId)

    @Synchronized
    fun upsertRemoteBook(book: RemoteBookRecord) = dao.upsertRemoteBook(book)

    @Synchronized
    fun upsertRemoteFile(file: RemoteFileRecord) = dao.upsertRemoteFile(file)

    fun remoteFile(fileId: Long): RemoteFileRecord? = dao.remoteFile(fileId)
    fun remoteBook(bookId: Long): RemoteBookRecord? = dao.remoteBook(bookId)
    /**
     * Rehydrate the exact BookOrbit metadata that has already been fetched.
     * This is intentionally a local-only read: callers use it to keep the
     * cached catalog and file rows available when the server is offline.
     */
    fun cachedRemoteBooks(): List<RemoteBookPayload> = dao.remoteBooks().map { book ->
        RemoteBookPayload(
            id = book.id,
            title = book.title,
            author = book.author,
            coverUrl = book.coverUrl,
            files = dao.remoteFilesForBook(book.id).map { file ->
                RemoteFilePayload(
                    id = file.id,
                    fileName = file.fileName,
                    format = file.format,
                    sizeBytes = file.sizeBytes,
                    contentHash = file.contentHash,
                    localPath = file.localPath,
                )
            },
        )
    }
    fun localPublications(limit: Int = 200): List<LocalPublication> = dao.localPublications(limit.coerceIn(1, 1000))

    @Synchronized
    fun upsertDownload(task: DownloadTaskRecord) = dao.upsertDownload(task)

    fun downloadTask(fileId: Long): DownloadTaskRecord? = dao.downloadTask(fileId)

    @Synchronized
    fun upsertReadingProgress(progress: ReadingProgressRecord) = dao.upsertReadingProgress(progress)

    fun readingProgress(fileId: Long): ReadingProgressRecord? = dao.readingProgress(fileId)

    @Synchronized
    fun upsertAudioProgress(progress: AudioProgressRecord) = dao.upsertAudioProgress(progress)

    fun audioProgress(bookId: Long): AudioProgressRecord? = dao.audioProgress(bookId)

    @Synchronized
    fun deleteAudioProgress(bookId: Long) = dao.deleteAudioProgress(bookId)

    @Synchronized
    fun saveProgressBaseline(baseline: ProgressSyncBaselineRecord) = dao.saveProgressBaseline(baseline)

    fun progressBaseline(kind: String, key: String): ProgressSyncBaselineRecord? =
        dao.progressBaseline(kind, key)

    /** Coalesce snapshots so an audiobook session has one pending upload. */
    @Synchronized
    fun enqueueOutbox(kind: String, key: String, payload: String, now: Long = System.currentTimeMillis()): Long {
        dao.deleteOutboxForKey(kind, key)
        return dao.insertOutbox(SyncOutboxRecord(0L, kind, key, payload, 0, now, now))
    }

    fun dueOutbox(now: Long = System.currentTimeMillis(), limit: Int = 20): List<SyncOutboxRecord> =
        dao.dueOutbox(now, limit.coerceIn(1, 100))

    @Synchronized
    fun deleteOutbox(id: Long) = dao.deleteOutbox(id)

    @Synchronized
    fun retryOutbox(id: Long, attempts: Int, nextAttemptAt: Long) = dao.retryOutbox(id, attempts, nextAttemptAt)

    @Synchronized
    fun saveConflict(conflict: SyncConflictRecord) = dao.saveConflict(conflict)

    fun conflict(kind: String, key: String): SyncConflictRecord? = dao.conflict(kind, key)
    fun conflicts(): List<SyncConflictRecord> = dao.conflicts()

    @Synchronized
    fun deleteConflict(kind: String, key: String) = dao.deleteConflict(kind, key)

    @Synchronized
    fun saveServerProfile(profile: ServerProfileRecord) = dao.saveServerProfile(profile)

    fun serverProfile(): ServerProfileRecord? = dao.serverProfile()

    /** Remove the persisted BookOrbit endpoint and encrypted session values. */
    @Synchronized
    fun deleteServerProfile() = dao.deleteServerProfile()

    /** Remove the cached BookOrbit catalog; foreign-keyed file rows follow it. */
    @Synchronized
    fun deleteCachedRemoteBooks() = dao.deleteCachedRemoteBooks()

    @Synchronized
    fun saveTransfer(upload: TransferUploadRecord) = dao.saveTransfer(upload)

    fun transfer(uploadId: String): TransferUploadRecord? = dao.transfer(uploadId)

    @Synchronized
    fun updateTransferReceived(uploadId: String, receivedBytes: Long, now: Long = System.currentTimeMillis()) =
        dao.updateTransferReceived(uploadId, receivedBytes, now)

    @Synchronized
    fun deleteTransfer(uploadId: String) = dao.deleteTransfer(uploadId)

    fun staleTransfers(beforeEpochMillis: Long): List<TransferUploadRecord> = dao.staleTransfers(beforeEpochMillis)

    companion object {
        private const val DATABASE_NAME = "papria.db"
        private val MIGRATION_4_5 = object : Migration(4, 5) {
            override fun migrate(db: SupportSQLiteDatabase) {
                // Version 4 already contains every table/column used by Room.
                // Bumping the Room schema records the migration without
                // deleting local books, progress, or resumable transfers.
            }
        }
        private val MIGRATION_5_6 = object : Migration(5, 6) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE server_profile ADD COLUMN certificate_sha256 TEXT")
            }
        }
        private val MIGRATION_6_7 = object : Migration(6, 7) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE audio_progress ADD COLUMN playback_speed REAL NOT NULL DEFAULT 1.0")
                db.execSQL("ALTER TABLE audio_progress ADD COLUMN sleep_until INTEGER")
            }
        }
        private val MIGRATION_7_8 = object : Migration(7, 8) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE server_profile ADD COLUMN cleartext_http_confirmed_host TEXT")
                db.execSQL("ALTER TABLE server_profile ADD COLUMN cleartext_http_confirmed_port INTEGER")
                db.execSQL("ALTER TABLE server_profile ADD COLUMN cleartext_http_confirmed_at INTEGER")
            }
        }
        private val MIGRATION_8_9 = object : Migration(8, 9) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL(
                    "CREATE TABLE IF NOT EXISTS `progress_sync_baselines` (" +
                        "`kind` TEXT NOT NULL, " +
                        "`item_key` TEXT NOT NULL, " +
                        "`remote_payload` TEXT, " +
                        "`pulled_at` INTEGER NOT NULL, " +
                        "PRIMARY KEY(`kind`, `item_key`))",
                )
            }
        }

        /**
         * Incomplete uploads created before v10 are intentionally discarded.
         * They were bound to an expired receiver bearer and have no independent
         * resume proof. Reusing `token_hash` as a resume key would silently map
         * two credentials with different lifetimes, so it is not permitted.
         */
        private val MIGRATION_9_10 = object : Migration(9, 10) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("DROP TABLE IF EXISTS `transfer_uploads`")
                db.execSQL(
                    "CREATE TABLE IF NOT EXISTS `transfer_uploads` (" +
                        "`upload_id` TEXT NOT NULL, " +
                        "`file_name` TEXT NOT NULL, " +
                        "`size_bytes` INTEGER NOT NULL, " +
                        "`resume_token_hash` TEXT NOT NULL, " +
                        "`temp_path` TEXT NOT NULL, " +
                        "`received_bytes` INTEGER NOT NULL, " +
                        "`created_at` INTEGER NOT NULL, " +
                        "`updated_at` INTEGER NOT NULL, " +
                        "PRIMARY KEY(`upload_id`))",
                )
            }
        }

        // Kept visible to the Android migration test; production construction
        // still registers the same singleton migration above.
        internal val progressBaselineMigration: Migration = MIGRATION_8_9

        @Volatile private var instance: PapriaDatabase? = null

        fun get(context: Context): PapriaDatabase = instance ?: synchronized(this) {
            instance ?: PapriaDatabase(
                Room.databaseBuilder(context.applicationContext, PapriaRoomDatabase::class.java, DATABASE_NAME)
                    .addMigrations(MIGRATION_4_5)
                    .addMigrations(MIGRATION_5_6)
                    .addMigrations(MIGRATION_6_7)
                    .addMigrations(MIGRATION_7_8)
                    .addMigrations(MIGRATION_8_9)
                    .addMigrations(MIGRATION_9_10)
                    // The existing facade is intentionally synchronous. The
                    // calling layers already dispatch long operations to
                    // WorkManager/IO; this flag only keeps tiny state reads
                    // compatible with the original API.
                    .allowMainThreadQueries()
                    .build(),
            ).also { instance = it }
        }
    }
}

@Database(
    entities = [
        LocalPublication::class,
        RemoteBookRecord::class,
        RemoteFileRecord::class,
        DownloadTaskRecord::class,
        ReadingProgressRecord::class,
        AudioProgressRecord::class,
        ProgressSyncBaselineRecord::class,
        SyncOutboxRecord::class,
        ServerProfileRecord::class,
        TransferUploadRecord::class,
        SyncConflictRecord::class,
    ],
    version = 10,
    exportSchema = false,
)
abstract class PapriaRoomDatabase : RoomDatabase() {
    abstract fun dao(): PapriaDao
}

@Dao
abstract class PapriaDao {
    @Query("SELECT * FROM publications ORDER BY updated_at DESC LIMIT :limit")
    abstract fun localPublications(limit: Int): List<LocalPublication>

    @Query("SELECT * FROM publications ORDER BY updated_at DESC")
    abstract fun observePublications(): Flow<List<LocalPublication>>

    @Query("DELETE FROM publications WHERE local_id = :localId")
    abstract fun deletePublication(localId: String)

    @Query("SELECT EXISTS(SELECT 1 FROM publications WHERE content_hash = :hash AND (:excludingLocalId IS NULL OR local_id <> :excludingLocalId))")
    abstract fun hasPublicationWithHash(hash: String, excludingLocalId: String?): Boolean

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    abstract fun upsertPublication(publication: LocalPublication)

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    abstract fun upsertRemoteBook(book: RemoteBookRecord)

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    abstract fun upsertRemoteFile(file: RemoteFileRecord)

    @Query("SELECT * FROM remote_files WHERE remote_file_id = :fileId LIMIT 1")
    abstract fun remoteFile(fileId: Long): RemoteFileRecord?

    @Query("SELECT * FROM remote_books WHERE remote_book_id = :bookId LIMIT 1")
    abstract fun remoteBook(bookId: Long): RemoteBookRecord?

    @Query("SELECT * FROM remote_books ORDER BY updated_at DESC")
    abstract fun remoteBooks(): List<RemoteBookRecord>

    @Query("SELECT * FROM remote_files WHERE remote_book_id = :bookId ORDER BY remote_file_id ASC")
    abstract fun remoteFilesForBook(bookId: Long): List<RemoteFileRecord>

    @Query("SELECT * FROM download_tasks ORDER BY updated_at DESC")
    abstract fun observeDownloads(): Flow<List<DownloadTaskRecord>>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    abstract fun upsertDownload(task: DownloadTaskRecord)

    @Query("SELECT * FROM download_tasks WHERE remote_file_id = :fileId LIMIT 1")
    abstract fun downloadTask(fileId: Long): DownloadTaskRecord?

    @Query("DELETE FROM download_tasks WHERE remote_file_id = :fileId")
    abstract fun deleteDownloadTask(fileId: Long)

    @Query("DELETE FROM download_tasks")
    abstract fun deleteAllDownloadTasks()

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    abstract fun upsertReadingProgress(progress: ReadingProgressRecord)

    @Query("SELECT * FROM reading_progress WHERE file_id = :fileId LIMIT 1")
    abstract fun readingProgress(fileId: Long): ReadingProgressRecord?

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    abstract fun upsertAudioProgress(progress: AudioProgressRecord)

    @Query("SELECT * FROM audio_progress WHERE book_id = :bookId LIMIT 1")
    abstract fun audioProgress(bookId: Long): AudioProgressRecord?

    @Query("DELETE FROM audio_progress WHERE book_id = :bookId")
    abstract fun deleteAudioProgress(bookId: Long)

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    abstract fun saveProgressBaseline(baseline: ProgressSyncBaselineRecord)

    @Query("SELECT * FROM progress_sync_baselines WHERE kind = :kind AND item_key = :key LIMIT 1")
    abstract fun progressBaseline(kind: String, key: String): ProgressSyncBaselineRecord?

    @Insert
    abstract fun insertOutbox(outbox: SyncOutboxRecord): Long

    @Query("DELETE FROM sync_outbox WHERE kind = :kind AND item_key = :key")
    abstract fun deleteOutboxForKey(kind: String, key: String)

    @Query("SELECT * FROM sync_outbox WHERE next_attempt_at <= :now ORDER BY created_at ASC LIMIT :limit")
    abstract fun dueOutbox(now: Long, limit: Int): List<SyncOutboxRecord>

    @Query("DELETE FROM sync_outbox WHERE id = :id")
    abstract fun deleteOutbox(id: Long)

    @Query("UPDATE sync_outbox SET attempts = :attempts, next_attempt_at = :nextAttemptAt WHERE id = :id")
    abstract fun retryOutbox(id: Long, attempts: Int, nextAttemptAt: Long)

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    abstract fun saveConflict(conflict: SyncConflictRecord)

    @Query("SELECT * FROM sync_conflicts WHERE kind = :kind AND item_key = :key LIMIT 1")
    abstract fun conflict(kind: String, key: String): SyncConflictRecord?

    @Query("SELECT * FROM sync_conflicts ORDER BY created_at ASC")
    abstract fun conflicts(): List<SyncConflictRecord>

    @Query("DELETE FROM sync_conflicts WHERE kind = :kind AND item_key = :key")
    abstract fun deleteConflict(kind: String, key: String)

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    abstract fun saveServerProfile(profile: ServerProfileRecord)

    @Query("SELECT * FROM server_profile WHERE id = 1 LIMIT 1")
    abstract fun serverProfile(): ServerProfileRecord?

    @Query("DELETE FROM server_profile WHERE id = 1")
    abstract fun deleteServerProfile()

    @Query("DELETE FROM remote_books")
    abstract fun deleteCachedRemoteBooks()

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    abstract fun saveTransfer(upload: TransferUploadRecord)

    @Query("SELECT * FROM transfer_uploads WHERE upload_id = :uploadId LIMIT 1")
    abstract fun transfer(uploadId: String): TransferUploadRecord?

    @Query("UPDATE transfer_uploads SET received_bytes = :receivedBytes, updated_at = :now WHERE upload_id = :uploadId")
    abstract fun updateTransferReceived(uploadId: String, receivedBytes: Long, now: Long)

    @Query("DELETE FROM transfer_uploads WHERE upload_id = :uploadId")
    abstract fun deleteTransfer(uploadId: String)

    @Query("SELECT * FROM transfer_uploads WHERE updated_at < :beforeEpochMillis")
    abstract fun staleTransfers(beforeEpochMillis: Long): List<TransferUploadRecord>
}

@Entity(tableName = "server_profile")
data class ServerProfileRecord(
    @androidx.room.PrimaryKey val id: Int = 1,
    @androidx.room.ColumnInfo(name = "base_url") val baseUrl: String,
    val username: String,
    @androidx.room.ColumnInfo(name = "access_token") val accessToken: String?,
    @androidx.room.ColumnInfo(name = "refresh_cookie") val refreshCookie: String?,
    @androidx.room.ColumnInfo(name = "server_version") val serverVersion: String?,
    @androidx.room.ColumnInfo(name = "certificate_sha256") val certificateSha256: String?,
    @androidx.room.ColumnInfo(name = "cleartext_http_confirmed_host") val cleartextHttpConfirmedHost: String? = null,
    @androidx.room.ColumnInfo(name = "cleartext_http_confirmed_port") val cleartextHttpConfirmedPort: Int? = null,
    @androidx.room.ColumnInfo(name = "cleartext_http_confirmed_at") val cleartextHttpConfirmedAt: Long? = null,
)

@Entity(tableName = "transfer_uploads")
data class TransferUploadRecord(
    @androidx.room.PrimaryKey @androidx.room.ColumnInfo(name = "upload_id") val uploadId: String,
    @androidx.room.ColumnInfo(name = "file_name") val fileName: String,
    @androidx.room.ColumnInfo(name = "size_bytes") val sizeBytes: Long,
    @androidx.room.ColumnInfo(name = "resume_token_hash") val resumeTokenHash: String,
    @androidx.room.ColumnInfo(name = "temp_path") val tempPath: String,
    @androidx.room.ColumnInfo(name = "received_bytes") val receivedBytes: Long,
    @androidx.room.ColumnInfo(name = "created_at") val createdAt: Long,
    @androidx.room.ColumnInfo(name = "updated_at") val updatedAt: Long,
)

@Entity(tableName = "sync_conflicts", primaryKeys = ["kind", "item_key"])
data class SyncConflictRecord(
    val kind: String,
    @androidx.room.ColumnInfo(name = "item_key") val key: String,
    @androidx.room.ColumnInfo(name = "local_payload") val localPayload: String,
    @androidx.room.ColumnInfo(name = "remote_payload") val remotePayload: String,
    @androidx.room.ColumnInfo(name = "created_at") val createdAt: Long,
)
