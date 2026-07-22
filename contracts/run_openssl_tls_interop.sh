#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ] || [ ! -x "$1" ]; then
  exit 64
fi
fixture_dir="$(mktemp -d)"
server_pid=""
cleanup() {
  if [ -n "$server_pid" ]; then kill "$server_pid" >/dev/null 2>&1 || true; fi
  rm -rf "$fixture_dir"
}
trap cleanup EXIT
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$fixture_dir/ca-key.pem" -out "$fixture_dir/ca.pem" -subj /CN=minna-san-interop-ca -days 1 >/dev/null 2>&1
openssl req -newkey rsa:2048 -nodes -keyout "$fixture_dir/key.pem" -out "$fixture_dir/request.pem" -subj /CN=localhost -addext subjectAltName=DNS:localhost >/dev/null 2>&1
openssl x509 -req -in "$fixture_dir/request.pem" -CA "$fixture_dir/ca.pem" -CAkey "$fixture_dir/ca-key.pem" -CAcreateserial -out "$fixture_dir/cert.pem" -days 1 -copy_extensions copy >/dev/null 2>&1
"$1" "$fixture_dir/cert.pem" "$fixture_dir/key.pem" "$fixture_dir/ca.pem"

start_server() {
  local mode="$1"
  local log="$fixture_dir/$mode.log"
  "$2" server "$mode" "$fixture_dir/cert.pem" "$fixture_dir/key.pem" >"$log" 2>&1 &
  server_pid=$!
  local attempts=0
  while [ "$attempts" -lt 100 ]; do
    if [ -s "$log" ]; then
      server_port="$(sed -n 's/^PORT=//p' "$log")"
      if [ -n "$server_port" ]; then return; fi
    fi
    attempts=$((attempts + 1))
    sleep 0.01
  done
  cat "$log" >&2
  return 1
}

finish_server() {
  wait "$server_pid"
  server_pid=""
}

start_server http1 "$1"
curl --fail --silent --show-error --cacert "$fixture_dir/ca.pem" --http1.1 "https://localhost:$server_port/public" >/dev/null
finish_server

cat >"$fixture_dir/node_fixture.mjs" <<'NODE'
import crypto from 'node:crypto';
import fs from 'node:fs';
import http2 from 'node:http2';
import https from 'node:https';

const [mode, certificatePath, privateKeyPath] = process.argv.slice(2);
const options = { cert: fs.readFileSync(certificatePath), key: fs.readFileSync(privateKeyPath), allowHTTP1: mode !== 'h2' };
const server = mode === 'h2' ? http2.createSecureServer(options) : https.createServer(options, (request, response) => {
  response.writeHead(request.url === '/public' ? 200 : 404, { 'content-length': '0', connection: 'close' });
  response.end(() => server.close());
});
if (mode === 'h2') server.on('stream', (stream, headers) => {
  stream.respond({ ':status': headers[':path'] === '/public' ? 200 : 404, 'content-length': '0' });
  stream.end(() => server.close());
});
if (mode === 'ws') server.on('upgrade', (request, socket) => {
  const accept = crypto.createHash('sha1').update(`${request.headers['sec-websocket-key']}258EAFA5-E914-47DA-95CA-C5AB0DC85B11`).digest('base64');
  socket.end(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`, () => server.close());
});
server.listen(0, '127.0.0.1', () => console.log(`PORT=${server.address().port}`));
NODE

start_node_server() {
  local mode="$1"
  local log="$fixture_dir/node-$mode.log"
  node "$fixture_dir/node_fixture.mjs" "$mode" "$fixture_dir/cert.pem" "$fixture_dir/key.pem" >"$log" 2>&1 &
  server_pid=$!
  local attempts=0
  while [ "$attempts" -lt 100 ]; do
    if [ -s "$log" ]; then
      server_port="$(sed -n 's/^PORT=//p' "$log")"
      if [ -n "$server_port" ]; then return; fi
    fi
    attempts=$((attempts + 1))
    sleep 0.01
  done
  cat "$log" >&2
  return 1
}

for mode in http1 h2 ws; do
  start_node_server "$mode"
  "$1" client "$mode" "$server_port" "$fixture_dir/ca.pem"
  finish_server
done

start_server h2 "$1"
curl --fail --silent --show-error --cacert "$fixture_dir/ca.pem" --http2 "https://localhost:$server_port/public" >/dev/null
finish_server

start_server ws "$1"
curl --silent --cacert "$fixture_dir/ca.pem" --http1.1 --include --output "$fixture_dir/ws.response" -H 'Upgrade: websocket' -H 'Connection: Upgrade' -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' "https://localhost:$server_port/socket" || true
grep -q '^HTTP/1.1 101 ' "$fixture_dir/ws.response" || { cat "$fixture_dir/ws.log" >&2; exit 1; }
finish_server
