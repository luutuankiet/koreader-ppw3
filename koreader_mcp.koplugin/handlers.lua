local handlers = {}

-- Try to load KOReader Device module for real device info
local Device = nil
pcall(function() Device = require("device") end)

-- Try to load UIManager for L3 Lua API (widget introspection + menu navigation)
local UIManager = nil
pcall(function() UIManager = require("ui/uimanager") end)

local Event = nil
pcall(function() Event = require("ui/event") end)

function handlers.read_files(params)
    if not params or not params.files then
        return nil, {code = -32602, message = "Missing 'files' parameter"}
    end
    local results = {}
    for _, file_spec in ipairs(params.files) do
        local path = file_spec.path
        local head = file_spec.head
        local f, err = io.open(path, "r")
        if not f then
            table.insert(results, {path = path, error = "Cannot open file: " .. tostring(err)})
        else
            if head then
                local lines = {}
                local count = 0
                for line in f:lines() do
                    count = count + 1
                    if count > head then break end
                    table.insert(lines, line)
                end
                table.insert(results, {path = path, content = table.concat(lines, "\n")})
            else
                local content = f:read("*a")
                table.insert(results, {path = path, content = content})
            end
            f:close()
        end
    end
    return results
end

function handlers.run_command(params)
    if not params or not params.command then
        return nil, {code = -32602, message = "Missing 'command' parameter"}
    end
    local cmd = params.command
    -- Append exit code capture
    local full_cmd = cmd .. " 2>&1; echo \"\n__EXIT_CODE__:$?\""
    local handle = io.popen(full_cmd)
    if not handle then
        return nil, {code = -32603, message = "Failed to execute command"}
    end
    local output = handle:read("*a")
    handle:close()
    -- Parse exit code from output
    local exit_code = 0
    local stdout = output
    local code_match = output:match("__EXIT_CODE__:(%d+)%s*$")
    if code_match then
        exit_code = tonumber(code_match)
        stdout = output:gsub("\n?__EXIT_CODE__:%d+%s*$", "")
    end
    return {stdout = stdout, exit_code = exit_code}
end

function handlers.device_status(params)
    if Device then
        -- Running inside KOReader
        local status = {
            model = Device.model or "unknown",
            has_wifi = Device:hasWifiToggle() or false,
            screen_width = Device.screen:getWidth(),
            screen_height = Device.screen:getHeight(),
            is_kindle = Device:isKindle() or false,
            is_kobo = Device:isKobo() or false,
        }
        if Device.powerd then
            status.battery_level = Device.powerd:getCapacity()
            status.is_charging = Device.powerd:isCharging()
        end
        return status
    else
        -- Standalone mode - return mock data
        return {
            model = "standalone-test",
            has_wifi = false,
            screen_width = 0,
            screen_height = 0,
            is_kindle = false,
            is_kobo = false,
            battery_level = -1,
            is_charging = false,
            mode = "standalone",
        }
    end
end

-- ============================================================
-- L3 Lua API: Widget introspection + Menu navigation
-- These tools let agents interact with KOReader semantically
-- instead of blind coordinate tapping via xdotool.
-- ============================================================

--- Helper: extract widget info from a window stack entry
local function describeWidget(widget)
    if not widget then return nil end
    local info = {
        name = widget.name or "unknown",
        type = "widget",
    }
    -- Detect widget class
    if widget.item_table then
        info.type = "menu"
        info.title = widget.title or nil
        info.item_count = #widget.item_table
        info.page = widget.page or nil
        info.page_num = widget.page_num or nil
    elseif widget.text then
        info.type = "info_message"
        info.text = widget.text
    elseif widget.title then
        info.type = "dialog"
        info.title = widget.title
    end
    if widget.dimen then
        info.dimen = {
            x = widget.dimen.x,
            y = widget.dimen.y,
            w = widget.dimen.w,
            h = widget.dimen.h,
        }
    end
    return info
end

--- Helper: find the topmost Menu widget in the window stack
-- Only list-style Menu widgets have switchItemTable; the main menu is a
-- TouchMenu and is skipped (issue #14).
local function findTopMenu()
    if not UIManager then return nil end
    for widget in UIManager:topdown_widgets_iter() do
        if widget.item_table and widget.switchItemTable then
            return widget
        end
    end
    return nil
end

--- get_current_view: Report what's currently displayed
--- Returns the widget stack (top to bottom) with type info
function handlers.get_current_view(params)
    if not UIManager then
        return nil, {code = -32603, message = "UIManager not available (standalone mode)"}
    end
    local stack = {}
    for widget in UIManager:topdown_widgets_iter() do
        local info = describeWidget(widget)
        if info then
            table.insert(stack, info)
        end
    end
    return {
        widget_count = #stack,
        widgets = stack,
        top_widget = stack[1] or nil,
    }
end

--- get_menu_items: If a Menu is visible, return its items
--- Params: { max_items: number (optional, default 50) }
function handlers.get_menu_items(params)
    if not UIManager then
        return nil, {code = -32603, message = "UIManager not available (standalone mode)"}
    end
    local menu = findTopMenu()
    if not menu then
        return nil, {code = -32602, message = "No menu widget is currently visible"}
    end
    local max_items = (params and params.max_items) or 50
    local items = {}
    for i, item in ipairs(menu.item_table) do
        if i > max_items then break end
        local entry = {
            index = i,
            text = item.text or "",
            bold = item.bold or false,
            has_callback = item.callback ~= nil,
            has_sub_items = item.sub_item_table ~= nil,
        }
        if item.sub_item_table then
            entry.sub_item_count = #item.sub_item_table
        end
        table.insert(items, entry)
    end
    return {
        menu_title = menu.title or "untitled",
        total_items = #menu.item_table,
        returned_items = #items,
        page = menu.page or 1,
        page_num = menu.page_num or 1,
        items = items,
    }
end

--- select_menu_item: Find a menu item by text (substring match) and activate it
--- Params: { text: string, index: number (optional — use instead of text) }
function handlers.select_menu_item(params)
    if not UIManager then
        return nil, {code = -32603, message = "UIManager not available (standalone mode)"}
    end
    if not params or (not params.text and not params.index) then
        return nil, {code = -32602, message = "Provide 'text' (substring match) or 'index' (1-based)"}
    end
    local menu = findTopMenu()
    if not menu then
        return nil, {code = -32602, message = "No menu widget is currently visible"}
    end

    local target_item = nil
    local target_index = nil

    if params.index then
        -- Direct index access
        target_index = params.index
        target_item = menu.item_table[target_index]
        if not target_item then
            return nil, {code = -32602, message = "Index " .. target_index .. " out of range (max: " .. #menu.item_table .. ")"}
        end
    else
        -- Substring text match
        local search = params.text:lower()
        for i, item in ipairs(menu.item_table) do
            local item_text = (item.text or ""):lower()
            if item_text:find(search, 1, true) then
                target_item = item
                target_index = i
                break
            end
        end
        if not target_item then
            -- Return available items for debugging
            local available = {}
            for i, item in ipairs(menu.item_table) do
                if i > 20 then break end
                table.insert(available, item.text or "")
            end
            return nil, {code = -32602, message = "No item matching '" .. params.text .. "'. Available: " .. table.concat(available, ", ")}
        end
    end

    -- Trigger the menu selection (same path as user tap)
    local result = {
        selected_text = target_item.text or "",
        selected_index = target_index,
    }

    if target_item.sub_item_table then
        -- Has submenu — use Menu:onMenuSelect to push submenu
        menu:onMenuSelect(target_item)
        result.action = "opened_submenu"
        result.sub_item_count = #target_item.sub_item_table
    elseif target_item.callback then
        -- Has callback — invoke it
        target_item.callback()
        result.action = "invoked_callback"
    else
        result.action = "no_action"
        result.note = "Item has neither callback nor sub_item_table"
    end

    return result
end

--- go_back: Navigate back in menu stack (equivalent to Back button)
function handlers.go_back(params)
    if not UIManager then
        return nil, {code = -32603, message = "UIManager not available (standalone mode)"}
    end
    local menu = findTopMenu()
    if not menu then
        return nil, {code = -32602, message = "No menu widget is currently visible"}
    end
    menu:onClose()
    return {action = "navigated_back"}
end

--- close_top_widget: Close whatever is on top (dismiss dialogs, info messages)
function handlers.close_top_widget(params)
    if not UIManager then
        return nil, {code = -32603, message = "UIManager not available (standalone mode)"}
    end
    local top = UIManager:getTopmostVisibleWidget()
    if not top then
        return nil, {code = -32602, message = "No visible widget to close"}
    end
    local info = describeWidget(top)
    UIManager:close(top)
    return {closed = info}
end

--- send_event: Trigger any KOReader internal event programmatically
--- Params: { event: string (event name), args: table (optional event args) }
--- Use instead of touch simulation — works in emulator AND on device
function handlers.send_event(params)
    if not UIManager then
        return nil, {code = -32603, message = "UIManager not available (standalone mode)"}
    end
    if not params or not params.event then
        return nil, {code = -32602, message = "Missing 'event' parameter (KOReader event name, e.g. 'ShowMenu')"}
    end
    local Event = require("ui/event")
    UIManager:broadcastEvent(Event:new(params.event, params.args))
    return {sent = params.event, args = params.args or {}}
end

--- capture_screenshot: Capture e-ink framebuffer, return base64 PNG
--- The gateway converts this to an MCP image content block
function handlers.capture_screenshot(params)
    -- Android apps cannot write /tmp, so on Android this fails with "Screen:shot failed: nil".
    local ss_path = "/tmp/mcp_ss.png"
    -- Capture framebuffer (fbgrab from USBNet)
    local fbgrab = "/mnt/us/usbnet/bin/fbgrab"
    local fbgrab_file = io.open(fbgrab, "r")
    if fbgrab_file then
        fbgrab_file:close()
        local ok = os.execute(fbgrab .. " " .. ss_path)
        -- Lua 5.1: os.execute returns exit status as number (0 = success)
        if ok ~= 0 and ok ~= true then
            return nil, {code = -32603, message = "fbgrab failed (exit: " .. tostring(ok) .. ")"}
        end
    else
        -- No fbgrab (the emulator): KOReader writes its own screen buffer to PNG.
        if not Device or not Device.screen or not Device.screen.shot then
            return nil, {code = -32603, message = "no fbgrab and no KOReader screen API"}
        end
        os.remove(ss_path)  -- a leftover file would hide a failed shot
        local shot_ok, shot_err = pcall(function() Device.screen:shot(ss_path) end)
        local png = shot_ok and io.open(ss_path, "rb")
        if not png then
            return nil, {code = -32603, message = "Screen:shot failed: " .. tostring(shot_err)}
        end
        png:close()
    end
    -- Base64 encode the PNG
    local handle = io.popen("base64 " .. ss_path)
    if not handle then
        os.execute("rm -f " .. ss_path)
        return nil, {code = -32603, message = "base64 encoding failed"}
    end
    local b64 = handle:read("*a")
    handle:close()
    -- Cleanup temp files (fbgrab leaves koreader-fb.dump as side effect)
    os.execute("rm -f " .. ss_path .. " /tmp/koreader-fb.dump /tmp/fm-out-*")
    -- Strip whitespace from base64 output
    b64 = b64:gsub("%s", "")
    return {
        image_base64 = b64,
        mime_type = "image/png",
        size_bytes = #b64 * 3 / 4,  -- approximate decoded size
    }
end

--- write_file: atomically write a file from base64 content
--- Bypasses shell ARG_MAX (run_command 'printf %s <b64>' truncates >64KB silently).
--- Params: { path: string, content_base64: string }
--- Returns: { path, bytes_written, md5 (busybox md5sum, may be nil if unavailable) }
function handlers.write_file(params)
    if not params or not params.path or not params.content_base64 then
        return nil, {code = -32602, message = "Missing 'path' or 'content_base64' parameter"}
    end

    -- Decode base64: prefer LuaSocket's mime.unb64 (bundled with KOReader)
    local decoded
    local ok_mime, mime = pcall(require, "mime")
    if ok_mime and mime and mime.unb64 then
        local dec, _ = mime.unb64(params.content_base64)
        decoded = dec
    end
    if not decoded then
        -- Pure-Lua fallback decoder (well-known idiom; slower but works without LuaSocket)
        local b = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
        local data = params.content_base64:gsub('[^'..b..'=]', '')
        decoded = (data:gsub('.', function(x)
            if x == '=' then return '' end
            local r, f = '', (b:find(x) - 1)
            for i = 6, 1, -1 do r = r..(f % 2^i - f % 2^(i-1) > 0 and '1' or '0') end
            return r
        end):gsub('%d%d%d?%d?%d?%d?%d?%d?', function(x)
            if #x ~= 8 then return '' end
            local c = 0
            for i = 1, 8 do c = c + (x:sub(i,i) == '1' and 2^(8-i) or 0) end
            return string.char(c)
        end))
    end
    if not decoded then
        return nil, {code = -32603, message = "Base64 decode failed"}
    end

    -- Ensure parent dir exists (best effort)
    local parent = params.path:match("(.*/)")
    if parent and parent ~= "" then
        os.execute("mkdir -p '" .. parent:gsub("'", "'\\''") .. "'")
    end

    -- Atomic write: temp + rename (POSIX guarantee within same filesystem)
    local tmp_path = params.path .. ".tmp." .. os.time() .. "." .. math.random(10000, 99999)
    local f, err = io.open(tmp_path, "wb")
    if not f then
        return nil, {code = -32603, message = "Cannot open " .. tmp_path .. ": " .. tostring(err)}
    end
    local write_ok, write_err = pcall(function() f:write(decoded) end)
    f:close()
    if not write_ok then
        os.remove(tmp_path)
        return nil, {code = -32603, message = "Write failed: " .. tostring(write_err)}
    end
    local ren_ok, ren_err = os.rename(tmp_path, params.path)
    if not ren_ok then
        os.remove(tmp_path)
        return nil, {code = -32603, message = "Rename failed: " .. tostring(ren_err)}
    end

    -- Compute md5 for caller-side verification (busybox md5sum is reliable on Kindle)
    local md5 = nil
    local md5_handle = io.popen("md5sum '" .. params.path:gsub("'", "'\\''") .. "' 2>/dev/null | awk '{print $1}'")
    if md5_handle then
        md5 = md5_handle:read("*l")
        md5_handle:close()
    end

    return {
        path = params.path,
        bytes_written = #decoded,
        md5 = md5,
    }
end

function handlers.list_tools(params)
    return {
        {name = "read_files", description = "Read files from disk"},
        {name = "run_command", description = "Execute shell command"},
        {name = "device_status", description = "Get device info"},
        {name = "list_tools", description = "List available tools"},
        {name = "get_current_view", description = "L3: Report widget stack (what's on screen)"},
        {name = "get_menu_items", description = "L3: List items in the current menu"},
        {name = "select_menu_item", description = "L3: Select a menu item by text or index"},
        {name = "go_back", description = "L3: Navigate back in menu stack"},
        {name = "close_top_widget", description = "L3: Close/dismiss the top widget"},
        {name = "send_event", description = "L3: Trigger a KOReader internal event (e.g. ShowMenu)"},
        {name = "capture_screenshot", description = "Capture e-ink framebuffer as base64 PNG"},
        {name = "write_file", description = "Atomically write a file from base64 content (no shell ARG_MAX)"},
    }
end

local dispatch_table = {
    read_files = handlers.read_files,
    run_command = handlers.run_command,
    device_status = handlers.device_status,
    list_tools = handlers.list_tools,
    get_current_view = handlers.get_current_view,
    get_menu_items = handlers.get_menu_items,
    select_menu_item = handlers.select_menu_item,
    go_back = handlers.go_back,
    close_top_widget = handlers.close_top_widget,
    send_event = handlers.send_event,
    capture_screenshot = handlers.capture_screenshot,
    write_file = handlers.write_file,
}

-- Widget snapshot and actions (issue #35); see ui_agent.lua.
local ui_agent = require("ui_agent")
ui_agent.installLogCapture()
handlers.ui_agent = ui_agent

function handlers.ui_snapshot(params)
    local snap, err = ui_agent.snapshot()
    if not snap then return nil, {code = -32603, message = err} end
    return snap
end
dispatch_table.ui_snapshot = handlers.ui_snapshot

-- Methods that reply later, once the UI is idle: fn(params, done).
handlers.deferred = {
    ui_act = function(params, done) ui_agent.act(params or {}, done) end,
}

function handlers.dispatch(method, params)
    local fn = dispatch_table[method]
    if not fn then
        return nil, {code = -32601, message = "Method not found: " .. tostring(method)}
    end
    local ok, result_or_err, rpc_error = pcall(fn, params)
    if not ok then
        return nil, {code = -32603, message = "Internal error: " .. tostring(result_or_err)}
    end
    return result_or_err, rpc_error
end

return handlers
