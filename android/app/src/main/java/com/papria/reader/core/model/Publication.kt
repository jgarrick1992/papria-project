package com.papria.reader.core.model

data class Publication(
    val localId: String,
    val title: String,
    val author: String?,
    val format: String,
    val localPath: String?,
    val remoteBookId: Long?,
    val remoteFileId: Long?,
    val downloaded: Boolean,
)
