package com.mydroid.android.net

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import com.mydroid.protocol.HostPort
import java.net.Inet4Address
import java.util.concurrent.Executors

/**
 * Bonjour discovery of `_mydroid._tcp`, matched on TXT `id`. Holds a MulticastLock only while running; the caller bounds every run (ConnectionManager: <= 10 s).
 */
class Discovery(ctx: Context, private val macId: String, private val onFound: (HostPort) -> Unit) {
    private val nsd = ctx.applicationContext.getSystemService(Context.NSD_SERVICE) as NsdManager
    private val wifi = ctx.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
    private var lock: WifiManager.MulticastLock? = null
    private var listener: NsdManager.DiscoveryListener? = null
    private val callbacks = ArrayList<NsdManager.ServiceInfoCallback>()
    // NsdManager keeps posting callbacks (e.g. onServiceInfoCallbackUnregistered) after stop(), so the
    // callback executor must outlive any one Discovery. Never shut it down.
    private val exec get() = callbackExec
    private val resolveQueue = java.util.concurrent.LinkedBlockingQueue<NsdServiceInfo>()
    @Volatile private var running = false

    private fun matches(info: NsdServiceInfo): Boolean {
        val id = info.attributes?.get("id") ?: return false
        return String(id, Charsets.UTF_8) == macId
    }

    @Synchronized
    fun start() {
        if (running) return
        running = true
        lock = wifi.createMulticastLock("mydroid-discovery").apply { setReferenceCounted(false); runCatching { acquire() } }
        val l = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) {}
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {}
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {}
            override fun onDiscoveryStopped(serviceType: String) {}
            override fun onServiceLost(serviceInfo: NsdServiceInfo) {}
            override fun onServiceFound(serviceInfo: NsdServiceInfo) {
                if (!running) return
                resolve(serviceInfo)
            }
        }
        listener = l
        try {
            nsd.discoverServices("_mydroid._tcp", NsdManager.PROTOCOL_DNS_SD, l)
        } catch (e: Exception) {
            listener = null
        }
        if (Build.VERSION.SDK_INT < 34) Thread(::legacyResolveLoop, "mydroid-nsd-resolve").apply { isDaemon = true }.start()
    }

    private fun resolve(info: NsdServiceInfo) {
        if (Build.VERSION.SDK_INT >= 34) {
            val cb = object : NsdManager.ServiceInfoCallback {
                override fun onServiceInfoCallbackRegistrationFailed(errorCode: Int) {}
                override fun onServiceUpdated(serviceInfo: NsdServiceInfo) {
                    if (!matches(serviceInfo)) return
                    val addrs = serviceInfo.hostAddresses.sortedBy { if (it is Inet4Address) 0 else 1 }
                    for (a in addrs) onFound(HostPort(a.hostAddress ?: continue, serviceInfo.port))
                }
                override fun onServiceLost() {}
                override fun onServiceInfoCallbackUnregistered() {}
            }
            synchronized(callbacks) { callbacks += cb }
            runCatching { nsd.registerServiceInfoCallback(info, exec, cb) }
        } else {
            resolveQueue.put(info)
        }
    }

    /** Pre-34 NsdManager can resolve only one service at a time, so serialise. */
    @Suppress("DEPRECATION")
    private fun legacyResolveLoop() {
        while (running) {
            val info = resolveQueue.poll(500, java.util.concurrent.TimeUnit.MILLISECONDS) ?: continue
            val done = java.util.concurrent.CountDownLatch(1)
            try {
                nsd.resolveService(info, object : NsdManager.ResolveListener {
                    override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) = done.countDown()
                    override fun onServiceResolved(serviceInfo: NsdServiceInfo) {
                        if (matches(serviceInfo)) serviceInfo.host?.hostAddress?.let { onFound(HostPort(it, serviceInfo.port)) }
                        done.countDown()
                    }
                })
                done.await(4, java.util.concurrent.TimeUnit.SECONDS)
            } catch (e: Exception) {
            }
        }
    }

    @Synchronized
    fun stop() {
        if (!running) return
        running = false
        listener?.let { runCatching { nsd.stopServiceDiscovery(it) } }
        listener = null
        if (Build.VERSION.SDK_INT >= 34) {
            synchronized(callbacks) {
                callbacks.forEach { runCatching { nsd.unregisterServiceInfoCallback(it) } }
                callbacks.clear()
            }
        }
        lock?.let { runCatching { if (it.isHeld) it.release() } }
        lock = null
    }
}

private val callbackExec = Executors.newSingleThreadExecutor { Thread(it, "mydroid-nsd").apply { isDaemon = true } }
