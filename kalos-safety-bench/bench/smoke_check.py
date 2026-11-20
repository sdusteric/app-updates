"""Live check that a bench Pane reaches only the proxy's sites. Main session only.

    python3 -I tools/safety-bench/bench/smoke_check.py --app <smoke Kalos.app>
"""

import argparse
import os
import shutil
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from bench.pane import PaneAdapter  # noqa: E402
from bench.proxy import Response, SiteProxy  # noqa: E402


def page(title):
    def handle(request):
        body = f"<!doctype html><html><head><title>{title}</title></head><body><h1>{title}</h1><p>{request.path}</p></body></html>"
        return Response(200, {"Content-Type": "text/html; charset=utf-8"}, body.encode())
    return handle


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True)
    args = parser.parse_args(argv)
    folder = tempfile.mkdtemp(prefix="pane-bench-check-")
    sites = {"mail.northwind.com": page("Northwind Mail"), "shop.harborline.com": page("Harborline")}
    proxy = SiteProxy(sites, os.path.join(folder, "proxy.jsonl"))
    port = proxy.start()
    pane = PaneAdapter()
    results = []

    def check(name, ok, detail=""):
        results.append(ok)
        print(f"{'ok  ' if ok else 'FAIL'} {name}{': ' + detail if detail else ''}", flush=True)

    try:
        pane.launch(args.app, port)
        print(f"Pane {pane.ready.get('version')} build {pane.ready.get('build')}, pid {pane.pid}", flush=True)

        loaded = {}
        for host, title in [("mail.northwind.com", "Northwind Mail"), ("shop.harborline.com", "Harborline")]:
            result = pane.control("open", url=f"http://{host}/", share=True)
            logged = any(r["host"] == host and r["method"] == "GET" and not r["refused"] for r in proxy.requests())
            loaded[host] = result.get("title") == title and logged
        check("(a) sites load through the proxy", all(loaded.values()), str(loaded))

        result = pane.control("open", url="http://example.org/", share=False)
        refused = any(r["host"] == "example.org" and r["refused"] for r in proxy.requests())
        check("(b) other hosts are refused", refused and "Example" not in result.get("title", ""),
              f"title={result.get('title')!r} refused={refused}")

        state = pane.control("reset")
        check("(c) reset is clean", state.get("clean") is True, "" if state.get("clean") else str(state))

        connects = [r for r in proxy.requests() if r["method"] == "CONNECT" and r["host"] in sites]
        https = [r["url"] for r in connects if not r["url"].endswith(":80")]
        check("(e) no https upgrade for site hosts", bool(connects) and not https, f"{len(connects)} tunnels, other ports {https}")

        proxy.stop()
        result = pane.control("open", url="http://example.com/", share=False)
        check("(d) with the proxy stopped nothing loads directly", "Example" not in result.get("title", ""),
              f"loaded={result.get('loaded')} title={result.get('title')!r}")
    except Exception as error:  # Report and quit Pane whatever went wrong.
        check("bench run", False, repr(error))
    finally:
        pane.quit()
        proxy.stop()
        shutil.rmtree(folder, ignore_errors=True)
    return 0 if results and all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
