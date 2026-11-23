package com.mydroid.android.ui

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.mydroid.android.auth.AuthGate
import com.mydroid.android.auth.ImportDone
import com.mydroid.android.auth.ImportReview
import com.mydroid.android.manager
import com.mydroid.protocol.auth.AuthImportWire
import com.mydroid.protocol.auth.ImportItem

/**
 * PROTOCOL.md 14.4: the Mac's camera read some accounts and wants to add them. This screen lists issuer and account (never a secret),
 * asks for the biometric on Add, and only then do the accounts reach the vault. The window is FLAG_SECURE: no screenshots, blank in Recents.
 * Opened by the "wants to add N accounts" notification; closes itself when the import ends any other way (Cancel, timeout, Mac gone).
 */
class AuthImportActivity : ComponentActivity() {
    private var done by mutableStateOf<ImportDone?>(null)
    private var hint by mutableStateOf<String?>(null)
    private var asking by mutableStateOf(false)

    override fun onCreate(savedInstanceState: Bundle?) {
        window.addFlags(android.view.WindowManager.LayoutParams.FLAG_SECURE)
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val importer = manager().auth.importer
        setContent {
            MydroidTheme {
                val review by importer.review.collectAsStateWithLifecycle()
                val d = done
                val r = review
                // The import ended without Add (Cancel, 2 minute timeout, Mac disconnected, process restarted): nothing left to show.
                LaunchedEffect(r, d) { if (r == null && d == null) finish() }
                Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
                    when {
                        d != null -> ImportDoneContent(d, onBackup = { openBackup() }, onClose = { finish() })
                        r != null -> ImportReviewContent(r, hint = hint, busy = asking, onAdd = { add(r) }, onCancel = { importer.cancel(r.req); finish() })
                    }
                }
            }
        }
    }

    private fun add(r: ImportReview) {
        val auth = manager().auth
        asking = true; hint = null
        auth.gate.prompt(
            this, "Add accounts", "Confirm it's you to add ${if (r.items.size == 1) "1 account" else "${r.items.size} accounts"} from ${r.mac}",
            unlockGate = false,
            onError = { code -> if (AuthGate.isLockout(code)) auth.importer.fail(r.req, AuthImportWire.LOCKED) },
        ) { ok ->
            asking = false
            if (!ok) { hint = "Nothing added"; return@prompt }
            val result = auth.importer.confirm(r.req)
            if (result == null) finish() else done = result
        }
    }

    private fun openBackup() {
        startActivity(Intent(this, MainActivity::class.java).putExtra(MainActivity.EXTRA_BACKUP, true).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP))
        finish()
    }

    override fun onStop() {
        manager().auth.gate.cancelPrompt()
        super.onStop()
    }
}

private fun plural(n: Int) = if (n == 1) "1 account" else "$n accounts"

@Composable
internal fun ImportReviewContent(review: ImportReview, hint: String? = null, busy: Boolean = false, onAdd: () -> Unit, onCancel: () -> Unit) {
    val cs = MaterialTheme.colorScheme
    Column(Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.safeDrawing).padding(horizontal = 20.dp)) {
        Spacer(Modifier.height(24.dp))
        Box(Modifier.size(56.dp).clip(CircleShape).background(cs.primaryContainer), contentAlignment = Alignment.Center) {
            Icon(Glyphs.Key, null, Modifier.size(28.dp), tint = cs.onPrimaryContainer)
        }
        Spacer(Modifier.height(16.dp))
        Text("Add ${plural(review.items.size)} from ${review.mac}?", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.SemiBold)
        Spacer(Modifier.height(6.dp))
        Text("Only add these if you just scanned them", style = MaterialTheme.typography.bodyMedium, color = cs.onSurfaceVariant)
        Spacer(Modifier.height(16.dp))
        Card28(Modifier.weight(1f, fill = false)) {
            LazyColumn(Modifier.padding(vertical = 8.dp)) {
                itemsIndexed(review.items) { i, it ->
                    if (i > 0) HorizontalDivider(Modifier.padding(start = 76.dp, end = 16.dp), color = cs.outlineVariant.copy(alpha = 0.5f))
                    ReviewRow(it)
                }
            }
        }
        if (review.skipped > 0) {
            Spacer(Modifier.height(10.dp))
            Text(
                "${review.skipped} skipped: duplicate or unreadable",
                style = MaterialTheme.typography.bodyMedium, color = cs.onSurfaceVariant,
            )
        }
        if (hint != null) {
            Spacer(Modifier.height(10.dp))
            Text(hint, style = MaterialTheme.typography.bodyMedium, color = cs.error)
        }
        Spacer(Modifier.height(16.dp))
        Button(onAdd, Modifier.fillMaxWidth().height(56.dp), enabled = !busy, shape = RoundedCornerShape(18.dp)) {
            Text("Add ${plural(review.items.size)}")
        }
        TextButton(onCancel, Modifier.fillMaxWidth().heightIn(min = 48.dp)) { Text("Cancel") }
        Spacer(Modifier.height(8.dp))
    }
}

@Composable
private fun ReviewRow(item: ImportItem) {
    val cs = MaterialTheme.colorScheme
    Row(Modifier.fillMaxWidth().heightIn(min = 64.dp).padding(horizontal = 16.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
        Avatar(item.title)
        Spacer(Modifier.width(16.dp))
        Column(Modifier.weight(1f)) {
            Text(item.title, style = MaterialTheme.typography.titleMedium, maxLines = 1, overflow = TextOverflow.Ellipsis)
            if (item.subtitle.isNotEmpty()) Text(item.subtitle, style = MaterialTheme.typography.bodyMedium, color = cs.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}

@Composable
internal fun ImportDoneContent(done: ImportDone, onBackup: () -> Unit, onClose: () -> Unit) {
    val cs = MaterialTheme.colorScheme
    Column(
        Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.safeDrawing).padding(horizontal = 20.dp),
        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center,
    ) {
        Box(Modifier.size(72.dp).clip(CircleShape).background(cs.primaryContainer), contentAlignment = Alignment.Center) {
            Icon(Icons.Filled.Check, null, Modifier.size(36.dp), tint = cs.onPrimaryContainer)
        }
        Spacer(Modifier.height(16.dp))
        Text(if (done.added == 0) "Nothing new" else "Added ${plural(done.added)}", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.SemiBold, textAlign = TextAlign.Center)
        if (done.skipped > 0) {
            Spacer(Modifier.height(6.dp))
            Text("${done.skipped} skipped: duplicate or unreadable", style = MaterialTheme.typography.bodyMedium, color = cs.onSurfaceVariant, textAlign = TextAlign.Center)
        }
        Spacer(Modifier.height(24.dp))
        if (done.needsBackup && done.added > 0) {
            Card28(color = cs.tertiaryContainer) {
                Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Text("Back up your accounts", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, color = cs.onTertiaryContainer)
                    Text("In case you lose this phone", style = MaterialTheme.typography.bodyMedium, color = cs.onTertiaryContainer)
                    Button(onBackup, Modifier.heightIn(min = 48.dp)) { Text("Back up") }
                }
            }
            Spacer(Modifier.height(12.dp))
        }
        TextButton(onClose, Modifier.heightIn(min = 48.dp)) { Text("Done") }
    }
}
