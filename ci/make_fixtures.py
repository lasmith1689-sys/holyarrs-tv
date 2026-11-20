"""Writes ci/fixtures/*.json: stand-in HolyArrs answers shaped like HolyArrs 1.2.0's (field names from its
OpenAPI file, Go handlers and web app types). Replace any of them with a real answer captured from the PC
(ci/capture_fixtures.ps1) to test against the real shape."""
import json
from pathlib import Path

OUT = Path(__file__).resolve().parent / "fixtures"
OUT.mkdir(exist_ok=True)
T = "https://image.tmdb.org/t/p/w500/{}.jpg"
B = "https://image.tmdb.org/t/p/w1280/{}.jpg"

MOVIES = [("603", "The Matrix", 1999), ("27205", "Inception", 2010), ("157336", "Interstellar", 2014),
          ("438631", "Dune", 2021), ("693134", "Dune: Part Two", 2024), ("155", "The Dark Knight", 2008),
          ("680", "Pulp Fiction", 1994), ("13", "Forrest Gump", 1994), ("550", "Fight Club", 1999),
          ("120", "The Lord of the Rings: The Fellowship of the Ring", 2001), ("78", "Blade Runner", 1982),
          ("335984", "Blade Runner 2049", 2017)]
SHOWS = [("1396", "Breaking Bad", 2008), ("100088", "The Last of Us", 2023), ("94997", "House of the Dragon", 2022),
         ("1399", "Game of Thrones", 2011), ("66732", "Stranger Things", 2016), ("95396", "Severance", 2022)]


def item(kind, tmdb, name, year, in_lib=False, ask=None, title_id=None):
    d = {"tmdb_id": tmdb, "kind": kind, "name": name, "year": year, "poster": T.format("p" + tmdb),
         "backdrop": B.format("b" + tmdb), "overview": f"{name} ({year}): a stand-in summary for the screen check.",
         "genres": ["Science Fiction", "Drama"], "in_library": in_lib}
    if title_id:
        d["title_id"] = title_id
    if ask:
        d["ask"] = ask
    return d


def w(name, data):
    (OUT / f"{name}.json").write_text(json.dumps(data, indent=1))


movies = [item("movie", *m, in_lib=i < 3, title_id=1 if i == 0 else (10 + i if i < 3 else None),
               ask={"id": 5, "state": "asked", "state_label": "Waiting for an OK", "mine": True, "people": 1} if i == 4 else None)
          for i, m in enumerate(MOVIES)]
shows = [item("show", *s, in_lib=i == 0, title_id=2 if i == 0 else None) for i, s in enumerate(SHOWS)]

w("me", {"id": 1, "name": "luke", "role": "owner", "perms": ["ask", "approve", "manage_library", "settings", "users"],
         "two_factor": False, "views": {}})
w("home", {"rows": ["arrived", "approval", "asks", "new_season", "following", "soon", "discover"], "owner": True, "kid": False,
           "arrived": [{"key": "m1", "kind": "movie", "title_id": 1, "name": "The Matrix", "year": 1999, "line": "Added today",
                        "href": "/title/1", "backdrop": B.format("b603"), "poster": T.format("p603")},
                       {"key": "s2", "kind": "show", "title_id": 2, "name": "Breaking Bad", "year": 2008, "line": "S5 · 3 new episodes",
                        "href": "/title/2", "backdrop": B.format("b1396"), "poster": T.format("p1396"), "season": 5}],
           "new_seasons": [], "following": [{"key": "f2", "kind": "show", "title_id": 2, "name": "Breaking Bad", "year": 2008,
                                              "href": "/title/2", "poster": T.format("p1396")}],
           "soon": [{"key": "c9", "kind": "movie", "title_id": 12, "name": "Interstellar", "year": 2014, "line": "Digital on Friday",
                     "href": "/title/12", "backdrop": B.format("b157336"), "poster": T.format("p157336")}],
           "missing_count": 0, "ask_progress": {}})
w("explore_head", {"type": "all", "building": False, "seeds": 3, "tail_cap": 8, "tail_rows": 4,
                   "hero": [movies[3], movies[4], shows[1]], "taste": ["Science Fiction"],
                   "head": [{"id": "trending", "type": "trending", "title": "Trending now", "items": movies[3:] + shows[1:]},
                            {"id": "because", "type": "because", "title": "Because you have The Matrix", "subtitle": "Science fiction with a twist", "items": movies[5:]},
                            {"id": "shows", "type": "shows", "title": "Popular shows", "items": shows}]})
w("explore_tail", {"page": 0, "more": False, "rows": [{"id": "classics", "type": "classics", "title": "Top-rated classics", "items": movies[6:10]}]})
w("genre_row", {"type": "all", "genres": [{"kind": "movie", "id": 878, "name": "Science Fiction", "backdrop": B.format("b78"), "from": "Blade Runner", "both": True},
                                          {"kind": "movie", "id": 18, "name": "Drama", "backdrop": B.format("b13"), "from": "Forrest Gump"},
                                          {"kind": "show", "id": 10765, "name": "Sci-Fi & Fantasy", "backdrop": B.format("b1399"), "from": "Game of Thrones"}]})
w("genre", {"type": "all", "genre": {"id": 878, "name": "Science Fiction", "kind": "movie"}, "hero": [movies[10], movies[11]],
            "rows": [{"id": "genre_trending", "type": "trending", "title": "Trending science fiction", "items": movies[:8]}], "partial": False})
w("explore_music", {"v2": True, "kid": False, "cold": False, "genres": [], "genre": "",
                    "hero": {"key": "h", "kind": "album", "mbid": "a1", "name": "Random Access Memories", "artist": "Daft Punk", "artist_mbid": "056e4f3e-d505-4dad-8ec1-d04f521cbb56", "image": T.format("ram"), "genres": ["electronic"]},
                    "rows": [{"id": "top_albums", "type": "top_albums", "title": "Top albums", "reason": "", "shape": "square",
                              "items": [{"key": f"al{i}", "kind": "album", "mbid": f"al{i}", "name": f"Album {i}", "artist": "Daft Punk",
                                         "artist_mbid": "056e4f3e-d505-4dad-8ec1-d04f521cbb56", "image": T.format(f"al{i}"), "genres": []} for i in range(8)]}],
                    "next": ""})
w("suggest", {"q": "dune", "completions": ["dune part two"], "items": [
    {"kind": "movie", "name": "Dune", "sub": "2021", "art": T.format("p438631"), "tmdb": "438631"},
    {"kind": "movie", "name": "Dune: Part Two", "sub": "2024", "art": T.format("p693134"), "tmdb": "693134", "state": "asked"},
    {"kind": "person", "name": "Denis Villeneuve", "sub": "Director", "art": T.format("dv"), "person_id": "137427"},
    {"kind": "artist", "name": "Hans Zimmer", "sub": "Artist", "art": T.format("hz"), "mbid": "e6de1f3b-6484-491c-88dd-6d619f142abc"}]})
w("search_plain", {"query": {"text": "space movies from 2014", "plain": False, "name": "", "kind": "movie", "year_from": 2014, "year_to": 2014,
                             "genres": ["Science Fiction"], "people": [], "words": ["space"]},
                   "titles": [], "more": [movies[2]]})
asks = [{"id": 5, "kind": "movie", "tmdb_id": "693134", "name": "Dune: Part Two", "year": 2024, "poster": T.format("p693134"), "state": "asked",
         "state_label": "Waiting for an OK", "asked_by": {"id": 2, "name": "anya"}, "asked_at": "2026-11-19T20:01:00Z",
         "people": [{"id": 2, "name": "anya", "asked_at": "2026-11-19T20:01:00Z"}], "auto_approved": False, "mine": False},
        {"id": 6, "kind": "show", "tmdb_id": "100088", "name": "The Last of Us", "year": 2023, "poster": T.format("p100088"), "state": "approved",
         "state_label": "Downloading", "season_words": "Seasons 1 and 2", "asked_by": {"id": 1, "name": "luke"}, "asked_at": "2026-11-18T12:00:00Z",
         "people": [{"id": 1, "name": "luke", "asked_at": "2026-11-18T12:00:00Z"}], "auto_approved": True, "mine": True},
        {"id": 7, "kind": "movie", "tmdb_id": "78", "name": "Blade Runner", "year": 1982, "poster": T.format("p78"), "state": "asked",
         "state_label": "Waiting for an OK", "asked_by": {"id": 1, "name": "luke"}, "asked_at": "2026-11-20T09:00:00Z",
         "people": [{"id": 1, "name": "luke", "asked_at": "2026-11-20T09:00:00Z"}], "auto_approved": False, "mine": True}]
w("asks", {"asks": asks, "counts": {"pending": 2, "processing": 1, "done": 0, "failed": 0}, "total": 3})
w("needs_decision", {"count": 1, "items": [{"kind": "movie", "title": "Fight Club", "year": 1999, "title_id": 20, "slot_id": 31, "version": "Main",
                                           "reason": "Every release found was smaller than your pick rules allow.", "since": "2026-11-19T10:00:00Z",
                                           "release_name": "Fight.Club.1999.720p.WEB", "has_copy": False}]})
w("downloads", {"downloads": [
    {"id": 41, "state": "downloading", "label": "Downloading", "text": "12 seeds", "progress": 0.42, "speed": 18_400_000, "eta": 1260, "active": True,
     "phase": "downloading", "name": "The.Last.of.Us.S02.2160p", "title_id": 3, "title": "The Last of Us", "year": 2023, "version": "Main",
     "downloader": "qBittorrent", "size": 41_000_000_000, "updated_at": "2026-11-20T21:30:00Z", "can_act": True, "kind": "show",
     "episodes": [{"label": "S2"}]},
    {"id": 42, "state": "paused", "label": "Paused", "progress": 0.88, "speed": 0, "active": False, "phase": "paused", "name": "Inception.2010.2160p",
     "title_id": 11, "title": "Inception", "year": 2010, "version": "Main", "downloader": "SABnzbd", "size": 62_000_000_000,
     "updated_at": "2026-11-20T21:00:00Z", "can_act": True, "kind": "movie"}]})
w("calendar", {"from": "2026-11-20", "to": "2026-12-20", "dates": [
    {"kind": "episode", "title_id": 2, "name": "Breaking Bad", "season": 6, "episode": 1, "episode_name": "Pilot (again)", "date": "2026-11-21T02:00:00Z",
     "timed": True, "air_day": "2026-11-20", "poster": T.format("p1396"), "state": "missing", "item_id": 501},
    {"kind": "digital", "title_id": 12, "name": "Interstellar", "year": 2014, "date": "2026-11-27", "air_day": "2026-11-27", "poster": T.format("p157336"), "item_id": 12}]})
lookup_movie = {"movies": [{"name": "The Matrix", "year": 1999, "ids": {"tmdb": "603", "imdb": "tt0133093"}, "poster": T.format("p603"), "title_id": 1,
                            "never_add": False, "hidden": False}]}
w("titles_lookup", lookup_movie)
w("shows_lookup", {"shows": [{"name": "Breaking Bad", "year": 2008, "ids": {"tmdb": "1396"}, "poster": T.format("p1396"), "title_id": 2, "never_add": False}]})
w("people_search", {"people": [{"id": "6384", "name": "Keanu Reeves", "profile": T.format("kr")}], "page": 1, "total_pages": 1})
w("title_movie", {"id": 1, "kind": "movie", "name": "The Matrix", "year": 1999, "overview": "A hacker learns the world is a simulation and joins the fight against its makers.",
                  "ids": {"tmdb": "603", "imdb": "tt0133093"}, "keep_up_to_date": True, "why_added": "ask", "release_gate": "any", "gate_delay_days": 0,
                  "stage": "done", "gate_open": True, "gate_reason": "", "artwork": [T.format("p603")], "backdrop": B.format("b603"),
                  "genres": ["Action", "Science Fiction"], "runtime_minutes": 136, "rating": "R", "versions": [{"id": 1, "name": "Main"}],
                  "slots": [{"id": 1, "version": "Main", "version_id": 1, "state": "in_library", "state_label": "In library",
                             "file": {"Quality": {"resolution": 1080}}}]})
w("title_show", {"id": 2, "kind": "show", "name": "Breaking Bad", "year": 2008, "overview": "A chemistry teacher turns to making drugs.",
                 "ids": {"tmdb": "1396"}, "keep_up_to_date": True, "why_added": "ask", "release_gate": "any", "gate_delay_days": 0, "stage": "done",
                 "gate_open": True, "gate_reason": "", "artwork": [T.format("p1396")], "backdrop": B.format("b1396"), "genres": ["Drama", "Crime"],
                 "versions": [], "slots": [{"state": "partial", "state_label": "4 of 5 seasons"}]})
w("title_seasons", {"seasons": [{"number": n, "name": f"Season {n}", "episodes": 13, "aired": 13, "in_library": 13 if n < 5 else 8,
                                 "missing": 0 if n < 5 else 5, "not_out_yet": 0, "keep_up_to_date": True} for n in range(1, 6)]})
w("title_episodes", {"episode_order": "aired", "episodes": [{"id": i, "season": 5, "episode": i, "name": f"Episode {i}", "air_day": "2013-08-11",
                                                             "runtime": 47, "slots": [{"state_label": "In library" if i < 9 else "Missing"}]} for i in range(1, 14)]})
cast = [{"name": n, "role": "actor", "character": c, "profile": T.format("c" + str(i)), "id": str(6384 + i)}
        for i, (n, c) in enumerate([("Keanu Reeves", "Neo"), ("Carrie-Anne Moss", "Trinity"), ("Laurence Fishburne", "Morpheus"), ("Hugo Weaving", "Agent Smith")])]
w("metadata_movie", {"tmdb_id": "603", "kind": "movie", "name": "The Matrix", "year": 1999, "overview": "A hacker learns the world is a simulation.",
                     "poster": T.format("p603"), "backdrop": B.format("b603"), "genres": ["Action", "Science Fiction"], "runtime_minutes": 136,
                     "rating": "R", "people": cast, "moods": ["mind-bending"], "similar": [m for m in movies[5:11]],
                     "collection": {"name": "The Matrix Collection", "parts": [item("movie", "603", "The Matrix", 1999), item("movie", "604", "The Matrix Reloaded", 2003)]},
                     "title_id": 1})
w("metadata_show", {"tmdb_id": "1396", "kind": "show", "name": "Breaking Bad", "year": 2008, "overview": "A chemistry teacher turns to making drugs.",
                    "poster": T.format("p1396"), "backdrop": B.format("b1396"), "genres": ["Drama"], "network": "AMC", "people": cast[:2],
                    "seasons": [{"number": n, "episode_count": 13, "year": 2007 + n} for n in range(1, 6)], "similar": shows[1:], "title_id": 2})
w("metadata_season", {"tmdb_id": "1396", "season": 1, "episodes": [{"number": i, "name": f"Episode {i}", "overview": "A stand-in episode.", "runtime": 47, "air_day": "2008-01-20"} for i in range(1, 8)]})
w("person", {"person": {"id": "6384", "name": "Keanu Reeves", "department": "Acting", "biography": "Canadian actor.", "birthday": "1964-09-02",
                        "birthplace": "Beirut, Lebanon", "profile": T.format("kr"), "known_for": []},
             "movies": [dict(m, characters=["Neo"]) for m in movies[:6]], "page": 1, "page_size": 100, "total_pages": 1, "total_results": 6,
             "library": [dict(movies[0], characters=["Neo"])], "asked": [], "known_for": movies[:4], "coming_soon": [], "stats": {}})
w("artist", {"mbid": "056e4f3e-d505-4dad-8ec1-d04f521cbb56", "name": "Daft Punk", "type": "Group", "country": "FR", "genres": ["electronic", "house"],
             "image": T.format("dp"), "have": 0, "total": 4, "bio": {"title": "Daft Punk", "extract": "Daft Punk were a French electronic music duo."},
             "albums": [{"mbid": f"al{i}", "name": n, "type": "Album", "shelf": "albums", "image": T.format(f"al{i}"), "release_date": f"{y}-01-01"}
                        for i, (n, y) in enumerate([("Homework", 1997), ("Discovery", 2001), ("Human After All", 2005), ("Random Access Memories", 2013)])],
             "top": [], "similar": [{"mbid": "j1", "name": "Justice", "image": T.format("j1")}], "related": [], "kid": False, "missing": {"count": 0}})
w("rtx_library", {"films": [{"id": "matrix", "title": "The Matrix", "year": 1999, "sort": "matrix", "duration_s": 8160, "width": 1920, "height": 800,
                             "upscale": True, "cleanup": False, "range": "SDR"}],
                  "status": {"scanned": True, "probed": 1, "posters": 1, "films": 1}})
print("wrote", len(list(OUT.glob("*.json"))), "fixtures")
