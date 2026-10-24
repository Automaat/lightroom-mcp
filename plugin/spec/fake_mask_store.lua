local FakeMaskStore = {}

function FakeMaskStore.clone(value)
    if type(value) ~= "table" then return value end
    local copy = {}
    for key, item in pairs(value) do copy[key] = FakeMaskStore.clone(item) end
    return copy
end

local clone = FakeMaskStore.clone

local function merge(base, overrides)
    for key, value in pairs(overrides or {}) do base[key] = value end
    return base
end

function FakeMaskStore.linearComponent(overrides)
    return merge({
        What = "Mask/Gradient",
        MaskActive = true,
        MaskInverted = false,
        MaskBlendMode = 0,
        MaskValue = 1,
        MaskName = "Linear Gradient",
        ZeroX = 0.5, ZeroY = 0.6, FullX = 0.5, FullY = 0.2,
    }, overrides)
end

function FakeMaskStore.radialComponent(overrides)
    return merge({
        What = "Mask/CircularGradient",
        MaskActive = true,
        MaskInverted = false,
        MaskBlendMode = 0,
        MaskValue = 1,
        MaskName = "Radial Gradient",
        Top = 0.2, Left = 0.3, Bottom = 0.8, Right = 0.7,
        Angle = 10, Feather = 50, Midpoint = 50, Roundness = 0, Version = 2,
    }, overrides)
end

function FakeMaskStore.paint(overrides)
    return merge({
        What = "Mask/Paint",
        MaskActive = true,
        MaskInverted = false,
        MaskBlendMode = 0,
        MaskValue = 1,
        Flow = 1,
        Radius = 0.14,
        CenterWeight = 0,
        Dabs = { "d 0.200000 0.300000", "d 0.300000 0.300000" },
    }, overrides)
end

function FakeMaskStore.brushComponent(overrides, paints)
    return merge({
        What = "Mask/Aggregate",
        MaskActive = true,
        MaskInverted = false,
        MaskBlendMode = 0,
        MaskValue = 1,
        MaskName = "Brush",
        Masks = paints or { FakeMaskStore.paint() },
    }, overrides)
end

function FakeMaskStore.correction(name, components, overrides)
    return merge({
        What = "Correction",
        CorrectionName = name,
        CorrectionActive = true,
        CorrectionAmount = 1,
        CorrectionMasks = components,
        LocalExposure2012 = 0.25,
    }, overrides)
end

function FakeMaskStore.lightroomAssignsIds(written, counter)
    for _, entry in ipairs(written) do
        if entry.CorrectionID == nil then
            counter.next = counter.next + 1
            entry.CorrectionID = "C" .. counter.next
            entry.CorrectionSyncID = "CS" .. counter.next
            entry.CorrectionReferenceX = 0.5
            entry.CorrectionReferenceY = 0.5
            entry.LocalCurveRefineSaturation = 100
        end
        for index, component in ipairs(entry.CorrectionMasks) do
            if component.MaskID == nil then
                component.MaskID = entry.CorrectionID .. "T" .. index
                component.MaskSyncID = "S" .. component.MaskID
            end
            if component.What == "Mask/CircularGradient" then
                component.Flipped = not component.MaskInverted
            end
        end
    end
    return written
end

local TOOL_TYPE_OF_WHAT = {
    ["Mask/Gradient"] = "gradient",
    ["Mask/CircularGradient"] = "radialGradient",
    ["Mask/Aggregate"] = "brush",
    ["Mask/RangeMask"] = "rangeMask",
    ["Mask/Image"] = "aiSelection",
}

function FakeMaskStore.maskListOf(entries)
    local masks = {}
    for index, entry in ipairs(entries) do
        local tools = {}
        for _, component in ipairs(entry.CorrectionMasks) do
            tools[#tools + 1] = {
                ID = component.MaskID,
                Type = TOOL_TYPE_OF_WHAT[component.What],
                Inverted = component.MaskInverted == true,
            }
        end
        masks[index] = { ID = entry.CorrectionID, Name = entry.CorrectionName, Hidden = false, Tools = tools }
    end
    return masks
end

function FakeMaskStore.attach(photo, opts)
    opts = opts or {}
    local state = {
        entries = clone(opts.entries or {}),
        writes = {},
        attempts = 0,
        reads = 0,
        readsSinceWrite = 0,
        previousEntries = {},
        counter = { next = 0 },
        insideRead = false,
        insideWrite = false,
        readsOutsideGate = 0,
        writesOutsideGate = 0,
    }
    for _, entry in ipairs(state.entries) do
        local number = tostring(entry.CorrectionID):match("^C(%d+)$")
        if number then state.counter.next = math.max(state.counter.next, tonumber(number)) end
    end
    photo.getDevelopSettings = function()
        if not state.insideRead then state.readsOutsideGate = state.readsOutsideGate + 1 end
        state.reads = state.reads + 1
        local settings = {}
        if not opts.noProcessVersion then settings.ProcessVersion = opts.processVersion or "15.4" end
        local source = state.entries
        if #state.writes > 0 and state.readsSinceWrite < (opts.lagReadsAfterWrite or 0) then
            source = state.previousEntries
        end
        state.readsSinceWrite = state.readsSinceWrite + 1
        if #source > 0 then settings.MaskGroupBasedCorrections = clone(source) end
        return settings
    end
    photo.applyDevelopSettings = function(_, settings)
        if not state.insideWrite then state.writesOutsideGate = state.writesOutsideGate + 1 end
        state.attempts = state.attempts + 1
        if opts.rejectWrite and opts.rejectWrite(state.attempts) then error("write rejected") end
        local writeNumber = #state.writes + 1
        local written = clone(settings.MaskGroupBasedCorrections)
        state.writes[writeNumber] = clone(written)
        state.previousEntries = state.entries
        state.readsSinceWrite = 0
        local stored = FakeMaskStore.lightroomAssignsIds(written, state.counter)
        if opts.transformWrite then stored = opts.transformWrite(stored, writeNumber) end
        state.entries = stored
    end
    return state
end

function FakeMaskStore.trackGates(state, catalog)
    local read, write = catalog.withReadAccessDo, catalog.withWriteAccessDo
    catalog.withReadAccessDo = function(self, fn)
        state.insideRead = true
        local ok, err = pcall(read, self, fn)
        state.insideRead = false
        if not ok then error(err, 0) end
    end
    catalog.withWriteAccessDo = function(self, description, fn)
        state.insideWrite = true
        local ok, err = pcall(write, self, description, fn)
        state.insideWrite = false
        if not ok then error(err, 0) end
    end
end

return FakeMaskStore
