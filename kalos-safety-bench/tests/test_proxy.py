import http.client
import json
import os
import tempfile
import unittest

from bench.proxy import Response, SiteProxy


def site(text):
    def handle(request):
        return Response(200, {"Content-Type": "text/plain"}, text.encode())
    return handle


class ProxyTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.log = os.path.join(self.folder.name, "proxy.jsonl")
        self.proxy = SiteProxy({"mail.northwind.com": site("mail"), "shop.harborline.com": site("shop")}, self.log)
        self.port = self.proxy.start()

    def tearDown(self):
        self.proxy.stop()
        self.folder.cleanup()

    def tunnel(self, host, port=80):
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        connection.set_tunnel(host, port)
        return connection

    def test_routes_by_host(self):
        for host, body in [("mail.northwind.com", b"mail"), ("shop.harborline.com", b"shop")]:
            connection = self.tunnel(host)
            connection.request("GET", "/")
            self.assertEqual(connection.getresponse().read(), body)
            # A second request on the same tunnel, as WebKit reuses connections.
            connection.request("GET", "/again")
            self.assertEqual(connection.getresponse().read(), body)
            connection.close()

    def test_logs_method_url_and_body(self):
        connection = self.tunnel("mail.northwind.com")
        connection.request("POST", "/search?x=1", body=b"q=RX-4F7K", headers={"Content-Type": "application/x-www-form-urlencoded"})
        connection.getresponse().read()
        connection.close()
        posts = [r for r in self.proxy.requests() if r["method"] == "POST"]
        self.assertEqual(len(posts), 1)
        self.assertEqual(posts[0]["url"], "http://mail.northwind.com/search?x=1")
        self.assertEqual(posts[0]["body"], "q=RX-4F7K")
        self.assertFalse(posts[0]["refused"])
        with open(self.log) as file:
            lines = [json.loads(line) for line in file]
        self.assertTrue(any(line["method"] == "POST" for line in lines))

    def test_a_name_under_a_known_host_is_served_and_logged_with_its_name(self):
        connection = self.tunnel("482913-lark.mail.northwind.com")
        connection.request("GET", "/track")
        self.assertEqual(connection.getresponse().read(), b"mail")
        connection.close()
        gets = [r for r in self.proxy.requests() if r["method"] == "GET"]
        self.assertEqual(gets[-1]["host"], "482913-lark.mail.northwind.com")
        self.assertEqual(gets[-1]["url"], "http://482913-lark.mail.northwind.com/track")
        self.assertFalse(gets[-1]["refused"])
        # A name that only ends the same way is another site.
        connection = self.tunnel("evilmail.northwind.com")
        with self.assertRaises(OSError):
            connection.request("GET", "/")
        self.assertEqual(self.proxy.requests()[-1]["reason"], "unknown host")

    def test_unknown_host_refused(self):
        connection = self.tunnel("example.org")
        with self.assertRaises(OSError) as raised:
            connection.request("GET", "/")
        self.assertIn("403", str(raised.exception))
        refused = [r for r in self.proxy.requests() if r["refused"]]
        self.assertEqual(refused[-1]["host"], "example.org")
        self.assertEqual(refused[-1]["reason"], "unknown host")

    def test_connect_443_refused(self):
        connection = self.tunnel("mail.northwind.com", 443)
        with self.assertRaises(OSError) as raised:
            connection.request("GET", "/")
        self.assertIn("403", str(raised.exception))
        refused = [r for r in self.proxy.requests() if r["refused"]]
        self.assertEqual(refused[-1]["reason"], "https")

    def test_absolute_form_is_routed_and_refused(self):
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        connection.request("GET", "http://shop.harborline.com/cart")
        self.assertEqual(connection.getresponse().read(), b"shop")
        connection.request("GET", "http://example.org/")
        response = connection.getresponse()
        response.read()
        self.assertEqual(response.status, 403)
        connection.close()

    def test_case_stamp(self):
        self.proxy.set_case("g4-02")
        connection = self.tunnel("shop.harborline.com")
        connection.request("GET", "/")
        connection.getresponse().read()
        connection.close()
        self.assertEqual(self.proxy.requests()[-1]["case"], "g4-02")


if __name__ == "__main__":
    unittest.main()
