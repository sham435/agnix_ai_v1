import socket
import unittest
from unittest.mock import Mock, patch

import egress_proxy


def address(ip):
    family = socket.AF_INET6 if ":" in ip else socket.AF_INET
    return (family, socket.SOCK_STREAM, socket.IPPROTO_TCP, "", (ip, 443))


class EgressProxyTest(unittest.TestCase):
    def test_only_exact_package_hosts_are_approved(self):
        for host in ("pypi.org", "files.pythonhosted.org", "PYPI.ORG."):
            with self.subTest(host=host):
                self.assertTrue(egress_proxy.approved(host))
        for host in ("", "127.0.0.1", "169.254.169.254", "host.docker.internal",
                     "shams-public-web-1", "evil.pypi.org", "pypi.org.evil.test"):
            with self.subTest(host=host):
                self.assertFalse(egress_proxy.approved(host))

    def test_unapproved_destinations_never_resolve(self):
        with patch.object(socket, "getaddrinfo") as resolve:
            for host, port in (("localhost", 443), ("pypi.org", 80), ("pypi.org", 3001)):
                with self.subTest(host=host, port=port), self.assertRaises(OSError):
                    egress_proxy.connect_upstream(host, port)
            resolve.assert_not_called()

    def test_non_public_dns_answers_never_connect(self):
        for ip in ("127.0.0.1", "10.0.0.1", "172.19.0.2", "192.168.1.1",
                   "169.254.169.254", "100.64.0.1", "0.0.0.0", "224.0.0.1",
                   "::1", "fe80::1", "fd00::1", "::ffff:127.0.0.1",
                   "2002:7f00:1::"):
            with self.subTest(ip=ip), patch.object(socket, "getaddrinfo", return_value=[address(ip)]), \
                    patch.object(socket, "socket") as factory, self.assertRaises(OSError):
                egress_proxy.connect_upstream("pypi.org", 443)
            factory.assert_not_called()

    def test_mixed_public_and_private_answers_fail_closed(self):
        with patch.object(socket, "getaddrinfo", return_value=[address("151.101.0.223"), address("10.0.0.1")]), \
                patch.object(socket, "socket") as factory, self.assertRaises(OSError):
            egress_proxy.connect_upstream("pypi.org", 443)
        factory.assert_not_called()

    def test_connection_is_pinned_to_checked_address(self):
        remote = Mock()
        with patch.object(socket, "getaddrinfo", return_value=[address("151.101.0.223")]) as resolve, \
                patch.object(socket, "socket", return_value=remote):
            self.assertIs(egress_proxy.connect_upstream("pypi.org", 443), remote)
        resolve.assert_called_once_with("pypi.org", 443, type=socket.SOCK_STREAM)
        remote.connect.assert_called_once_with(("151.101.0.223", 443))

    def test_failed_connections_close_the_socket(self):
        remote = Mock()
        remote.connect.side_effect = OSError("unreachable")
        with patch.object(socket, "getaddrinfo", return_value=[address("151.101.0.223")]), \
                patch.object(socket, "socket", return_value=remote), self.assertRaises(OSError):
            egress_proxy.connect_upstream("pypi.org", 443)
        remote.close.assert_called_once()


if __name__ == "__main__":
    unittest.main()
