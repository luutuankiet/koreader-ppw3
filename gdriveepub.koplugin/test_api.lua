-- Unit tests for gdriveepub_api.lua. Run: luajit test_api.lua
package.path = "./?.lua;" .. package.path
local Api = require("gdriveepub_api")
local pass, fail = 0, 0
local function eq(a, b, what)
    if a == b then pass = pass + 1 else fail = fail + 1
        print("FAIL " .. what .. ": got " .. tostring(a) .. ", want " .. tostring(b)) end
end
-- tiny JSON decoder stand-in: tests feed pre-built tables keyed by body
local bodies = {}
local function decode(s) if bodies[s] then return bodies[s] end error("not json") end

eq(Api.normaliseBaseUrl("  https://example.org/// "), "https://example.org", "trim and strip slashes")
eq(Api.normaliseBaseUrl("http://personal:8791"), "http://personal:8791", "host:port kept")
eq(Api.normaliseBaseUrl("example.org"), nil, "scheme required")
eq(Api.normaliseBaseUrl(""), nil, "empty rejected")
eq(Api.normaliseBaseUrl(nil), nil, "nil rejected")

eq(Api.encode("a b&c/é"), "a%20b%26c%2F%C3%A9", "percent encoding")
eq(Api.query({ view = "search", q = "dbt guide", page_size = 25, empty = "" }),
    "page_size=25&q=dbt%20guide&view=search", "sorted keys, empty dropped")
eq(Api.query({}), "", "empty query")

local b = "https://s.example"
eq(Api.healthRequest(b).url, b .. "/health", "health url")
local ps = Api.pairStartRequest(b)
eq(ps.method, "POST", "pair start is POST"); eq(ps.url, b .. "/pair/start", "pair start url")
eq(Api.pairPollRequest(b, "p 1", "s&x").url, b .. "/pair/p%201/poll?secret=s%26x", "poll url encoded")
local st = Api.statusRequest(b, "k1")
eq(st.headers.Authorization, "Bearer k1", "bearer header")
eq(Api.listRequest(b, "k", { view = "recent" }).url, b .. "/api/files?view=recent", "list url")
local dl = Api.downloadRequest(b, "k", "abc_1-2")
eq(dl.url, b .. "/api/files/abc_1-2/download", "download url"); eq(dl.headers.Accept, "*/*", "download accepts any")

-- parse
eq(Api.parse(nil, decode).error, "network", "nil answer is network")
eq(Api.parse({ err = "timeout" }, decode).message, "timeout", "network message")
bodies.ok = { files = {} }
local p = Api.parse({ status = 200, body = "ok" }, decode)
eq(p.ok, true, "2xx ok"); eq(type(p.data), "table", "2xx data")
eq(Api.parse({ status = 200, body = "<html>" }, decode).error, "bad_answer", "2xx non-json")
bodies.reauth = { error = "google_reauth", signin_url = "https://s.example/reauth" }
p = Api.parse({ status = 401, body = "reauth" }, decode)
eq(p.error, "google_reauth", "error code"); eq(p.signin_url, "https://s.example/reauth", "signin url")
eq(p.message, "HTTP 401", "default message")
eq(Api.parse({ status = 404, body = "" }, decode).error, "not_found", "bare 404")
eq(Api.parse({ status = 500, body = "x" }, decode).error, "server", "bare 500")

-- files
bodies.list = { files = {
    { id = "a", name = "Title A", kind = "pdf", modified_time = "2026-11-15T10:00:00Z", size = "2048" },
    { id = "", name = "no id" }, { name = "missing id" },
    { id = "b", kind = "weird" } }, next_page_token = "" }
local files, token = Api.files(bodies.list)
eq(#files, 2, "rows without id dropped"); eq(files[1].size, 2048, "size string to number")
eq(files[2].name, "Untitled", "missing name"); eq(files[2].kind, "doc", "unknown kind is doc")
eq(token, nil, "empty token is nil")
local _, t2 = Api.files({ files = {}, next_page_token = "T" }); eq(t2, "T", "token kept")
eq(#(Api.files(nil)), 0, "nil data")

-- pairing
bodies.pend = { status = "pending" }; bodies.appr = { status = "approved", device_key = "K" }
bodies.apprnokey = { status = "approved" }
local function poll(status, body) return Api.pairPollResult(Api.parse({ status = status, body = body }, decode)) end
eq(poll(200, "pend"), "pending", "pending")
local r, k = poll(200, "appr"); eq(r, "approved", "approved"); eq(k, "K", "key")
eq(poll(200, "apprnokey"), "error", "approved without key")
eq(poll(404, ""), "expired", "404 expired")
eq(poll(500, ""), "error", "500 error")
bodies.pair = { pair_id = "p", poll_secret = "s", url = "https://s.example/pair/p" }
eq(Api.validPairing(Api.parse({ status = 200, body = "pair" }, decode)), true, "valid pairing")
eq(Api.validPairing(Api.parse({ status = 200, body = "pend" }, decode)), false, "invalid pairing")

print(string.format("test_api: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
