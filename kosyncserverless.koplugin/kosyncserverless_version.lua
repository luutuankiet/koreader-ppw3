--[[--
Which progress wins on a manual pull when the book's file has versions.

A book downloaded from Google Drive carries `gdriveepub_source.modified` in
its sidecar: the Drive modifiedTime of the copy on disk. Progress pushes send
it as `doc_version`. An xpointer saved on an older version may not exist in
the newer one, so progress from an older version is carried as a percentage.
No KOReader requires, so it runs under plain luajit in tests.
]]

local Version = {}

local function daysFromCivil(y, m, d)
    if m <= 2 then y = y - 1 end
    local era = math.floor(y / 400)
    local yoe = y - era * 400
    local mp = (m + 9) % 12
    local doy = math.floor((153 * mp + 2) / 5) + d - 1
    return era * 146097 + yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy - 719468
end

--- "2026-11-20T15:42:16.942Z" -> seconds since the epoch in UTC, or nil.
function Version.toEpoch(s)
    if type(s) ~= "string" then return nil end
    local y, mo, d, h, mi, sec, frac = s:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)(%.?%d*)Z$")
    if not y then return nil end
    local t = daysFromCivil(tonumber(y), tonumber(mo), tonumber(d)) * 86400
        + tonumber(h) * 3600 + tonumber(mi) * 60 + tonumber(sec)
    if frac ~= "" and frac ~= "." then t = t + tonumber("0" .. frac) end
    return t
end

--- This book's version from its sidecar record, or nil.
function Version.fromRecord(rec)
    if type(rec) == "table" and type(rec.modified) == "string" and rec.modified ~= "" then
        return rec.modified
    end
    return nil
end

--[[--
What a manual pull does with the server's progress.
  "pull"          same or newer version, or versions unknown: take it as usual
  "percent"       older version and newer timestamp: go to its percentage
  "keep_local"    older version and this device read later: keep and push ours
]]
function Version.decide(local_version, server_version, server_ts, local_ts)
    local lv, sv = Version.toEpoch(local_version), Version.toEpoch(server_version)
    if not lv or not sv or sv >= lv then return "pull" end
    if (server_ts or 0) > (local_ts or 0) then return "percent" end
    return "keep_local"
end

return Version
