package com.mydroid.simulator

import java.io.File
import kotlin.system.exitProcess

private fun usage(): Nothing {
    System.err.println("usage: simulator smoke --url <mydroid://pair?...> --state <dir> --photo <file> --photo2 <file>")
    exitProcess(2)
}

fun main(args: Array<String>) {
    if (args.firstOrNull() != "smoke") usage()
    val opts = HashMap<String, String>()
    var i = 1
    while (i < args.size) {
        val k = args[i]
        if (!k.startsWith("--") || i + 1 >= args.size) usage()
        opts[k.removePrefix("--")] = args[i + 1]; i += 2
    }
    val url = opts["url"] ?: usage(); val state = opts["state"] ?: usage()
    val photo = opts["photo"] ?: usage(); val photo2 = opts["photo2"] ?: usage()

    // Hard 60 s overall limit.
    Thread {
        Thread.sleep(60_000)
        println("SMOKE FAIL timeout after 60s"); System.out.flush()
        Runtime.getRuntime().halt(1)
    }.apply { isDaemon = true }.start()

    val code = try {
        Smoke.run(url, File(state), File(photo), File(photo2))
        println("SMOKE OK"); 0
    } catch (e: SmokeFailure) {
        println("SMOKE FAIL ${e.message}"); 1
    } catch (e: Throwable) {
        println("SMOKE FAIL ${e.javaClass.simpleName}: ${e.message}"); 1
    }
    System.out.flush()
    Runtime.getRuntime().halt(code)
}
