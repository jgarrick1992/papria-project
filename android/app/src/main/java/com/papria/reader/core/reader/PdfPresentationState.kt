package com.papria.reader.core.reader

import android.content.SharedPreferences

/** The two fit choices exposed by the PDF reader. */
enum class PdfFitMode {
    PAGE,
    WIDTH,
}

/**
 * Device-local PDF presentation state. Page progress continues to use the
 * existing ReadingProgress.pageNumber contract; zoom and fit are not sent to
 * BookOrbit because they describe a particular device viewport.
 */
data class PdfPresentationState(
    val zoom: Float = 1f,
    val fitMode: PdfFitMode = PdfFitMode.PAGE,
) {
    init {
        require(zoom in MIN_ZOOM..MAX_ZOOM) { "PDF zoom must be between $MIN_ZOOM and $MAX_ZOOM" }
    }

    fun serialize(): String = "${fitMode.name}|$zoom"

    companion object {
        const val MIN_ZOOM = 1f
        const val MAX_ZOOM = 5f

        /** Exact state format only; malformed or alternate encodings are rejected. */
        fun deserialize(value: String?): PdfPresentationState? {
            if (value == null) return null
            val parts = value.split('|')
            if (parts.size != 2) return null
            val fitMode = runCatching { PdfFitMode.valueOf(parts[0]) }.getOrNull() ?: return null
            val zoom = parts[1].toFloatOrNull() ?: return null
            return runCatching { PdfPresentationState(zoom, fitMode) }.getOrNull()
        }
    }
}

/** Persists PDF-only viewport settings without changing the shared progress schema. */
class PdfPresentationStore(private val preferences: SharedPreferences) {
    fun load(progressId: Long): PdfPresentationState =
        PdfPresentationState.deserialize(preferences.getString(key(progressId), null)) ?: PdfPresentationState()

    fun save(progressId: Long, state: PdfPresentationState) {
        preferences.edit().putString(key(progressId), state.serialize()).apply()
    }

    private fun key(progressId: Long): String = "pdf.presentation.$progressId"
}
