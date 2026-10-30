--[[--
A progress sync device id that belongs to this Kindle, not to a settings file.

KOReader makes the id once, at random, and keeps it as "device_id" in
settings.reader.lua. Restoring that file on a second device copies the id, and
the built-in progress sync then treats the other device's position as its own
("Latest progress is coming from this device") and never pulls it.

Every Kindle has a hardware serial in /proc/usid that no backup carries. When
it can be read, the id becomes the uppercase md5 of "kosync:" .. serial, so it
is the same on every run and different on every Kindle. Android and the
emulator have no /proc/usid: nothing changes there.

The serial is never logged; at most the last 4 characters of the new id are.
]]

local DeviceId = {}

DeviceId.SERIAL_PATH = "/proc/usid"
DeviceId.PREFIX = "kosync:"

local function readSerial(path, open)
    local f = open(path, "r")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    s = s and s:match("^%s*(.-)%s*$")
    if not s or s == "" then return nil end
    return s
end

--- The id for a serial: uppercase md5 of "kosync:" .. serial.
function DeviceId.derive(serial, md5)
    return md5(DeviceId.PREFIX .. serial):upper()
end

--[[--
Set settings "device_id" from the serial when they differ, and flush.

@tparam table opts
  settings  (required) G_reader_settings, or anything with readSetting,
            saveSetting and flush
  md5       (required) function(string) -> hex digest
  path      serial file, default /proc/usid
  open      default io.open
  log       default none; gets info(...)
@treturn string "changed", "same" or "no_serial"
]]
function DeviceId.apply(opts)
    assert(opts and opts.settings and opts.md5, "DeviceId.apply: settings and md5 are required")
    local serial = readSerial(opts.path or DeviceId.SERIAL_PATH, opts.open or io.open)
    if not serial then return "no_serial" end
    local id = DeviceId.derive(serial, opts.md5)
    if opts.settings:readSetting("device_id") == id then return "same" end
    opts.settings:saveSetting("device_id", id)
    opts.settings:flush()
    if opts.log then
        opts.log.info("syncedhistory: progress sync device id set from the hardware serial, ends", id:sub(-4))
    end
    return "changed"
end

return DeviceId
