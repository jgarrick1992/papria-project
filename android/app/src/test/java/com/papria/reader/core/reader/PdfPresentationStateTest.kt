package com.papria.reader.core.reader

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class PdfPresentationStateTest {
    @Test
    fun serializesAndRestoresExactZoomAndFitMode() {
        val state = PdfPresentationState(zoom = 2.75f, fitMode = PdfFitMode.WIDTH)

        assertEquals(state, PdfPresentationState.deserialize(state.serialize()))
    }

    @Test
    fun rejectsMalformedOrOutOfRangePresentationWithoutAliases() {
        assertNull(PdfPresentationState.deserialize("width|2.0"))
        assertNull(PdfPresentationState.deserialize("WIDTH|0.5"))
        assertNull(PdfPresentationState.deserialize("WIDTH|2.0|extra"))
    }
}
