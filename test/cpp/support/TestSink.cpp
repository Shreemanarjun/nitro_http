#include "support/TestSink.h"

#include <chrono>
#include <thread>

namespace nitrohttp::test {

Captures& Captures::instance() {
  static Captures singleton;
  return singleton;
}

void Captures::addChunk(CapturedChunk chunk) {
  std::lock_guard<std::mutex> lock(mtx_);
  chunks_.push_back(std::move(chunk));
}

void Captures::addEvent(CapturedEvent event) {
  std::lock_guard<std::mutex> lock(mtx_);
  events_.push_back(event);
}

void Captures::addFrame(CapturedFrame frame) {
  std::lock_guard<std::mutex> lock(mtx_);
  frames_.push_back(std::move(frame));
}

void Captures::addPost(CapturedPost post) {
  std::lock_guard<std::mutex> lock(mtx_);
  posts_.push_back(std::move(post));
}

std::vector<CapturedChunk> Captures::chunks() const {
  std::lock_guard<std::mutex> lock(mtx_);
  return chunks_;
}

std::vector<CapturedEvent> Captures::events() const {
  std::lock_guard<std::mutex> lock(mtx_);
  return events_;
}

std::vector<CapturedFrame> Captures::frames() const {
  std::lock_guard<std::mutex> lock(mtx_);
  return frames_;
}

std::vector<CapturedPost> Captures::posts() const {
  std::lock_guard<std::mutex> lock(mtx_);
  return posts_;
}

namespace {
template <typename Fn>
bool waitUntil(Fn predicate, int timeoutMs) {
  const auto deadline =
      std::chrono::steady_clock::now() + std::chrono::milliseconds(timeoutMs);
  while (std::chrono::steady_clock::now() < deadline) {
    if (predicate()) return true;
    std::this_thread::sleep_for(std::chrono::milliseconds(2));
  }
  return predicate();
}
}  // namespace

bool Captures::waitForPosts(size_t count, int timeoutMs) {
  return waitUntil([&] { return posts().size() >= count; }, timeoutMs);
}

bool Captures::waitForChunks(size_t count, int timeoutMs) {
  return waitUntil([&] { return chunks().size() >= count; }, timeoutMs);
}

bool Captures::waitForFrames(size_t count, int timeoutMs) {
  return waitUntil([&] { return frames().size() >= count; }, timeoutMs);
}

void Captures::setPortAlive(bool alive) {
  std::lock_guard<std::mutex> lock(mtx_);
  portAlive_ = alive;
}

bool Captures::portAlive() const {
  std::lock_guard<std::mutex> lock(mtx_);
  return portAlive_;
}

void Captures::clear() {
  std::lock_guard<std::mutex> lock(mtx_);
  chunks_.clear();
  events_.clear();
  frames_.clear();
  posts_.clear();
  portAlive_ = true;
}

std::vector<RawResponse> Captures::responses() const {
  std::vector<RawResponse> out;
  for (const CapturedPost& post : posts()) {
    out.push_back(RawResponse::fromNative(
        NitroCppBuffer{post.payload.data(), post.payload.size()}));
  }
  return out;
}

std::vector<RawResponseHead> Captures::heads() const {
  std::vector<RawResponseHead> out;
  for (const CapturedPost& post : posts()) {
    out.push_back(RawResponseHead::fromNative(
        NitroCppBuffer{post.payload.data(), post.payload.size()}));
  }
  return out;
}

std::vector<RawWsHandshake> Captures::handshakes() const {
  std::vector<RawWsHandshake> out;
  for (const CapturedPost& post : posts()) {
    out.push_back(RawWsHandshake::fromNative(
        NitroCppBuffer{post.payload.data(), post.payload.size()}));
  }
  return out;
}

void installTestSeams() {
  StreamSink sink;

  sink.chunk = [](RawChunk item) {
    // Copy immediately, exactly as the Dart runner's demux does — the payload
    // is native-owned and may be released by the next ack.
    CapturedChunk captured;
    captured.requestId = item.requestId;
    captured.kind = item.kind;
    captured.aux = item.aux;
    if (item.bytes != nullptr && item.bytesLength > 0) {
      captured.bytes.assign(item.bytes, item.bytes + item.bytesLength);
    }
    Captures::instance().addChunk(std::move(captured));
  };

  sink.event = [](NitroCppBuffer item) {
    if (item.data != nullptr) {
      // The emitted buffer is `[4B len][payload]` and ownership transfers here,
      // matching the generated `emit_events`.
      const int32_t payloadLen = *reinterpret_cast<const int32_t*>(item.data);
      CapturedEvent captured;
      captured.value = RawEvent::fromNative(NitroCppBuffer{
          item.data + sizeof(int32_t), static_cast<size_t>(payloadLen)});
      Captures::instance().addEvent(captured);
      ::free(const_cast<uint8_t*>(item.data));
    }
  };

  sink.wsFrame = [](RawWsFrame item) {
    CapturedFrame captured;
    captured.socketId = item.socketId;
    captured.opcode = item.opcode;
    captured.flags = item.flags;
    if (item.payload != nullptr && item.payloadLength > 0) {
      captured.payload.assign(item.payload, item.payload + item.payloadLength);
    }
    Captures::instance().addFrame(std::move(captured));
  };

  installStreamSink(std::move(sink));

  setPostHook([](int64_t port, Blob blob) {
    const bool alive = Captures::instance().portAlive();
    if (alive && !blob.empty()) {
      const int32_t payloadLen = *reinterpret_cast<const int32_t*>(blob.data);
      CapturedPost post;
      post.port = port;
      post.payload.assign(blob.data + sizeof(int32_t),
                          blob.data + sizeof(int32_t) + payloadLen);
      Captures::instance().addPost(std::move(post));
    }
    // The hook owns the blob on every path — same contract as
    // `Dart_PostCObject_DL`, where a dead port means the poster frees.
    blob.release();
    return alive;
  });
}

RawRequestOptions defaultOptions() {
  RawRequestOptions options{};
  options.connectTimeoutMs = -1;
  options.requestTimeoutMs = -1;
  options.followRedirects = -1;
  options.maxRedirects = -1;
  options.cacheMode = RawCacheMode::RAWCACHEMODE_NORMAL;
  options.reportProgress = false;
  options.wantTimings = true;
  options.uploadContentLength = -1;
  options.pinnedSpkiOverride = "";
  return options;
}

RawClientConfig defaultClientConfig() {
  RawClientConfig config{};
  config.httpVersion = RawHttpVersionPref::RAWHTTPVERSIONPREF_AUTO;
  config.connectTimeoutMs = 5000;
  config.requestTimeoutMs = 15000;
  config.idleTimeoutMs = 0;
  config.followRedirects = true;
  config.maxRedirects = 10;
  config.enableCompression = true;
  config.enableCache = false;
  config.userAgent = "nitro_http-tests";
  config.altSvcCachePath = "";

  config.tls.verifyCertificates = true;
  config.tls.rootCaSource = 0;
  config.tls.minTlsVersion = 0;
  config.tls.maxTlsVersion = 0;

  config.proxy.mode = RawProxyMode::RAWPROXYMODE_SYSTEM;
  config.dns.dohUrl = "";

  config.cookies.enabled = true;
  config.cookies.persistPath = "";

  config.pool.maxConnections = 16;
  config.pool.maxConnectionsPerHost = 6;
  config.pool.idleTimeoutMs = 90000;
  config.pool.maxLifetimeMs = 600000;
  config.pool.keepAlivePingMs = 0;
  return config;
}

RawRequest getRequest(int64_t requestId, const std::string& url) {
  RawRequest request{};
  request.requestId = requestId;
  request.method = RawMethod::RAWMETHOD_GET;
  request.customMethod = "";
  request.url = url;
  request.bodyKind = RawBodyKind::RAWBODYKIND_NONE;
  request.bodyFilePath = "";
  request.options = defaultOptions();
  return request;
}

}  // namespace nitrohttp::test
