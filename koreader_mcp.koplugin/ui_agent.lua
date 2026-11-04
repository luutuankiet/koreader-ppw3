-- Widget-level snapshot and actions for agents (issue #35).
--
-- snapshot: walk the topmost non-toast window and list each actionable or
-- text-bearing widget as {ref, kind, text, state}. References are
-- "<snapshot>_<n>"; only the last 2 snapshots resolve.
-- Actions (tap, hold, tap_text, type, action) run, then the reply waits until
-- the UI manager has no pending work (capped), and carries one result line,
-- a new snapshot and the log lines written since the action started.
-- Also: wait (ui_wait, poll for text), powerButton (suspend or resume) and
-- readLog (read_log, the captured log by sequence-number marker).
--
-- The walk follows the array part of each widget only: that is the tree
-- KOReader propagates gesture events through (WidgetContainer:propagateEvent),
-- so anything a finger can reach is in it.
local M = {}

local KEEP_SNAPSHOTS = 2
local MAX_DEPTH = 60
local TEXT_MAX = 80
-- 1000 lines of a few hundred bytes each: well under 1 MB on a 512 MB Kindle.
local LOG_KEEP = 1000
M.LOG_KEEP = LOG_KEEP

-- ---------------------------------------------------------------- references
-- Pure: no KOReader needed, covered by test_ui_agent.lua.
local Store = {}
Store.__index = Store

function M.newStore()
    return setmetatable({ counter = 0, snaps = {} }, Store)
end

--- Register a list of widgets as a new snapshot; returns its id.
function Store:add(widgets)
    self.counter = self.counter + 1
    self.snaps[self.counter] = widgets
    self.snaps[self.counter - KEEP_SNAPSHOTS] = nil
    return self.counter
end

--- Resolve "<snapshot>_<n>" to a widget, or nil plus an error message.
function Store:resolve(ref)
    local snap, n = tostring(ref or ""):match("^s?(%d+)_(%d+)$")
    if not snap then
        return nil, "bad reference '" .. tostring(ref) .. "', expected <snapshot>_<n> such as 3_7"
    end
    local widgets = self.snaps[tonumber(snap)]
    if not widgets then
        return nil, "stale reference " .. ref .. ", take a new snapshot"
    end
    local w = widgets[tonumber(n)]
    if not w then
        return nil, "no widget " .. n .. " in snapshot " .. snap
    end
    return w
end

M.store = M.newStore()

-- ------------------------------------------------------------- log capture
-- KOReader's logger ends in io.write (frontend/logger.lua), and Logger:setLevel
-- swaps the logger functions, so wrap io.write instead of logger.*.
local log_lines, log_seq = {}, 0

function M.installLogCapture()
    if M._io_write then return end
    local orig = io.write
    M._io_write = orig
    io.write = function(...)
        local ok, s = pcall(table.concat, { ... })
        if ok and s and not s:find("[MCP]", 1, true) then
            for line in s:gmatch("[^\n]+") do
                log_seq = log_seq + 1
                log_lines[log_seq] = line
                log_lines[log_seq - LOG_KEEP] = nil
            end
        end
        return orig(...)
    end
end

function M.logMark() return log_seq end

function M.logsSince(mark, max)
    local out = {}
    for i = math.max(mark + 1, log_seq - LOG_KEEP + 1), log_seq do
        out[#out + 1] = log_lines[i]
    end
    max = max or 30
    if #out > max then
        local cut = #out - max
        local tail = { "[" .. cut .. " earlier lines cut]" }
        for i = cut + 1, #out do tail[#tail + 1] = out[i] end
        out = tail
    end
    return out
end

--- read_log: lines after marker `since` (or the last `max_lines` without one).
-- `marker` is the newest line's sequence number, the `since` for the next call.
-- `truncated` says lines after `since` are missing: they fell out of the ring,
-- or `max_lines` cut the oldest of them.
function M.readLog(params)
    params = params or {}
    local max = math.floor(tonumber(params.max_lines) or 200)
    max = math.max(1, math.min(max, LOG_KEEP))
    local grep = params.grep ~= nil and tostring(params.grep) or nil
    if grep == "" then grep = nil end
    local oldest = math.max(1, log_seq - LOG_KEEP + 1)
    local since = tonumber(params.since)
    local truncated = false
    local first = oldest
    if since then
        since = math.floor(since)
        if since + 1 < oldest then truncated = true end
        first = math.max(oldest, since + 1)
    end
    local out = {}
    for i = first, log_seq do
        local line = log_lines[i]
        if line and (not grep or line:find(grep, 1, true)) then out[#out + 1] = line end
    end
    if #out > max then
        if since then truncated = true end
        local tail = {}
        for i = #out - max + 1, #out do tail[#tail + 1] = out[i] end
        out = tail
    end
    return { marker = log_seq, lines = out, truncated = truncated }
end

-- ------------------------------------------------------------------- walk
local function clip(s)
    if type(s) ~= "string" then return nil end
    s = s:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
    if s == "" then return nil end
    if #s > TEXT_MAX then s = s:sub(1, TEXT_MAX) .. "..." end
    return s
end

local function call(f)
    if type(f) ~= "function" then return nil end
    local ok, v = pcall(f)
    if ok then return v end
end

local function hasTapGesture(w)
    if type(w.ges_events) ~= "table" then return false end
    for name in pairs(w.ges_events) do
        if type(name) == "string" and (name:find("^Tap") or name:find("^Hold")) and not name:find("Close") then
            return true
        end
    end
    return false
end

--- Classify one widget: returns kind, text, state list, or nil if not listed.
-- Exported for tests.
function M.describe(w)
    local state = {}
    if w.item and w.menu and w.onTapSelect then
        -- TouchMenuItem (main menu row)
        local item = w.item
        local text = item.text or call(item.text_func)
        if item.checked or call(item.checked_func) then
            state[#state + 1] = "checked"
        elseif item.checked ~= nil or item.checked_func then
            state[#state + 1] = "unchecked"
        end
        local enabled = item.enabled
        if item.enabled_func then enabled = call(item.enabled_func) end
        if enabled == false then state[#state + 1] = "disabled" end
        if item.sub_item_table or item.sub_item_table_func then state[#state + 1] = "submenu" end
        return "item", clip(text), state
    end
    if w.entry and w.onTapSelect then
        -- MenuItem (list row)
        local e = w.entry
        if e.dim then state[#state + 1] = "dim" end
        local text = clip(w.text or e.text)
        local right = clip(e.mandatory or w.mandatory)
        if right then text = (text or "") .. " | " .. right end
        return "row", text, state
    end
    if w.onTapCheckButton then
        state[#state + 1] = w.checked and "checked" or "unchecked"
        if w.enabled == false then state[#state + 1] = "disabled" end
        return "check", clip(w.text), state
    end
    if w.onTapSelectButton then
        if w.enabled == false then state[#state + 1] = "disabled" end
        return "button", clip(w.text) or clip(w.icon and ("icon:" .. w.icon)), state
    end
    if w.onTapIconButton then
        return "icon", clip(w.icon), state
    end
    if w.addChars and w.charlist then
        if w.focused then state[#state + 1] = "focused" end
        local text = clip(w.text)
        if not text and w.hint then text = clip("hint: " .. tostring(w.hint)) end
        return "input", text, state
    end
    if hasTapGesture(w) and w.dimen and (w.callback or w.text) then
        return "tap", clip(w.text), state
    end
    if type(w.text) == "string" and clip(w.text) then
        return "text", clip(w.text), state
    end
    return nil
end

local function isTappable(kind) return kind ~= "text" end

--- Walk a widget tree; returns a list of {widget, kind, text, state}.
function M.walk(root)
    local out, seen = {}, {}
    local function visit(w, depth)
        if type(w) ~= "table" or seen[w] or depth > MAX_DEPTH then return end
        seen[w] = true
        local kind, text, state = M.describe(w)
        if kind then
            -- An actionable widget stands for its own labels: do not descend.
            if not isTappable(kind) or w.dimen then
                local prev = out[#out]
                if not (kind == "text" and prev and prev.text == text) then
                    out[#out + 1] = { widget = w, kind = kind, text = text, state = state }
                end
            end
            if isTappable(kind) then return end
        end
        for _, child in ipairs(w) do visit(child, depth + 1) end
    end
    visit(root, 0)
    return out
end

-- ------------------------------------------------------------ KOReader glue
local UIManager, Event
local function ui()
    if not UIManager then
        local ok, m = pcall(require, "ui/uimanager")
        if ok then UIManager = m end
        local ok2, e = pcall(require, "ui/event")
        if ok2 then Event = e end
    end
    return UIManager
end

local function topWindow()
    local stack = ui() and UIManager._window_stack
    if not stack then return nil end
    for i = #stack, 1, -1 do
        local w = stack[i].widget
        if not w.toast then return w end
    end
end

--- Take and register a snapshot; returns the JSON-ready table.
-- `top` and `nodes` reuse a walk the caller already made.
function M.snapshot(top, nodes)
    top = top or topWindow()
    if not top then return nil, "no window on screen" end
    nodes = nodes or M.walk(top)
    local widgets, lines = {}, {}
    for i, n in ipairs(nodes) do widgets[i] = n.widget end
    local id = M.store:add(widgets)
    for i, n in ipairs(nodes) do
        lines[i] = { ref = id .. "_" .. i, kind = n.kind, text = n.text or "", state = table.concat(n.state, " ") }
    end
    return {
        snapshot = id,
        -- clip: a dialog's title can hold newlines, and this goes on one line.
        window = clip(tostring(top.name or top.title or (top.covers_fullscreen and "fullscreen") or "window")) or "window",
        total = #lines,
        nodes = lines,
    }
end

-- Tasks of our own (the server poll, the idle check) never count as pending work.
M.own_tasks = setmetatable({}, { __mode = "k" })

function M.isIdle()
    if not ui() then return true end
    local ok_t, time = pcall(require, "ui/time")
    local horizon = ok_t and (time.now() + time.s(0.3)) or nil
    for _, task in ipairs(UIManager._task_queue or {}) do
        if not M.own_tasks[task.action] and (not horizon or task.time <= horizon) then
            return false
        end
    end
    -- Only windows UIManager:_repaint would reach count: it starts at the topmost
    -- covers_fullscreen window and never clears _dirty for anything under it, so
    -- a covered window (the file manager under a list that was just replaced)
    -- stays dirty until it is uncovered.
    local dirty, stack = UIManager._dirty, UIManager._window_stack
    if dirty and next(dirty) and stack then
        local start = 1
        for i = #stack, 1, -1 do
            if stack[i].widget.covers_fullscreen then start = i break end
        end
        for i = start, #stack do
            if dirty[stack[i].widget] then return false end
        end
    end
    if UIManager._refresh_stack and #UIManager._refresh_stack > 0 then return false end
    return true
end

local function centre(w)
    local d = w.dimen
    if not d or not d.w or d.w <= 0 then return nil end
    local p = d:copy()
    p.x = p.x + math.floor(p.w / 2)
    p.y = p.y + math.floor(p.h / 2)
    p.w, p.h = 0, 0
    return p
end

-- A gesture at the centre of the widget's dimen, sent through the UI manager the
-- way FocusManager:_sendGestureEventToFocusedWidget does. No touch injection.
local function gesture(w, ges)
    local pos = centre(w)
    if not pos then return nil, "widget has no size on screen" end
    local ok_t, time = pcall(require, "ui/time")
    local now = ok_t and time.now() or nil
    UIManager:sendEvent(Event:new("Gesture", { ges = ges, pos = pos, time = now }))
    if ges == "hold" then
        UIManager:sendEvent(Event:new("Gesture", { ges = "hold_release", pos = pos, time = now }))
    end
    return string.format("%s at %d,%d", ges, pos.x, pos.y)
end

local function label(n) return n.kind .. ' "' .. (n.text or "") .. '"' end

--- Run one action; returns a result line or nil plus an error.
function M.run(params)
    if not ui() then return nil, "UIManager not available" end
    local what = params.what
    if what == "tap" or what == "hold" then
        local w, err = M.store:resolve(params.ref)
        if not w then return nil, err end
        local kind, text = M.describe(w)
        local res, gerr = gesture(w, what)
        if not res then return nil, gerr end
        return res .. " on " .. params.ref .. " " .. label({ kind = kind, text = text })
    elseif what == "tap_text" then
        local want = tostring(params.text or ""):lower()
        if want == "" then return nil, "missing 'text'" end
        local top = topWindow()
        local nodes = top and M.walk(top) or {}
        local hit
        for pass = 1, 2 do
            for _, n in ipairs(nodes) do
                local t = (n.text or ""):lower()
                if n.widget.dimen and ((pass == 1 and t == want) or (pass == 2 and t:find(want, 1, true))) then
                    hit = n
                    break
                end
            end
            if hit then break end
        end
        if not hit then return nil, "no visible widget with text '" .. params.text .. "'" end
        local res, gerr = gesture(hit.widget, "tap")
        if not res then return nil, gerr end
        return res .. " on " .. label(hit)
    elseif what == "type" then
        local top = topWindow()
        local input
        for _, n in ipairs(top and M.walk(top) or {}) do
            if n.kind == "input" and (not input or n.widget.focused) then input = n.widget end
        end
        if not input then return nil, "no input field in the top window" end
        if params.clear and input.setText then input:setText("") end
        input:addChars(tostring(params.text or ""))
        return "typed " .. #tostring(params.text or "") .. " characters"
    elseif what == "action" then
        local ok_d, Dispatcher = pcall(require, "dispatcher")
        if not ok_d then return nil, "Dispatcher not available" end
        local value = params.value
        if value == nil then value = true end
        local ok, err = pcall(Dispatcher.execute, Dispatcher, { [params.name] = value })
        if not ok then return nil, "action " .. tostring(params.name) .. " failed: " .. tostring(err) end
        return "dispatched " .. tostring(params.name)
    end
    return nil, "unknown action '" .. tostring(what) .. "'"
end

--- Deferred handler: run the action, wait for idle, then reply with the bundle.
-- `done(result, err)` sends the JSON-RPC reply.
function M.act(params, done)
    local mark = M.logMark()
    local started = os.clock()
    local ok, line, err = pcall(M.run, params)
    if not ok then line, err = nil, tostring(line) end
    if not line then
        done(nil, { code = -32602, message = err })
        return
    end
    local cap = math.max(0, math.min(tonumber(params.wait_cap) or 5, 30))
    local t0 = os.time()
    local idle_runs = 0
    local check
    check = function()
        if M.isIdle() then idle_runs = idle_runs + 1 else idle_runs = 0 end
        local waited_out = os.time() - t0 > cap
        if idle_runs >= 2 or waited_out then
            local snap, serr = M.snapshot()
            done({
                result = line .. (waited_out and " (UI still busy after " .. cap .. "s)" or ""),
                snapshot = snap,
                snapshot_error = serr,
                logs = M.logsSince(mark),
                cpu_s = os.clock() - started,
            })
            return
        end
        UIManager:scheduleIn(0.1, check)
    end
    M.own_tasks[check] = true
    UIManager:scheduleIn(0.15, check)
end

-- Seconds as a float; tests replace it.
function M.now()
    local ok, socket = pcall(require, "socket")
    if ok and socket.gettime then return socket.gettime() end
    return os.time()
end

local WAIT_POLL = 0.3

--- True if any node's text contains `want` (case-insensitive), or equals it if exact.
local function hasText(nodes, want, exact)
    local lwant = want:lower()
    for _, n in ipairs(nodes) do
        local t = n.text or ""
        if exact then
            if t == want then return true end
        elseif t:lower():find(lwant, 1, true) then
            return true
        end
    end
    return false
end

--- Deferred handler for ui_wait: poll the top window until `text` shows (or is
-- gone, with `gone`) or `timeout` seconds pass. Never blocks: each poll is a
-- UIManager task, registered in own_tasks so ui_act's idle check ignores it.
function M.wait(params, done)
    local want = tostring(params.text or "")
    if want == "" then
        done(nil, { code = -32602, message = "missing 'text'" })
        return
    end
    if not ui() then
        done(nil, { code = -32603, message = "UIManager not available" })
        return
    end
    local gone = params.gone == true
    local exact = params.exact == true
    local timeout = math.max(0.5, math.min(tonumber(params.timeout) or 10, 60))
    local t0 = M.now()
    local poll
    poll = function()
        M.own_tasks[poll] = nil
        local top = topWindow()
        local nodes = top and M.walk(top) or {}
        local matched = hasText(nodes, want, exact) ~= gone
        local waited = M.now() - t0
        if matched or waited >= timeout then
            local snap, serr = M.snapshot(top, top and nodes or nil)
            done({
                matched = matched,
                waited = math.floor(waited * 10 + 0.5) / 10,
                snapshot = snap,
                snapshot_error = serr,
            })
            return
        end
        M.own_tasks[poll] = true
        UIManager:scheduleIn(math.min(WAIT_POLL, timeout - waited), poll)
    end
    poll()
end

--- Deferred handler for power_button: reply first, act on a later tick. On a
-- Kindle, suspending drops the connection, so a reply sent after would be lost.
function M.powerButton(_, done)
    if not ui() then
        done(nil, { code = -32603, message = "UIManager not available" })
        return
    end
    local ok_d, Device = pcall(require, "device")
    if not ok_d or type(Device) ~= "table" then
        done(nil, { code = -32603, message = "Device not available" })
        return
    end
    local asleep = Device.screen_saver_mode and true or false
    -- Locked: a screensaver delay is waiting for a tap; a press would re-suspend.
    if Device.screen_saver_lock then
        done({ action = "locked", screen_saver_mode = asleep })
        return
    end
    local handlers = UIManager.event_handlers or {}
    local act
    if handlers.PowerRelease then
        -- SDL, Kobo and others: the platform's own press handler.
        act = function() handlers.PowerRelease() end
    elseif asleep then
        -- Kindle has no PowerRelease handler (the framework owns the button).
        act = function() if handlers.Resume then handlers.Resume() end end
    else
        act = function() UIManager:suspend() end
    end
    done({ action = asleep and "resume" or "suspend", screen_saver_mode = asleep })
    M.own_tasks[act] = true
    UIManager:scheduleIn(0.2, act)
end

return M
