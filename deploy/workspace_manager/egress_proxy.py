#!/usr/bin/env python3
"""Allowlist CONNECT proxy for workspace dependency installs.

An execution container never gets a route to the internet. Installs run in a
short-lived helper on the internal egress network whose only way out is this
process, and this process only ever dials APPROVED_HOSTS. Anything else is
closed before a byte leaves the machine.

This is a package-source gate, not a general web proxy: no GET/POST forwarding,
no redirects followed, no DNS of unapproved names.
"""

import ipaddress
import logging
import os
import socket
import socketserver
import threading

APPROVED_HOSTS = {
    host.strip().rstrip(".").lower()
    for host in os.environ.get(
        "SHAMS_WS_ALLOWED_HOSTS",
        "pypi.org,files.pythonhosted.org,pypi.python.org,bootstrap.pypa.io",
    ).split(",")
    if host.strip()
}
LISTEN_PORT = int(os.environ.get("SHAMS_PROXY_PORT", "3128"))
MAX_CONNECTIONS = int(os.environ.get("SHAMS_PROXY_MAX_CONNECTIONS", "64"))
RELAY_BYTES = 64 * 1024 * 1024

COUNT = 0
COUNT_LOCK = threading.Lock()


def approved(host):
    host = host.strip().rstrip(".").lower()
    try:
        ipaddress.ip_address(host)
        return False
    except ValueError:
        return host in APPROVED_HOSTS


def connect_upstream(host, port):
    if not approved(host) or port != 443:
        raise OSError("destination rejected")
    addresses = socket.getaddrinfo(host, port, type=socket.SOCK_STREAM)
    for family, _, _, _, address in addresses:
        ip = ipaddress.ip_address(address[0])
        if family not in (socket.AF_INET, socket.AF_INET6) or not ip.is_global or ip.is_multicast:
            raise OSError("non-public destination rejected")
        if isinstance(ip, ipaddress.IPv6Address) and (ip.ipv4_mapped or ip.sixtofour or ip.teredo):
            raise OSError("translated destination rejected")
    for family, kind, protocol, _, address in addresses:
        remote = socket.socket(family, kind, protocol)
        remote.settimeout(15)
        try:
            # Connect to the checked numeric address without a second DNS lookup.
            remote.connect(address)
            return remote
        except OSError:
            remote.close()
    raise OSError("upstream unreachable")


def refuse(client, reason):
    try:
        client.sendall(
            f"HTTP/1.1 403 Forbidden\r\nProxy-Agent: shams-egress\r\nX-Refused-Reason: {reason}\r\n"
            "Content-Length: 0\r\nConnection: close\r\n\r\n".encode()
        )
    except OSError:
        pass


def pump(source, destination):
    moved = 0
    while moved < RELAY_BYTES:
        try:
            data = source.recv(65536)
        except OSError:
            return moved
        if not data:
            return moved
        try:
            destination.sendall(data)
        except OSError:
            return moved
        moved += len(data)
    return moved


class ProxyHandler(socketserver.BaseRequestHandler):
    def handle(self):
        global COUNT
        with COUNT_LOCK:
            COUNT += 1
            if COUNT > MAX_CONNECTIONS:
                COUNT -= 1
                refuse(self.request, "over-limit")
                return
        try:
            self.request.settimeout(15)
            line = self.request.makefile("rb").readline(8193)
            if len(line) > 8192:
                refuse(self.request, "request-too-large")
                return
            if not line:
                return
            pieces = line.decode("latin-1").split()
            if len(pieces) < 2 or pieces[0] != "CONNECT":
                refuse(self.request, "method")
                return
            authority = pieces[1]
            host = authority.rsplit(":", 1)[0] if ":" in authority and not authority.endswith("]") else authority
            try:
                port = int(authority.rsplit(":", 1)[1])
            except (IndexError, ValueError):
                port = 443
            if port != 443:
                refuse(self.request, "port")
                return
            if not approved(host):
                logging.warning("refused %s", host)
                refuse(self.request, "host-not-approved")
                return

            try:
                remote = connect_upstream(host, port)
            except OSError:
                refuse(self.request, "upstream-unreachable")
                return

            self.request.sendall(
                b"HTTP/1.1 200 Connection established\r\nProxy-Agent: shams-egress\r\n\r\n"
            )
            relay = threading.Thread(target=pump, args=(remote, self.request), daemon=True)
            relay.start()
            pump(self.request, remote)
            remote.close()
        finally:
            with COUNT_LOCK:
                COUNT -= 1


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def main():
    logging.basicConfig(level=logging.INFO, format="%(asctime)s egress %(message)s")
    logging.info("allowlist=%s port=%s", sorted(APPROVED_HOSTS), LISTEN_PORT)
    with Server(("0.0.0.0", LISTEN_PORT), ProxyHandler) as server:
        server.serve_forever()


if __name__ == "__main__":
    main()
