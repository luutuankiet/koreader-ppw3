# Source me: exports Cloudflare OAuth token + account id and the gateway keys, printing nothing.
# Values are read at runtime from ~/.config/cloudflare and the repo .env; none are stored here.
cf auth whoami >/dev/null 2>&1
export CLOUDFLARE_API_TOKEN="$(python3 -c "import json;print(json.load(open('$HOME/.config/cloudflare/config/default.json'))['oauth_token'])")"
_get() { grep "^$1=" $HOME/dev/koreader-ppw3/.env | head -1 | cut -d= -f2- | sed -e 's/^"//' -e 's/"$//'; }
export CLOUDFLARE_ACCOUNT_ID="$(_get CF_ACCOUNT_ID)"
export CF_ZONE_ID="$(_get CF_ZONE_ID)"
export AGENT_KEY="$(_get KINDLE_GW_AGENT_KEY)"
export DEVICE_KEY="$(_get KINDLE_GW_DEVICE_KEY)"
