if _G.LightroomMCP_State then
    require('PluginInfoProvider').shutdown()
end

return {
    LrShutdownFunction = function(doneFunction)
        if doneFunction then doneFunction() end
    end,
}
