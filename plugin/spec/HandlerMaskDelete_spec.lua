local helper = require 'spec_helper'

local function errorOf(fn)
    local ok, err = pcall(fn)
    assert.is_false(ok)
    return tostring(err)
end

local function tool(id)
    return { ID = id, Name = "Tool " .. id, Type = "brush", Hidden = false, Inverted = false }
end

local function mask(id, toolIds)
    local tools = {}
    for _, toolId in ipairs(toolIds) do tools[#tools + 1] = tool(toolId) end
    return { ID = id, Name = "Mask " .. id, Hidden = false, Tools = tools }
end

local function idsOf(masks)
    local ids = {}
    for _, m in ipairs(masks) do ids[#ids + 1] = m.ID end
    return ids
end

local function toolIdsOf(m)
    local ids = {}
    for _, t in ipairs(m.Tools) do ids[#ids + 1] = t.ID end
    return ids
end

local function savedSettingsOf(masks)
    local groups = {}
    for _, m in ipairs(masks) do
        local correctionMasks = {}
        for _, t in ipairs(m.Tools) do correctionMasks[#correctionMasks + 1] = { MaskID = t.ID } end
        groups[#groups + 1] = { CorrectionID = m.ID, CorrectionMasks = correctionMasks }
    end
    return { MaskGroupBasedCorrections = groups }
end

local function copyMasks(masks)
    local copy = {}
    for _, m in ipairs(masks) do
        local tools = {}
        for _, t in ipairs(m.Tools) do tools[#tools + 1] = t end
        copy[#copy + 1] = { ID = m.ID, Name = m.Name, Hidden = m.Hidden, Tools = tools }
    end
    return copy
end

local function setup(opts)
    local photos, masksOf, emptyReadsLeft, frozenSettings = {}, {}, {}, {}
    for _, spec in ipairs(opts.photos) do
        local p = helper.fakePhoto({ id = spec.id, path = "/" .. spec.id .. ".jpg" })
        photos[#photos + 1] = p
        masksOf[p] = spec.masks or {}
        emptyReadsLeft[p] = spec.emptyReadsFirst or 0
        local savedMasks = spec.settingsOnlyMasks or masksOf[p]
        if opts.neverSaves or spec.settingsOnlyMasks then
            frozenSettings[p] = savedSettingsOf(copyMasks(savedMasks))
        end
        p.getDevelopSettings = function()
            return frozenSettings[p] or savedSettingsOf(masksOf[p])
        end
    end
    local active = not opts.nothingSelected and photos[1] or nil
    local module = "library"
    local currentTool = opts.initialTool or "loupe"
    local selectedMaskId
    local calls = {
        modules = {}, selections = {}, tools = {}, selectedMasks = {}, deletedMasks = {},
        deletedTools = {}, deleteAllEmpty = {}, getAllMasks = 0,
    }
    local Handler

    local function requireMaskingTool()
        if module ~= "develop" then error("Develop module is not active") end
        if currentTool ~= "masking" then error("masking tool is not open") end
    end

    local function removeMask(list, id)
        for i, m in ipairs(list) do
            if m.ID == id then
                table.remove(list, i)
                return m
            end
        end
        return nil
    end

    local controller = {
        getAllMasks = function()
            calls.getAllMasks = calls.getAllMasks + 1
            if module ~= "develop" then error("Develop module is not active") end
            if emptyReadsLeft[active] > 0 then
                emptyReadsLeft[active] = emptyReadsLeft[active] - 1
                return {}
            end
            if opts.onGetAllMasks then opts.onGetAllMasks(Handler) end
            return copyMasks(masksOf[active])
        end,
        selectMask = function(id)
            requireMaskingTool()
            selectedMaskId = id
            calls.selectedMasks[#calls.selectedMasks + 1] = id
        end,
        selectMaskTool = function() end,
        selectTool = function(name)
            currentTool = name
            calls.tools[#calls.tools + 1] = name
        end,
        getSelectedTool = function() return currentTool end,
        deleteMask = function(id)
            requireMaskingTool()
            calls.deletedMasks[#calls.deletedMasks + 1] = id
            if opts.deleteFails then error(opts.deleteFails) end
            if opts.ignoreDelete then return end
            removeMask(masksOf[active], id)
        end,
        deleteMaskTool = function(id)
            requireMaskingTool()
            calls.deletedTools[#calls.deletedTools + 1] = id
            if opts.ignoreDelete then return end
            for _, m in ipairs(masksOf[active]) do
                if m.ID == selectedMaskId then
                    for i, t in ipairs(m.Tools) do
                        if t.ID == id then table.remove(m.Tools, i) end
                    end
                    if #m.Tools == 0 and not opts.keepEmptyMasks then
                        removeMask(masksOf[active], m.ID)
                    end
                end
            end
        end,
    }
    if opts.withoutDeleteApi then
        controller.deleteMask, controller.deleteMaskTool = nil, nil
    end

    local view = {
        getCurrentModuleName = function() return module end,
        switchToModule = function(name)
            module = name
            calls.modules[#calls.modules + 1] = name
        end,
    }
    local catalog = helper.fakeCatalog({ photos = photos })
    local recordSelection = catalog.setSelectedPhotos
    catalog.setSelectedPhotos = function(self, photo, selected)
        recordSelection(self, photo, selected)
        active = photo
        calls.selections[#calls.selections + 1] = photo.localIdentifier
    end
    catalog.getTargetPhoto = function() return active end
    catalog.kAllPhotos = "all photographs"
    catalog.getActiveSources = function() return { "folder" } end
    catalog.setActiveSources = function() end
    if not opts.withoutDeleteAllEmptyMasks then
        local withWriteAccess = catalog.withWriteAccessDo
        local insideWrite = false
        catalog.withWriteAccessDo = function(self, title, fn)
            return withWriteAccess(self, title, function()
                insideWrite = true
                local ok, err = pcall(fn)
                insideWrite = false
                if not ok then error(err, 0) end
            end)
        end
        catalog.deleteAllEmptyMasks = function(_, targets)
            if not insideWrite then error("deleteAllEmptyMasks outside withWriteAccessDo") end
            calls.deleteAllEmpty[#calls.deleteAllEmpty + 1] = targets
            for _, p in ipairs(targets) do
                local kept = {}
                for _, m in ipairs(masksOf[p]) do
                    if #m.Tools > 0 then kept[#kept + 1] = m end
                end
                masksOf[p] = kept
            end
        end
    end

    helper.installImport({
        LrApplication = { activeCatalog = function() return catalog end },
        LrApplicationView = view,
        LrDevelopController = controller,
        LrSelection = { selectNone = function() active = nil end },
        LrTasks = { pcall = pcall, sleep = function() end },
        LrLogger = helper.defaultLrLogger(),
    })
    package.loaded.HandlerMaskDelete = nil
    package.loaded.DevelopSession = nil
    Handler = require 'HandlerMaskDelete'
    return Handler, calls, catalog, masksOf, photos
end

local function twoPhotosWithMasks()
    return {
        { id = "1" },
        {
            id = "2",
            masks = {
                mask("m-1", { "t-1", "t-2" }),
                mask("m-2", { "t-3" }),
                mask("m-3", { "t-4" }),
            },
        },
    }
end

describe("HandlerMaskDelete.deleteMasks", function()
    it("deletes the masks named by mask_ids and keeps the others", function()
        local Handler, calls, _, masksOf, photos = setup({ photos = twoPhotosWithMasks() })

        local r = Handler.deleteMasks({ photo_id = "2", mask_ids = { "m-1", "m-3" } })

        assert.is_true(r.success)
        assert.are.equal("2", r.photo_id)
        assert.are.same({ "m-1", "m-3" }, r.deleted_mask_ids)
        assert.are.same({ "t-1", "t-2", "t-4" }, r.deleted_tool_ids)
        assert.are.equal(1, r.remaining_mask_count)
        assert.are.same({ "m-2" }, idsOf(masksOf[photos[2]]))
        assert.are.same({ "m-1", "m-3" }, calls.deletedMasks)
    end)

    it("deletes one component tool and keeps its mask when other tools remain", function()
        local Handler, _, _, masksOf, photos = setup({ photos = twoPhotosWithMasks() })

        local r = Handler.deleteMasks({ photo_id = "2", tool_ids = { "t-2" } })

        assert.are.same({}, r.deleted_mask_ids)
        assert.are.same({ "t-2" }, r.deleted_tool_ids)
        assert.are.equal(3, r.remaining_mask_count)
        assert.are.same({ "t-1" }, toolIdsOf(masksOf[photos[2]][1]))
    end)

    it("removes the mask when its last tool is deleted", function()
        local Handler, _, _, masksOf, photos = setup({ photos = twoPhotosWithMasks() })

        local r = Handler.deleteMasks({ photo_id = "2", tool_ids = { "t-1", "t-2", "t-3" } })

        assert.are.same({ "m-1", "m-2" }, r.deleted_mask_ids)
        assert.are.same({ "t-1", "t-2", "t-3" }, r.deleted_tool_ids)
        assert.are.equal(1, r.remaining_mask_count)
        assert.are.same({ "m-3" }, idsOf(masksOf[photos[2]]))
    end)

    it("deletes the empty mask Lightroom leaves behind after its last tool goes", function()
        local Handler, calls, _, masksOf, photos = setup({
            photos = twoPhotosWithMasks(),
            keepEmptyMasks = true,
        })

        local r = Handler.deleteMasks({ photo_id = "2", tool_ids = { "t-3" } })

        assert.are.same({ "m-2" }, r.deleted_mask_ids)
        assert.are.same({ "m-2" }, calls.deletedMasks)
        assert.are.same({ "m-1", "m-3" }, idsOf(masksOf[photos[2]]))
    end)

    it("deletes every mask with all=true", function()
        local Handler, _, _, masksOf, photos = setup({ photos = twoPhotosWithMasks() })

        local r = Handler.deleteMasks({ photo_id = "2", all = true })

        assert.are.same({ "m-1", "m-2", "m-3" }, r.deleted_mask_ids)
        assert.are.same({ "t-1", "t-2", "t-3", "t-4" }, r.deleted_tool_ids)
        assert.are.equal(0, r.remaining_mask_count)
        assert.are.same({}, masksOf[photos[2]])
    end)

    it("reports nothing deleted for all=true on a photo without masks", function()
        local Handler, calls = setup({ photos = { { id = "1" } } })

        local r = Handler.deleteMasks({ photo_id = "1", all = true })

        assert.is_true(r.success)
        assert.are.same({}, r.deleted_mask_ids)
        assert.are.same({}, r.deleted_tool_ids)
        assert.are.equal(0, r.remaining_mask_count)
        assert.are.same({}, calls.deletedMasks)
    end)

    it("deletes a duplicated mask id once", function()
        local Handler, calls = setup({ photos = twoPhotosWithMasks() })

        local r = Handler.deleteMasks({ photo_id = "2", mask_ids = { "m-2", "m-2" } })

        assert.are.same({ "m-2" }, r.deleted_mask_ids)
        assert.are.same({ "m-2" }, calls.deletedMasks)
    end)

    it("deletes nothing and names every unknown mask id", function()
        local Handler, calls, _, masksOf, photos = setup({ photos = twoPhotosWithMasks() })

        local err = errorOf(function()
            Handler.deleteMasks({ photo_id = "2", mask_ids = { "m-1", "nope", "t-1", "also-nope" } })
        end)

        assert.truthy(err:find("Unknown mask id(s) on photo 2: nope, t-1, also-nope", 1, true))
        assert.truthy(err:find("nothing was deleted", 1, true))
        assert.are.same({}, calls.deletedMasks)
        assert.are.same({ "m-1", "m-2", "m-3" }, idsOf(masksOf[photos[2]]))
        assert.are.same({ "develop", "library" }, calls.modules)
    end)

    it("deletes nothing and names every unknown tool id", function()
        local Handler, calls, _, masksOf, photos = setup({ photos = twoPhotosWithMasks() })

        local err = errorOf(function()
            Handler.deleteMasks({ photo_id = "2", tool_ids = { "t-1", "m-2" } })
        end)

        assert.truthy(err:find("Unknown tool id(s) on photo 2: m-2", 1, true))
        assert.are.same({}, calls.deletedTools)
        assert.are.same({}, calls.deletedMasks)
        assert.are.same({ "t-1", "t-2" }, toolIdsOf(masksOf[photos[2]][1]))
    end)

    it("accepts a call after a rejected one", function()
        local Handler = setup({ photos = twoPhotosWithMasks() })

        errorOf(function() Handler.deleteMasks({ photo_id = "2", mask_ids = { "nope" } }) end)
        local r = Handler.deleteMasks({ photo_id = "2", mask_ids = { "m-1" } })

        assert.are.same({ "m-1" }, r.deleted_mask_ids)
    end)

    it("requires exactly one of mask_ids, tool_ids and all", function()
        local Handler, calls = setup({ photos = twoPhotosWithMasks() })
        local needsOne = "delete_masks needs exactly one of mask_ids, tool_ids or all"

        for _, args in ipairs({
            { photo_id = "2" },
            { photo_id = "2", mask_ids = { "m-1" }, tool_ids = { "t-1" } },
            { photo_id = "2", mask_ids = { "m-1" }, all = true },
        }) do
            assert.truthy(errorOf(function() Handler.deleteMasks(args) end):find(needsOne, 1, true))
        end
        assert.truthy(errorOf(function() Handler.deleteMasks({ photo_id = "2", all = false }) end)
            :find("all must be true", 1, true))
        assert.are.equal(0, #calls.modules)
    end)

    it("rejects malformed id lists before touching Develop", function()
        local Handler, calls = setup({ photos = twoPhotosWithMasks() })
        local tooMany = {}
        for i = 1, 101 do tooMany[i] = "m-" .. i end

        for _, bad in ipairs({ {}, { 7 }, { "" }, "m-1", tooMany }) do
            assert.truthy(errorOf(function() Handler.deleteMasks({ photo_id = "2", mask_ids = bad }) end)
                :find("mask_ids", 1, true))
        end
        assert.are.equal(0, #calls.modules)
    end)

    it("requires a photo id", function()
        local Handler = setup({ photos = twoPhotosWithMasks() })

        for _, bad in ipairs({ "", true }) do
            assert.truthy(errorOf(function() Handler.deleteMasks({ photo_id = bad, all = true }) end)
                :find("photo_id is required", 1, true))
        end
    end)

    it("names the photo id when the photo is unknown and never touches Develop", function()
        local Handler, calls = setup({ photos = twoPhotosWithMasks() })

        local err = errorOf(function() Handler.deleteMasks({ photo_id = "404", all = true }) end)

        assert.truthy(err:find("Photo not found: 404", 1, true))
        assert.are.equal(0, #calls.modules)
    end)

    it("names the minimum Lightroom version when the delete API is missing", function()
        local Handler, calls = setup({ photos = twoPhotosWithMasks(), withoutDeleteApi = true })

        local err = errorOf(function() Handler.deleteMasks({ photo_id = "2", all = true }) end)

        assert.truthy(err:find("delete_masks needs Lightroom Classic 11 or later", 1, true))
        assert.are.equal(0, #calls.modules)
    end)

    it("opens the masking tool for the deletion and puts the previous tool back", function()
        local Handler, calls = setup({ photos = twoPhotosWithMasks(), initialTool = "crop" })

        Handler.deleteMasks({ photo_id = "2", mask_ids = { "m-1" } })

        assert.are.same({ "masking", "crop" }, calls.tools)
    end)

    it("leaves the tool alone when the masking tool is already open", function()
        local Handler, calls = setup({ photos = twoPhotosWithMasks(), initialTool = "masking" })

        Handler.deleteMasks({ photo_id = "2", mask_ids = { "m-1" } })

        assert.are.same({}, calls.tools)
    end)

    it("puts back the module and the selection", function()
        local Handler, calls = setup({ photos = twoPhotosWithMasks() })

        Handler.deleteMasks({ photo_id = "2", all = true })

        assert.are.same({ "develop", "library" }, calls.modules)
        assert.are.same({ "2", "1" }, calls.selections)
    end)

    it("waits until Lightroom reports the masks of a photo that is still loading", function()
        local Handler, _, _, _, photos = setup({
            photos = { { id = "1", masks = { mask("m-1", { "t-1" }) }, emptyReadsFirst = 3 } },
        })

        local r = Handler.deleteMasks({ photo_id = "1", all = true })

        assert.are.same({ "m-1" }, r.deleted_mask_ids)
        assert.is_truthy(photos[1])
    end)

    it("errors instead of reporting success when Lightroom never lists masks the photo has saved", function()
        local Handler, calls = setup({
            photos = { { id = "1", settingsOnlyMasks = { mask("m-1", { "t-1" }) } } },
        })

        local err = errorOf(function() Handler.deleteMasks({ photo_id = "1", all = true }) end)

        assert.truthy(err:find("reports no masks on photo 1", 1, true))
        assert.are.same({}, calls.deletedMasks)
        assert.are.same({ "develop", "library" }, calls.modules)
    end)

    it("errors and restores the view when Lightroom ignores the deletion", function()
        local Handler, calls = setup({ photos = twoPhotosWithMasks(), ignoreDelete = true })

        local err = errorOf(function() Handler.deleteMasks({ photo_id = "2", mask_ids = { "m-1" } }) end)

        assert.truthy(err:find("did not remove the requested masks from photo 2", 1, true))
        assert.are.same({ "develop", "library" }, calls.modules)
        assert.are.same({ "2", "1" }, calls.selections)
    end)

    it("errors when Lightroom shows the deletion but never saves it", function()
        local Handler = setup({ photos = twoPhotosWithMasks(), neverSaves = true })

        local err = errorOf(function() Handler.deleteMasks({ photo_id = "2", mask_ids = { "m-1" } }) end)

        assert.truthy(err:find("did not save it for photo 2", 1, true))
    end)

    it("reports the failing call when Lightroom raises while deleting", function()
        local Handler, calls = setup({ photos = twoPhotosWithMasks(), deleteFails = "mask is locked" })

        local err = errorOf(function() Handler.deleteMasks({ photo_id = "2", mask_ids = { "m-1" } }) end)

        assert.truthy(err:find("could not delete mask m-1: ", 1, true))
        assert.truthy(err:find("mask is locked", 1, true))
        assert.are.same({ "develop", "library" }, calls.modules)
    end)

    it("rejects a second Develop call while one is running", function()
        local nested
        local Handler = setup({
            photos = twoPhotosWithMasks(),
            onGetAllMasks = function(handler)
                if nested == nil then
                    nested = errorOf(function() handler.deleteMasks({ photo_id = "2", all = true }) end)
                end
            end,
        })

        Handler.deleteMasks({ photo_id = "2", mask_ids = { "m-1" } })

        assert.truthy(nested:find("delete_masks is already running", 1, true))
    end)

    it("errors with a clear message when a mask has no id", function()
        local Handler = setup({
            photos = { { id = "1", masks = { { Name = "x", Tools = {} } } } },
        })

        local err = errorOf(function() Handler.deleteMasks({ photo_id = "1", all = true }) end)

        assert.truthy(err:find("mask without an id for photo 1", 1, true))
    end)

    it("never opens a write gate and keeps catalog queries out of the read gate", function()
        local Handler, _, catalog = setup({ photos = twoPhotosWithMasks() })

        Handler.deleteMasks({ photo_id = "2", all = true })

        assert.are.equal(0, catalog.getWriteAccessCount())
        assert.is_false(catalog.getQueriedInsideReadAccess())
    end)
end)

describe("HandlerMaskDelete.deleteMasks with photo_ids", function()
    local function photosWithEmptyMasks()
        return {
            { id = "1", masks = { mask("a", { "t-1" }), mask("empty-a", {}) } },
            { id = "2", masks = { mask("b", { "t-2" }) } },
            { id = "3", masks = { mask("empty-b", {}), mask("empty-c", {}) } },
            { id = "4" },
        }
    end

    it("rejects mixing photo_ids with any single-photo deletion argument before access", function()
        for _, field in ipairs({ "photo_id", "mask_ids", "tool_ids", "all" }) do
            local Handler, calls, catalog, masksOf, photos = setup({ photos = photosWithEmptyMasks() })
            local before = copyMasks(masksOf[photos[1]])
            local args = { photo_ids = { "1" } }
            args[field] = field == "photo_id" and "1" or field == "all" and false or { "a" }

            assert.truthy(errorOf(function() Handler.deleteMasks(args) end):find("photo_ids must be given alone", 1, true))
            assert.are.equal(0, catalog.getWriteAccessCount())
            assert.are.equal(0, #calls.deleteAllEmpty)
            assert.are.equal(0, #calls.modules)
            assert.are.same(before, masksOf[photos[1]])
        end
    end)

    it("does not require the Develop deletion API for empty-mask deletion", function()
        local Handler, calls = setup({ photos = photosWithEmptyMasks(), withoutDeleteApi = true })

        local result = Handler.deleteMasks({ photo_ids = { "1" } })

        assert.are.equal(1, result.photos_changed)
        assert.are.equal(0, #calls.modules)
        assert.are.equal(0, #calls.selections)
    end)

    it("deletes empty masks and counts the photos that changed", function()
        local Handler, _, _, masksOf, photos = setup({ photos = photosWithEmptyMasks() })

        local r = Handler.deleteMasks({ photo_ids = { "1", "2", "3", "4" } })

        assert.is_true(r.success)
        assert.are.equal(2, r.photos_changed)
        assert.are.equal(4, r.photos_checked)
        assert.are.same({}, r.missing)
        assert.are.same({ "a" }, idsOf(masksOf[photos[1]]))
        assert.are.same({ "b" }, idsOf(masksOf[photos[2]]))
        assert.are.same({}, masksOf[photos[3]])
    end)

    it("counts zero when no photo has an empty mask", function()
        local Handler = setup({ photos = photosWithEmptyMasks() })

        local r = Handler.deleteMasks({ photo_ids = { "2", "4" } })

        assert.are.equal(0, r.photos_changed)
        assert.are.equal(2, r.photos_checked)
    end)

    it("only touches the photos it was given", function()
        local Handler, _, _, masksOf, photos = setup({ photos = photosWithEmptyMasks() })

        Handler.deleteMasks({ photo_ids = { "1" } })

        assert.are.same({ "empty-b", "empty-c" }, idsOf(masksOf[photos[3]]))
    end)

    it("accepts numeric ids and file paths and passes each photo once", function()
        local Handler, calls = setup({ photos = photosWithEmptyMasks() })

        local r = Handler.deleteMasks({ photo_ids = { 1, "/1.jpg", "3" } })

        assert.are.equal(2, r.photos_changed)
        assert.are.equal(1, #calls.deleteAllEmpty)
        assert.are.equal(2, #calls.deleteAllEmpty[1])
    end)

    it("reports unknown ids and still processes the known photos", function()
        local Handler = setup({ photos = photosWithEmptyMasks() })

        local r = Handler.deleteMasks({ photo_ids = { "1", "404" } })

        assert.are.equal(1, r.photos_changed)
        assert.are.equal(1, r.photos_checked)
        assert.are.same({ "404" }, r.missing)
    end)

    it("never calls Lightroom with an empty photo list because that targets the whole selection", function()
        local Handler, calls = setup({ photos = photosWithEmptyMasks() })

        local r = Handler.deleteMasks({ photo_ids = { "404", "405" } })

        assert.are.equal(0, r.photos_changed)
        assert.are.equal(0, r.photos_checked)
        assert.are.same({ "404", "405" }, r.missing)
        assert.are.equal(0, #calls.deleteAllEmpty)
    end)

    it("requires a non-empty photo list", function()
        local Handler = setup({ photos = photosWithEmptyMasks() })

        for _, bad in ipairs({ {}, "1", { true }, { "" } }) do
            assert.truthy(errorOf(function() Handler.deleteMasks({ photo_ids = bad }) end)
                :find("photo_ids", 1, true))
        end
        assert.truthy(errorOf(function() Handler.deleteMasks({}) end):find("photo_id is required", 1, true))
    end)

    it("names the minimum Lightroom version when the catalog call is missing", function()
        local Handler, calls = setup({ photos = photosWithEmptyMasks(), withoutDeleteAllEmptyMasks = true })

        local err = errorOf(function() Handler.deleteMasks({ photo_ids = { "1" } }) end)

        assert.truthy(err:find("delete_masks with photo_ids needs Lightroom Classic 14 or later", 1, true))
        assert.are.equal(0, #calls.deleteAllEmpty)
    end)

    it("does not open Develop or change the selection", function()
        local Handler, calls = setup({ photos = photosWithEmptyMasks() })
        local session = require 'DevelopSession'
        session.withPhoto = function() error("empty-mask deletion must not open a Develop session") end

        Handler.deleteMasks({ photo_ids = { "1", "3" } })

        assert.are.equal(0, #calls.modules)
        assert.are.equal(0, #calls.selections)
    end)

    it("resolves photos before the write gate and reads inside read gates only", function()
        local Handler, _, catalog = setup({ photos = photosWithEmptyMasks() })

        Handler.deleteMasks({ photo_ids = { "1", "/3.jpg" } })

        assert.are.equal(1, catalog.getWriteAccessCount())
        assert.is_false(catalog.getQueriedInsideWriteAccess())
        assert.is_false(catalog.getQueriedInsideReadAccess())
    end)
end)
