package com.papria.reader.core.local

import androidx.sqlite.db.SupportSQLiteDatabase
import androidx.sqlite.db.SupportSQLiteOpenHelper
import androidx.sqlite.db.framework.FrameworkSQLiteOpenHelperFactory
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class PapriaDatabaseMigrationTest {
    @Test
    fun version8AddsTheRemoteProgressBaselineTable() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val databaseName = "papria-progress-migration-test.db"
        val helper = FrameworkSQLiteOpenHelperFactory().create(
            SupportSQLiteOpenHelper.Configuration.builder(context)
                .name(databaseName)
                .callback(object : SupportSQLiteOpenHelper.Callback(8) {
                    override fun onCreate(db: SupportSQLiteDatabase) = Unit
                    override fun onUpgrade(db: SupportSQLiteDatabase, oldVersion: Int, newVersion: Int) = Unit
                })
                .build(),
        )

        try {
            PapriaDatabase.progressBaselineMigration.migrate(helper.writableDatabase)
            helper.writableDatabase.query("PRAGMA table_info(`progress_sync_baselines`)").use { cursor ->
                val columns = buildSet {
                    val nameIndex = cursor.getColumnIndex("name")
                    while (cursor.moveToNext()) add(cursor.getString(nameIndex))
                }
                assertEquals(
                    setOf("kind", "item_key", "remote_payload", "pulled_at"),
                    columns,
                )
            }
            assertTrue(
                helper.writableDatabase.query(
                    "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'progress_sync_baselines'",
                ).use { cursor -> cursor.moveToFirst() && cursor.getString(0).contains("PRIMARY KEY(`kind`, `item_key`)") },
            )
        } finally {
            helper.close()
            context.deleteDatabase(databaseName)
        }
    }
}
