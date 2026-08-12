package com.papria.reader.core.bookorbit

import com.papria.reader.core.model.AudioProgress
import com.papria.reader.core.model.FileProgress
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ProgressSyncConflictPolicyTest {
    @Test
    fun dirtyFileWithoutAPreviousPullIsAllowedToUpload() {
        val remote = FileProgress(12.0, cfi = "epubcfi(/6/4)", pageNumber = 2)

        assertFalse(
            ProgressSyncConflictPolicy.shouldCreateFileConflict(
                isLocalDirty = true,
                lastPulled = null,
                remote = remote,
            ),
        )
    }

    @Test
    fun dirtyFileWithUnchangedRemoteBaselineHasNoConflict() {
        val baseline = FileProgress(12.0, cfi = "epubcfi(/6/4)", pageNumber = 2)

        assertFalse(
            ProgressSyncConflictPolicy.shouldCreateFileConflict(
                isLocalDirty = true,
                lastPulled = baseline,
                remote = baseline.copy(percentage = 12.05),
            ),
        )
    }

    @Test
    fun dirtyFileWithChangedRemoteBaselineCreatesConflict() {
        val baseline = FileProgress(12.0, cfi = "epubcfi(/6/4)", pageNumber = 2)

        assertTrue(
            ProgressSyncConflictPolicy.shouldCreateFileConflict(
                isLocalDirty = true,
                lastPulled = baseline,
                remote = baseline.copy(pageNumber = 3),
            ),
        )
        assertFalse(
            ProgressSyncConflictPolicy.shouldCreateFileConflict(
                isLocalDirty = false,
                lastPulled = baseline,
                remote = baseline.copy(pageNumber = 3),
            ),
        )
    }

    @Test
    fun dirtyAudioWithoutAPreviousPullIsAllowedToUpload() {
        val remote = AudioProgress(20.0, currentFileId = 7, positionSeconds = 30.0)

        assertFalse(
            ProgressSyncConflictPolicy.shouldCreateAudioConflict(
                isLocalDirty = true,
                hasLastPull = false,
                lastPulled = null,
                remote = remote,
            ),
        )
    }

    @Test
    fun dirtyAudioWithUnchangedRemoteBaselineHasNoConflict() {
        val baseline = AudioProgress(20.0, currentFileId = 7, positionSeconds = 30.0)

        assertFalse(
            ProgressSyncConflictPolicy.shouldCreateAudioConflict(
                isLocalDirty = true,
                hasLastPull = true,
                lastPulled = baseline,
                remote = baseline.copy(positionSeconds = 30.5),
            ),
        )
    }

    @Test
    fun dirtyAudioWithChangedRemoteBaselineCreatesConflict() {
        val baseline = AudioProgress(20.0, currentFileId = 7, positionSeconds = 30.0)

        assertTrue(
            ProgressSyncConflictPolicy.shouldCreateAudioConflict(
                isLocalDirty = true,
                hasLastPull = true,
                lastPulled = baseline,
                remote = baseline.copy(currentFileId = 8),
            ),
        )
    }

    @Test
    fun audioBaselineTracksAnExplicitlyEmptyRemoteValue() {
        val remote = AudioProgress(20.0, currentFileId = 7, positionSeconds = 30.0)

        assertFalse(
            ProgressSyncConflictPolicy.shouldCreateAudioConflict(
                isLocalDirty = true,
                hasLastPull = true,
                lastPulled = null,
                remote = null,
            ),
        )
        assertTrue(
            ProgressSyncConflictPolicy.shouldCreateAudioConflict(
                isLocalDirty = true,
                hasLastPull = true,
                lastPulled = null,
                remote = remote,
            ),
        )
        assertTrue(
            ProgressSyncConflictPolicy.shouldCreateAudioConflict(
                isLocalDirty = true,
                hasLastPull = true,
                lastPulled = remote,
                remote = null,
            ),
        )
    }
}
