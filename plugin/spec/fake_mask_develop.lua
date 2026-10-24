local helper = require 'spec_helper'

local M = {}

function M.deepCopy(value)
    if type(value) ~= "table" then return value end
    local copied = {}
    for key, item in pairs(value) do copied[key] = M.deepCopy(item) end
    return copied
end

function M.build(opts)
    local photos, valuesOf, selectedMaskOf = {}, {}, {}
    for index, spec in ipairs(opts.photos) do
        local photo = helper.fakePhoto({ id = spec.id, path = "/" .. spec.id .. ".jpg" })
        photos[index] = photo
        valuesOf[photo] = spec.masks or {}
        selectedMaskOf[photo] = spec.selectedMask
    end

    local ctx = {
        active = photos[1],
        module = "library",
        sources = { "folder" },
        valuesOf = valuesOf,
        selectedMaskOf = selectedMaskOf,
        photos = photos,
        calls = { setValue = {}, selectMask = {}, modules = {}, selections = {}, goToMasking = 0 },
    }

    function ctx.currentValues()
        local selected = selectedMaskOf[ctx.active]
        return selected and valuesOf[ctx.active][selected] or nil
    end

    function ctx.requireMask()
        local values = ctx.currentValues()
        if not values then error("no mask selected") end
        return values
    end

    local controller = {
        getAllMasks = function()
            if ctx.module ~= "develop" then error("Develop module is not active") end
            local masks = {}
            for id in pairs(valuesOf[ctx.active]) do masks[#masks + 1] = { ID = id, Name = id, Tools = {} } end
            table.sort(masks, function(a, b) return a.ID < b.ID end)
            return masks
        end,
        goToMasking = function() ctx.calls.goToMasking = ctx.calls.goToMasking + 1 end,
        selectMaskTool = function() end,
        selectMask = function(id)
            ctx.calls.selectMask[#ctx.calls.selectMask + 1] = id
            if valuesOf[ctx.active][id] then selectedMaskOf[ctx.active] = id end
        end,
        getSelectedMask = function()
            if ctx.calls.goToMasking == 0 then error("masking tool is not open") end
            return selectedMaskOf[ctx.active]
        end,
        getValue = function(name)
            local value = ctx.requireMask()[name]
            return M.deepCopy(value)
        end,
        setValue = function(name, value)
            ctx.calls.setValue[#ctx.calls.setValue + 1] = { name, M.deepCopy(value) }
            local values = ctx.requireMask()
            if opts.rejectSet and opts.rejectSet[name] then error(opts.rejectSet[name]) end
            if opts.ignoreSet and opts.ignoreSet[name] then return end
            values[name] = M.deepCopy(value)
        end,
    }
    ctx.controller = controller
    if opts.extend then opts.extend(controller, ctx) end

    local catalog = helper.fakeCatalog({ photos = photos })
    catalog.setSelectedPhotos = function(_, photo)
        ctx.active = photo
        ctx.calls.selections[#ctx.calls.selections + 1] = photo.localIdentifier
    end
    catalog.getTargetPhoto = function() return ctx.active end
    catalog.getTargetPhotos = function() return { ctx.active } end
    catalog.kAllPhotos = "all photographs"
    catalog.getActiveSources = function() return ctx.sources end
    catalog.setActiveSources = function(_, newSources) ctx.sources = newSources end

    local lrApplication = { activeCatalog = function() return catalog end }
    if opts.version ~= false then
        lrApplication.versionTable = function() return opts.version or { major = 15, minor = 6 } end
    end

    helper.installImport({
        LrApplication = lrApplication,
        LrApplicationView = {
            getCurrentModuleName = function() return ctx.module end,
            switchToModule = function(name)
                ctx.module = name
                ctx.calls.modules[#ctx.calls.modules + 1] = name
            end,
        },
        LrDevelopController = controller,
        LrSelection = { selectNone = function() ctx.active = nil end },
        LrTasks = {
            pcall = pcall,
            sleep = function()
                if opts.onSleep then opts.onSleep(ctx) end
            end,
        },
        LrLogger = helper.defaultLrLogger(),
    })
    for _, name in ipairs(opts.modules) do package.loaded[name] = nil end
    ctx.Handler = require(opts.handler)
    return ctx
end

return M
