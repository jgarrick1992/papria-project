package com.papria.reader.core.reader

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Test
import java.util.Locale

class PdfPresentationStateBoundaryTest {
    @Test
    fun acceptsBothInclusiveZoomBounds() {
        val minimum = PdfPresentationState(PdfPresentationState.MIN_ZOOM, PdfFitMode.PAGE)
        val maximum = PdfPresentationState(PdfPresentationState.MAX_ZOOM, PdfFitMode.WIDTH)

        assertEquals(minimum, PdfPresentationState.deserialize(minimum.serialize()))
        assertEquals(maximum, PdfPresentationState.deserialize(maximum.serialize()))
    }

    @Test
    fun rejectsNonFiniteZoomValues() {
        listOf("NaN", "Infinity", "-Infinity").forEach { zoom ->
            assertNull("$zoom must not persist as a reader viewport", PdfPresentationState.deserialize("PAGE|$zoom"))
        }
    }

    @Test
    fun constructorRejectsTheNearestValuesOutsideBothZoomBounds() {
        val invalidZooms = listOf(
            Float.NEGATIVE_INFINITY,
            -0.0f,
            0.0f,
            Math.nextDown(PdfPresentationState.MIN_ZOOM),
            Math.nextUp(PdfPresentationState.MAX_ZOOM),
            Float.POSITIVE_INFINITY,
            Float.NaN,
        )

        invalidZooms.forEach { zoom ->
            assertThrows("must reject zoom $zoom", IllegalArgumentException::class.java) {
                PdfPresentationState(zoom, PdfFitMode.PAGE)
            }
        }
    }

    @Test
    fun deserializeRejectsNullEmptyMalformedAndAlternateEnumValues() {
        val invalidValues = listOf<String?>(
            null,
            "",
            "|",
            "PAGE",
            "PAGE|",
            "|1.0",
            "page|1.0",
            "Page|1.0",
            "LANDSCAPE|1.0",
            "PAGE|1.0|extra",
            "PAGE||1.0",
            "PAGE|not-a-number",
            "PAGE|0.0",
            "PAGE|${Math.nextDown(PdfPresentationState.MIN_ZOOM)}",
            "WIDTH|${Math.nextUp(PdfPresentationState.MAX_ZOOM)}",
        )

        invalidValues.forEach { value ->
            assertNull("must reject persisted value: $value", PdfPresentationState.deserialize(value))
        }
    }

    @Test
    fun serializationIsLocaleIndependentForEveryFitMode() {
        val original = Locale.getDefault()
        try {
            Locale.setDefault(Locale.FRANCE)
            PdfFitMode.entries.forEach { fitMode ->
                val state = PdfPresentationState(2.5f, fitMode)
                assertEquals("${fitMode.name}|2.5", state.serialize())
                assertEquals(state, PdfPresentationState.deserialize(state.serialize()))
            }
        } finally {
            Locale.setDefault(original)
        }
    }
}
