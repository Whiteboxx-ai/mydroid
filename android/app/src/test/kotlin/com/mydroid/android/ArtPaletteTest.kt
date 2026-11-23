package com.mydroid.android

import com.mydroid.android.remote.ArtPalette
import org.junit.Assert.*
import org.junit.Test

class ArtPaletteTest {
    private fun px(r: Int, g: Int, b: Int, a: Int = 255) = (a shl 24) or (r shl 16) or (g shl 8) or b
    private fun hueOf(c: Int): Int {
        val r = (c shr 16 and 0xFF) / 255.0; val g = (c shr 8 and 0xFF) / 255.0; val b = (c and 0xFF) / 255.0
        val mx = maxOf(r, g, b); val d = mx - minOf(r, g, b)
        val h = when { d == 0.0 -> 0.0; mx == r -> ((g - b) / d + 6) % 6; mx == g -> (b - r) / d + 2; else -> (r - g) / d + 4 }
        return (h * 60).toInt()
    }
    private fun brightest(c: Int) = maxOf(c shr 16 and 0xFF, c shr 8 and 0xFF, c and 0xFF) / 255.0

    @Test fun aGreyOrBlackCoverGetsTheNeutralWash() {
        assertEquals(listOf(ArtPalette.NEUTRAL), ArtPalette.wash(IntArray(100) { px(128, 128, 128) }))
        assertEquals(listOf(ArtPalette.NEUTRAL), ArtPalette.wash(IntArray(100) { px(5, 5, 5) }))
        assertEquals(listOf(ArtPalette.NEUTRAL), ArtPalette.wash(IntArray(0)))
    }

    @Test fun theMostProminentColourComesFirstAndKeepsItsHue() {
        val px = IntArray(100) { if (it < 70) px(220, 40, 60) else px(30, 120, 200) }
        val w = ArtPalette.wash(px)
        assertEquals(2, w.size)
        assertTrue("red first: ${hueOf(w[0])}", hueOf(w[0]) in 340..359 || hueOf(w[0]) in 0..10)
        assertTrue("blue second: ${hueOf(w[1])}", hueOf(w[1]) in 195..225)
    }

    @Test fun everyWashColourIsDarkEnoughForWhiteText() {
        val w = ArtPalette.wash(IntArray(100) { px(255, 240, 0) })
        assertTrue(w.all { brightest(it) <= 0.56 })
        assertTrue(w.all { brightest(it) >= 0.31 })
    }

    @Test fun similarHuesAreNotPickedTwice() {
        val px = IntArray(100) { if (it % 2 == 0) px(220, 40, 60) else px(225, 60, 40) }
        assertEquals(1, ArtPalette.wash(px).size)
    }

    @Test fun transparentPixelsAreIgnored() {
        assertEquals(listOf(ArtPalette.NEUTRAL), ArtPalette.wash(IntArray(50) { px(255, 0, 0, a = 0) }))
    }
}
