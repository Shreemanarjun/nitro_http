// nitro_http benchmark — a native download source.
//
// The app's own Dart server sends a body more slowly than the clients under
// test can receive one, so against it a download row measures the server.
// This one answers `GET /bytes/<n>` with n bytes straight from a static
// buffer, over keep-alive HTTP/1.1, one thread per connection.
//
//   cc -O2 -o source source.c && ./source <port>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

static char block[1 << 20];

static int send_all(int fd, const char* data, size_t n) {
  while (n > 0) {
    ssize_t sent = send(fd, data, n, 0);
    if (sent <= 0) return -1;
    data += sent;
    n -= (size_t)sent;
  }
  return 0;
}

static void* serve(void* arg) {
  int fd = (int)(long)arg;
  char request[4096];
  size_t have = 0;
  for (;;) {
    ssize_t got = recv(fd, request + have, sizeof(request) - 1 - have, 0);
    if (got <= 0) break;
    have += (size_t)got;
    request[have] = 0;
    char* end = strstr(request, "\r\n\r\n");
    if (end == NULL) {
      if (have == sizeof(request) - 1) break;
      continue;
    }
    unsigned long long n = 0;
    if (sscanf(request, "GET /bytes/%llu", &n) != 1) break;
    char head[160];
    int len = snprintf(head, sizeof(head),
                       "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\n"
                       "Content-Length: %llu\r\n\r\n", n);
    if (send_all(fd, head, (size_t)len) != 0) break;
    while (n > 0) {
      size_t part = n < sizeof(block) ? (size_t)n : sizeof(block);
      if (send_all(fd, block, part) != 0) goto done;
      n -= part;
    }
    have = 0;
  }
done:
  close(fd);
  return NULL;
}

int main(int argc, char** argv) {
  signal(SIGPIPE, SIG_IGN);
  memset(block, 'a', sizeof(block));
  int listener = socket(AF_INET, SOCK_STREAM, 0);
  int on = 1;
  setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &on, sizeof(on));
  struct sockaddr_in addr = {0};
  addr.sin_family = AF_INET;
  addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  addr.sin_port = htons((uint16_t)(argc > 1 ? atoi(argv[1]) : 18081));
  if (bind(listener, (struct sockaddr*)&addr, sizeof(addr)) != 0 || listen(listener, 64) != 0) {
    perror("source");
    return 1;
  }
  for (;;) {
    int fd = accept(listener, NULL, NULL);
    if (fd < 0) continue;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, sizeof(on));
    pthread_t thread;
    pthread_create(&thread, NULL, serve, (void*)(long)fd);
    pthread_detach(thread);
  }
}
