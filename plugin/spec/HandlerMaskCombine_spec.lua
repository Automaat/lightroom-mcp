local helper = require 'spec_helper'

local function errorOf(fn)
    local ok, err = pcall(fn)
    assert.is_false(ok)
    return tostring(err)
end

local function tool(id, toolType, subtype)
    return { ID = id, Name = toolType .. " " .. id, Type = toolType, Subtype = subtype, Hidden = false, Inverted = false }
end

local function mask(id, tools)
    return { ID = id, Name = "Mask " .. id, Hidden = false, Tools = tools }
end

local function twoMasks()
    return {
        mask("m-1", { tool("t-1", "aiSelection", "subject"), tool("t-2", "gradient") }),
        mask("m-2", { tool("t-3", "aiSelection", "sky") }),
    }
end

local SDK_FUNCTION_OF_OPERATION = {
    add = "addToCurrentMask",
    subtract = "subtractFromCurrentMask",
    intersect = "intersectWithCurrentMask",
}

local function fingerprint(value)
    if type(value) ~= "table" then return tostring(value) end
    local keys = {}
    for key in pairs(value) do keys[#keys + 1] = key end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local parts = {}
    for _, key in ipairs(keys) do
        parts[#parts + 1] = tostring(key) .. "=" .. fingerprint(value[key])
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

local function setup(opts)
    opts = opts or {}
    local masks = opts.masks or twoMasks()
    local settingsGroups = {}
    for index = 1, opts.settingsMaskCount or #masks do settingsGroups[index] = { CorrectionID = tostring(index) } end
    local photo = helper.fakePhoto({
        id = "10",
        path = "/10.jpg",
        developSettings = { MaskGroupBasedCorrections = settingsGroups },
    })
    local other = helper.fakePhoto({ id = "11", path = "/11.jpg" })

    local calls = {
        combined = {},
        selectMask = {},
        tools = {},
        modules = {},
    }
    local polls = 0
    local module = "library"
    local active = photo
    local tool_ = opts.startTool or "loupe"
    local selected = opts.startSelected
    local behavior = opts.behavior or "append"
    local pollsBeforeAppear = opts.pollsBeforeAppear or 0
    local blocked = false
    local combinedAtPoll

    local function findMask(id)
        for _, candidate in ipairs(masks) do
            if candidate.ID == id then return candidate end
        end
        return nil
    end

    local function newComponent(subtype, suffix)
        return tool("new-tool" .. (suffix or ""), "aiSelection", subtype)
    end

    local function applyBehavior(target, subtype)
        if behavior == "append" or behavior == "delayed" then
            target.Tools[#target.Tools + 1] = newComponent(subtype)
        elseif behavior == "double" then
            target.Tools[#target.Tools + 1] = newComponent(subtype, "-1")
            target.Tools[#target.Tools + 1] = newComponent(subtype, "-2")
        elseif behavior == "tamper" then
            target.Tools[1].Inverted = true
        elseif behavior == "alert" then
            blocked = true
        end
    end

    local controller = {
        getAllMasks = function()
            polls = polls + 1
            if module ~= "develop" then error("Develop module is not active") end
            if opts.notReadyPolls and polls <= opts.notReadyPolls then return {} end
            if opts.neverReady then return {} end
            if blocked then return {} end
            return masks
        end,
        selectMask = function(id)
            calls.selectMask[#calls.selectMask + 1] = id
            if not opts.selectIgnored then selected = id end
        end,
        getSelectedMask = function() return selected end,
        selectMaskTool = function() end,
        selectTool = function(name)
            tool_ = name
            calls.tools[#calls.tools + 1] = name
        end,
        getSelectedTool = function() return tool_ end,
    }
    for operation, functionName in pairs(SDK_FUNCTION_OF_OPERATION) do
        controller[functionName] = function(toolType, subtype)
            if module ~= "develop" then error("Develop module is not active") end
            if opts.combineThrows then error(opts.combineThrows) end
            calls.combined[#calls.combined + 1] = {
                operation = operation,
                functionName = functionName,
                toolType = toolType,
                subtype = subtype,
                selectedAtCall = selected,
                toolAtCall = tool_,
            }
            combinedAtPoll = polls
            local target = findMask(selected)
            if behavior == "delayed" then return end
            applyBehavior(target, subtype)
        end
    end
    local getAllMasks = controller.getAllMasks
    controller.getAllMasks = function()
        if behavior == "delayed" and combinedAtPoll and polls - combinedAtPoll == pollsBeforeAppear then
            applyBehavior(findMask(calls.combined[1].selectedAtCall), calls.combined[1].subtype)
        end
        return getAllMasks()
    end
    for _, name in ipairs(opts.withoutFunctions or {}) do controller[name] = nil end

    local catalog = helper.fakeCatalog({ photos = { photo, other } })
    local recordSelection = catalog.setSelectedPhotos
    catalog.setSelectedPhotos = function(self, selectedPhoto, selection)
        recordSelection(self, selectedPhoto, selection)
        active = selectedPhoto
    end
    catalog.getTargetPhoto = function() return active end
    catalog.kAllPhotos = "all photographs"
    catalog.getActiveSources = function() return { "folder" } end
    catalog.setActiveSources = function() end

    helper.installImport({
        LrApplication = { activeCatalog = function() return catalog end },
        LrApplicationView = {
            getCurrentModuleName = function() return module end,
            switchToModule = function(name)
                module = name
                calls.modules[#calls.modules + 1] = name
            end,
        },
        LrDevelopController = controller,
        LrSelection = { selectNone = function() active = nil end },
        LrTasks = { pcall = pcall, sleep = function() end },
        LrLogger = helper.defaultLrLogger(),
    })
    package.loaded.HandlerMaskCombine = nil
    package.loaded.DevelopSession = nil
    package.loaded.MaskTypes = nil
    local Handler = require 'HandlerMaskCombine'
    local state = {
        module = function() return module end,
        tool = function() return tool_ end,
        selected = function() return selected end,
    }
    return Handler, calls, masks, catalog, state
end

local function args(overrides)
    local base = { photo_id = "10", mask_id = "m-1", operation = "add", type = "sky" }
    for key, value in pairs(overrides or {}) do base[key] = value end
    return base
end

describe("HandlerMaskCombine.combineMask", function()
    it("maps each operation to its documented SDK call with the type's tool type and subtype", function()
        local expectedSubtype = { subject = "subject", sky = "sky", background = "background" }
        for operation, functionName in pairs(SDK_FUNCTION_OF_OPERATION) do
            for typeName, subtype in pairs(expectedSubtype) do
                local Handler, calls = setup({})

                local r = Handler.combineMask(args({ operation = operation, type = typeName }))

                assert.is_true(r.success)
                assert.are.equal(operation, r.operation)
                assert.are.equal(typeName, r.type)
                assert.are.equal(1, #calls.combined)
                assert.are.equal(functionName, calls.combined[1].functionName)
                assert.are.equal("aiSelection", calls.combined[1].toolType)
                assert.are.equal(subtype, calls.combined[1].subtype)
            end
        end
    end)

    it("returns the new component id and the updated mask", function()
        local Handler = setup({})

        local r = Handler.combineMask(args({ type = "subject" }))

        assert.are.equal("10", r.photo_id)
        assert.are.equal("m-1", r.mask_id)
        assert.are.equal("new-tool", r.tool_id)
        assert.are.same({ id = "new-tool", type = "aiSelection", subtype = "subject", inverted = false }, r.tool)
        assert.are.equal("m-1", r.mask.id)
        assert.are.equal(3, #r.mask.tools)
        assert.are.equal("new-tool", r.mask.tools[3].id)
    end)

    it("picks the new component out of tools that were already there", function()
        local Handler = setup({
            masks = { mask("m-1", { tool("a", "aiSelection", "sky"), tool("b", "aiSelection", "sky") }) },
        })

        local r = Handler.combineMask(args({ operation = "subtract" }))

        assert.are.equal("new-tool", r.tool_id)
    end)

    it("selects the named mask and verifies it before calling Lightroom, whatever was selected", function()
        local Handler, calls = setup({ startSelected = "m-2" })

        Handler.combineMask(args({ mask_id = "m-1" }))

        assert.are.equal("m-1", calls.combined[1].selectedAtCall)
        assert.are.equal("masking", calls.combined[1].toolAtCall)
        assert.are.equal("m-1", calls.selectMask[1])
    end)

    it("combines into the second mask without touching the first", function()
        local Handler, _, masks = setup({})
        local firstBefore = fingerprint(masks[1])

        local r = Handler.combineMask(args({ mask_id = "m-2", operation = "intersect" }))

        assert.are.equal("m-2", r.mask_id)
        assert.are.equal(firstBefore, fingerprint(masks[1]))
        assert.are.equal(2, #masks[2].Tools)
    end)

    it("puts back the previous mask, tool, module and photo", function()
        local Handler, calls, _, _, state = setup({ startSelected = "m-2", startTool = "crop" })

        Handler.combineMask(args({ mask_id = "m-1" }))

        assert.are.equal("m-2", state.selected())
        assert.are.equal("crop", state.tool())
        assert.are.equal("library", state.module())
        assert.are.same({ "develop", "library" }, calls.modules)
    end)

    it("leaves the Masking tool open when it was already open", function()
        local Handler, calls, _, _, state = setup({ startTool = "masking", startSelected = "m-1" })

        Handler.combineMask(args())

        assert.are.equal("masking", state.tool())
        assert.are.same({ "masking" }, calls.tools)
    end)

    it("waits for a slow detection before reporting the component", function()
        local Handler = setup({ behavior = "delayed", pollsBeforeAppear = 25 })

        local r = Handler.combineMask(args())

        assert.are.equal("new-tool", r.tool_id)
    end)

    it("waits out a Develop session that is not ready yet", function()
        local Handler = setup({ notReadyPolls = 5 })

        local r = Handler.combineMask(args())

        assert.are.equal("new-tool", r.tool_id)
    end)

    it("never opens a catalog write gate", function()
        local Handler, _, _, catalog = setup({})

        Handler.combineMask(args())

        assert.are.equal(0, catalog.getWriteAccessCount())
    end)

    it("accepts a numeric photo id and a file path", function()
        local Handler = setup({})
        assert.are.equal("10", Handler.combineMask(args({ photo_id = 10 })).photo_id)

        local PathHandler = setup({})
        assert.is_true(PathHandler.combineMask(args({ photo_id = "/10.jpg" })).success)
    end)
end)

describe("HandlerMaskCombine.combineMask when nothing changes", function()
    it("returns an error before changing anything for an unknown mask id", function()
        local Handler, calls, masks = setup({})
        local before = fingerprint(masks)

        local err = errorOf(function() Handler.combineMask(args({ mask_id = "nope" })) end)

        assert.truthy(err:find("Mask not found on photo 10: nope", 1, true))
        assert.are.equal(0, #calls.combined)
        assert.are.equal(0, #calls.selectMask)
        assert.are.same({}, calls.tools)
        assert.are.equal(before, fingerprint(masks))
    end)

    it("returns an error for a photo without masks", function()
        local Handler, calls = setup({ masks = {} })

        local err = errorOf(function() Handler.combineMask(args()) end)

        assert.truthy(err:find("Mask not found on photo 10: m-1", 1, true))
        assert.are.equal(0, #calls.combined)
    end)

    it("restores the module after an unknown mask id", function()
        local Handler, _, _, _, state = setup({})

        errorOf(function() Handler.combineMask(args({ mask_id = "nope" })) end)

        assert.are.equal("library", state.module())
    end)

    it("fails without calling Lightroom when the masks cannot be read", function()
        local Handler, calls = setup({ neverReady = true })

        local err = errorOf(function() Handler.combineMask(args()) end)

        assert.truthy(err:find("could not read the masks of photo 10", 1, true))
        assert.truthy(err:find("nothing was changed", 1, true))
        assert.are.equal(0, #calls.combined)
    end)

    it("fails without calling Lightroom when the mask cannot be selected", function()
        local Handler, calls, masks = setup({ selectIgnored = true, startSelected = "m-2" })
        local before = fingerprint(masks)

        local err = errorOf(function() Handler.combineMask(args()) end)

        assert.truthy(err:find("Could not select mask m-1 on photo 10", 1, true))
        assert.are.equal(0, #calls.combined)
        assert.are.equal(before, fingerprint(masks))
    end)

    it("reports nothing found, tells the caller to dismiss the alert and leaves the mask unchanged", function()
        local Handler, calls, masks, _, state = setup({ behavior = "nothing", startTool = "crop" })
        local before = fingerprint(masks)

        local err = errorOf(function() Handler.combineMask(args({ operation = "subtract", type = "sky" })) end)

        assert.truthy(err:find("Lightroom found no sky to subtract from mask m-1 on photo 10", 1, true))
        assert.truthy(err:find("No sky detected", 1, true))
        assert.truthy(err:find("click OK in Lightroom", 1, true))
        assert.truthy(err:find("mask m-1 is unchanged", 1, true))
        assert.are.equal(1, #calls.combined)
        assert.are.equal(before, fingerprint(masks))
        assert.are.equal("crop", state.tool())
        assert.are.equal("library", state.module())
    end)

    it("says to check the mask afterwards when the alert hides every mask", function()
        local Handler = setup({ behavior = "alert" })

        local err = errorOf(function() Handler.combineMask(args({ type = "background" })) end)

        assert.truthy(err:find("Lightroom found no background to add to mask m-1", 1, true))
        assert.truthy(err:find("click OK in Lightroom", 1, true))
        assert.truthy(err:find("check mask m-1 with list_masks afterwards", 1, true))
    end)

    it("reports a mask that changed without gaining a component", function()
        local Handler = setup({ behavior = "tamper" })

        local err = errorOf(function() Handler.combineMask(args({ operation = "intersect" })) end)

        assert.truthy(err:find("changed mask m-1 on photo 10 without adding a sky component (intersect)", 1, true))
    end)

    it("reports more than one new component instead of guessing which is the right one", function()
        local Handler = setup({ behavior = "double" })

        local err = errorOf(function() Handler.combineMask(args()) end)

        assert.truthy(err:find("added 2 components to mask m-1", 1, true))
    end)

    it("reports an SDK call that throws", function()
        local Handler, _, _, _, state = setup({ combineThrows = "boom", startTool = "crop" })

        local err = errorOf(function() Handler.combineMask(args({ operation = "subtract" })) end)

        assert.truthy(err:find("Lightroom could not run subtractFromCurrentMask on mask m-1", 1, true))
        assert.truthy(err:find("boom", 1, true))
        assert.are.equal("crop", state.tool())
        assert.are.equal("library", state.module())
    end)
end)

describe("HandlerMaskCombine.combineMask arguments", function()
    it("requires a photo id, a mask id, an operation and a type", function()
        local Handler = setup({})

        assert.truthy(errorOf(function() Handler.combineMask(args({ photo_id = "" })) end)
            :find("photo_id is required", 1, true))
        assert.truthy(errorOf(function() Handler.combineMask(args({ mask_id = "" })) end)
            :find("mask_id is required", 1, true))
        assert.truthy(errorOf(function() Handler.combineMask(args({ mask_id = 5 })) end)
            :find("mask_id is required", 1, true))
        assert.truthy(errorOf(function() Handler.combineMask(args({ operation = "invert" })) end)
            :find("operation must be one of: add, subtract, intersect", 1, true))
        assert.truthy(errorOf(function() Handler.combineMask(args({ operation = false })) end)
            :find("operation must be one of", 1, true))
        assert.truthy(errorOf(function() Handler.combineMask(args({ type = "people" })) end)
            :find("type must be one of: subject, sky, background", 1, true))
        assert.truthy(errorOf(function() Handler.combineMask(args({ type = 3 })) end)
            :find("type must be one of", 1, true))
    end)

    it("rejects bad arguments before Develop is touched", function()
        local Handler, calls = setup({})

        errorOf(function() Handler.combineMask(args({ operation = "invert" })) end)

        assert.are.equal(0, #calls.modules)
        assert.are.equal(0, #calls.combined)
    end)

    it("names the photo id when the photo is unknown and never touches Develop", function()
        local Handler, calls = setup({})

        local err = errorOf(function() Handler.combineMask(args({ photo_id = "404" })) end)

        assert.truthy(err:find("Photo not found: 404", 1, true))
        assert.are.equal(0, #calls.modules)
    end)

    it("names the minimum Lightroom version when the operation's SDK function is missing", function()
        for operation, functionName in pairs(SDK_FUNCTION_OF_OPERATION) do
            local Handler, calls = setup({ withoutFunctions = { functionName } })

            local err = errorOf(function() Handler.combineMask(args({ operation = operation })) end)

            assert.truthy(err:find("combine_mask needs Lightroom Classic 11 or later", 1, true))
            assert.are.equal(0, #calls.modules)
        end
    end)

    it("does not need the other operations' SDK functions", function()
        local Handler = setup({ withoutFunctions = { "subtractFromCurrentMask", "intersectWithCurrentMask" } })

        assert.is_true(Handler.combineMask(args({ operation = "add" })).success)
    end)

    it("names the older mask API requirement when mask reading is missing", function()
        local Handler = setup({ withoutFunctions = { "getAllMasks" } })

        local err = errorOf(function() Handler.combineMask(args()) end)

        assert.truthy(err:find("combine_mask needs Lightroom Classic 11 or later", 1, true))
    end)
end)
