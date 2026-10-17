// Raw URLSession benchmark — the native Apple baseline for comparison with
// nitro_http. Mirrors the Flutter harness methodology exactly: a warm-up, then
// serial small GETs timed per request (median p50/p90/p99), bulk download and
// upload timed over N transfers, and a 64-wide concurrent burst — all against
// the same shelf server (/bytes/<n>, /upload) the Dart harness uses.
//
//   swift run -c release nativebench <baseUrl> [smallIters] [transfers] [burst] [burstRepeats]
//
// Defaults match release_runner.dart: 50 warm-up, 10000 small GETs, 32 MiB
// download, 8 MiB upload, 64-wide burst x10.

import Foundation

setbuf(stdout, nil)  // unbuffered so a crash does not swallow progress

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("usage: nativebench <baseUrl> [smallIters] [transfers] [burst] [burstRepeats]\n".utf8))
    exit(2)
}
// Strip trailing slashes so `base + "/bytes/..."` can't become a double-slash
// path, which the shelf router 404s (a silent 15-byte error body that otherwise
// masquerades as a tiny-but-slow response).
var base = args[1]
while base.hasSuffix("/") { base.removeLast() }
let smallIters = args.count > 2 ? (Int(args[2]) ?? 10000) : 10000
let transfers  = args.count > 3 ? (Int(args[3]) ?? 10) : 10
let burstWidth = args.count > 4 ? (Int(args[4]) ?? 64) : 64
let burstReps  = args.count > 5 ? (Int(args[5]) ?? 10) : 10

let warmup = 50
let smallPath = "/bytes/1024"
let downloadBytes = 32 * 1024 * 1024
let uploadBytes = 8 * 1024 * 1024

// Match the Dart subjects: no response cache, a generous per-host pool so the
// burst is not serialised by connection limits, keep-alive on (the default).
let config = URLSessionConfiguration.default
config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
config.urlCache = nil
config.httpMaximumConnectionsPerHost = 64
let session = URLSession(configuration: config)

func url(_ path: String) -> URL { URL(string: base + path)! }
func nowNs() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
func median(_ xs: [Double]) -> Double { let s = xs.sorted(); return s[s.count / 2] }
func pctile(_ xs: [Double], _ p: Double) -> Double {
    let s = xs.sorted(); return s[min(s.count - 1, Int(Double(s.count) * p))]
}

// Round to `places` decimals and render — avoids Foundation's String(format:),
// whose CVarArg overload does not resolve cleanly here.
func r(_ x: Double, _ places: Int = 1) -> String {
    let m = pow(10.0, Double(places))
    return String((x * m).rounded() / m)
}

// Completion-handler dataTask wrapped in a continuation — available on every
// macOS, unlike the async `data(for:)`/`upload(for:from:)` methods which do not
// resolve under this toolchain. One request, body fully read, returns its size.
func runRequest(_ request: URLRequest) async throws -> Int {
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int, Error>) in
        let task = session.dataTask(with: request) { data, response, error in
            if let error = error { cont.resume(throwing: error); return }
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                cont.resume(throwing: NSError(domain: "bench", code: http.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode) for \(request.url?.path ?? "?")"]))
                return
            }
            cont.resume(returning: data?.count ?? 0)
        }
        task.resume()
    }
}

@discardableResult
func getFully(_ path: String) async throws -> Int {
    try await runRequest(URLRequest(url: url(path)))
}

func smallGet() async throws {
    for _ in 0..<warmup { try await getFully(smallPath) }
    var us = [Double](); us.reserveCapacity(smallIters)
    for _ in 0..<smallIters {
        let t = nowNs()
        try await getFully(smallPath)
        us.append(Double(nowNs() - t) / 1_000.0)
    }
    print("  small GET   p50 \(r(median(us))) us   p90 \(r(pctile(us, 0.90)))   p99 \(r(pctile(us, 0.99)))")
}

func burst() async throws {
    for _ in 0..<2 { try await getFully(smallPath) }
    var ms = [Double]()
    for _ in 0..<burstReps {
        let t = nowNs()
        try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<burstWidth { group.addTask { try await getFully(smallPath) } }
            for try await _ in group {}
        }
        ms.append(Double(nowNs() - t) / 1_000_000.0)
    }
    print("  burst GET   p50 \(r(median(ms), 2)) ms   (\(burstWidth) concurrent)")
}

func mibPerSec(_ bytes: Int, _ ms: Double) -> Double {
    let seconds = ms / 1000.0
    let mib = Double(bytes) / 1_048_576.0
    return mib / seconds
}

func download() async throws {
    let path = "/bytes/\(downloadBytes)"
    for _ in 0..<2 { _ = try await getFully(path) }
    var ms = [Double]()
    var lastN = 0
    for _ in 0..<transfers {
        let t = nowNs()
        lastN = try await getFully(path)
        ms.append(Double(nowNs() - t) / 1_000_000.0)
    }
    let m = median(ms)
    let note = lastN == downloadBytes ? "" : "  (!! got \(lastN) of \(downloadBytes))"
    print("  download    p50 \(r(m)) ms   \(r(mibPerSec(downloadBytes, m), 0)) MiB/s\(note)")
}

func upload() async throws {
    let body = Data(count: uploadBytes)
    var req = URLRequest(url: url("/upload"))
    req.httpMethod = "POST"
    req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
    req.httpBody = body
    for _ in 0..<2 { _ = try await runRequest(req) }
    var ms = [Double]()
    for _ in 0..<transfers {
        let t = nowNs()
        _ = try await runRequest(req)
        ms.append(Double(nowNs() - t) / 1_000_000.0)
    }
    let m = median(ms)
    print("  upload      p50 \(r(m)) ms   \(r(mibPerSec(uploadBytes, m), 0)) MiB/s")
}

let sema = DispatchSemaphore(value: 0)
Task {
    do {
        print("URLSession (native Swift) vs \(base)  [smallIters=\(smallIters) transfers=\(transfers) burst=\(burstWidth)x\(burstReps)]")
        try await smallGet()
        try await burst()
        try await download()
        try await upload()
    } catch {
        FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    }
    sema.signal()
}
sema.wait()
