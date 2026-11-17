"""HTTP routes. The contract is in the repo's docs/architecture/gdrive-epub-server.md."""

from __future__ import annotations

import html
import logging
import time
from datetime import datetime, timezone

from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import HTMLResponse, JSONResponse, RedirectResponse, Response, StreamingResponse
from starlette.routing import Route

from . import __version__, driveq, names, pairing
from .config import Settings, email_hash
from .google import Google, GoogleError, ReauthNeeded, TooLarge, auth_url, id_token_claims
from .store import Store

log = logging.getLogger("gdriveepub")


def err(status: int, code: str, message: str = "", **extra) -> JSONResponse:
    return JSONResponse({"error": code, "message": message or code, **extra}, status_code=status)


def page(title: str, text: str, status: int = 200) -> HTMLResponse:
    body = (f"<!doctype html><meta name=viewport content='width=device-width'><title>{html.escape(title)}</title>"
            f"<body style='font-family:sans-serif;max-width:30em;margin:3em auto;padding:0 1em'>"
            f"<h2>{html.escape(title)}</h2><p>{html.escape(text)}</p></body>")
    return HTMLResponse(body, status_code=status)


def create_app(settings: Settings, store: Store, google: Google | None = None, now=time.time) -> Starlette:
    g = google or Google(settings.client_id, settings.client_secret, quota_project=settings.dev_quota_project)
    skey = pairing.state_key(settings.client_secret or settings.dev_access_token)
    signin_url = settings.base_url + "/reauth"

    def reauth_401() -> JSONResponse:
        return err(401, "google_reauth", "Google sign-in expired; sign in again on your phone", signin_url=signin_url)

    async def token() -> str:
        if settings.dev_access_token:
            return settings.dev_access_token
        return await g.access_token(store.read().get("google", {}).get("refresh_token"))

    def device_ok(request: Request) -> bool:
        auth = request.headers.get("authorization", "")
        key = auth[7:].strip() if auth.lower().startswith("bearer ") else ""
        if settings.dev_device_key and key == settings.dev_device_key:
            return True
        return pairing.device_ok(store.read(), key)

    def api(fn):
        async def wrapped(request: Request):
            if not device_ok(request):
                return err(401, "device_unauthorized", "Missing or unknown device key")
            try:
                return await fn(request)
            except ReauthNeeded:
                return reauth_401()
            except driveq.BadQuery as e:
                return err(400, "bad_request", str(e), field=e.field)
            except GoogleError as e:
                log.warning("google error: %s", e)
                if e.status == 404:
                    return err(404, "not_found", "No such file")
                return err(502, "google_error", f"Google returned {e.status}")
        return wrapped

    async def health(request):
        return JSONResponse({"status": "ok", "version": __version__})

    async def pair_start(request):
        def fn(state):
            return pairing.start(state, now())
        pair_id, secret = store.update(fn)
        return JSONResponse({"pair_id": pair_id, "poll_secret": secret,
                             "url": f"{settings.base_url}/pair/{pair_id}", "expires_in": pairing.PAIR_TTL})

    async def pair_page(request):
        pair_id = request.path_params["pair_id"]
        if not pairing.pending(store.read(), pair_id, now()):
            return page("Pairing expired", "Start pairing again on the Kindle and scan the new code.", 404)
        state = pairing.sign_state(skey, "pair:" + pair_id, now())
        return RedirectResponse(auth_url(settings.client_id, settings.redirect_uri, state), 302)

    async def reauth(request):
        state = pairing.sign_state(skey, "reauth", now())
        return RedirectResponse(auth_url(settings.client_id, settings.redirect_uri, state), 302)

    async def callback(request):
        q = request.query_params
        purpose = pairing.verify_state(skey, q.get("state", ""), now())
        if not purpose:
            return page("Sign-in link expired", "Scan the code on the Kindle again.", 400)
        if q.get("error") or not q.get("code"):
            return page("Sign-in cancelled", q.get("error", "No code from Google."), 400)
        try:
            tokens = await g.exchange_code(q["code"], settings.redirect_uri)
        except GoogleError as e:
            log.warning("code exchange failed: %s", e)
            return page("Sign-in failed", "Google refused the sign-in code. Try again.", 502)
        claims = id_token_claims(tokens.get("id_token", "x.e30.x"))
        email = (claims.get("email") or "").lower()
        if claims.get("aud") != settings.client_id or not claims.get("email_verified") or not settings.is_owner(email):
            log.warning("rejected sign-in for a non-owner account")
            return page("Wrong account", "This server only accepts the Google accounts its owner allowed.", 403)
        refresh = tokens.get("refresh_token")

        def fn(state):
            if refresh:
                state["google"] = {"refresh_token": refresh, "email_sha256": email_hash(email), "updated_at": now()}
            if purpose.startswith("pair:"):
                return pairing.approve(state, purpose[5:], now())
            return True
        if not refresh and not store.read().get("google"):
            return page("Sign-in incomplete", "Google sent no refresh token. Try again.", 502)
        ok = store.update(fn)
        if purpose.startswith("pair:") and not ok:
            return page("Pairing expired", "Google sign-in worked, but the pairing timed out. Start pairing again.", 410)
        if purpose.startswith("pair:"):
            return page("Kindle paired", "Kindle paired, you can close this.")
        return page("Signed in again", "Google sign-in renewed, you can close this.")

    async def pair_poll(request):
        pair_id = request.path_params["pair_id"]
        secret = request.query_params.get("secret", "")
        result = store.update(lambda state: pairing.poll(state, pair_id, secret, now()))
        if result is None:
            return err(404, "pairing_expired", "Unknown or expired pairing")
        if result["status"] == "forbidden":
            return err(403, "bad_secret", "Wrong poll secret")
        return JSONResponse(result)

    async def status(request):
        if not device_ok(request):
            return err(401, "device_unauthorized", "Missing or unknown device key")
        try:
            await token()
            return JSONResponse({"google": "ok"})
        except ReauthNeeded:
            return JSONResponse({"google": "reauth_needed", "signin_url": signin_url})

    @api
    async def files(request):
        args = dict(request.query_params)
        params = driveq.build_list_params(args, datetime.now(timezone.utc))
        data = await g.list_files(await token(), params)
        items = [driveq.to_item(f) for f in data.get("files", []) if f.get("mimeType") in driveq.MIME]
        if "orderBy" not in params:
            view = args.get("view") or "recent"
            items = driveq.sort_page(items, args.get("sort") or ("viewed" if view == "recent" else "modified"))
        return JSONResponse({"files": items, "next_page_token": data.get("nextPageToken")})

    @api
    async def download(request):
        fid = request.path_params["file_id"]
        tok = await token()
        meta = await g.get_meta(tok, fid)
        kind = driveq.MIME.get(meta.get("mimeType", ""))
        if not kind or meta.get("trashed"):
            return err(415, "unsupported", "Only Google Docs, PDFs and EPUBs")
        fname = names.sanitise(meta.get("name", ""), kind)
        headers = {"Content-Disposition": names.content_disposition(fname),
                   "X-File-Name": names.header_value(fname), "X-Modified-Time": meta.get("modifiedTime", "")}
        ctype = "application/pdf" if kind == "pdf" else "application/epub+zip"
        if kind == "doc":
            try:
                raw = await g.export_epub(tok, fid)
            except TooLarge:
                return err(413, "too_large", "Google cannot export documents over 10 MB")
            from .epubclean import clean_epub
            try:
                body, stats = clean_epub(raw)
                log.info("cleaned %s: %s", fid, stats)
            except Exception:  # never fail a download because cleanup choked
                log.exception("cleanup failed for %s; serving Google's export", fid)
                body = raw
            return Response(body, media_type=ctype, headers=headers)
        upstream = await g.open_media(tok, fid)
        if upstream.headers.get("content-length"):
            headers["Content-Length"] = upstream.headers["content-length"]

        async def stream():
            try:
                async for chunk in upstream.aiter_bytes(65536):
                    yield chunk
            finally:
                await upstream.aclose()
        return StreamingResponse(stream(), media_type=ctype, headers=headers)

    return Starlette(routes=[
        Route("/health", health),
        Route("/pair/start", pair_start, methods=["POST"]),
        Route("/pair/{pair_id}", pair_page),
        Route("/pair/{pair_id}/poll", pair_poll),
        Route("/auth/callback", callback),
        Route("/reauth", reauth),
        Route("/api/status", status),
        Route("/api/files", files),
        Route("/api/files/{file_id}/download", download),
    ])
