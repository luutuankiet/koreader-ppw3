# gdriveepub-server

Cloud Run service that lists the owner's Google Drive files and serves Google Docs as cleaned EPUBs (PDFs and EPUBs unchanged) to the KOReader Drive plugin. How it works and its HTTP contract: `docs/architecture/gdrive-epub-server.md`. Why it exists: `docs/adr/0007-google-drive-access-through-a-cloud-run-server.md`.

## Develop

```
uv sync
uv run pytest -q
```

Run locally against real Drive data with a short-lived access token instead of a stored refresh token (all `DEV_*` settings are refused on Cloud Run):

```
DEV_ACCESS_TOKEN=<google access token with Drive read access> \
DEV_QUOTA_PROJECT=<project, only for a gcloud user token> \
DEV_DEVICE_KEY=<any string the plugin will send> \
BASE_URL=http://127.0.0.1:8080 OWNER_EMAIL=owner@example.com STATE_FILE=./state.json \
uv run gdriveepub
```

## Deploy from a clean project

1. **OAuth Web client.** In Google Cloud Console, Google Auth Platform, create (or reuse) an OAuth client of type Web application. Enable the Google Drive API. While the app is in Testing mode add the owner as a test user; refresh tokens then last 7 days.
2. **Client secret in Secret Manager.** `printf '%s' '<client secret>' | gcloud secrets create <secret name> --data-file=-` (or reuse an existing secret). Note the version number; the deploy pins it.
3. **Settings.** `cp .env.example .env` and fill in the deploy section: project id and number, region, service name, service account name, a bucket name (must not contain "google"), the owner's email, the client id, the secret name and version. `GCLOUD` can name a wrapper that runs gcloud as the right account. `.env` is gitignored.
4. **Deploy.** `./deploy.sh` enables the APIs, creates the service account and the private state bucket if missing, grants the account `roles/storage.objectAdmin` on the bucket and `roles/secretmanager.secretAccessor` on the secret, then builds from source and deploys with unauthenticated invoke allowed (the app checks its own device keys). `./deploy.sh --no-setup` redeploys only.
5. **Redirect URI.** Add `<BASE_URL>/auth/callback` to the OAuth client's Authorized redirect URIs (Google Auth Platform, Clients, the Web client). `BASE_URL` is `https://<service>-<project number>.<region>.run.app`; `deploy.sh` prints the exact URI. There is no CLI for this step.
6. **Check.** `curl <BASE_URL>/health` answers `{"status":"ok",...}`; `curl <BASE_URL>/api/files` answers 401 `device_unauthorized`. Pair from the Kindle plugin: it shows a QR code, sign in on the phone with the owner account.

## Operate

- Google sign-in expired: the plugin shows the `signin_url`; open `<BASE_URL>/reauth` on the phone. Devices stay paired.
- Revoke a Kindle: remove its entry from `device_keys` in the state object (`gdrive-epub/state.json` in the bucket). Delete the object to reset everything.
- Rotate the client secret: add a secret version, set `CLIENT_SECRET_VERSION`, `./deploy.sh --no-setup`.
