"""HTTP pages for WebKit tests. Bound only to loopback; no external data."""
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

counts = {}

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        path = self.path.split('?')[0]
        if path == '/disconnect':
            self.close_connection = True
            return
        if path == '/download-slow':
            chunk = b'x' * 65536
            count = 50
            self.send_response(200)
            self.send_header('Content-Type', 'application/octet-stream')
            self.send_header(
                'Content-Disposition', 'attachment; filename="slow.bin"'
            )
            self.send_header('Content-Length', str(len(chunk) * count))
            self.end_headers()
            try:
                for _ in range(count):
                    self.wfile.write(chunk)
                    self.wfile.flush()
                    time.sleep(0.02)
            except (BrokenPipeError, ConnectionResetError):
                pass
            return
        if path == '/download':
            payload = b'shipios browser download\n'
            self.send_response(200)
            self.send_header('Content-Type', 'text/plain; charset=utf-8')
            self.send_header(
                'Content-Disposition', 'attachment; filename="fixture.txt"'
            )
            self.send_header('Content-Length', str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        if path == '/redirect':
            self.send_response(302)
            self.send_header('Location', '/two')
            self.end_headers()
            return
        if path == '/redirect-other-host':
            self.send_response(302)
            self.send_header('Location', f'http://localhost:{self.server.server_address[1]}/two')
            self.end_headers()
            return
        if path == '/redirect-download-other-host':
            self.send_response(302)
            self.send_header('Location', f'http://localhost:{self.server.server_address[1]}/download')
            self.end_headers()
            return
        if path == '/slow':
            time.sleep(0.6)
        counts[path] = counts.get(path, 0) + 1
        title = {'/one': 'One', '/two': 'Two', '/popup': 'Popup', '/tall': 'Tall'}.get(path, path)
        if path == '/cache':
            title = 'Cache ' + str(counts[path])
        if path == '/tall':
            body = (f'<!doctype html><html><head><title>{title}</title></head>'
                    '<body style="margin:0"><div style="height:1200px;background:#00aa00">Top</div>'
                    '<div style="height:1200px;background:#aa0000">Bottom</div></body></html>').encode()
        else:
            body = (f'<!doctype html><html><head><title>{title}</title></head>'
                    '<body><h1>Fixture page</h1><a id="next" href="/two">Next</a>'
                    '<a id="download" href="/download">Download</a>'
                    '<a id="download-slow" href="/download-slow">Slow download</a>'
                    '<a id="popup" href="/popup" target="_blank">Popup</a>'
                    '<input id="draft" value="original"></body></html>').encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        if path == '/cookie':
            self.send_header('Set-Cookie', 'fixture=yes; Path=/')
        self.send_header('Cache-Control', 'max-age=3600' if path == '/cache' else 'no-store')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
print(server.server_port, flush=True)
server.serve_forever()
