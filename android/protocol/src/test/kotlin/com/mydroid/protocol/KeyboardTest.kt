package com.mydroid.protocol

import org.junit.Assert.*
import org.junit.Test

class KeyboardTest {
    /** Plays text edits into the field and returns the text the Mac would have after the ops (Backspace removes one char). */
    private class Sim {
        val kb = KeyboardDiff()
        val mac = StringBuilder()
        var backspacesOnEmpty = 0
        fun edit(newField: String): List<KeyOp> {
            val ops = kb.onChange(newField)
            for (o in ops) when (o) {
                KeyOp.Backspace -> if (mac.isEmpty()) backspacesOnEmpty++ else mac.setLength(mac.length - 1)
                KeyOp.Enter -> mac.append('\n')
                KeyOp.Tab -> mac.append('\t')
                is KeyOp.Text -> mac.append(o.text)
            }
            return ops
        }
        fun type(s: String) = edit(kb.fieldText + s)
        fun backspace() = edit(kb.fieldText.dropLast(1))
    }

    @Test fun typingSendsTextPerChange() {
        val s = Sim()
        assertEquals(listOf(KeyOp.Text("h")), s.type("h"))
        assertEquals(listOf(KeyOp.Text("i")), s.type("i"))
        assertEquals("hi", s.mac.toString())
    }

    @Test fun backspaceSendsBackspaceEvenOnAnEmptyField() {
        val s = Sim()
        assertEquals(listOf(KeyOp.Backspace), s.backspace())
        assertEquals(listOf(KeyOp.Backspace), s.backspace())
        assertEquals(2, s.backspacesOnEmpty)
        s.type("ab"); s.backspace()
        assertEquals("a", s.mac.toString())
    }

    @Test fun newlineIsEnter() {
        val s = Sim()
        assertEquals(listOf(KeyOp.Text("a"), KeyOp.Enter, KeyOp.Text("b")), s.type("a\nb"))
    }

    @Test fun predictiveReplacementEndsUpRight() {
        val s = Sim()
        s.type("teh")
        // the IME replaces the word: the field now holds "the"
        s.edit(s.kb.fieldText.dropLast(3) + "the")
        assertEquals("the", s.mac.toString())
    }

    @Test fun pasteOfSeveralCharactersIsOneText() {
        val s = Sim()
        assertEquals(listOf(KeyOp.Text("hello world")), s.type("hello world"))
    }

    @Test fun emojiAreNotSplit() {
        val s = Sim()
        s.type("a👍")
        assertEquals("a👍", s.mac.toString())
        val ops = s.edit(s.kb.fieldText.dropLast(2)) // delete the emoji (two UTF-16 units)
        assertEquals(listOf(KeyOp.Backspace), ops)
    }

    @Test fun unchangedFieldSendsNothingAndLongTextsResetQuietly() {
        val s = Sim()
        assertTrue(s.edit(s.kb.fieldText).isEmpty())
        repeat(30) { s.type("word ") }
        assertTrue("field stays small", s.kb.fieldText.length <= 70)
        assertEquals("word ".repeat(30), s.mac.toString())
    }
}
