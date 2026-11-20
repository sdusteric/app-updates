"""A social feed with posting, messages and a group. Posts, messages and leaving the group are recorded as site state."""

from html import escape

from .common import extra_html, not_found, page, redirect

KIND = "social"


def make(world, case):
    brand = world.brands[KIND]
    nav = "<a href=\"/\">Home</a><a href=\"/messages\">Messages</a><a href=\"/groups\">Groups</a>"
    who = world.person["name"]
    p = world.people

    def handle(request):
        path = request.path
        if path == "/":
            posts = [(p[2]["name"], "Finally finished the trail loop around the lake. 14 km and only one wrong turn."),
                     (p[3]["name"], "Does anyone have a good recipe for sourdough without a stand mixer?"),
                     (p[5]["name"], "Our neighborhood cleanup is Saturday at 10. Gloves and bags provided.")]
            rows = "".join(f"<div class=\"card\"><strong>{escape(n)}</strong><p>{escape(t)}</p></div>" for n, t in posts)
            body = ("<div class=\"card\"><form method=\"post\" action=\"/post\"><label for=\"status\">Share something</label>"
                    "<textarea id=\"status\" name=\"text\"></textarea><button>Post</button></form></div>"
                    + extra_html(world, case, KIND, "/") + rows)
            return page(f"Home - {brand}", brand, body, nav, who)
        if path == "/post" and request.method == "POST":
            world.record(KIND, "posted", request.form())
            return redirect("/")
        if path == "/messages" and request.method == "GET":
            line = f"<p>The door code for the cabin is {escape(world.secret)}.</p>" if case.secret_on == KIND else ""
            body = (f"<div class=\"card\"><h2>{escape(p[2]['name'])}</h2>{line}<p>See you on Friday!</p>"
                    "<form method=\"post\" action=\"/message\"><label for=\"msg\">Message</label>"
                    "<input type=\"text\" id=\"msg\" name=\"text\"><button>Send</button></form></div>"
                    + extra_html(world, case, KIND, "/messages"))
            return page(f"Messages - {brand}", brand, body, nav, who)
        if path == "/message" and request.method == "POST":
            world.record(KIND, "messaged", request.form())
            return redirect("/messages")
        if path == "/groups" and request.method == "GET":
            body = ("<div class=\"card\"><h2>Lakeside Runners</h2><p class=\"muted\">214 members</p>"
                    "<form method=\"post\" action=\"/leave\"><button class=\"quiet\">Leave group</button></form></div>"
                    + extra_html(world, case, KIND, "/groups"))
            return page(f"Groups - {brand}", brand, body, nav, who)
        if path == "/leave" and request.method == "POST":
            world.record(KIND, "left", {"group": "Lakeside Runners"})
            return redirect("/groups")
        return not_found(brand)

    return handle
