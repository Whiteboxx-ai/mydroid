package com.mydroid.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

class SessionTest {
    @Test fun restoredNetworkChecksAnAlreadyConnectedSessionImmediately() {
        ServerSocket(0).use { server ->
            val remote = HostPort("127.0.0.1", server.localPort)
            val phone = Socket(remote.host, remote.port)
            val mac = server.accept().apply { soTimeout = 2_000 }
            val keys = SessionKeys(ByteArray(32) { 1 }, ByteArray(32) { 2 }, "123456")
            fun channel(socket: Socket, sessionKeys: SessionKeys) =
                SecureChannel(socket, socket.getInputStream(), socket.getOutputStream(), sessionKeys, "mac", remote)

            val ready = CountDownLatch(1)
            val closed = CountDownLatch(1)
            val session = ClientSession(channel(phone, keys), DeviceIdentity("Phone", "Phone", 36), false,
                object : SessionListener {
                    override fun onReady(pairing: Boolean, macName: String) { ready.countDown() }
                    override fun onClosed(reason: String?) { closed.countDown() }
                }) { Heartbeat.SCREEN_OFF_MS }
            channel(mac, SessionKeys(keys.s2c, keys.c2s, keys.confirmCode)).use { peer ->
                val reader = thread(isDaemon = true) { session.run() }
                try {
                    assertEquals("auth", peer.receive().type)
                    peer.send(Message.of("welcome"))
                    assertTrue(ready.await(2, TimeUnit.SECONDS))
                    session.checkLiveness()
                    assertEquals("ping", peer.receive().type)
                    peer.send(Message.of("pong"))
                    assertEquals(SessionState.READY, session.state)
                } finally {
                    session.close()
                    reader.join(2_000)
                }
                assertTrue(closed.await(2, TimeUnit.SECONDS))
            }
        }
    }
}
