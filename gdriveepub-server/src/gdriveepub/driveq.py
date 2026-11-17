"""Build Drive v3 files.list parameters from the /api/files query."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

MIME = {
    "application/vnd.google-apps.document": "doc",
    "application/pdf": "pdf",
    "application/epub+zip": "epub",
}
WITHIN = {"1d": timedelta(days=1), "1w": timedelta(weeks=1), "1m": timedelta(days=30), "3m": timedelta(days=91)}
ORDER = {"viewed": "viewedByMeTime desc", "modified": "modifiedTime desc", "created": "createdTime desc", "name": "name_natural"}
FIELDS = "nextPageToken,files(id,name,mimeType,modifiedTime,createdTime,viewedByMeTime,size)"
MAX_PAGE = 100


class BadQuery(ValueError):
    def __init__(self, field: str, message: str):
        super().__init__(message)
        self.field = field


def quote_term(value: str) -> str:
    return "'" + value.replace("\\", "\\\\").replace("'", "\\'") + "'"


def _ts(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S")


def build_list_params(args: dict[str, str], now: datetime) -> dict[str, str]:
    view = args.get("view") or "recent"
    if view not in ("recent", "search"):
        raise BadQuery("view", "view must be recent or search")
    clauses = ["trashed = false", "(" + " or ".join(f"mimeType = {quote_term(m)}" for m in MIME) + ")"]
    q = (args.get("q") or "").strip()
    if view == "recent":
        clauses.append("viewedByMeTime > '1970-01-01T00:00:00'")
    if q:
        words = [w for w in q.split() if w]
        for w in words:
            clauses.append(f"(fullText contains {quote_term(w)} or name contains {quote_term(w)})")
    elif view == "search":
        raise BadQuery("q", "search needs q")
    for arg, field in (("modified_within", "modifiedTime"), ("created_within", "createdTime")):
        v = args.get(arg)
        if v:
            if v not in WITHIN:
                raise BadQuery(arg, f"{arg} must be one of " + "|".join(WITHIN))
            clauses.append(f"{field} > '{_ts(now - WITHIN[v])}'")
    sort = args.get("sort") or ("viewed" if view == "recent" else "modified")
    if sort not in ORDER:
        raise BadQuery("sort", "sort must be one of " + "|".join(ORDER))
    try:
        size = int(args.get("page_size") or 25)
    except ValueError:
        raise BadQuery("page_size", "page_size must be a number") from None
    params = {
        "q": " and ".join(clauses),
        "fields": FIELDS,
        "pageSize": str(max(1, min(size, MAX_PAGE))),
        "corpora": "allDrives",
        "includeItemsFromAllDrives": "true",
        "supportsAllDrives": "true",
        "spaces": "drive",
    }
    # Drive rejects orderBy on queries with fullText terms; those come back by relevance
    # and are sorted per page in sort_page().
    if not q:
        params["orderBy"] = ORDER[sort]
    if args.get("page_token"):
        params["pageToken"] = args["page_token"]
    return params


def to_item(f: dict) -> dict:
    kind = MIME.get(f.get("mimeType", ""))
    size = f.get("size")
    return {
        "id": f["id"],
        "name": f.get("name", ""),
        "kind": kind,
        "modified_time": f.get("modifiedTime"),
        "created_time": f.get("createdTime"),
        "viewed_time": f.get("viewedByMeTime"),
        "size": int(size) if size is not None and kind != "doc" else None,
    }


_SORT_KEY = {"viewed": "viewed_time", "modified": "modified_time", "created": "created_time"}


def sort_page(items: list[dict], sort: str) -> list[dict]:
    if sort == "name":
        return sorted(items, key=lambda i: i["name"].casefold())
    key = _SORT_KEY[sort]
    return sorted(items, key=lambda i: i.get(key) or "", reverse=True)
