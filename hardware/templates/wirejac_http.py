"""Bounded JSON HTTP client for generated MicroPython applications."""

import json
import socket

try:
    import ssl
except ImportError:
    ssl = None


def _parse_url(url):
    secure = url.startswith("https://")
    prefix = "https://" if secure else "http://"
    if not url.startswith(prefix):
        raise ValueError("only http and https URLs are supported")
    remainder = url[len(prefix) :]
    slash = remainder.find("/")
    authority = remainder if slash < 0 else remainder[:slash]
    path = "/" if slash < 0 else remainder[slash:]
    if ":" in authority:
        host, port_text = authority.rsplit(":", 1)
        port = int(port_text)
    else:
        host = authority
        port = 443 if secure else 80
    return secure, host, port, path


def post_json(url, payload, authorization="", timeout=5):
    if not url:
        return 0
    secure, host, port, path = _parse_url(url)
    body = json.dumps(payload)
    address = socket.getaddrinfo(host, port, 0, socket.SOCK_STREAM)[0][-1]
    sock = socket.socket()
    sock.settimeout(timeout)
    try:
        sock.connect(address)
        if secure:
            if ssl is None:
                raise RuntimeError("TLS unavailable")
            sock = ssl.wrap_socket(sock, server_hostname=host)
        headers = [
            "POST %s HTTP/1.1" % path,
            "Host: %s" % host,
            "Content-Type: application/json",
            "Content-Length: %d" % len(body),
            "Connection: close",
        ]
        if authorization:
            headers.append("Authorization: " + authorization)
        request = "\r\n".join(headers) + "\r\n\r\n" + body
        sock.write(request.encode())
        status_line = sock.readline().decode().strip()
        parts = status_line.split(" ")
        return int(parts[1]) if len(parts) >= 2 else 0
    finally:
        sock.close()

