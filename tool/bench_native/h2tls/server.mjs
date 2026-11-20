// nitro_http benchmark — a TLS server that speaks HTTP/2 and HTTP/1.1 on one
// port (ALPN picks), for comparing clients across protocols against the same
// host. Dart's HttpServer cannot serve HTTP/2.
//
//   GET /bytes/<n>   n bytes of 'a'
import { createSecureServer } from 'node:http2';
import { readFileSync } from 'node:fs';

const [, , port, key, cert] = process.argv;
const server = createSecureServer({
  key: readFileSync(key),
  cert: readFileSync(cert),
  allowHTTP1: true,
  settings: { maxConcurrentStreams: 256 },
});
server.on('request', (req, res) => {
  const match = /^\/bytes\/(\d+)$/.exec(req.url);
  if (!match) {
    res.writeHead(404).end();
    return;
  }
  const body = Buffer.alloc(Number(match[1]), 0x61);
  res.writeHead(200, {
    'content-type': 'application/octet-stream',
    'content-length': body.length,
  });
  res.end(body);
});
server.listen(Number(port), '0.0.0.0');
