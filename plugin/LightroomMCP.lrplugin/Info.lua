return {
    LrSdkVersion = 8.0,
    LrSdkMinimumVersion = 8.0,

    LrToolkitIdentifier = 'com.lightroom.mcp',
    LrPluginName = "Lightroom MCP",

    LrPluginInfoUrl = "https://github.com/automaat/lightroom-mcp",

    VERSION = { major=0, minor=8, revision=0, build=0 },

    LrPluginInfoProvider = 'PluginInfoProvider.lua',
    LrInitPlugin = 'PluginInit.lua',
    -- LrForceInitPlugin forces eager load on Lr launch, but ONLY if the
    -- plugin also exposes at least one menu item — see LrLibraryMenuItems
    -- below. Adobe's own remote_control_socket sample uses this pattern.
    LrForceInitPlugin = true,
    LrShutdownPlugin = 'PluginShutdown.lua',
    LrShutdownApp = 'PluginShutdown.lua',

    LrLibraryMenuItems = {
        {
            title = "Lightroom MCP — Show Status",
            file = "MenuShowStatus.lua",
        },
    },
}
