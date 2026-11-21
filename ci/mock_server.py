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


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    plex_checks = 0

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
        if path == "/sports":
            return self._send(200, {"files": [{"id": "0123456789ab", "name": F1_FILE, "title": F1_FILE[:-4], "duration_s": 7340.0,
                                               "width": 1920, "height": 1080, "range": "SDR", "upscale": True, "note": ""}]})
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
