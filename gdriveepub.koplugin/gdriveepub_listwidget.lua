--[[--
Full-screen file list for the Google Drive plugin.

KOReader's Menu shows one line per item, so long titles get cut. Each row
here is a 2-line wrapped title plus a smaller line with the dates and kind.

    local ListWidget = require("gdriveepub_listwidget")
    local w = ListWidget:new{
        subtitle = "Recent · by opened",
        files = files, more = true,
        on_tap = function(file) end, on_hold = function(file) end,
        on_action = function(name) end,  -- "recent" | "search" | "filter" | "sort" | "more" | "close"
        meta = function(file) return "Updated ... · Created ... · DOC" end,
    }
    UIManager:show(w)
    w:setFiles(files, more, subtitle)  -- after a reload; keeps the page when appending

Optional: `title` (default "Google Drive"), `toolbar` (a row of
`{ text =, action = }` buttons replacing Recent/Search/Filter/Sort, each
calling `on_action(action)`), and `row_title(file)` for the row text
(default `file.name`). `redraw()` repaints the current page in place.
]]

local Blitbuffer = require("ffi/blitbuffer")
local ButtonTable = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Screen = Device.screen

local State = require("gdriveepub_state")

local TITLE_FONT = Font:getFace("cfont", 20)
local META_FONT = Font:getFace("cfont", 15)

--- One tappable row.
local Row = InputContainer:extend{
    file = nil, width = nil, height = nil, meta_text = "", title_text = nil,
    on_tap = nil, on_hold = nil,
}

function Row:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    local pad = Size.padding.large
    local inner_w = self.width - 2 * pad
    local title = TextBoxWidget:new{
        text = self.title_text or self.file.name,
        face = TITLE_FONT,
        width = inner_w,
        height = self.title_height,
        height_overflow_show_ellipsis = true,
        alignment = "left",
    }
    local meta = TextWidget:new{
        text = self.meta_text,
        face = META_FONT,
        max_width = inner_w,
        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
    }
    self[1] = FrameContainer:new{
        width = self.width, height = self.height,
        padding = 0, padding_left = pad, padding_right = pad, bordersize = 0,
        LeftContainer:new{
            dimen = Geom:new{ w = inner_w, h = self.height },
            VerticalGroup:new{ align = "left", title, VerticalSpan:new{ width = Size.span.vertical_default }, meta },
        },
    }
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = self.dimen } },
        Hold = { GestureRange:new{ ges = "hold", range = self.dimen } },
    }
end

function Row:onTap() if self.on_tap then self.on_tap(self.file) end return true end
function Row:onHold() if self.on_hold then self.on_hold(self.file) end return true end

local ListWidget = InputContainer:extend{
    subtitle = "", files = nil, more = false, page = 1, empty_text = "No files.",
    on_tap = nil, on_hold = nil, on_action = nil, meta = nil,
    title = "Google Drive", toolbar = nil, row_title = nil,
}

local DEFAULT_TOOLBAR = {
    { text = "Recent", action = "recent" },
    { text = "Search", action = "search" },
    { text = "Filter", action = "filter" },
    { text = "Sort", action = "sort" },
}

function ListWidget:init()
    self.width, self.height = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    self.files = self.files or {}
    -- Row height: two title lines + meta line + padding.
    local probe = TextBoxWidget:new{ text = "Ag\nAg", face = TITLE_FONT, width = self.width }
    self.title_height = probe:getSize().h
    probe:free()
    local meta_h = TextWidget:new{ text = "Ag", face = META_FONT }:getSize().h
    self.row_height = self.title_height + meta_h + Size.span.vertical_default + 2 * Size.padding.large
    if Device:hasKeys() then
        self.key_events = { Close = { { "Back" } }, NextPage = { { "RPgFwd" } }, PrevPage = { { "RPgBack" } } }
    end
    self.ges_events = {
        Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } },
    }
    self:build()
end

function ListWidget:action(name)
    if self.on_action then self.on_action(name) end
end

function ListWidget:build()
    local w = self.width
    self.title_bar = TitleBar:new{
        width = w, title = self.title, subtitle = self.subtitle,
        subtitle_truncate_left = false, with_bottom_line = true,
        close_callback = function() self:action("close") end,
    }
    local toolbar = ButtonTable:new{
        width = w - 2 * Size.padding.default,
        buttons = { self:toolbarButtons() },
        zero_sep = true, show_parent = self,
    }
    -- Footer first, so the rows know how much room is left.
    self.footer_label = TextWidget:new{ text = "Page 1 of 1", face = Font:getFace("cfont", 18) }
    local footer = ButtonTable:new{
        width = w - 2 * Size.padding.default,
        buttons = { {
            { text = "< Prev", id = "prev", callback = function() self:prevPage() end },
            { text = "Page", id = "label", enabled = false, callback = function() end },
            { text = "Next >", id = "next", callback = function() self:nextPage() end },
        } },
        zero_sep = true, show_parent = self,
    }
    self.footer = footer
    local used = self.title_bar:getSize().h + toolbar:getSize().h + footer:getSize().h + 2 * Size.span.vertical_default
    self.rows_height = self.height - used
    self.per_page = math.max(1, math.floor(self.rows_height / (self.row_height + Size.line.thin)))
    self.rows_group = VerticalGroup:new{ align = "left" }
    self[1] = FrameContainer:new{
        width = self.width, height = self.height, padding = 0, bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{
            align = "center",
            self.title_bar,
            CenterContainer:new{ dimen = Geom:new{ w = w, h = toolbar:getSize().h }, toolbar },
            VerticalSpan:new{ width = Size.span.vertical_default },
            LineWidget:new{ dimen = Geom:new{ w = w, h = Size.line.medium } },
            FrameContainer:new{ width = w, height = self.rows_height, padding = 0, bordersize = 0, self.rows_group },
            VerticalSpan:new{ width = Size.span.vertical_default },
            CenterContainer:new{ dimen = Geom:new{ w = w, h = footer:getSize().h }, footer },
        },
    }
    self:fillRows()
end

function ListWidget:toolbarButtons()
    local row = {}
    for _i, b in ipairs(self.toolbar or DEFAULT_TOOLBAR) do
        local name = b.action
        table.insert(row, { text = b.text, callback = function() self:action(name) end })
    end
    return row
end

function ListWidget:pages()
    return State.pageCount(#self.files, self.per_page)
end

function ListWidget:fillRows()
    self.rows_group:clear()
    local pages = self:pages()
    if self.page > pages then self.page = pages end
    if #self.files == 0 then
        self.rows_group[1] = CenterContainer:new{
            dimen = Geom:new{ w = self.width, h = self.rows_height },
            TextBoxWidget:new{ text = self.empty_text, face = TITLE_FONT, width = math.floor(self.width * 0.8), alignment = "center" },
        }
    end
    local first = (self.page - 1) * self.per_page + 1
    for i = first, math.min(#self.files, first + self.per_page - 1) do
        local f = self.files[i]
        table.insert(self.rows_group, Row:new{
            file = f, width = self.width, height = self.row_height, title_height = self.title_height,
            meta_text = self.meta and self.meta(f) or "",
            title_text = self.row_title and self.row_title(f) or nil,
            on_tap = self.on_tap, on_hold = self.on_hold,
        })
        table.insert(self.rows_group, LineWidget:new{
            dimen = Geom:new{ w = self.width, h = Size.line.thin }, background = Blitbuffer.COLOR_LIGHT_GRAY,
        })
    end
    self.rows_group:resetLayout()
    local label = self.footer:getButtonById("label")
    label:setText(State.pageLabel(self.page, pages, self.more), label.width)
    self.footer:getButtonById("prev"):enableDisable(self.page > 1)
    self.footer:getButtonById("next"):enableDisable(self.page < pages or self.more)
end

function ListWidget:refresh()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
end

--- Replace the list. `keep_page` after appending a fetched page.
function ListWidget:setFiles(files, more, subtitle, keep_page)
    self.files, self.more = files or {}, more
    if subtitle then
        self.subtitle = subtitle
        self.title_bar:setSubTitle(subtitle)
    end
    if not keep_page then self.page = 1 end
    self:fillRows()
    self:refresh()
end

--- Repaint the current page, e.g. after a selection mark changed.
function ListWidget:redraw(subtitle)
    if subtitle then
        self.subtitle = subtitle
        self.title_bar:setSubTitle(subtitle)
    end
    self:fillRows()
    self:refresh()
end

function ListWidget:nextPage()
    if self.page < self:pages() then
        self.page = self.page + 1
        self:fillRows(); self:refresh()
    elseif self.more then
        -- main.lua fetches the next page and calls setFiles(..., keep_page) then showPage(page + 1).
        self:action("more")
    end
end

function ListWidget:showPage(p)
    self.page = math.max(1, math.min(p, self:pages()))
    self:fillRows(); self:refresh()
end

function ListWidget:prevPage()
    if self.page > 1 then
        self.page = self.page - 1
        self:fillRows(); self:refresh()
    end
end

function ListWidget:onNextPage() self:nextPage() return true end
function ListWidget:onPrevPage() self:prevPage() return true end
function ListWidget:onClose() self:action("close") return true end

function ListWidget:onSwipe(_, ges)
    local dir = ges.direction
    if dir == "west" or dir == "north" then self:nextPage()
    elseif dir == "east" or dir == "south" then self:prevPage() end
    return true
end

function ListWidget:onShow()
    self:refresh()
end

function ListWidget:onCloseWidget()
    UIManager:setDirty(nil, function() return "ui", self.dimen end)
end

return ListWidget
