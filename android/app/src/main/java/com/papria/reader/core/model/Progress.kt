package com.papria.reader.core.model

data class FileProgress(
    val percentage: Double,
    val cfi: String? = null,
    val pageNumber: Int? = null,
    val positionSeconds: Double? = null,
    val updatedAt: String? = null,
    val dirty: Boolean = false,
    val koboLocationSource: String? = null,
    val koboLocationType: String? = null,
    val koboLocationValue: String? = null,
    val koboContentSourceProgressPercent: Double? = null,
    val koreaderProgress: String? = null,
)

data class AudioProgress(
    val percentage: Double,
    val currentFileId: Long,
    val positionSeconds: Double,
    val updatedAt: String? = null,
    val dirty: Boolean = false,
)
