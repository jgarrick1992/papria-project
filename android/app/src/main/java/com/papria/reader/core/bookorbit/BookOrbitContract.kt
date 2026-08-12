package com.papria.reader.core.bookorbit

import com.papria.reader.core.model.AudioProgress
import com.papria.reader.core.model.FileProgress
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.RequestBody
import okhttp3.RequestBody.Companion.toRequestBody

object BookOrbitContract {
    const val apiPrefix = "/api/v1"
    const val loginPath = "/auth/login"
    const val refreshPath = "/auth/refresh"
    const val mePath = "/auth/me"
    const val appInfoPath = "/app-info"
    const val booksQueryPath = "/books/query"
    const val bookPath = "/books/{bookId}"
    const val coverPath = "/books/{bookId}/cover"
    const val fileServePath = "/books/files/{fileId}/serve"
    const val fileProgressPath = "/books/files/{fileId}/progress"
    const val audioProgressPath = "/books/{bookId}/audio-progress"

    private val jsonMediaType = "application/json; charset=utf-8".toMediaType()

    fun loginBody(username: String, password: String): RequestBody =
        jsonObject(
            "\"username\":${jsonString(username)}",
            "\"password\":${jsonString(password)}",
        ).toRequestBody(jsonMediaType)

    fun refreshBody(): RequestBody = "{}".toRequestBody(jsonMediaType)

    fun queryBody(page: Int, size: Int, query: String? = null): RequestBody {
        val fields = mutableListOf(
            "\"sort\":[{\"field\":\"title\",\"dir\":\"asc\"}]",
            "\"pagination\":{\"page\":$page,\"size\":$size}",
            "\"collapseSeries\":false",
        )
        if (!query.isNullOrBlank()) fields += "\"q\":${jsonString(query)}"
        return jsonObject(*fields.toTypedArray()).toRequestBody(jsonMediaType)
    }

    fun fileProgressBody(progress: FileProgress): RequestBody {
        val fields = mutableListOf("\"percentage\":${progress.percentage}")
        progress.cfi?.let { fields += "\"cfi\":${jsonString(it)}" }
        progress.pageNumber?.let { fields += "\"pageNumber\":$it" }
        progress.positionSeconds?.let { fields += "\"positionSeconds\":$it" }
        progress.koboLocationSource?.let { fields += "\"koboLocationSource\":${jsonString(it)}" }
        progress.koboLocationType?.let { fields += "\"koboLocationType\":${jsonString(it)}" }
        progress.koboLocationValue?.let { fields += "\"koboLocationValue\":${jsonString(it)}" }
        progress.koboContentSourceProgressPercent?.let { fields += "\"koboContentSourceProgressPercent\":$it" }
        progress.koreaderProgress?.let { fields += "\"koreaderProgress\":${jsonString(it)}" }
        return jsonObject(*fields.toTypedArray()).toRequestBody(jsonMediaType)
    }

    fun audioProgressBody(progress: AudioProgress): RequestBody =
        jsonObject(
            "\"percentage\":${progress.percentage}",
            "\"currentFileId\":${progress.currentFileId}",
            "\"positionSeconds\":${progress.positionSeconds}",
        )
            .toRequestBody(jsonMediaType)

    private fun jsonObject(vararg fields: String): String = fields.joinToString(",", "{", "}")

    private fun jsonString(value: String): String = buildString(value.length + 2) {
        append('"')
        value.forEach { character ->
            when (character) {
                '\\' -> append("\\\\")
                '"' -> append("\\\"")
                '\b' -> append("\\b")
                '\u000C' -> append("\\f")
                '\n' -> append("\\n")
                '\r' -> append("\\r")
                '\t' -> append("\\t")
                else -> if (character.code < 0x20) {
                    append("\\u%04x".format(character.code))
                } else {
                    append(character)
                }
            }
        }
        append('"')
    }
}
