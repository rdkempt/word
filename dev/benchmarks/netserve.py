# Dev-only benchmark server for nethttp / nethttps: one fixed body just under
# 64 KiB, no keep-alive, no logging. python3 is a dev tool here, like `as` and
# `openssl` elsewhere: nothing in it is needed to build or run word.
import ssl, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
PAYLOAD = (b"word-net-benchmark " * 3446)[:65536]
class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Type', 'text/plain')
        self.send_header('Content-Length', str(len(PAYLOAD)))
        self.send_header('Connection', 'close')
        self.end_headers()
        self.wfile.write(PAYLOAD)
    def log_message(self, *a):
        pass
srv = HTTPServer(('127.0.0.1', int(sys.argv[1])), H)
if len(sys.argv) > 2:
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(sys.argv[2], sys.argv[3])
    srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
srv.serve_forever()
