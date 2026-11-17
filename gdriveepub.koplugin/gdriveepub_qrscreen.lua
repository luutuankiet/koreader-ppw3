--[[--
Full-screen QR code with a heading, instructions, a status line and
buttons. Used for pairing the Kindle and for signing in to Google again.

KOReader's QRMessage shows only the code and closes on any tap, so the user
could not see what to do or retry.

    local QrScreen = require("gdriveepub_qrscreen")
    local s = QrScreen:new{
        heading = "Pair this Kindle", text = "Scan with your phone ...",
        url = "https://.../pair/abc", status = "Waiting ...",
        buttons = { { text = "Cancel", callback = ... }, { text = "Retry", callback = ... } },
    }
    UIManager:show(s); s:setStatus("Expired."); s:setUrl(new_url)
]]

local Blitbuffer = require("ffi/blitbuffer")
local ButtonTable = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local InputContainer = require("ui/widget/container/inputcontainer")
local QRWidget = require("ui/widget/qrwidget")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Screen = Device.screen

local QrScreen = InputContainer:extend{
    heading = "", text = "", url = "", status = "", buttons = nil,
}

function QrScreen:init()
    self.width, self.height = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    if Device:hasKeys() then self.key_events = { Close = { { "Back" } } } end
    self:build()
end

function QrScreen:build()
    local w = self.width
    local text_w = math.floor(w * 0.86)
    local span = VerticalSpan:new{ width = Size.span.vertical_large * 2 }
    local function box(text, size, bold, align)
        return TextBoxWidget:new{ text = text, face = Font:getFace("cfont", size), bold = bold,
            width = text_w, alignment = align or "center" }
    end
    local buttons = ButtonTable:new{ width = text_w, buttons = { self.buttons or {} }, show_parent = self }
    local heading = box(self.heading, 26, true)
    local text = box(self.text, 19)
    local url = box(self.url, 14)
    self.status_box = box(self.status, 19, true)
    local used = heading:getSize().h + text:getSize().h + url:getSize().h + self.status_box:getSize().h * 2
        + buttons:getSize().h + 7 * span:getSize().h
    local qr_size = math.min(math.floor(w * 0.7), self.height - used)
    self.qr_holder = CenterContainer:new{
        dimen = Geom:new{ w = w, h = qr_size },
        QRWidget:new{ text = self.url, width = qr_size, height = qr_size },
    }
    self[1] = FrameContainer:new{
        width = w, height = self.height, bordersize = 0, padding = 0, background = Blitbuffer.COLOR_WHITE,
        CenterContainer:new{
            dimen = Geom:new{ w = w, h = self.height },
            VerticalGroup:new{
                align = "center",
                heading, span, text, span, self.qr_holder, span, url, span,
                self.status_box, span, buttons,
            },
        },
    }
end

function QrScreen:rebuild()
    self:build()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
end

function QrScreen:setStatus(status)
    self.status = status or ""
    self:rebuild()
end

function QrScreen:setUrl(url, status)
    self.url = url or ""
    if status then self.status = status end
    self:rebuild()
end

function QrScreen:onClose()
    if self.on_close then self.on_close() end
    UIManager:close(self)
    return true
end

function QrScreen:onShow()
    UIManager:setDirty(self, function() return "full", self.dimen end)
end

function QrScreen:onCloseWidget()
    UIManager:setDirty(nil, function() return "full", self.dimen end)
end

return QrScreen
