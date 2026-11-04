local _ = require("gettext")
return {
    name = "koreader_mcp",
    fullname = _("KOReader MCP Server"),
    description = _([[Agent bridge for remote device management. While live mode is on, the device holds a connection to the gateway and answers file, command, status and UI calls over it. Send diagnostics uploads one bundle to the gateway inbox.]]),
    version = "0.5.0",
}
