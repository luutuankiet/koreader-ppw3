local DataStorage = require("datastorage")
local Persist = require("persist")
local logger = require("logger")

local QUEUE_PATH = DataStorage:getSettingsDir() .. "/kosyncserverless_queue.lua"
local MAX_AGE = 28 * 24 * 3600 -- 4 weeks in seconds
local MAX_ENTRIES = 200 -- paranoia cap

local KOSyncServerlessQueue = {
    path = QUEUE_PATH, -- tests point this at a temporary file
}

function KOSyncServerlessQueue:_storage()
    if not self._persist or self._persist.path ~= self.path then
        self._persist = Persist:new{ path = self.path, codec = "dump" }
    end
    return self._persist
end

function KOSyncServerlessQueue:load()
    local storage = self:_storage()
    if not storage:exists() then return {} end
    local data, err = storage:load()
    if not data then
        logger.warn("KOSyncServerlessQueue: failed to load queue:", err)
        return {}
    end
    return data
end

function KOSyncServerlessQueue:save(queue)
    local ok, err = self:_storage():save(queue)
    if not ok then
        logger.warn("KOSyncServerlessQueue: failed to save queue:", err)
    end
end

--- Queue a failed progress update for later retry.
-- Keeps one entry per document per day (for statistics granularity).
-- Expires entries older than 4 weeks.
function KOSyncServerlessQueue:push(item)
    local queue = self:load()
    local now = os.time()
    item.queued_at = now

    local today = math.floor(now / 86400)

    -- Filter: expire old entries, deduplicate same document+same day
    local filtered = {}
    for _, entry in ipairs(queue) do
        local dominated = entry.document == item.document
            and math.floor((entry.queued_at or 0) / 86400) == today
        if (now - (entry.queued_at or 0)) < MAX_AGE and not dominated then
            table.insert(filtered, entry)
        end
    end

    table.insert(filtered, item)

    -- Paranoia cap: drop oldest
    while #filtered > MAX_ENTRIES do
        table.remove(filtered, 1)
    end

    self:save(filtered)
    logger.dbg("KOSyncServerlessQueue: queued progress for", item.document, "total:", #filtered)
end

-- Removes one entry, matched by document and queued_at, re-reading the file
-- so entries queued while a send was in flight are kept.
function KOSyncServerlessQueue:remove(item)
    local queue = self:load()
    for i, entry in ipairs(queue) do
        if entry.document == item.document and entry.queued_at == item.queued_at then
            table.remove(queue, i)
            self:save(queue)
            return true
        end
    end
    return false
end

--- Send queued items one at a time, oldest first. An entry leaves the queue
-- only after send reports a confirmed success; the first failure stops the
-- drain and keeps that entry and every later one.
-- @param send function(item, cb): sends one item, then calls cb(ok) once
-- @param done optional function(sent, remaining)
-- @treturn bool false when a drain is already running (done is not called)
function KOSyncServerlessQueue:drainAsync(send, done)
    if self._draining then return false end
    local pending = self:load()
    if #pending == 0 then
        if done then done(0, 0) end
        return true
    end
    self._draining = true
    logger.info("KOSyncServerlessQueue: draining", #pending, "queued items")
    local sent = 0
    local i = 0
    local next_item
    next_item = function()
        i = i + 1
        local item = pending[i]
        if not item then
            self._draining = nil
            logger.info("KOSyncServerlessQueue: sent all", sent, "items")
            if done then done(sent, self:count()) end
            return
        end
        send(item, function(ok)
            if ok then
                self:remove(item)
                sent = sent + 1
                next_item()
            else
                self._draining = nil
                local remaining = self:count()
                logger.info("KOSyncServerlessQueue: sent", sent, ", remaining", remaining)
                if done then done(sent, remaining) end
            end
        end)
    end
    next_item()
    return true
end

function KOSyncServerlessQueue:count()
    return #self:load()
end

function KOSyncServerlessQueue:clear()
    self:save({})
end

return KOSyncServerlessQueue
