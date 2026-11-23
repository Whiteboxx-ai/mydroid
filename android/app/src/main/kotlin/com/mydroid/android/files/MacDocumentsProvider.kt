package com.mydroid.android.files

import android.content.res.AssetFileDescriptor
import android.database.Cursor
import android.database.MatrixCursor
import android.os.Bundle
import android.os.CancellationSignal
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
import android.provider.DocumentsContract.Root
import android.provider.DocumentsProvider
import android.graphics.Point
import android.util.Log
import com.mydroid.android.R
import com.mydroid.android.manager
import com.mydroid.protocol.FsDocId
import com.mydroid.protocol.FsEntry
import com.mydroid.protocol.FsHit
import com.mydroid.protocol.FsListing
import java.io.File
import java.io.FileNotFoundException

private const val TAG = "MydroidFs"

private val ROOT_COLUMNS = arrayOf(
    Root.COLUMN_ROOT_ID, Root.COLUMN_FLAGS, Root.COLUMN_ICON, Root.COLUMN_TITLE, Root.COLUMN_SUMMARY,
    Root.COLUMN_DOCUMENT_ID, Root.COLUMN_MIME_TYPES,
)
private val DOC_COLUMNS = arrayOf(
    Document.COLUMN_DOCUMENT_ID, Document.COLUMN_DISPLAY_NAME, Document.COLUMN_MIME_TYPE, Document.COLUMN_SIZE,
    Document.COLUMN_LAST_MODIFIED, Document.COLUMN_FLAGS,
)

/** A cursor whose extras ([DocumentsContract.EXTRA_LOADING], [DocumentsContract.EXTRA_ERROR]) the Files app reads. */
private class DocCursor(columns: Array<String>) : MatrixCursor(columns) {
    private var extra: Bundle = Bundle.EMPTY
    fun extras(loading: Boolean, error: String?): DocCursor {
        extra = Bundle().apply {
            if (loading) putBoolean(DocumentsContract.EXTRA_LOADING, true)
            if (error != null) putString(DocumentsContract.EXTRA_ERROR, error)
        }
        return this
    }
    override fun getExtras(): Bundle = extra
}

/**
 * Your Mac in Android's Files app and every system file picker (PROTOCOL.md 9). One root per Mac; the top level is the
 * folders the Mac shares. Folder contents are fetched over the live session: a query returns at once with
 * `EXTRA_LOADING` and the cached rows, and `notifyChange` on the children URI delivers the real ones. Calls arrive on
 * binder threads, never the main thread; nothing here touches the socket directly.
 */
class MacDocumentsProvider : DocumentsProvider() {
    private val files: MacFiles get() = context!!.manager().macFiles
    private val cr get() = context!!.contentResolver

    override fun onCreate(): Boolean = true

    // ---------------------------------------------------------------- roots

    override fun queryRoots(projection: Array<String>?): Cursor {
        val c = DocCursor(projection ?: ROOT_COLUMNS)
        c.setNotificationUri(cr, files.rootsUri())
        val mf = files
        val mac = mf.macId
        if (mac == null || !mf.rootVisible) return c
        var flags = Root.FLAG_SUPPORTS_SEARCH or Root.FLAG_SUPPORTS_RECENTS or Root.FLAG_SUPPORTS_IS_CHILD
        if (mf.anyWritable) flags = flags or Root.FLAG_SUPPORTS_CREATE
        c.newRow().apply {
            add(Root.COLUMN_ROOT_ID, mac)
            add(Root.COLUMN_FLAGS, flags)
            add(Root.COLUMN_ICON, R.drawable.ic_laptop)
            add(Root.COLUMN_TITLE, mf.macName)
            add(Root.COLUMN_SUMMARY, "via Mydroid")
            add(Root.COLUMN_DOCUMENT_ID, mac)
            add(Root.COLUMN_MIME_TYPES, "*/*")
        }
        return c
    }

    // ---------------------------------------------------------------- documents

    private fun parse(documentId: String?): FsDocId {
        val id = FsDocId.parse(documentId) ?: throw FileNotFoundException("Not a Mac document")
        if (id.mac != files.macId) throw FileNotFoundException("That Mac isn't paired anymore")
        return id
    }

    private fun addShare(c: MatrixCursor, id: FsDocId, name: String, writable: Boolean) {
        c.newRow().apply {
            add(Document.COLUMN_DOCUMENT_ID, id.encode())
            add(Document.COLUMN_DISPLAY_NAME, name)
            add(Document.COLUMN_MIME_TYPE, Document.MIME_TYPE_DIR)
            add(Document.COLUMN_SIZE, null)
            add(Document.COLUMN_LAST_MODIFIED, null)
            add(Document.COLUMN_FLAGS, if (writable) Document.FLAG_DIR_SUPPORTS_CREATE else 0)
        }
    }

    private fun thumbable(mime: String) = mime.startsWith("image/") || mime.startsWith("video/") || mime == "application/pdf"

    private fun addEntry(c: MatrixCursor, id: FsDocId, e: FsEntry?, pending: PendingDoc? = null) {
        val name = e?.name ?: pending?.name ?: id.name
        val dir = e?.dir == true
        val mime = if (dir) Document.MIME_TYPE_DIR else MacFiles.mimeFor(name, e?.mime ?: pending?.mime ?: "")
        var flags = 0
        if (dir) { if (files.writable(id.share ?: "")) flags = flags or Document.FLAG_DIR_SUPPORTS_CREATE }
        else {
            if (thumbable(mime)) flags = flags or Document.FLAG_SUPPORTS_THUMBNAIL
            if (pending != null) flags = flags or Document.FLAG_SUPPORTS_WRITE
        }
        c.newRow().apply {
            add(Document.COLUMN_DOCUMENT_ID, id.encode())
            add(Document.COLUMN_DISPLAY_NAME, name)
            add(Document.COLUMN_MIME_TYPE, mime)
            add(Document.COLUMN_SIZE, if (dir || e == null && pending == null) null else (e?.size ?: 0L))
            add(Document.COLUMN_LAST_MODIFIED, e?.mtime?.takeIf { it > 0 })
            add(Document.COLUMN_FLAGS, flags)
        }
    }

    private fun addHit(c: MatrixCursor, mac: String, h: FsHit) = addEntry(c, FsDocId.of(mac, h.root, h.path), h.entry)

    override fun queryDocument(documentId: String?, projection: Array<String>?): Cursor {
        val id = parse(documentId)
        val mf = files
        val c = DocCursor(projection ?: DOC_COLUMNS)
        when {
            id.isMacRoot -> c.newRow().apply {
                add(Document.COLUMN_DOCUMENT_ID, id.encode())
                add(Document.COLUMN_DISPLAY_NAME, mf.macName)
                add(Document.COLUMN_MIME_TYPE, Document.MIME_TYPE_DIR)
                add(Document.COLUMN_FLAGS, 0)
            }
            id.isShare -> {
                val r = mf.browser.roots?.roots?.firstOrNull { it.id == id.share }
                addShare(c, id, r?.name ?: id.share!!, r?.writable == true)
            }
            else -> {
                val pending = mf.pending[id.encode()]
                val e = if (pending != null) null else mf.browser.known(id.share!!, id.path) ?: mf.browser.lookup(id.share!!, id.path, 4_000)
                addEntry(c, id, e, pending)
            }
        }
        return c
    }

    override fun queryChildDocuments(parentDocumentId: String?, projection: Array<String>?, sortOrder: String?): Cursor {
        val parent = parse(parentDocumentId)
        val mf = files
        val mac = parent.mac
        val c = DocCursor(projection ?: DOC_COLUMNS)
        c.setNotificationUri(cr, DocumentsContract.buildChildDocumentsUri(MacFiles.AUTHORITY, parent.encode()))
        if (parent.isMacRoot) {
            val l = mf.browser.rootsListing()
            l.items.forEach { addShare(c, FsDocId.of(mac, it.id, ""), it.name, it.writable) }
            return c.extras(l.loading, l.error)
        }
        val share = parent.share!!
        val l: FsListing<FsEntry> = mf.browser.children(share, parent.path)
        val names = HashSet<String>()
        l.items.sortedWith(compareByDescending<FsEntry> { it.dir }.thenBy { it.name.lowercase() }).forEach {
            names += it.name
            addEntry(c, parent.child(it.name), it)
        }
        // Documents created through the picker that haven't reached the Mac yet.
        mf.pending.values.filter { it.id.parent() == parent && it.name !in names }.forEach { addEntry(c, it.id, null, it) }
        Log.i(TAG, "children rows=${c.count} loading=${l.loading} error=${l.error != null}")
        return c.extras(l.loading, l.error)
    }

    override fun isChildDocument(parentDocumentId: String?, documentId: String?): Boolean {
        val p = FsDocId.parse(parentDocumentId) ?: return false
        val d = FsDocId.parse(documentId) ?: return false
        return p.contains(d)
    }

    override fun findDocumentPath(parentDocumentId: String?, childDocumentId: String?): DocumentsContract.Path {
        val child = parse(childDocumentId)
        val chain = ArrayList<String>()
        var cur: FsDocId? = child
        val stop = parentDocumentId?.let { FsDocId.parse(it) }
        while (cur != null) {
            chain += cur.encode()
            if (stop != null && cur == stop) break
            cur = cur.parent()
        }
        chain.reverse()
        return DocumentsContract.Path(if (parentDocumentId == null) child.mac else null, chain)
    }

    // ---------------------------------------------------------------- search and recents

    override fun querySearchDocuments(rootId: String?, query: String?, projection: Array<String>?): Cursor {
        val mf = files
        val root = rootId?.takeIf { it == mf.macId } ?: throw FileNotFoundException("That Mac isn't paired anymore")
        val q = query.orEmpty().trim()
        val c = DocCursor(projection ?: DOC_COLUMNS)
        c.setNotificationUri(cr, DocumentsContract.buildSearchDocumentsUri(MacFiles.AUTHORITY, root, q))
        if (q.isEmpty()) return c
        val l = mf.browser.search(q)
        l.items.forEach { addHit(c, root, it) }
        return c.extras(l.loading, l.error)
    }

    override fun queryRecentDocuments(rootId: String?, projection: Array<String>?): Cursor {
        val mf = files
        val root = rootId?.takeIf { it == mf.macId } ?: throw FileNotFoundException("That Mac isn't paired anymore")
        val c = DocCursor(projection ?: DOC_COLUMNS)
        c.setNotificationUri(cr, DocumentsContract.buildRecentDocumentsUri(MacFiles.AUTHORITY, root))
        val l = mf.browser.recent()
        l.items.forEach { addHit(c, root, it) }
        return c.extras(l.loading, l.error)
    }

    // ---------------------------------------------------------------- bytes

    override fun openDocument(documentId: String?, mode: String?, signal: CancellationSignal?): ParcelFileDescriptor {
        val id = parse(documentId)
        val m = mode ?: "r"
        val mf = files
        if (m.any { it == 'w' || it == 'a' }) {
            val doc = mf.pending[id.encode()]
                ?: throw FileNotFoundException("Changing a file that's already on your Mac isn't supported. Save a new file instead.")
            val tmp = mf.newUploadFile()
            // Closing the descriptor (by the app that is saving) is what starts the upload.
            return ParcelFileDescriptor.open(
                tmp, ParcelFileDescriptor.MODE_WRITE_ONLY or ParcelFileDescriptor.MODE_CREATE or ParcelFileDescriptor.MODE_TRUNCATE,
                mf.closeHandler,
            ) { err ->
                if (err == null) mf.finishUpload(doc, tmp) else {
                    tmp.delete(); mf.pending.remove(id.encode())
                }
            }
        }
        val f: File = mf.openForRead(id, signal)
        return ParcelFileDescriptor.open(f, ParcelFileDescriptor.MODE_READ_ONLY)
    }

    override fun openDocumentThumbnail(documentId: String?, sizeHint: Point?, signal: CancellationSignal?): AssetFileDescriptor {
        val id = parse(documentId)
        val f = files.thumbnail(id, signal)
        return AssetFileDescriptor(ParcelFileDescriptor.open(f, ParcelFileDescriptor.MODE_READ_ONLY), 0, f.length())
    }

    override fun createDocument(parentDocumentId: String?, mimeType: String?, displayName: String?): String {
        val parent = parse(parentDocumentId)
        if (parent.isMacRoot) throw UnsupportedOperationException("Pick one of your Mac's folders first")
        return files.create(parent, mimeType ?: "application/octet-stream", displayName ?: "Untitled").encode()
    }

    override fun getDocumentType(documentId: String?): String {
        val id = parse(documentId)
        if (id.isMacRoot || id.isShare) return Document.MIME_TYPE_DIR
        val pending = files.pending[id.encode()]
        val e = if (pending != null) null else files.browser.known(id.share!!, id.path)
        return if (e?.dir == true) Document.MIME_TYPE_DIR else MacFiles.mimeFor(e?.name ?: id.name, e?.mime ?: pending?.mime ?: "")
    }

}
