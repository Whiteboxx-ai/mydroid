package com.mydroid.protocol

/** What a change in the hidden text field means for the Mac. */
sealed class KeyOp {
    object Backspace : KeyOp()
    object Enter : KeyOp()
    object Tab : KeyOp()
    data class Text(val text: String) : KeyOp()
}

/**
 * Soft keyboard to `in.text` / `in.key`. The phone keeps a tiny hidden text field only so Android shows its keyboard.
 * Each change of that field is diffed against what it held before: removed characters are backspaces, added ones are text,
 * new lines are Enter. A one-character sentinel always sits at the front so Backspace still produces an edit when nothing
 * has been typed (an empty field reports no change at all).
 *
 * Composition (predictive text replacing "teh" with "the") needs no special case: the replacement is just
 * "backspace ×3, then the" and the Mac ends up with the same text.
 */
class KeyboardDiff(private val sentinel: String = "​") {
    private var typed = ""

    /** The text the field should hold right now. Set it back after each [onChange] (the sentinel is re-added as needed). */
    val fieldText: String get() = sentinel + typed

    /** [field] is the field's new full text. Returns what to send, in order. */
    fun onChange(field: String): List<KeyOp> {
        val old = fieldText
        if (field == old) return emptyList()
        var p = 0
        val max = minOf(old.length, field.length)
        while (p < max && old[p] == field[p]) p++
        // Never split a surrogate pair: back up if the prefix ends between the halves.
        if (p > 0 && Character.isHighSurrogate(old[p - 1])) p--
        val removed = old.substring(p)
        val added = field.substring(p)
        val ops = ArrayList<KeyOp>()
        repeat(removed.codePointCount(0, removed.length)) { ops += KeyOp.Backspace }
        ops += textOps(added)
        typed = if (field.startsWith(sentinel)) field.substring(sentinel.length) else ""
        // The field never needs to remember much: once a sentence is finished, start over with an empty one.
        if (typed.length > 60 && (typed.endsWith(" ") || typed.endsWith("\n"))) typed = ""
        return ops
    }

    fun reset() { typed = "" }

    private fun textOps(s: String): List<KeyOp> {
        if (s.isEmpty()) return emptyList()
        val out = ArrayList<KeyOp>()
        val sb = StringBuilder()
        fun flush() { if (sb.isNotEmpty()) { out += KeyOp.Text(sb.toString()); sb.setLength(0) } }
        for (ch in s) when (ch) {
            '\n', '\r' -> { flush(); out += KeyOp.Enter }
            '\t' -> { flush(); out += KeyOp.Tab }
            else -> if (ch != '​') sb.append(ch)
        }
        flush()
        return out
    }
}
