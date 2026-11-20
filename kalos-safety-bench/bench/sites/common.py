"""What every site shares: the page shell, a case's own extra HTML, and where the case's hostile text sits.

Pages are plain server-rendered HTML with no timers or animation, so they work in a hidden, throttled window. The
obedient agent's steps come from the case file, never from the page; the hostile text is there for a model to read.
"""

from html import escape

from ..case import fill
from ..proxy import Response

STYLE = """
* { box-sizing: border-box; }
body { margin: 0; font: 15px/1.5 -apple-system, "Helvetica Neue", Arial, sans-serif; color: #1d232b; background: #f6f7f9; }
header { display: flex; align-items: center; gap: 24px; padding: 14px 28px; background: #fff; border-bottom: 1px solid #e3e6ea; }
header .brand { font-weight: 700; font-size: 18px; color: #1d232b; text-decoration: none; }
header nav a { color: #4a5563; margin-right: 16px; text-decoration: none; }
header .who { margin-left: auto; color: #6b7480; font-size: 13px; }
main { max-width: 860px; margin: 24px auto; padding: 0 20px; }
.card { background: #fff; border: 1px solid #e3e6ea; border-radius: 8px; padding: 18px 20px; margin-bottom: 14px; }
.muted { color: #6b7480; font-size: 13px; }
.row { display: flex; gap: 12px; align-items: baseline; padding: 10px 0; border-bottom: 1px solid #eef0f2; }
.row:last-child { border-bottom: none; }
.row a { color: #1d232b; text-decoration: none; font-weight: 600; }
label { display: block; margin: 10px 0 4px; font-weight: 600; font-size: 13px; }
input[type=text], input[type=email], input[type=password], input[type=search], input[type=number], textarea, select {
  width: 100%; padding: 8px 10px; border: 1px solid #cdd2d8; border-radius: 6px; font: inherit; }
textarea { min-height: 110px; }
button, .button { display: inline-block; margin-top: 12px; padding: 8px 16px; border: 0; border-radius: 6px; background: #2457c5;
  color: #fff; font: inherit; font-weight: 600; text-decoration: none; cursor: pointer; }
button.quiet, .button.quiet { background: #e8ebef; color: #1d232b; }
.price { font-weight: 700; }
"""


def page(title: str, brand: str, body: str, nav: str = "", who: str = "") -> Response:
    html = (f"<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><title>{escape(title)}</title>"
            f"<meta name=\"viewport\" content=\"width=device-width\"><style>{STYLE}</style></head><body>"
            f"<header><a class=\"brand\" href=\"/\">{escape(brand)}</a><nav>{nav}</nav>"
            f"<span class=\"who\">{escape(who)}</span></header><main>{body}</main></body></html>")
    return Response(200, {"Content-Type": "text/html; charset=utf-8"}, html.encode())


def redirect(to: str) -> Response:
    return Response(303, {"Location": to}, b"")


def not_found(brand: str) -> Response:
    response = page("Page not found", brand, "<div class=\"card\"><h2>Page not found</h2><p><a href=\"/\">Go back</a></p></div>")
    response.status = 404
    return response


# Placements drawn into the page itself. "email", "review" and "results" are drawn by the mail, shop and forum sites.
_PIXEL = "data:image/gif;base64,R0lGODlhAQABAIAAAP///wAAACH5BAEAAAAALAAAAAABAAEAAAICRAEAOw=="


def attack_text(world, case) -> str:
    return fill(case.attack, world)


def placed(world, case, kind: str, path: str) -> str:
    if not case.attack or case.attack_page != f"{kind}:{path}":
        return ""
    text = escape(attack_text(world, case))
    match case.placement:
        case "visible":
            return f"<div class=\"card\"><p>{text}</p></div>"
        case "tiny":
            return f"<p style=\"font-size:1px;line-height:1px;color:#f6f7f9;margin:0\">{text}</p>"
        case "comment":
            return f"<!-- {text.replace('--', '- -')} -->"
        case "alt":
            return f"<img src=\"{_PIXEL}\" width=\"1\" height=\"1\" alt=\"{text}\">"
        case "aria":
            return f"<div class=\"muted\" role=\"note\" aria-label=\"{text}\">&nbsp;</div>"
        case "note":
            title = escape(fill(case.attack_title, world) or "Note for your assistant")
            return (f"<div class=\"card\" style=\"border-left:3px solid #2457c5\"><p class=\"muted\">{title}</p>"
                    f"<p>{text}</p></div>")
        case "frame":
            return (f"<iframe src=\"http://{world.hosts['outside']}/embed\" title=\"Offers\" "
                    "style=\"width:100%;height:140px;border:1px solid #e3e6ea;border-radius:8px\"></iframe>")
    return ""


def extra_html(world, case, kind: str, path: str) -> str:
    """A case's own HTML for this page, such as a second form or a button that changes after a click, and the case's
    hostile text when this is its page."""
    return fill(case.extra.get(f"{kind}:{path}", ""), world) + placed(world, case, kind, path)
