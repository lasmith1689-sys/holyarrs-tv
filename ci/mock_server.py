"""Stand-in for HolyArrs (and the RTX 4K server) so the simulator screen check runs without the PC.

    python3 ci/mock_server.py <fixtures dir> <port>

Serves /api/v1/* from ci/fixtures/*.json, with HolyArrs' sign-in rules: POST /auth/login sets the session
cookie and answers the CSRF token; every other /api/v1 call needs the cookie, and state-changing calls need
X-CSRF-Token too (403 otherwise, like HolyArrs). Pictures (/api/v1/artwork/...) are generated solid-colour
PNGs. RTX routes (/library, /play, /stop) answer from rtx_library.json. Every request is logged to
<fixtures dir>/requests.log with its status, so the run shows what the app called.
"""
import json
import struct
import time
import sys
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

HERE = Path(__file__).resolve().parent / "fixtures"
OUT = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("/tmp/fixtures")
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 8799
OUT.mkdir(parents=True, exist_ok=True)
LOG = OUT / "requests.log"
TOKEN = "session-token-for-tests"
CSRF = "csrf-token-for-tests"
NAME, PASSWORD = "luke", "test-password-1"


def png(w, h, rgb):
    raw = b"".join(b"\x00" + bytes(rgb) * w for _ in range(h))
    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")


def crest(size, rgb):
    """A filled circle on a clear background (a stand-in team crest)."""
    r = size / 2
    rows = []
    for y in range(size):
        row = bytearray(b"\x00")
        for x in range(size):
            inside = (x - r + 0.5) ** 2 + (y - r + 0.5) ** 2 <= (r - 1) ** 2
            row += bytes(rgb) + (b"\xff" if inside else b"\x00")
        rows.append(bytes(row))
    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(b"".join(rows), 9)) + chunk(b"IEND", b""))


def fixture(name):
    p = HERE / f"{name}.json"
    return json.loads(p.read_text()) if p.exists() else None


# GET routes: path (after /api/v1/) -> fixture name. Longest prefix wins for templated ids.
GETS = {
    "auth/me": "me",
    "home": "home",
    "explore/head": "explore_head",
    "explore/tail": "explore_tail",
    "explore/genre-row": "genre_row",
    "explore/genre": "genre",
    "explore/music": "explore_music",
    "search/suggest": "suggest",
    "search": "search_plain",
    "asks": "asks",
    "needs-decision": "needs_decision",
    "downloads/view": "downloads",
    "calendar": "calendar",
    "titles/lookup": "titles_lookup",
    "shows/lookup": "shows_lookup",
    "people/search": "people_search",
}


SPORTARR_KEY = "sportarr-key-for-tests"
F1_FILE = "Formula 1 - s2026e47 - Las Vegas Grand Prix - Race - 1080p.mkv"


def iso(days, hour=None):
    """A date `days` from today: a set start time (UTC) when hour is given, else Sportarr's date-only midnight."""
    t = time.gmtime(time.time() + days * 86400)
    return time.strftime("%Y-%m-%dT", t) + (f"{hour:02d}:00:00Z" if hour is not None else "00:00:00Z")


def art(name, wide=True):
    return f"http://127.0.0.1:{PORT}/api/v1/artwork/sport/{name}/{'w780' if wide else 'w342'}.png"


def sport_leagues():
    def lg(i, name, sport, fmt, monitored, events, upcoming):
        return {"id": i, "externalId": f"lg-{i:06d}", "name": name, "sport": sport, "sportFormat": fmt,
                "monitored": monitored, "monitorType": "Future" if monitored else "None", "eventCount": events,
                "upcomingCount": upcoming, "fileCount": 1 if i == 1 else 0, "logoUrl": art(f"logo{i}", False),
                "posterUrl": None, "bannerUrl": art(f"banner{i}"), "monitoredTeams": []}
    return [lg(1, "Formula 1", "Motorsport", "EventSport", True, 120, 6), lg(2, "NFL", "Football", "TeamvsTeam", False, 0, 0),
            lg(3, "English Premier League", "Soccer", "TeamvsTeam", False, 0, 0), lg(4, "PGA Tour", "Golf", "EventSport", False, 48, 4)]


def sport_events():
    def ev(i, lid, league, title, date, sport, monitored=False, home=None, away=None, file=None, venue=None):
        return {"id": i, "leagueId": lid, "leagueName": league, "leagueLogoUrl": art(f"logo{lid}", False), "title": title,
                "eventDate": date, "sport": sport, "venue": venue, "homeTeamName": home, "awayTeamName": away,
                "thumbUrl": art(f"event{i}"), "monitored": monitored, "hasFile": file is not None,
                "filePath": f"D:\\Sports\\Formula 1\\Season 2026\\{file}" if file else None, "files": [],
                "status": "scheduled", "homeScore": 27 if home else None, "awayScore": 24 if home else None}
    return [
        ev(1, 1, "Formula 1", "Las Vegas Grand Prix - Race", iso(-1, 4), "Motorsport", True, file=F1_FILE, venue="Las Vegas Strip Circuit"),
        ev(2, 1, "Formula 1", "Las Vegas Grand Prix - Qualifying", iso(-2, 4), "Motorsport", True,
           file="Formula 1 - s2026e46 - Las Vegas Grand Prix - Qualifying - 1080p.mkv", venue="Las Vegas Strip Circuit"),
        ev(3, 2, "NFL", "Philadelphia Eagles vs New York Giants", iso(1, 18), "Football", True,
           home="New York Giants", away="Philadelphia Eagles", venue="MetLife Stadium"),
        ev(4, 3, "English Premier League", "Arsenal vs Chelsea", iso(2, 16), "Soccer", home="Arsenal", away="Chelsea", venue="Emirates Stadium"),
        ev(5, 4, "PGA Tour", "The RSM Classic - Round 1", iso(3), "Golf", venue="Sea Island"),
        ev(6, 1, "Formula 1", "Qatar Grand Prix - Race", iso(7, 16), "Motorsport", True, venue="Lusail International Circuit"),
    ]


# Stand-in teams (the PC's /tv/teams answers ESPN's real lists): abbr, short name, colour, second colour, names.
TEAMS = {
    "NFL": [("CHI", "Bears", "0b1c3a", "e64100", ["chicago bears", "bears"]), ("NO", "Saints", "d3bc8d", "000000", ["new orleans saints", "saints"]),
            ("TEN", "Titans", "4b92db", "002a5c", ["tennessee titans", "titans"]), ("DAL", "Cowboys", "002a5c", "b0b7bc", ["dallas cowboys", "cowboys"]),
            ("LV", "Raiders", "000000", "a5acaf", ["las vegas raiders", "raiders"]), ("DEN", "Broncos", "0a2343", "fc4c02", ["denver broncos", "broncos"]),
            ("PHI", "Eagles", "06424d", "a5acaf", ["philadelphia eagles", "eagles"]), ("NYG", "Giants", "003c7f", "a6192e", ["new york giants", "giants"])],
    "Premier League": [("LIV", "Liverpool", "d11317", "ffffff", ["liverpool"]), ("MAN", "Man Utd", "da020e", "ffe500", ["manchester united", "man united", "man utd"]),
                       ("ARS", "Arsenal", "e20520", "ffffff", ["arsenal"]), ("CHE", "Chelsea", "034694", "ffffff", ["chelsea"])],
}


def team(league, abbr):
    key = "nfl" if league == "NFL" else "epl"
    a, short, color, alt, names = next(t for t in TEAMS[league] if t[0] == abbr)
    return {"abbr": a, "name": names[0].title(), "short": short, "color": color, "alt": alt, "logo": f"/tv/teamlogo/{key}/{a.lower()}.png"}


def tv_event(i, title, league, start_h, mine=(), teams=None):
    s = time.time() + start_h * 3600
    e = {"id": str(9000 + i), "title": title, "league": league, "start": s, "end": s + 3.5 * 3600, "mine": list(mine), "alt": []}
    if teams:
        e["teams"] = [team(league, t) for t in teams]
    return e


def on_demand_item(i, title, year, kind="movie"):
    return {"id": str(70000 + i), "kind": kind, "title": title, "year": year, "rating": 7.1,
            "poster": f"https://image.tmdb.org/t/p/w600_and_h900_bestv2/od{i}.jpg", "ext": "mkv"}


def on_demand():
    films = [on_demand_item(i, t, y) for i, (t, y) in enumerate([("The Odyssey", 2026), ("Nimrods", 2026), ("The Fix", 2026),
                                                                   ("Heartland", 2026), ("Kalocsa", 2026), ("The Beast", 2026)])]
    series = [on_demand_item(20 + i, t, y, "series") for i, (t, y) in enumerate([("The Witch Farm", 2026), ("Slow Horses", 2022),
                                                                                  ("Severance", 2022)])]
    return {"rows": [{"id": "new", "title": "New releases", "kind": "movie", "category": "163", "items": films},
                     {"id": "series-new", "title": "New series", "kind": "series", "category": "156", "items": series},
                     {"id": "imdb", "title": "IMDb Top 250", "kind": "movie", "category": "1453", "items": films[::-1]}],
            "counts": {"movies": 34102, "series": 8519}}


def tv_groups():
    def ch(i, name, show):
        now = time.time()
        return {"id": str(100 + i), "alt": [], "name": name, "logo": f"/tv/logo/{100 + i}.png",
                "now": {"title": show, "start": now - 1200, "end": now + 2400}, "next": None}
    return [
        {"id": "sports", "name": "Sports", "channels": [ch(1, "ESPN", "SportsCenter"), ch(2, "NFL RedZone", "RedZone"),
                                                       ch(3, "Sky Sports Premier League", "Super Sunday")]},
        {"id": "golf", "name": "Golf", "channels": [ch(4, "Golf Channel", "Golf Central")]},
        {"id": "racing", "name": "Racing", "channels": [ch(5, "F1 TV", "Qatar Grand Prix build-up")]},
        {"id": "news", "name": "News", "channels": [ch(6, "CNN", "State of the Union"), ch(7, "BBC News", "BBC News")]},
        {"id": "local", "name": "New York", "channels": [ch(8, "FOX 5 New York", "FOX NFL Sunday")]},
    ]


def tv_sports():
    groups = {g["id"]: g for g in tv_groups()}
    redzone = groups["sports"]["channels"][1]
    return {"now": time.time(), "pinned": [redzone],
            "yours": [tv_event(1, "Saints at Bears", "NFL", -0.5, ["Bears"], ["NO", "CHI"]),
                      tv_event(2, "Liverpool vs Manchester United", "Premier League", 26, ["Man United"], ["LIV", "MAN"])],
            "live": [tv_event(3, "Titans at Cowboys", "NFL", -0.4, teams=["TEN", "DAL"])],
            "today": [tv_event(4, "Raiders at Broncos", "NFL", 3.2, teams=["LV", "DEN"])],
            "golf": [tv_event(5, "CME Group Tour Championship: Round 4", "Golf", 1)],
            "racing": [tv_event(6, "Qatar Grand Prix \u00b7 Race", "F1", 150)],
            "channels": [groups["sports"], groups["golf"], groups["racing"]]}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    plex_checks = 0
    # One film part-way through, so Home's Continue Watching row has something to show.
    # And an On Demand film part-way through, so its page offers Resume.
    positions = {"matrix": {"t": 3120.0, "duration": 8160.0, "at": 1795300000.0, "where": "iphone"},
                 "od:movie-70000": {"t": 2700.0, "duration": 10320.0, "at": 1795300100.0, "where": "apple-tv"}}
    cast = {"state": "idle", "film": None, "stalls": 0}

    def log_message(self, *a):
        pass

    def _send(self, code, body, ctype="application/json", headers=None):
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)
        with LOG.open("a") as f:
            f.write(f"{code} {self.command} {self.path}\n")

    def _signed_in(self):
        return f"holyarrs_session={TOKEN}" in (self.headers.get("Cookie") or "")

    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        try:
            return json.loads(self.rfile.read(n) or b"{}")
        except ValueError:
            return {}

    def do_GET(self):
        self.route()

    def do_POST(self):
        self.route()

    def do_PUT(self):
        self.route()

    def do_DELETE(self):
        self.route()

    def route(self):
        u = urlparse(self.path)
        path = u.path
        q = {k: v[0] for k, v in parse_qs(u.query).items()}
        # The RTX 4K server.
        if path == "/library":
            return self._send(200, fixture("rtx_library"))
        if path in ("/play", "/stop"):
            return self._send(200, {"session": "s1", "url": "/missing.m3u8", "ready": True})
        if path == "/positions":
            return self._send(200, {"positions": Handler.positions})
        if path == "/position":
            Handler.positions[q.get("id", "")] = {"t": float(q.get("t", 0)), "duration": float(q.get("d", 0)),
                                                  "at": time.time(), "where": q.get("where", "")}
            return self._send(200, Handler.positions[q.get("id", "")])
        if path == "/cast/status":
            return self._send(200, Handler.cast)
        if path == "/cast/devices":
            return self._send(200, {"devices": [{"name": "Patio TV", "model": "Hisense 75M7SG", "type": "cast"}]})
        if path == "/cast/stop":
            Handler.cast = dict(Handler.cast, state="stopped")
            return self._send(200, Handler.cast)
        if path == "/cast":
            Handler.cast = {"ok": True, "film": q.get("id"), "title": "Cast title", "state": "playing", "device": "Patio TV",
                            "position": float(q.get("t", 0)), "startup_s": 7.4, "stalls": 0, "error": None}
            return self._send(200, Handler.cast)
        if path in ("/offline/make", "/offline/status"):
            # Stand-in: the copy is "ready" at once (a few bytes) so the download path can be tried end to end.
            return self._send(200, {"state": "ready", "progress": 1.0, "bytes": 16})
        if path.startswith("/offline/file/"):
            body = b"\x00" * 16
            self.send_response(200)
            self.send_header("Content-Type", "video/mp4")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if path == "/sports":
            return self._send(200, {"files": [{"id": "0123456789ab", "name": F1_FILE, "title": F1_FILE[:-4], "duration_s": 7340.0,
                                               "width": 1920, "height": 1080, "range": "SDR", "upscale": True, "note": ""}]})
        # Live TV on the PC (IPTV through rtx-upscale-stream).
        if path == "/tv/status":
            return self._send(200, {"configured": True, "kind": "xtream", "host": "tv.example", "check": {"state": "ok"}})
        if path == "/tv/sports":
            return self._send(200, tv_sports())
        if path == "/tv/lineup":
            return self._send(200, {"groups": tv_groups(), "epg_at": time.time()})
        if path == "/tv/categories":
            return self._send(200, {"categories": [{"id": "1", "name": "US| SPORTS \u1d34\u1d30/\u1d3f\u1d2c\u1d42", "count": 3},
                                                   {"id": "2", "name": "UK| NEWS", "count": 2}]})
        if path == "/tv/channels":
            qq = q.get("q", "").lower()
            chans = [c for g in tv_groups() for c in g["channels"] if qq in c["name"].lower()]
            return self._send(200, {"channels": [{"id": c["id"], "name": c["name"], "logo": c["logo"]} for c in chans]})
        if path.startswith("/tv/logo/"):
            return self._send(200, png(160, 90, (235, 235, 240)), "image/png")
        if path == "/tv/play":
            return self._send(200, {"ok": True, "session": "tv-0000000000", "url": "/missing.m3u8", "attempts": 1})
        if path == "/tv/stop":
            return self._send(200, {"stopped": True})
        if path == "/tv/teams":
            return self._send(200, {"leagues": {lg: [{**team(lg, t[0]), "aliases": t[4]} for t in ts] for lg, ts in TEAMS.items()}})
        if path.startswith("/tv/teamlogo/"):
            abbr = path.rsplit("/", 1)[-1][:-4].upper()
            t = next((t for ts in TEAMS.values() for t in ts if t[0] == abbr), None)
            rgb = tuple(int(t[3][j:j + 2], 16) for j in (0, 2, 4)) if t else (200, 200, 200)  # its second colour
            return self._send(200, crest(120, rgb), "image/png")
        if path == "/subscriptions":
            return self._send(200, {"warn_days": 14, "warnings": 1, "today": time.strftime("%Y-%m-%d"), "items": [
                {"id": "iptv", "name": "IPTV", "what": "Live TV, live sports and On Demand", "state": "soon", "days_left": 9,
                 "expires": time.strftime("%Y-%m-%d", time.localtime(time.time() + 9 * 86400)), "source": "account check"},
                {"id": "newshosting", "name": "Newshosting", "what": "Usenet downloads (SABnzbd)", "state": "ok", "days_left": 190,
                 "expires": time.strftime("%Y-%m-%d", time.localtime(time.time() + 190 * 86400)), "source": "entered"},
                {"id": "nzbgeek", "name": "NZBgeek", "what": "Usenet search for HolyArrs and Sportarr", "state": "unknown",
                 "days_left": None, "expires": None, "source": None}]})
        if path == "/tv/ondemand":
            return self._send(200, on_demand())
        if path in ("/tv/ondemand/search", "/tv/ondemand/category"):
            items = [i for r in on_demand()["rows"] for i in r["items"]]
            qq = q.get("q", "").lower()
            return self._send(200, {"items": [i for i in items if qq in i["title"].lower()]})
        if path == "/tv/ondemand/categories":
            return self._send(200, {"categories": [{"id": "163", "name": "NEW RELEASE", "count": 6671},
                                                   {"id": "1453", "name": "IMDB TOP 250", "count": 250}]})
        if path == "/tv/ondemand/movie":
            it = next((i for r in on_demand()["rows"] for i in r["items"] if i["id"] == q.get("id")), on_demand()["rows"][0]["items"][0])
            return self._send(200, {**it, "plot": "Odysseus makes the long journey home after the Trojan War.",
                                    "duration_s": 10320, "genre": "Adventure, Drama", "cast": "Matt Damon, Tom Holland",
                                    "backdrop": "https://image.tmdb.org/t/p/w1280/odback.jpg"})
        if path == "/tv/ondemand/series":
            it = next((i for r in on_demand()["rows"] for i in r["items"] if i["id"] == q.get("id")), on_demand()["rows"][1]["items"][0])
            eps = [{"id": str(80000 + n), "episode": n, "title": f"Chapter {n}", "plot": "A remote farmhouse, 1989.",
                    "duration_s": 3480, "still": f"https://image.tmdb.org/t/p/w185/ep{n}.jpg", "ext": "mp4"} for n in range(1, 5)]
            return self._send(200, {**it, "plot": "A family moves to a remote Welsh farmhouse.", "seasons": [
                {"season": 1, "episodes": eps}, {"season": 2, "episodes": eps[:2]}]})
        if path == "/tv/ondemand/play":
            return self._send(200, {"ok": True, "session": "tv-1111111111", "url": "/missing.m3u8", "attempts": 1,
                                    "start_s": float(q.get("t", 0)), "duration_s": 10320})
        if path == "/tv/ondemand/position":
            Handler.positions["od:" + q.get("key", "")] = {"t": float(q.get("t", 0)), "duration": float(q.get("d", 0)),
                                                           "at": time.time(), "where": q.get("where", "")}
            return self._send(200, {})
        # Sportarr: hands its key to its own page while its login is off, then wants it in X-Api-Key.
        if path == "/initialize.json":
            return self._send(200, {"apiKey": SPORTARR_KEY, "version": "4.1.12.1122", "urlBase": ""})
        if path.startswith("/api/") and not path.startswith("/api/v1/"):
            return self.sportarr(path[len("/api/"):], q)
        if not path.startswith("/api/v1/"):
            return self._send(404, {"error": "not found"})
        p = path[len("/api/v1/"):]
        body = self._body() if self.command in ("POST", "PUT") else {}

        if p == "auth/login" and self.command == "POST":
            if body.get("name") == NAME and body.get("password") == PASSWORD:
                return self._send(200, {"name": NAME, "csrf": CSRF},
                                  headers={"Set-Cookie": f"holyarrs_session={TOKEN}; Path=/; HttpOnly; SameSite=Lax"})
            return self._send(401, {"error": "name or password is wrong"})
        if p == "auth/state":
            return self._send(200, {"min_password_length": 8, "needs_setup": False, "safe_mode": False,
                                    "setup_ways": ["password", "plex", "jellyfin"], "ways": ["password", "plex"]})
        if p == "auth/plex/start" and self.command == "POST":
            Handler.plex_checks = 0
            return self._send(200, {"id": 7, "auth_url": "https://app.plex.tv/auth#?clientID=test&code=abcdef&context%5Bdevice%5D%5Bproduct%5D=HolyArrs"},
                              headers={"Set-Cookie": "holyarrs_plex_7=pin-secret; Path=/; HttpOnly; SameSite=Lax"})
        if p == "auth/plex/finish" and self.command == "POST":
            if body.get("id") != 7 or "holyarrs_plex_7=pin-secret" not in (self.headers.get("Cookie") or ""):
                return self._send(404, {"error": "this Plex sign-in has ended; start again"})
            Handler.plex_checks += 1
            if Handler.plex_checks < 2:  # the first check: not approved yet
                return self._send(202, {"waiting": True})
            return self._send(200, {"name": NAME, "csrf": CSRF},
                              headers={"Set-Cookie": f"holyarrs_session={TOKEN}; Path=/; HttpOnly; SameSite=Lax"})
        if p.startswith("artwork/"):
            # A different colour per picture, so a poster grid is visibly made of separate images.
            h = zlib.crc32(p.encode())
            rgb = (60 + h % 160, 40 + (h >> 8) % 120, 30 + (h >> 16) % 90)
            wide = "w780" in p or "w1280" in p
            return self._send(200, png(160 if wide else 100, 90 if wide else 150, rgb), "image/png")
        if not self._signed_in():
            return self._send(401, {"error": "sign in first"})
        if self.command != "GET":
            if self.headers.get("X-CSRF-Token") != CSRF:
                return self._send(403, {"error": "missing or wrong CSRF token"})
            if p == "asks":
                return self._send(201, {"already": False, "joined": False, "ask": {"id": 99, "state": "approved", "state_label": "Approved", "name": "Asked title"}})
            if p.endswith("/follow"):
                return self._send(200, {"following": self.command == "PUT"})
            return self._send(200, {"ok": True})

        if p == "asks/limit":
            return self._send(200, {"qualities": {"movie": [{"id": "standard", "name": "1080p"}, {"id": "4k", "name": "4K"}],
                                                  "show": [{"id": "standard", "name": "1080p"}, {"id": "4k", "name": "4K"}]},
                                    "four_k": {"movie": True, "show": True}})
        if p == "auth/me":
            me = fixture("me")
            me["csrf"] = CSRF
            return self._send(200, me)
        if p.startswith("titles/") and p.endswith("/seasons"):
            return self._send(200, fixture("title_seasons"))
        if p.startswith("titles/") and p.endswith("/episodes"):
            return self._send(200, fixture("title_episodes"))
        if p.startswith("titles/") and p.endswith("/follow"):
            return self._send(200, {"following": False})
        if p.startswith("titles/") and p[len("titles/"):].isdigit():
            t = fixture("title_movie") if p.endswith("/1") else fixture("title_show")
            return self._send(200, t)
        if p.startswith("metadata/movie/"):
            return self._send(200, fixture("metadata_movie"))
        if p.startswith("metadata/show/") and "/seasons/" in p:
            return self._send(200, fixture("metadata_season"))
        if p.startswith("metadata/show/"):
            return self._send(200, fixture("metadata_show"))
        if p.startswith("people/") and p != "people/search":
            return self._send(200, fixture("person"))
        if p.startswith("music/artists/"):
            return self._send(200, fixture("artist"))
        if p.startswith("trailer/"):
            return self._send(404, {"error": "no trailer kept"})
        for prefix in sorted(GETS, key=len, reverse=True):
            if p == prefix:
                data = fixture(GETS[prefix])
                if data is None:
                    break
                if p == "asks" and q.get("state") == "asked":
                    data = dict(data, asks=[a for a in data["asks"] if a["state"] == "asked"])
                if p == "asks" and q.get("mine") == "1":
                    data = dict(data, asks=[a for a in data["asks"] if a.get("mine")])
                return self._send(200, data)
        return self._send(404, {"error": f"no fixture for {p}"})

    def sportarr(self, p, q):
        if self.headers.get("X-Api-Key") != SPORTARR_KEY:
            return self._send(401, {"error": "Unauthorized", "message": "API key required"})
        if self.command in ("POST", "PUT", "DELETE"):
            self._body()
            return self._send(200, {"success": True})
        events = sport_events()
        if p == "system/status":
            return self._send(200, {"appName": "Sportarr", "version": "4.1.12.1122", "isDocker": False})
        if p == "leagues":
            return self._send(200, sport_leagues())
        if p == "calendar":
            return self._send(200, events)
        if p == "queue":
            return self._send(200, [{"id": 1, "eventId": 6, "title": "Formula.1.2026.Round23.Qatar.Qualifying.1080p.WEB.h264",
                                     "event": {"title": "Qatar Grand Prix - Qualifying"}, "status": 1, "quality": "WEB 1080p",
                                     "size": 4_000_000_000, "downloaded": 1_700_000_000, "progress": 42.5}])
        parts = p.split("/")
        if parts[0] == "leagues" and len(parts) >= 2 and parts[1] == "search":
            return self._send(200, [{"idLeague": "lg-000044", "strLeague": "NBA", "strSport": "Basketball",
                                     "strSportFormat": "TeamvsTeam", "strBadge": art("nba", False), "strCountry": "USA"}])
        if parts[0] == "leagues" and len(parts) == 3 and parts[2] == "events":
            lid = int(parts[1])
            return self._send(200, [e for e in events if e["leagueId"] == lid])
        if parts[0] == "leagues" and len(parts) == 3 and parts[2] == "teams":
            return self._send(200, [{"idTeam": f"tm-{i}", "strTeam": n, "strTeamBadge": art(f"team{i}", False)}
                                    for i, n in enumerate(["Dallas Cowboys", "New York Giants", "New York Jets", "Philadelphia Eagles"])])
        if parts[0] == "leagues" and len(parts) == 2:
            lg = next((x for x in sport_leagues() if str(x["id"]) == parts[1]), None)
            return self._send(200, lg) if lg else self._send(404, {"error": "League not found"})
        if parts[0] == "events" and len(parts) == 2:
            e = next((x for x in events if str(x["id"]) == parts[1]), None)
            return self._send(200, e) if e else self._send(404, {"error": "not found"})
        return self._send(404, {"error": f"no Sportarr stand-in for {p}"})


if __name__ == "__main__":
    print(f"mock HolyArrs on :{PORT}, fixtures {HERE}")
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
