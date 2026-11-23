package com.mydroid.android.mac

import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import com.mydroid.android.manager
import com.mydroid.android.net.Link

/**
 * "Lock Mac" Quick Settings tile (PROTOCOL.md 11). One tap sends `mac.action lock`. It only works while the Mac is
 * connected: there is nothing to queue, since a lock that arrives an hour later would be a surprise.
 */
class LockTileService : TileService() {
    override fun onStartListening() = refresh()

    private fun refresh(sub: String? = null) {
        val m = manager()
        val paired = m.store.isPaired
        val connected = m.state.value.link == Link.Connected
        qsTile?.apply {
            label = "Lock Mac"
            state = when {
                !paired -> Tile.STATE_UNAVAILABLE
                connected -> Tile.STATE_INACTIVE
                else -> Tile.STATE_UNAVAILABLE
            }
            if (Build.VERSION.SDK_INT >= 30) subtitle = sub ?: when {
                !paired -> "Not paired"
                connected -> null
                else -> "Mac is away"
            }
            updateTile()
        }
    }

    override fun onClick() {
        val m = manager()
        if (m.state.value.link != Link.Connected) { refresh(); return }
        m.mac.lock()
        refresh(sub = "Locking…")
    }
}
