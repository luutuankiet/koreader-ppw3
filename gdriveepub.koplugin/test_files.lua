-- Unit tests for gdriveepub_files.lua. Run: luajit test_files.lua
package.path = "./?.lua;" .. package.path
local F = require("gdriveepub_files")
local pass, fail = 0, 0
local function eq(a, b, what)
    if a == b then pass = pass + 1 else fail = fail + 1
        print("FAIL " .. what .. ": got " .. tostring(a) .. ", want " .. tostring(b)) end
end
local DOT = " \194\183 "

-- Names
eq(F.isPlainName("Book.epub"), true, "plain name")
eq(F.isPlainName("Notes 2026 (v2).pdf"), true, "spaces and brackets")
eq(F.isPlainName(""), false, "empty"); eq(F.isPlainName(nil), false, "nil")
eq(F.isPlainName("."), false, "dot"); eq(F.isPlainName(".."), false, "dotdot")
eq(F.isPlainName("../x.epub"), false, "parent path"); eq(F.isPlainName("a..b"), false, "embedded dotdot")
eq(F.isPlainName("sub/x.epub"), false, "slash"); eq(F.isPlainName("sub\\x.epub"), false, "backslash")
eq(F.isPlainName("x\0.epub"), false, "nul")

-- List building
local list = F.build({
    { name = "old.pdf", mode = "file", size = 2048, modification = 100 },
    { name = "new.epub", mode = "file", size = 3 * 1024 * 1024, modification = 300 },
    { name = "b.epub", mode = "file", size = 10, modification = 200 },
    { name = "a.epub", mode = "file", size = 10, modification = 200 },
    { name = "new.epub.sdr", mode = "directory", modification = 400 },
    { name = ".x.epub.part", mode = "file", size = 1, modification = 500 },
    { name = ".", mode = "directory" }, { name = "..", mode = "directory" },
})
eq(#list, 4, "only plain visible files")
eq(list[1].name, "new.epub", "newest first"); eq(list[2].name, "a.epub", "tie by name")
eq(list[3].name, "b.epub", "tie by name 2"); eq(list[4].name, "old.pdf", "oldest last")
eq(#F.build(nil), 0, "nil entries")
eq(F.meta(list[1], 0), "3.0 MB" .. DOT .. "1970-01-01 00:05", "meta MB utc")
eq(F.meta(list[4], 3600), "2 KB" .. DOT .. "1970-01-01 01:01", "meta KB offset")
eq(F.meta({ size = 10, modified = 0 }, 0):sub(1, 4), "1 KB", "tiny rounds up to 1 KB")
eq(F.label(list[1], true), "\226\156\147 new.epub", "label marked")
eq(F.label(list[1], false), "new.epub", "label unmarked")

-- Selection
local sel = F.newSelection()
eq(F.subtitle(list, sel), "4 files", "subtitle none")
eq(F.toggle(sel, "a.epub"), true, "toggle on"); eq(F.isSelected(sel, "a.epub"), true, "is selected")
F.toggle(sel, "old.pdf")
eq(table.concat(F.selectedNames(sel, list), ","), "a.epub,old.pdf", "selected in list order")
eq(F.subtitle(list, sel), "4 files" .. DOT .. "2 selected", "subtitle selected")
eq(F.toggle(sel, "a.epub"), false, "toggle off")
F.selectAll(sel, list); eq(#F.selectedNames(sel, list), 4, "select all")
F.clear(sel); eq(#F.selectedNames(sel, list), 0, "select none")
F.toggle(sel, "gone.epub"); F.toggle(sel, "b.epub"); F.prune(sel, list)
eq(F.isSelected(sel, "gone.epub"), false, "prune drops missing"); eq(F.isSelected(sel, "b.epub"), true, "prune keeps listed")
eq(F.subtitle({ list[1] }, F.newSelection()), "1 file", "singular")

-- Delete safety, against a fake file system with a link out of the folder
local fs = {
    ["/docs/GDrive"] = "/docs/GDrive",
    ["/docs/GDrive/"] = "/docs/GDrive",
    ["/docs/GDrive/a.epub"] = "/docs/GDrive/a.epub",
    ["/docs/GDrive/b.epub"] = "/docs/GDrive/b.epub",
    ["/docs/GDrive/link.epub"] = "/docs/other/secret.epub",
    ["/docs/GDrive/deep.epub"] = "/docs/GDrive/sub/deep.epub",
    ["/link/GDrive"] = "/docs/GDrive",
    ["/docs/GDrive/./a.epub"] = "/docs/GDrive/a.epub",
}
local function realpath(p) return fs[p] end
eq(F.resolveInside("/docs/GDrive", "a.epub", realpath), "/docs/GDrive/a.epub", "inside")
eq(F.resolveInside("/docs/GDrive/", "a.epub", realpath), "/docs/GDrive/a.epub", "trailing slash dir")
eq(F.resolveInside("/link/GDrive", "a.epub", realpath), "/docs/GDrive/a.epub", "dir via link")
eq(select(2, F.resolveInside("/docs/GDrive", "../other/secret.epub", realpath)), "bad_name", "dotdot refused")
eq(select(2, F.resolveInside("/docs/GDrive", "/etc/passwd", realpath)), "bad_name", "absolute refused")
eq(select(2, F.resolveInside("/docs/GDrive", "link.epub", realpath)), "outside", "link out refused")
eq(select(2, F.resolveInside("/docs/GDrive", "deep.epub", realpath)), "outside", "link into subfolder refused")
eq(select(2, F.resolveInside("/docs/GDrive", "none.epub", realpath)), "missing", "missing file")
eq(select(2, F.resolveInside("/nowhere", "a.epub", realpath)), "no_dir", "missing dir")
eq(select(2, F.resolveInside(nil, "a.epub", realpath)), "no_dir", "nil dir")

local plan = F.planDelete("/docs/GDrive", { "a.epub", "b.epub", "link.epub", "../x" }, "/docs/GDrive/./a.epub", realpath)
eq(#plan.paths, 1, "one path to delete"); eq(plan.paths[1], "/docs/GDrive/b.epub", "b deleted")
eq(plan.names[1], "b.epub", "b name"); eq(#plan.skipped, 3, "three skipped")
eq(plan.skipped[1].name, "a.epub", "open doc skipped"); eq(plan.skipped[1].reason, "open", "reason open")
eq(plan.skipped[2].reason, "outside", "link skipped"); eq(plan.skipped[3].reason, "bad_name", "bad name skipped")
eq(#F.planDelete("/docs/GDrive", { "a.epub" }, nil, realpath).paths, 1, "no open doc")
eq(#F.planDelete("/docs/GDrive", {}, nil, realpath).paths, 0, "nothing selected")

-- Sidecars
eq(F.sidecarDir("/d/GDrive/Book.epub"), "/d/GDrive/Book.sdr", "sidecar drops last suffix")
eq(F.sidecarDir("/d/GDrive/a.b.pdf"), "/d/GDrive/a.b.sdr", "only last suffix")
eq(F.canPurgeSidecar({ "extra-note.txt", "cover.jpg" }), true, "no metadata left")
eq(F.canPurgeSidecar({}), true, "empty sidecar")
eq(F.canPurgeSidecar({ "metadata.pdf.lua" }), false, "sibling metadata kept")
eq(F.canPurgeSidecar({ "metadata.pdf.lua.old" }), false, "sibling backup kept")

print(string.format("test_files: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
