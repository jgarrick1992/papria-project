package com.papria.reader.core.reader

import android.content.SharedPreferences
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class PdfPresentationStoreIsolationTest {
    @Test
    fun missingAndMalformedStateFallBackWithoutMutatingPreferences() {
        val preferences = MemorySharedPreferences()
        val store = PdfPresentationStore(preferences)

        assertEquals(PdfPresentationState(), store.load(0))
        assertTrueMapEmpty(preferences)

        preferences.edit().putString("pdf.presentation.0", "WIDTH|NaN").commit()
        assertEquals(PdfPresentationState(), store.load(0))
        assertEquals(mapOf("pdf.presentation.0" to "WIDTH|NaN"), preferences.all)
    }

    @Test
    fun savesAndLoadsEachSignedProgressIdInAnIndependentExactKey() {
        val preferences = MemorySharedPreferences()
        val store = PdfPresentationStore(preferences)
        val states = linkedMapOf(
            Long.MIN_VALUE to PdfPresentationState(1f, PdfFitMode.PAGE),
            -1L to PdfPresentationState(2f, PdfFitMode.WIDTH),
            0L to PdfPresentationState(3f, PdfFitMode.PAGE),
            1L to PdfPresentationState(4f, PdfFitMode.WIDTH),
            Long.MAX_VALUE to PdfPresentationState(5f, PdfFitMode.PAGE),
        )

        states.forEach { (progressId, state) -> store.save(progressId, state) }

        states.forEach { (progressId, state) -> assertEquals(state, store.load(progressId)) }
        assertEquals(
            states.mapKeys { (progressId, _) -> "pdf.presentation.$progressId" }
                .mapValues { (_, state) -> state.serialize() },
            preferences.all,
        )
        assertEquals(PdfPresentationState(), store.load(2))
    }

    @Test
    fun overwritingOneProgressIdCannotChangeAnother() {
        val preferences = MemorySharedPreferences()
        val store = PdfPresentationStore(preferences)
        val untouched = PdfPresentationState(4.5f, PdfFitMode.WIDTH)
        store.save(10, PdfPresentationState(2f, PdfFitMode.PAGE))
        store.save(11, untouched)

        store.save(10, PdfPresentationState(3f, PdfFitMode.WIDTH))

        assertEquals(PdfPresentationState(3f, PdfFitMode.WIDTH), store.load(10))
        assertEquals(untouched, store.load(11))
        assertEquals(2, preferences.all.size)
    }

    private fun assertTrueMapEmpty(preferences: MemorySharedPreferences) {
        assertFalse(preferences.all.isNotEmpty())
    }

    private class MemorySharedPreferences : SharedPreferences {
        private val values = linkedMapOf<String, Any?>()

        override fun getAll(): MutableMap<String, *> = LinkedHashMap(values)
        override fun getString(key: String, defValue: String?): String? = values[key] as? String ?: defValue
        @Suppress("UNCHECKED_CAST")
        override fun getStringSet(key: String, defValues: MutableSet<String>?): MutableSet<String>? =
            (values[key] as? Set<String>)?.toMutableSet() ?: defValues
        override fun getInt(key: String, defValue: Int): Int = values[key] as? Int ?: defValue
        override fun getLong(key: String, defValue: Long): Long = values[key] as? Long ?: defValue
        override fun getFloat(key: String, defValue: Float): Float = values[key] as? Float ?: defValue
        override fun getBoolean(key: String, defValue: Boolean): Boolean = values[key] as? Boolean ?: defValue
        override fun contains(key: String): Boolean = values.containsKey(key)
        override fun registerOnSharedPreferenceChangeListener(listener: SharedPreferences.OnSharedPreferenceChangeListener?) = Unit
        override fun unregisterOnSharedPreferenceChangeListener(listener: SharedPreferences.OnSharedPreferenceChangeListener?) = Unit
        override fun edit(): SharedPreferences.Editor = Editor()

        private inner class Editor : SharedPreferences.Editor {
            private val updates = linkedMapOf<String, Any?>()
            private val removals = mutableSetOf<String>()
            private var clearRequested = false

            override fun putString(key: String, value: String?): SharedPreferences.Editor = set(key, value)
            override fun putStringSet(key: String, values: MutableSet<String>?): SharedPreferences.Editor =
                set(key, values?.toSet())
            override fun putInt(key: String, value: Int): SharedPreferences.Editor = set(key, value)
            override fun putLong(key: String, value: Long): SharedPreferences.Editor = set(key, value)
            override fun putFloat(key: String, value: Float): SharedPreferences.Editor = set(key, value)
            override fun putBoolean(key: String, value: Boolean): SharedPreferences.Editor = set(key, value)
            override fun remove(key: String): SharedPreferences.Editor = apply {
                updates.remove(key)
                removals += key
            }
            override fun clear(): SharedPreferences.Editor = apply {
                clearRequested = true
                updates.clear()
                removals.clear()
            }
            override fun commit(): Boolean {
                applyChanges()
                return true
            }
            override fun apply() = applyChanges()

            private fun set(key: String, value: Any?): SharedPreferences.Editor = apply {
                removals -= key
                updates[key] = value
            }

            private fun applyChanges() {
                if (clearRequested) values.clear()
                removals.forEach(values::remove)
                updates.forEach { (key, value) ->
                    if (value == null) values.remove(key) else values[key] = value
                }
            }
        }
    }
}
