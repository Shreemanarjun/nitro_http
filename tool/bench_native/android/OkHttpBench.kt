// Raw native OkHttp benchmark — the Android baseline for the nitro_http
// comparison. Mirrors the Swift/URLSession harness and the Flutter harness
// methodology exactly: warm-up, serial small GETs (median p50/p90/p99), bulk
// download and upload over N transfers, and a concurrent burst — all against
// the same shelf server (/bytes/<n>, /upload) reached via `adb reverse`.
//
// Run on the device (no Gradle needed) via d8 + app_process; see bench-native's
// Android section. Args: <baseUrl> [smallIters=10000] [transfers=10]
// [burst=64] [burstRepeats=10].

import okhttp3.Call
import okhttp3.Callback
import okhttp3.ConnectionPool
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.system.exitProcess

private val octet = "application/octet-stream".toMediaType()

fun main(args: Array<String>) {
    if (args.isEmpty()) {
        System.err.println("usage: OkHttpBench <baseUrl> [smallIters] [transfers] [burst] [burstRepeats]")
        exitProcess(2)
    }
    var base = args[0]
    while (base.endsWith("/")) base = base.dropLast(1)
    val smallIters = args.getOrNull(1)?.toIntOrNull() ?: 10000
    val transfers = args.getOrNull(2)?.toIntOrNull() ?: 10
    val burstWidth = args.getOrNull(3)?.toIntOrNull() ?: 64
    val burstReps = args.getOrNull(4)?.toIntOrNull() ?: 10
    val warmup = 50
    val smallPath = "/bytes/1024"
    val downloadBytes = 32 * 1024 * 1024
    val uploadBytes = 8 * 1024 * 1024

    // A generous pool + keep-alive so the burst isn't serialised by connection
    // limits — the OkHttp analogue of URLSession's httpMaximumConnectionsPerHost.
    val client = OkHttpClient.Builder()
        .connectionPool(ConnectionPool(64, 5, TimeUnit.MINUTES))
        .retryOnConnectionFailure(false)
        .build()
    client.dispatcher.maxRequests = 128
    client.dispatcher.maxRequestsPerHost = 128

    fun getFully(path: String): Int {
        client.newCall(Request.Builder().url(base + path).build()).execute().use { resp ->
            if (!resp.isSuccessful) throw RuntimeException("HTTP ${resp.code} for $path")
            return resp.body!!.bytes().size
        }
    }

    fun median(xs: DoubleArray): Double { xs.sort(); return xs[xs.size / 2] }
    fun pctile(xs: DoubleArray, p: Double): Double {
        // xs already sorted by the median() call site order; sort defensively.
        val s = xs.clone(); s.sort(); return s[minOf(s.size - 1, (s.size * p).toInt())]
    }
    fun r(x: Double, places: Int = 1): String {
        val m = Math.pow(10.0, places.toDouble()); return ((x * m).let { Math.round(it) } / m).toString()
    }
    fun mibps(bytes: Int, ms: Double) = (bytes / 1_048_576.0) / (ms / 1000.0)

    println("OkHttp (native Kotlin) vs $base  [smallIters=$smallIters transfers=$transfers burst=${burstWidth}x$burstReps]")

    // small GET
    repeat(warmup) { getFully(smallPath) }
    val us = DoubleArray(smallIters)
    for (i in 0 until smallIters) {
        val t = System.nanoTime(); getFully(smallPath); us[i] = (System.nanoTime() - t) / 1000.0
    }
    val p90 = pctile(us, 0.90); val p99 = pctile(us, 0.99)
    println("  small GET   p50 ${r(median(us))} us   p90 ${r(p90)}   p99 ${r(p99)}")

    // burst: `burstWidth` concurrent GETs, repeated. Uses OkHttp's async
    // enqueue (its dispatcher thread pool) rather than one raw thread per
    // request — the fair analogue of nitro_http firing N concurrent requests on
    // its async engine. Raw threads would charge OkHttp 64 OS-thread creations
    // per round, which nitro never pays.
    run {
        repeat(2) { getFully(smallPath) }
        val ms = DoubleArray(burstReps)
        for (rep in 0 until burstReps) {
            val latch = CountDownLatch(burstWidth)
            val t = System.nanoTime()
            for (j in 0 until burstWidth) {
                client.newCall(Request.Builder().url(base + smallPath).build())
                    .enqueue(object : Callback {
                        override fun onFailure(call: Call, e: IOException) { latch.countDown() }
                        override fun onResponse(call: Call, response: Response) {
                            response.use { it.body!!.bytes() }; latch.countDown()
                        }
                    })
            }
            latch.await()
            ms[rep] = (System.nanoTime() - t) / 1_000_000.0
        }
        println("  burst GET   p50 ${r(median(ms), 2)} ms   ($burstWidth concurrent, async enqueue)")
    }

    // download
    run {
        val path = "/bytes/$downloadBytes"
        repeat(2) { getFully(path) }
        val ms = DoubleArray(transfers)
        var lastN = 0
        for (i in 0 until transfers) {
            val t = System.nanoTime(); lastN = getFully(path); ms[i] = (System.nanoTime() - t) / 1_000_000.0
        }
        val m = median(ms)
        val note = if (lastN == downloadBytes) "" else "  (!! got $lastN of $downloadBytes)"
        println("  download    p50 ${r(m)} ms   ${r(mibps(downloadBytes, m), 0)} MiB/s$note")
    }

    // upload
    run {
        val body = ByteArray(uploadBytes)
        fun post(): Int {
            val req = Request.Builder().url("$base/upload").post(body.toRequestBody(octet)).build()
            client.newCall(req).execute().use { resp ->
                if (!resp.isSuccessful) throw RuntimeException("HTTP ${resp.code} /upload")
                return resp.body!!.bytes().size
            }
        }
        repeat(2) { post() }
        val ms = DoubleArray(transfers)
        for (i in 0 until transfers) { val t = System.nanoTime(); post(); ms[i] = (System.nanoTime() - t) / 1_000_000.0 }
        val m = median(ms)
        println("  upload      p50 ${r(m)} ms   ${r(mibps(uploadBytes, m), 0)} MiB/s")
    }

    client.dispatcher.executorService.shutdown()
    client.connectionPool.evictAll()
    exitProcess(0)
}
