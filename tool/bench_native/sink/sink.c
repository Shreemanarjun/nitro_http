// ─────────────────────────────────────────────────────────────────────────────
// nitro_http benchmark — a native upload sink.
//
// The bench server the example app runs is `dart:io`, which reads a large
// request body more slowly than the clients under test send one, so an upload
// timed against it measures the server. This program is the alternative
// target: it reads the request head, discards exactly Content-Length bytes
// with `recv` into one reused megabyte buffer, and answers 200. Nothing per
// byte beyond the copy out of the kernel.
//
// Keep-alive, one thread per connection, loopback only. It understands just
// enough HTTP/1.1 for the benchmark's uploads (a Content-Length body); it is
// not a server for anything else.
//
//   tool/bench_native/sink/sink.sh start macos      # prints the base URL
//   BENCH_UPLOAD_SINK=http://127.0.0.1:18080 <the release binary>
//   tool/bench_native/sink/sink.sh stop macos
//
// On Android the sink runs on the device, so the upload still never leaves it:
//   tool/bench_native/sink/sink.sh start android
//   flutter build apk --release ... --dart-define=BENCH_UPLOAD_SINK=http://127.0.0.1:18080
// ─────────────────────────────────────────────────────────────────────────────
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/socket.h>
#include <unistd.h>

static void* serve(void* arg) {
  int fd = (int)(long)arg;
  int one = 1;
  setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
  const size_t cap = 1 << 20;
  char* buf = malloc(cap);
  size_t have = 0;
  for (;;) {
    // headers
    char* end = NULL;
    while ((end = have >= 4 ? memmem(buf, have, "\r\n\r\n", 4) : NULL) == NULL) {
      if (have == cap) goto done;
      ssize_t n = recv(fd, buf + have, cap - have, 0);
      if (n <= 0) goto done;
      have += (size_t)n;
    }
    size_t header_len = (size_t)(end - buf) + 4;
    long long length = 0;
    for (char* line = buf; line < end; ) {
      char* nl = memmem(line, (size_t)(end - line) + 2, "\r\n", 2);
      if (!nl) break;
      if (strncasecmp(line, "content-length:", 15) == 0) length = atoll(line + 15);
      line = nl + 2;
    }
    size_t body_have = have - header_len;
    long long remaining = length - (long long)body_have;
    have = 0;
    if (remaining < 0) { // pipelined bytes of the next request
      memmove(buf, buf + header_len + (size_t)length, (size_t)(-remaining));
      have = (size_t)(-remaining);
      remaining = 0;
    }
    while (remaining > 0) {
      ssize_t n = recv(fd, buf, remaining < (long long)cap ? (size_t)remaining : cap, 0);
      if (n <= 0) goto done;
      remaining -= n;
    }
    char resp[160];
    int body = snprintf(resp + 100, 60, "{\"bytes\":%lld}", length);
    int head = snprintf(resp, 100, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n", body);
    memmove(resp + head, resp + 100, (size_t)body);
    if (send(fd, resp, (size_t)(head + body), 0) < 0) goto done;
  }
done:
  free(buf);
  close(fd);
  return NULL;
}

int main(int argc, char** argv) {
  int port = argc > 1 ? atoi(argv[1]) : 18080;
  int s = socket(AF_INET, SOCK_STREAM, 0);
  int one = 1;
  setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
  struct sockaddr_in a = {0};
  a.sin_family = AF_INET;
  a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  a.sin_port = htons((uint16_t)port);
  if (bind(s, (struct sockaddr*)&a, sizeof a) != 0 || listen(s, 64) != 0) { perror("bind/listen"); return 1; }
  for (;;) {
    int c = accept(s, NULL, NULL);
    if (c < 0) continue;
    pthread_t t;
    pthread_create(&t, NULL, serve, (void*)(long)c);
    pthread_detach(t);
  }
}
