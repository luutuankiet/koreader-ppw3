-- Guards against a bug that hid the Filter dialog: a loop written as
-- `for _, x in ipairs(...)` in a file where `_` is gettext replaces `_`
-- with a number inside the loop, so `_("...")` there throws and the
-- dialog never opens. Run: luajit test_gettext.lua
local pass, fail = 0, 0
local function check(ok, msg)
    if ok then pass = pass + 1 else fail = fail + 1; print("FAIL: " .. msg) end
end

local files = { "main.lua", "gdriveepub_listwidget.lua", "gdriveepub_qrscreen.lua" }
for _i, name in ipairs(files) do
    local fh = assert(io.open(name, "r"))
    local src = fh:read("*a"); fh:close()
    if src:find('local _ = require%("gettext"%)') then
        local n = 0
        for lineno_text in src:gmatch("[^\n]*") do
            if lineno_text:match("^%s*for%s+_%s*,") or lineno_text:match("^%s*local%s+_%s*,") then
                n = n + 1
                print("  shadows gettext: " .. lineno_text)
            end
        end
        check(n == 0, name .. ": no loop or local rebinds `_`")
    else
        check(true, name .. ": does not use gettext")
    end
end

-- The filter dialog must still build its labels through gettext.
local fh = assert(io.open("main.lua", "r"))
local main = fh:read("*a"); fh:close()
local body = main:match("function GDrive:showFilter%(%)(.-)\nend\n")
check(body ~= nil, "showFilter found")
check(body and body:find('_%("Updated within"%)') ~= nil, "filter labels use gettext")

print(string.format("test_gettext: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
