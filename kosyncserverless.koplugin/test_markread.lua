-- luajit test_markread.lua
package.path = "./?.lua;" .. package.path
local MarkRead = require("kosyncserverless_markread")

local failures, count = 0, 0
local function eq(name, got, want)
    count = count + 1
    if got ~= want then
        failures = failures + 1
        print("FAIL " .. name .. ": got " .. tostring(got) .. ", want " .. tostring(want))
    end
end

-- transitions
eq("reading to complete", MarkRead.isTransition("reading", "complete"), true)
eq("abandoned to complete", MarkRead.isTransition("abandoned", "complete"), true)
eq("unknown to complete", MarkRead.isTransition(nil, "complete"), true)
eq("new to complete", MarkRead.isTransition("new", "complete"), true)
eq("already complete", MarkRead.isTransition("complete", "complete"), false)
eq("complete to reading", MarkRead.isTransition("complete", "reading"), false)
eq("reading to abandoned", MarkRead.isTransition("reading", "abandoned"), false)

-- setting
eq("default on", MarkRead.enabled({}), true)
eq("explicit on", MarkRead.enabled({ mark_read_push = true }), true)
eq("off", MarkRead.enabled({ mark_read_push = false }), false)
eq("no settings", MarkRead.enabled(nil), false)

-- digest
local function md5(s) return "md5:" .. s end
local function partial(p) return "partial:" .. p end
eq("filename method", MarkRead.digest("/a/b/Book.epub", true, "x", md5, partial), "md5:Book.epub")
eq("binary uses sidecar", MarkRead.digest("/a/Book.epub", false, "abc", md5, partial), "abc")
eq("binary computes", MarkRead.digest("/a/Book.epub", false, nil, md5, partial), "partial:/a/Book.epub")

-- position
eq("xpointer", MarkRead.position("/body/DocFragment[3]", 12), "/body/DocFragment[3]")
eq("page", MarkRead.position(nil, 12), "12")
eq("empty xpointer falls to page", MarkRead.position("", 7), "7")
eq("never opened", MarkRead.position(nil, nil), nil)

-- item
local item = MarkRead.item({ document = "d", progress = "p", device = "emu", device_id = "id" })
eq("item percentage", item.percentage, 1)
eq("item document", item.document, "d")

-- Drive decision
local src = { id = "x", modified = "2026-11-01T00:00:00Z" }
eq("not drive", MarkRead.driveAction({}, false), "none")
eq("no sidecar", MarkRead.driveAction(nil, false), "none")
eq("drive closed", MarkRead.driveAction({ gdriveepub_source = src }, false), "delete")
eq("drive open", MarkRead.driveAction({ gdriveepub_source = src }, true), "after_close")
eq("drive annotations", MarkRead.driveAction({ gdriveepub_source = src, annotations = { {} } }, false), "keep")
eq("drive empty annotations", MarkRead.driveAction({ gdriveepub_source = src, annotations = {} }, false), "delete")
eq("drive old highlight", MarkRead.driveAction({ gdriveepub_source = src, highlight = { [3] = {} } }, true), "keep")
eq("drive bookmarks", MarkRead.driveAction({ gdriveepub_source = src, bookmarks = { {} } }, false), "keep")

-- Sidecar snapshot: an open book's highlights live in memory until the
-- reader saves, so the live list wins over the stale sidecar copy.
local stored = { gdriveepub_source = src, annotations = {} }
local function read(key) return stored[key] end
eq("snapshot from sidecar", MarkRead.driveAction(MarkRead.sidecar(read), false), "delete")
eq("live highlight beats stale sidecar",
    MarkRead.driveAction(MarkRead.sidecar(read, { {} }), true), "keep")
eq("live empty list", MarkRead.driveAction(MarkRead.sidecar(read, {}), true), "after_close")

-- Leaving the synced reading list
eq("list: ordinary book stays", MarkRead.removeFromList({}), false)
eq("list: no sidecar", MarkRead.removeFromList(nil), false)
eq("list: drive doc leaves", MarkRead.removeFromList({ gdriveepub_source = src }), true)
eq("list: drive doc with highlights still leaves",
    MarkRead.removeFromList({ gdriveepub_source = src, annotations = { {} } }), true)

print(string.format("%d/%d passed", count - failures, count))
os.exit(failures == 0 and 0 or 1)
