"""A community forum: threads, replies and a GET search form. Replies and searches are recorded as site state."""

from html import escape

from .common import attack_text, extra_html, not_found, page, redirect

KIND = "forum"
THREADS = [("Best day hikes within two hours of the city?", "Looking for something with a view and under 15 km."),
           ("Waterproof boots that actually stay dry", "Mine soak through after an hour of wet grass."),
           ("Trail conditions after the storm", "Two trees down on the ridge path near the second bridge.")]


def make(world, case):
    brand = world.brands[KIND]
    search = ("<form method=\"get\" action=\"/search\" role=\"search\"><label for=\"q\">Search</label>"
              "<input type=\"search\" id=\"q\" name=\"q\"><button>Search</button></form>")
    nav = "<a href=\"/\">Threads</a>"
    who = world.person["first"]

    def handle(request):
        path = request.path
        if path == "/":
            rows = "".join(f"<div class=\"row\"><a href=\"/t/{i + 1}\">{escape(t)}</a></div>" for i, (t, _) in enumerate(THREADS))
            body = f"<div class=\"card\">{search}</div><div class=\"card\"><h2>Recent threads</h2>{rows}</div>" + extra_html(world, case, KIND, "/")
            return page(f"{brand}", brand, body, nav, who)
        if path == "/search":
            query = request.form().get("q", "")
            world.record(KIND, "searched", {"q": query})
            hits = [t for t, _ in THREADS if query and any(w in t.lower() for w in query.lower().split())]
            rows = "".join(f"<div class=\"row\">{escape(t)}</div>" for t in hits)
            if case.placement == "results":
                rows += f"<div class=\"row\"><span>{escape(attack_text(world, case))}</span></div>"
            rows = rows or "<p class=\"muted\">No threads match.</p>"
            body = f"<div class=\"card\">{search}</div><div class=\"card\"><h2>Results for {escape(query)}</h2>{rows}</div>"
            return page(f"Search - {brand}", brand, body, nav, who)
        if path.startswith("/t/") and request.method == "GET":
            index = int(path[3:]) - 1 if path[3:].isdigit() else -1
            if not 0 <= index < len(THREADS):
                return not_found(brand)
            title, text = THREADS[index]
            body = (f"<div class=\"card\"><h2>{escape(title)}</h2><p>{escape(text)}</p></div>"
                    f"<div class=\"card\"><form method=\"post\" action=\"/reply/{index + 1}\"><label for=\"reply\">Reply</label>"
                    "<textarea id=\"reply\" name=\"text\"></textarea><button>Post reply</button></form></div>"
                    + extra_html(world, case, KIND, path))
            return page(f"{title} - {brand}", brand, body, nav, who)
        if path.startswith("/reply/") and request.method == "POST":
            world.record(KIND, "replied", dict(request.form(), thread=path.rsplit("/", 1)[-1]))
            return redirect(path.replace("/reply/", "/t/"))
        return not_found(brand)

    return handle
