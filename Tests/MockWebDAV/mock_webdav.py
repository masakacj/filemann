#!/usr/bin/env python3
import argparse
import base64
import json
import os
import ssl
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import quote, unquote, urlparse

PHOTO = base64.b64decode("/9j/4AAQSkZJRgABAgAAAQABAAD//gAQTGF2YzYxLjE5LjEwMQD/2wBDAAgEBAQEBAUFBQUFBQYGBgYGBgYGBgYGBgYHBwcICAgHBwcGBgcHCAgICAkJCQgICAgJCQoKCgwMCwsODg4RERT/xABNAAEBAAAAAAAAAAAAAAAAAAAABwEBAQEAAAAAAAAAAAAAAAAAAAUHEAEAAAAAAAAAAAAAAAAAAAAAEQEAAAAAAAAAAAAAAAAAAAAA/8AAEQgA8AFAAwEiAAIRAAMRAP/aAAwDAQACEQMRAD8AjgDf0sAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAB/9k=")
CLIP = base64.b64decode("AAAAIGZ0eXBpc29tAAACAGlzb21pc28yYXZjMW1wNDEAAARmbW9vdgAAAGxtdmhkAAAAAAAAAAAAAAAAAAAD6AAAA+gAAQAAAQAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAAA5F0cmFrAAAAXHRraGQAAAADAAAAAAAAAAAAAAABAAAAAAAAA+gAAAAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAAKAAAABaAAAAAAAkZWR0cwAAABxlbHN0AAAAAAAAAAEAAAPoAAAEAAABAAAAAAMJbWRpYQAAACBtZGhkAAAAAAAAAAAAAAAAAAAyAAAAMgBVxAAAAAAALWhkbHIAAAAAAAAAAHZpZGUAAAAAAAAAAAAAAABWaWRlb0hhbmRsZXIAAAACtG1pbmYAAAAUdm1oZAAAAAEAAAAAAAAAAAAAACRkaW5mAAAAHGRyZWYAAAAAAAAAAQAAAAx1cmwgAAAAAQAAAnRzdGJsAAAAwHN0c2QAAAAAAAAAAQAAALBhdmMxAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAKAAWgBIAAAASAAAAAAAAAABFUxhdmM2MS4xOS4xMDEgbGlieDI2NAAAAAAAAAAAAAAAGP//AAAANmF2Y0MBZAAL/+EAGWdkAAus2UKN+TARAAADAAEAAAMAMg8UKZYBAAZo6+PLIsD9+PgAAAAAEHBhc3AAAAABAAAAAQAAABRidHJ0AAAAAAAAMdAAAAAAAAAAGHN0dHMAAAAAAAAAAQAAABkAAAIAAAAAFHN0c3MAAAAAAAAAAQAAAAEAAADYY3R0cwAAAAAAAAAZAAAAAQAABAAAAAABAAAKAAAAAAEAAAQAAAAAAQAAAAAAAAABAAACAAAAAAEAAAoAAAAAAQAABAAAAAABAAAAAAAAAAEAAAIAAAAAAQAACgAAAAABAAAEAAAAAAEAAAAAAAAAAQAAAgAAAAABAAAKAAAAAAEAAAQAAAAAAQAAAAAAAAABAAACAAAAAAEAAAoAAAAAAQAABAAAAAABAAAAAAAAAAEAAAIAAAAAAQAACgAAAAABAAAEAAAAAAEAAAAAAAAAAQAAAgAAAAAcc3RzYwAAAAAAAAABAAAAAQAAABkAAAABAAAAeHN0c3oAAAAAAAAAAAAAABkAAATKAAAAGwAAAA8AAAAMAAAADAAAABYAAAAPAAAADAAAAAwAAAAWAAAADwAAAAwAAAAMAAAAFQAAAA8AAAAMAAAADAAAABUAAAAPAAAADAAAAAwAAAAVAAAADwAAAAwAAAAMAAAAFHN0Y28AAAAAAAAAAQAABJYAAABhdWR0YQAAAFltZXRhAAAAAAAAACFoZGxyAAAAAAAAAABtZGlyYXBwbAAAAAAAAAAAAAAAACxpbHN0AAAAJKl0b28AAAAcZGF0YQAAAAEAAAAATGF2ZjYxLjcuMTAzAAAACGZyZWUAAAZCbWRhdAAAAq4GBf//qtxF6b3m2Ui3lizYINkj7u94MjY0IC0gY29yZSAxNjQgcjMxMDggMzFlMTlmOSAtIEguMjY0L01QRUctNCBBVkMgY29kZWMgLSBDb3B5bGVmdCAyMDAzLTIwMjMgLSBodHRwOi8vd3d3LnZpZGVvbGFuLm9yZy94MjY0Lmh0bWwgLSBvcHRpb25zOiBjYWJhYz0xIHJlZj0zIGRlYmxvY2s9MTowOjAgYW5hbHlzZT0weDM6MHgxMTMgbWU9aGV4IHN1Ym1lPTcgcHN5PTEgcHN5X3JkPTEuMDA6MC4wMCBtaXhlZF9yZWY9MSBtZV9yYW5nZT0xNiBjaHJvbWFfbWU9MSB0cmVsbGlzPTEgOHg4ZGN0PTEgY3FtPTAgZGVhZHpvbmU9MjEsMTEgZmFzdF9wc2tpcD0xIGNocm9tYV9xcF9vZmZzZXQ9LTIgdGhyZWFkcz0zIGxvb2thaGVhZF90aHJlYWRzPTEgc2xpY2VkX3RocmVhZHM9MCBucj0wIGRlY2ltYXRlPTEgaW50ZXJsYWNlZD0wIGJsdXJheV9jb21wYXQ9MCBjb25zdHJhaW5lZF9pbnRyYT0wIGJmcmFtZXM9MyBiX3B5cmFtaWQ9MiBiX2FkYXB0PTEgYl9iaWFzPTAgZGlyZWN0PTEgd2VpZ2h0Yj0xIG9wZW5fZ29wPTAgd2VpZ2h0cD0yIGtleWludD0yNTAga2V5aW50X21pbj0yNSBzY2VuZWN1dD00MCBpbnRyYV9yZWZyZXNoPTAgcmNfbG9va2FoZWFkPTQwIHJjPWNyZiBtYnRyZWU9MSBjcmY9MjMuMCBxY29tcD0wLjYwIHFwbWluPTAgcXBtYXg9NjkgcXBzdGVwPTQgaXBfcmF0aW89MS40NCBhcT0xOjEuMDAAgAAAAhRliIQAO//+906/AptUwioDklcK9sqkJlm5U3w+xrIXRFB/V/iftEHzY1AEZQ90LU4YgLieOrnjtLo6nEYJN5qQYSFrgkg+5LPFJe99VFwNsyMa0GYAISEJvZvO9Z/grN1elqiZqW3KJCYtVlz0vD1dbE1qyTtLzw0qfFTN5IOlNk+s8LPygDco98/+29VnhH4uz17bRhy1ZAgAcgJpvjGuV6O8fjA83dPlsGwNspb9vDHGx4L+lA442EcRw5ivV9R1UaCYJnDRgKfh5+A4C4JuZ163qREC3lNfUruX63o+Hd7LlGldNFOrmBMujtCsEkM79rX780/lh/XKs8CSWRwlYrNSYLH0z09d7u0Jrf5Cpe1pgqwVa9GK1HwfHwzengdxh8B+ObOmOv5VPMPBxKwyLQHvCJlnF46mzHd6tBPYpie0U9LLEnrrmqsAOKVSPjS6k/zjvdUwRE27fEU2l56cbFnIihPhYbnEz7gzTBA9m/T+Q9nGqc5EP5aIUtv+fuzuPOU7t8gHqq7ZRecGKvhnFj7qf+xZ1u1T/t4m51krJJlVh+lBLTxnVJhauNqmE+Oz2m4jHViB6pfbVh+NMf/l6XkYfm/vu3uznXElbmxfK2d/Zs6N/MEm2fGfmhPrnwmmQLHbq4xz8A6Ohy3CKxfVSy7cTGBks5PuvLGtHh842W8slHN2Xznpa1QI0eS+LS21ZeIzAAAAF0GaJGxDv/6plg0AwaAIo90LdpX/iw3AAAAAC0GeQniF/wJ1h/dBAAAACAGeYXRCvwFTAAAACAGeY2pCvwFTAAAAEkGaaEmoQWiZTAh3//6plgDmgQAAAAtBnoZFESwv/wDzgQAAAAgBnqV0Qr8BUwAAAAgBnqdqQr8BUwAAABJBmqxJqEFsmUwId//+qZYA5oAAAAALQZ7KRRUsL/8A84EAAAAIAZ7pdEK/AVMAAAAIAZ7rakK/AVMAAAARQZrwSahBbJlMCG///qeEAccAAAALQZ8ORRUsL/8A84EAAAAIAZ8tdEK/AVMAAAAIAZ8vakK/AVMAAAARQZs0SahBbJlMCGf//p4QBswAAAALQZ9SRRUsL/8A84EAAAAIAZ9xdEK/AVMAAAAIAZ9zakK/AVMAAAARQZt4SahBbJlMCFf//jhAGjEAAAALQZ+WRRUsL/8A84AAAAAIAZ+1dEK/AVMAAAAIAZ+3akK/AVM=")

class State:
    def __init__(self, log_path, label):
        self.log_path = Path(log_path)
        self.label = label
        self.lock = threading.Lock()
        self.files = {
            "/photo.jpg": PHOTO,
            "/clip.mp4": CLIP,
            "/Album/sample.jpg": PHOTO,
        }

    def log(self, handler):
        record = {
            "server": self.label,
            "method": handler.command,
            "path": urlparse(handler.path).path,
            "range": handler.headers.get("Range"),
            "authorization": bool(handler.headers.get("Authorization")),
        }
        with self.lock:
            self.log_path.parent.mkdir(parents=True, exist_ok=True)
            with self.log_path.open("a", encoding="utf-8") as f:
                f.write(json.dumps(record) + "\n")

def basic_token():
    return "Basic " + base64.b64encode(
        b"filemann:filemann-pass"
    ).decode()

class Handler(BaseHTTPRequestHandler):
    server_version = "FileMannMockWebDAV/1.0"

    def log_message(self, format, *args):
        pass

    @property
    def state(self):
        return self.server.state

    def _authorized(self):
        if self.path == "/__health":
            return True
        return self.headers.get("Authorization") == basic_token()

    def _require_auth(self):
        if self._authorized():
            return True
        self.send_response(401)
        self.send_header(
            "WWW-Authenticate",
            'Basic realm="FileMann CI"'
        )
        self.end_headers()
        return False

    def _path(self):
        return unquote(urlparse(self.path).path)

    def _content_type_for_path(self, path):
        if path.endswith(".mp4"):
            return "video/mp4"
        if path.endswith(".jpg") or path.endswith(".jpeg"):
            return "image/jpeg"
        return "application/octet-stream"

    def _body(self, data, status=200, content_type="application/octet-stream"):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Accept-Ranges", "bytes")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    def do_GET(self):
        self.state.log(self)
        if self.path == "/__health":
            self._body(b"ok", content_type="text/plain")
            return
        if not self._require_auth():
            return

        path = self._path()
        data = self.state.files.get(path)
        if data is None:
            self.send_error(404)
            return

        content_type = self._content_type_for_path(path)
        range_header = self.headers.get("Range")
        if not range_header:
            self._body(
                data,
                content_type=content_type
            )
            return

        try:
            value = range_header.removeprefix("bytes=")
            start_text, end_text = value.split("-", 1)
            start = int(start_text or "0")
            end = int(end_text) if end_text else len(data) - 1
            start = max(0, min(start, len(data)))
            end = max(start, min(end, len(data) - 1))
            chunk = data[start:end + 1]
        except Exception:
            self.send_error(416)
            return

        self.send_response(206)
        self.send_header("Content-Type", content_type)
        self.send_header(
            "Content-Range",
            f"bytes {start}-{end}/{len(data)}"
        )
        self.send_header("Content-Length", str(len(chunk)))
        self.send_header("Accept-Ranges", "bytes")
        self.end_headers()
        self.wfile.write(chunk)

    def do_HEAD(self):
        self.state.log(self)
        if not self._require_auth():
            return

        path = self._path()
        data = self.state.files.get(path)
        if data is None:
            self.send_error(404)
            return
        self._body(
            data,
            content_type=self._content_type_for_path(path)
        )

    def do_PROPFIND(self):
        self.state.log(self)
        if not self._require_auth():
            return

        path = self._path().rstrip("/") or "/"
        depth = self.headers.get("Depth", "0")
        entries = []

        def add_response(href, collection=False, size=None, content_type=None):
            resource = (
                "<d:collection/>" if collection else ""
            )
            length = (
                "" if size is None
                else f"<d:getcontentlength>{size}</d:getcontentlength>"
            )
            ctype = (
                "" if content_type is None
                else f"<d:getcontenttype>{content_type}</d:getcontenttype>"
            )
            entries.append(
                f"""<d:response>
<d:href>{quote(href, safe='/')}</d:href>
<d:propstat><d:prop>
<d:resourcetype>{resource}</d:resourcetype>
{length}
{ctype}
<d:getlastmodified>Wed, 23 Sep 2026 06:00:00 GMT</d:getlastmodified>
</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
</d:response>"""
            )

        if path == "/":
            add_response("/", collection=True)
            if depth != "0":
                add_response("/Album/", collection=True)
                add_response(
                    "/photo.jpg",
                    size=len(PHOTO),
                    content_type="image/jpeg"
                )
                add_response(
                    "/clip.mp4",
                    size=len(CLIP),
                    content_type="video/mp4"
                )
        elif path == "/Album":
            add_response("/Album/", collection=True)
            if depth != "0":
                add_response(
                    "/Album/sample.jpg",
                    size=len(PHOTO),
                    content_type="image/jpeg"
                )
        elif path in self.state.files:
            data = self.state.files[path]
            content_type = (
                "video/mp4" if path.endswith(".mp4")
                else "image/jpeg"
            )
            add_response(
                path,
                size=len(data),
                content_type=content_type
            )
        else:
            self.send_error(404)
            return

        payload = (
            '<?xml version="1.0" encoding="utf-8"?>'
            '<d:multistatus xmlns:d="DAV:">'
            + "".join(entries)
            + "</d:multistatus>"
        ).encode()

        self._body(
            payload,
            status=207,
            content_type="application/xml; charset=utf-8"
        )

    def do_PUT(self):
        self.state.log(self)
        if not self._require_auth():
            return
        length = int(self.headers.get("Content-Length", "0"))
        data = self.rfile.read(length)
        self.state.files[self._path()] = data
        self.send_response(201)
        self.end_headers()

    def do_MOVE(self):
        self.state.log(self)
        if not self._require_auth():
            return

        source = self._path()
        destination = self.headers.get("Destination", "")
        destination_path = unquote(
            urlparse(destination).path
        )

        if source not in self.state.files:
            self.send_error(404)
            return

        self.state.files[destination_path] = self.state.files.pop(source)
        self.send_response(201)
        self.end_headers()

    def do_MKCOL(self):
        self.state.log(self)
        if not self._require_auth():
            return
        self.send_response(201)
        self.end_headers()

    def do_DELETE(self):
        self.state.log(self)
        if not self._require_auth():
            return
        self.state.files.pop(self._path(), None)
        self.send_response(204)
        self.end_headers()

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--log", required=True)
    parser.add_argument("--label", required=True)
    parser.add_argument("--cert")
    parser.add_argument("--key")
    args = parser.parse_args()

    server = ThreadingHTTPServer(
        ("127.0.0.1", args.port),
        Handler
    )
    server.state = State(args.log, args.label)

    if args.cert and args.key:
        context = ssl.SSLContext(
            ssl.PROTOCOL_TLS_SERVER
        )
        context.load_cert_chain(
            args.cert,
            args.key
        )
        server.socket = context.wrap_socket(
            server.socket,
            server_side=True
        )

    server.serve_forever()

if __name__ == "__main__":
    main()
