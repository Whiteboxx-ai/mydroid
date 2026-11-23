package com.mydroid.callbridge

import android.os.Process
import com.mydroid.protocol.CallBridge
import java.io.BufferedReader
import java.io.FileDescriptor
import java.io.FileOutputStream
import java.io.InputStreamReader
import kotlin.system.exitProcess

/**
 * Mac call audio helper (PROTOCOL.md 8.3). Not an Android component: a plain class that the Mac starts as the shell user,
 *
 *     adb shell CLASSPATH=$(pm path com.mydroid.android | cut -d: -f2) app_process / com.mydroid.callbridge.Main
 *
 * JSON lines on stdin and stdout, nothing else on stdout (logs go to stderr). The audio is never stored.
 * Exits on `quit` or when stdin closes (the Mac or adb went away), after releasing every audio resource.
 */
object Main {
    @JvmStatic
    fun main(args: Array<String>) {
        // Keep stdout clean: take the real descriptor for our own lines, and point System.out at stderr for stray prints.
        val stdout = FileOutputStream(FileDescriptor.out)
        System.setOut(System.err)
        val outLock = Any()
        val emit = { line: String ->
            synchronized(outLock) {
                try { stdout.write((line + "\n").toByteArray(Charsets.UTF_8)); stdout.flush() } catch (e: java.io.IOException) { /* the Mac is gone; stdin EOF follows */ }
            }
        }
        val log = { msg: String -> System.err.println("callbridge: $msg") }
        // Whatever goes wrong on a thread must not take the helper (and the Mac's session) down with it.
        Thread.setDefaultUncaughtExceptionHandler { t, e -> log("uncaught on ${t.name}: $e") }

        val bridge = CallBridge(
            ShellAudioBackend(log),
            emit, log,
            audioThread = { try { Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_AUDIO) } catch (e: Throwable) { } },
        )
        bridge.start()
        val reader = BufferedReader(InputStreamReader(System.`in`, Charsets.UTF_8))
        try {
            while (true) {
                val line = reader.readLine() ?: break // EOF
                if (!bridge.handleLine(line)) break // quit
            }
        } catch (e: Throwable) {
            log("stdin: $e")
        } finally {
            bridge.shutdown()
        }
        exitProcess(0)
    }
}
