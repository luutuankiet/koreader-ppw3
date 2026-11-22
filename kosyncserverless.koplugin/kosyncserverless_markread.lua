--[[--
Decisions for "push 100% when a book is marked as read". No KOReader
dependencies: main.lua passes in what it reads, so test_markread.lua runs
under plain luajit.
]]

local MarkRead = {}

-- A book counts as just marked read only on the change into "complete".
-- An unknown previous status (nil: nothing cached yet) counts as a change.
function MarkRead.isTransition(prev, new)
    return new == "complete" and prev ~= "complete"
end

-- The setting is on unless explicitly turned off (nil means the default).
function MarkRead.enabled(settings)
    return settings ~= nil and settings.mark_read_push ~= false
end

-- The sync key for a closed book, the same way main.lua computes it for an
-- open one: md5 of the file name, or the sidecar's partial_md5_checksum,
-- falling back to computing it from the file.
function MarkRead.digest(path, use_filename, sidecar_md5, md5_fn, partial_md5_fn)
    if use_filename then
        local name = tostring(path):match("([^/]+)$")
        return name and md5_fn(name) or nil
    end
    if sidecar_md5 then return sidecar_md5 end
    return partial_md5_fn and partial_md5_fn(path) or nil
end

-- The position to send: the server needs a non-empty progress. A book never
-- opened has none, so nothing is pushed for it.
function MarkRead.position(last_xpointer, last_page)
    if type(last_xpointer) == "string" and last_xpointer ~= "" then return last_xpointer end
    if last_page then return tostring(last_page) end
    return nil
end

function MarkRead.item(fields)
    return {
        document = fields.document,
        progress = fields.progress,
        percentage = 1,
        device = fields.device,
        device_id = fields.device_id,
        doc_version = fields.doc_version,
        metadata = fields.metadata,
    }
end

-- The fields driveAction needs, read through read(key) (a DocSettings
-- readSetting). live_annotations, when given, is the open reader's in-memory
-- list, which is newer than the sidecar until the reader saves.
function MarkRead.sidecar(read, live_annotations)
    return {
        gdriveepub_source = read("gdriveepub_source"),
        annotations = live_annotations or read("annotations"),
        highlight = read("highlight"),
        bookmarks = read("bookmarks"),
    }
end

local function hasAnnotations(sidecar)
    local a = sidecar.annotations
    if type(a) == "table" and #a > 0 then return true end
    for _, key in ipairs({ "highlight", "bookmarks" }) do
        local t = sidecar[key]
        if type(t) == "table" and next(t) ~= nil then return true end
    end
    return false
end

--[[--
What to do with the file once 100% was pushed.
@tparam table sidecar { gdriveepub_source, annotations, highlight, bookmarks }
@tparam bool is_open the book is open in the reader right now
@treturn string "none" (not a Drive doc), "keep" (has highlights, notes or
bookmarks), "after_close" (delete once the reader closes), "delete"
]]
function MarkRead.driveAction(sidecar, is_open)
    if type(sidecar) ~= "table" or type(sidecar.gdriveepub_source) ~= "table" then return "none" end
    if hasAnnotations(sidecar) then return "keep" end
    if is_open then return "after_close" end
    return "delete"
end

-- After a successful 100% push: does the book leave the synced reading list?
-- Only a Drive doc does, so other devices clean up their copy; it leaves the
-- list even when its file is kept for its highlights or is still open.
function MarkRead.removeFromList(sidecar)
    return type(sidecar) == "table" and type(sidecar.gdriveepub_source) == "table"
end

return MarkRead
