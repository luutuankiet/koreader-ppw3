#!/usr/bin/env bash
# Deploy gdrive-epub to Cloud Run from this folder, reading settings from ./.env.
# Idempotent: creates the service account and state bucket and grants their roles if missing,
# then builds from source and deploys. See README.md for the one-time OAuth client steps.
# Usage: ./deploy.sh            (setup + deploy)
#        ./deploy.sh --no-setup (deploy only)
set -euo pipefail
cd "$(dirname "$0")"
[ -f .env ] || { echo "deploy.sh: copy .env.example to .env and fill it in" >&2; exit 2; }
set -a; . ./.env; set +a
: "${GCP_PROJECT:?}" "${GCP_PROJECT_NUMBER:?}" "${REGION:?}" "${SERVICE:?}" "${SERVICE_ACCOUNT:?}"
: "${STATE_BUCKET:?}" "${OWNER_EMAIL:?}" "${GOOGLE_CLIENT_ID:?}" "${CLIENT_SECRET_SECRET:?}" "${CLIENT_SECRET_VERSION:?}"
read -r -a G <<< "${GCLOUD:-gcloud}"
g() { "${G[@]}" "$@" --project="$GCP_PROJECT"; }
SA="$SERVICE_ACCOUNT@$GCP_PROJECT.iam.gserviceaccount.com"
BASE_URL="https://$SERVICE-$GCP_PROJECT_NUMBER.$REGION.run.app"

if [ "${1:-}" != "--no-setup" ]; then
  g services enable run.googleapis.com cloudbuild.googleapis.com artifactregistry.googleapis.com \
    drive.googleapis.com secretmanager.googleapis.com storage.googleapis.com
  g iam service-accounts describe "$SA" >/dev/null 2>&1 \
    || g iam service-accounts create "$SERVICE_ACCOUNT" --display-name="gdrive-epub Cloud Run"
  g storage buckets describe "gs://$STATE_BUCKET" >/dev/null 2>&1 \
    || g storage buckets create "gs://$STATE_BUCKET" --location="$REGION" \
         --uniform-bucket-level-access --public-access-prevention
  g storage buckets add-iam-policy-binding "gs://$STATE_BUCKET" \
    --member="serviceAccount:$SA" --role=roles/storage.objectAdmin >/dev/null
  g secrets add-iam-policy-binding "$CLIENT_SECRET_SECRET" \
    --member="serviceAccount:$SA" --role=roles/secretmanager.secretAccessor >/dev/null
fi

g run deploy "$SERVICE" --source . --region="$REGION" --service-account="$SA" \
  --allow-unauthenticated --min-instances=0 --max-instances=2 --cpu=1 --memory=512Mi \
  --concurrency=20 --timeout=300 \
  --set-env-vars="BASE_URL=$BASE_URL,OWNER_EMAIL=$OWNER_EMAIL,GOOGLE_CLIENT_ID=$GOOGLE_CLIENT_ID,STATE_BUCKET=$STATE_BUCKET" \
  --set-secrets="GOOGLE_CLIENT_SECRET=$CLIENT_SECRET_SECRET:$CLIENT_SECRET_VERSION"

echo "Deployed. Health: $BASE_URL/health"
echo "Add this redirect URI to the OAuth Web client: $BASE_URL/auth/callback"
