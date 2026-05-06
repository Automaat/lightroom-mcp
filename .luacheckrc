std = "lua54"

-- Lightroom Classic SDK globals
read_globals = {
  "import",
  "LrApplication",
  "LrApplicationView",
  "LrBinding",
  "LrCatalog",
  "LrColor",
  "LrControlBar",
  "LrDate",
  "LrDevelopController",
  "LrDevelopAdjustment",
  "LrDialogs",
  "LrErrors",
  "LrExportSession",
  "LrExportSettings",
  "LrFileUtils",
  "LrFtp",
  "LrFunctionContext",
  "LrFunctionInfo",
  "LrHttp",
  "LrLogger",
  "LrMath",
  "LrMD5",
  "LrPasswords",
  "LrPathUtils",
  "LrPhoto",
  "LrPluginInfo",
  "LrPrefs",
  "LrProgressScope",
  "LrPublishService",
  "LrRecursionGuard",
  "LrRequire",
  "LrSelection",
  "LrShell",
  "LrSocket",
  "LrStringUtils",
  "LrSystemInfo",
  "LrTasks",
  "LrUUID",
  "LrView",
  "LrXml",
  "MAC_ENV",
  "WIN_ENV",
  "_PLUGIN",
}

-- Tune defaults: Lightroom plugin code typically uses long lines and
-- keeps unused arguments for callback signature parity.
max_line_length = 200
unused_args = false
self = false

-- Suppress noisy warning codes; keep real errors (undefined globals,
-- syntax issues) failing the build.
--   211 unused variable    212 unused argument
--   213 unused loop var    221 variable never set
ignore = { "211", "212", "213", "221" }

exclude_files = {
  "plugin/LightroomMCP.lrplugin/JSON.lua",
  "plugin/spec/",
}

