local helper = require 'spec_helper'

-- Mirrors the real SDK: LrFileUtils.exists returns 'file' / 'directory' / false,
-- and LrFileUtils.isDirectory is intentionally absent (nil on some Lightroom
-- Classic runtimes -- issue #129).
--
-- Two omissions here are deliberate and load-bearing:
--   * no `extension` -- that field lives on LrPathUtils, not LrFileUtils.
--   * no `files`     -- the handler must walk nested subfolders via
--                       recursiveFiles; a plain files() walk misses them.
-- Providing either would let a regression to the wrong API pass green, which
-- is precisely how both bugs shipped.
local function fakeFileUtils(opts)
    local function volumeForm(p)
        local form = p
        if opts.caseInsensitiveVolume then form = form:lower() end
        if opts.normalizationInsensitiveVolume then form = form:gsub("e\204\129", "\195\169") end
        return form
    end
    local function matches(known, p)
        for candidate in pairs(known or {}) do
            if volumeForm(candidate) == volumeForm(p) then
                return true
            end
        end
        return false
    end
    return {
        exists = function(p)
            if matches(opts.directories, p) then return 'directory' end
            if matches(opts.exists, p) then return 'file' end
            return false
        end,
        directoryEntries = function(dir)
            local entries = {}
            for _, known in ipairs({ opts.exists or {}, opts.directories or {} }) do
                for p in pairs(known) do
                    if p:match("^(.*)/[^/]+$") == dir then entries[#entries + 1] = p end
                end
            end
            table.sort(entries)
            local i = 0
            return function()
                i = i + 1
                return entries[i]
            end
        end,
        copy = function(source, target)
            if opts.copyFails then return false end
            opts.exists[target] = true
            opts.copies = opts.copies or {}
            opts.copies[#opts.copies + 1] = { source, target }
            return true
        end,
        createAllDirectories = function(dir)
            opts.directories = opts.directories or {}
            opts.directories[dir] = true
            return true
        end,
        fileAttributes = function(p) return { fileSize = (opts.sizes or {})[p] or 1 } end,
        readFile = function(p) return (opts.contents or {})[p] or "same" end,
        chooseUniqueFileName = function(p) return (p:gsub("(%.[^.]+)$", "-2%1")) end,
        recursiveFiles = function(_)
            local i = 0
            local list = opts.dirContents or {}
            return function()
                i = i + 1
                return list[i]
            end
        end,
    }
end

-- extension() belongs to LrPathUtils in the real SDK.
local function fakePathUtils()
    return {
        extension = function(p) return p:match("%.([^.]+)$") or "" end,
        removeExtension = function(p) return (p:gsub("%.[^.]+$", "")) end,
        leafName = function(p) return p:match("([^/]+)$") end,
        parent = function(p) return p:match("^(.*)/[^/]+$") end,
        child = function(parent, child) return parent .. "/" .. child end,
    }
end

local function setup(opts)
    local catalog = helper.fakeCatalog({ collectionSets = opts.collectionSets, collections = opts.collections or {}, photos = opts.photos, folders = opts.folders })
    helper.installImport({
        LrApplication = { activeCatalog = function() return catalog end },
        LrLogger = helper.defaultLrLogger(),
        LrTasks = { pcall = pcall, sleep = function() end },
        LrFileUtils = fakeFileUtils(opts.fs or {}),
        LrPathUtils = fakePathUtils(),
    })
    package.loaded.HandlerImport = nil
    return catalog, require 'HandlerImport'
end

local function importedPaths(catalog)
    local paths = {}
    for _, photo in ipairs(catalog:getAllPhotos()) do
        paths[#paths + 1] = photo:getRawMetadata('path')
    end
    return paths
end

describe("HandlerImport.importPhotos", function()
    describe("collection_name", function()
        local function folder(extra)
            local opts = {
                fs = { directories = { ["/dir"] = true }, dirContents = { "/dir/a.jpg", "/dir/b.jpg" } },
            }
            for key, value in pairs(extra) do opts[key] = value end
            return setup(opts)
        end

        it("fails before importing when the collection does not exist", function()
            local catalog, Handler = folder({})
            local ok, err = pcall(Handler.importPhotos, { source_path = "/dir", collection_name = "Trip" })
            assert.is_false(ok)
            assert.truthy(tostring(err):find("Collection not found: Trip", 1, true))
            assert.are.equal(0, #catalog:getAllPhotos())
        end)

        it("refuses a smart collection before importing", function()
            local smart = helper.fakeCollection("Smart", {}, { smart = true })
            local catalog, Handler = folder({ collections = { smart } })
            local ok, err = pcall(Handler.importPhotos, { source_path = "/dir", collection_name = "Smart" })
            assert.is_false(ok)
            assert.truthy(tostring(err):find("smart collection", 1, true))
            assert.are.equal(0, #catalog:getAllPhotos())
        end)

        it("adds new and already cataloged photos, including to a nested path", function()
            local nested = helper.fakeCollection("City", {})
            local set = helper.fakeCollectionSet("Trips", { collections = { nested } })
            local existing = helper.fakePhoto({ path = "/dir/a.jpg", id = "/dir/a.jpg" })
            local _, Handler = folder({ collectionSets = { set }, photos = { existing } })

            local r = Handler.importPhotos({ source_path = "/dir", collection_name = "Trips / City" })

            assert.are.equal(2, r.added_to_collection)
            assert.are.equal(2, #nested.getAddedPhotos())
        end)
    end)

    describe("a file Lightroom cannot import", function()
        it("still imports the others, reports it and fills the collection", function()
            local collection = helper.fakeCollection("Shoot", {})
            local catalog, Handler = setup({
                collections = { collection },
                fs = { directories = { ["/dir"] = true }, dirContents = { "/dir/a.jpg", "/dir/bad.jpg", "/dir/c.jpg" } },
            })
            local addPhoto = catalog.addPhoto
            catalog.addPhoto = function(self, path)
                if path == "/dir/bad.jpg" then error("dng_error_bad_format") end
                return addPhoto(self, path)
            end

            local r = Handler.importPhotos({ source_path = "/dir", collection_name = "Shoot" })

            assert.is_false(r.success)
            assert.are.equal(2, r.imported)
            assert.are.equal("/dir/bad.jpg", r.failed[1].path)
            assert.truthy(r.failed[1].error:find("dng_error_bad_format", 1, true))
            assert.are.equal(2, #collection.getAddedPhotos())
        end)

        it("names the file when a single import fails", function()
            local catalog, Handler = setup({ fs = { exists = { ["/a.jpg"] = true } } })
            catalog.addPhoto = function() error("dng_error_bad_format") end
            local ok, err = pcall(Handler.importPhotos, { source_path = "/a.jpg" })
            assert.is_false(ok)
            assert.truthy(tostring(err):find("/a.jpg: ", 1, true))
        end)
    end)

    it("skips the contents of a library package chosen as the source", function()
        local _, Handler = setup({
            fs = {
                directories = { ["/x.lrdata"] = true },
                dirContents = { "/x.lrdata/0/a.dng" },
            },
        })
        local ok, err = pcall(Handler.importPhotos, { source_path = "/x.lrdata" })
        assert.is_false(ok)
        assert.truthy(tostring(err):find("library packages", 1, true), tostring(err))
    end)

    it("skips files inside library packages", function()
        local catalog, Handler = setup({
            fs = {
                directories = { ["/dir"] = true },
                dirContents = { "/dir/top.jpg", "/dir/Cat Previews.lrdata/0/a.dng", "/dir/x.LRLIBRARY/b.jpg" },
            },
        })
        local r = Handler.importPhotos({ source_path = "/dir" })
        assert.are.equal(1, r.imported)
        assert.are.equal(2, r.skipped_package_files)
        assert.are.same({ "/dir/top.jpg" }, importedPaths(catalog))
    end)

    describe("copy_to", function()
        it("imports a copy that keeps subfolders and brings sidecars along", function()
            local fs = {
                directories = { ["/card"] = true },
                exists = { ["/card/d/a.arw"] = true },
                dirContents = { "/card/d/a.arw", "/card/d/a.jpg", "/card/d/a.xmp" },
            }
            local catalog, Handler = setup({ fs = fs })

            local r = Handler.importPhotos({ source_path = "/card", copy_to = "/archive" })

            assert.are.equal(1, r.imported)
            assert.are.same({ "/archive/d/a.arw" }, importedPaths(catalog))
            local copied = {}
            for _, pair in ipairs(fs.copies) do copied[pair[2]] = pair[1] end
            assert.are.equal("/card/d/a.arw", copied["/archive/d/a.arw"])
            assert.are.equal("/card/d/a.jpg", copied["/archive/d/a.jpg"])
            assert.are.equal("/card/d/a.xmp", copied["/archive/d/a.xmp"])
        end)

        it("reuses an identical copy and renames a different file in the way", function()
            local fs = {
                exists = { ["/card/a.jpg"] = true, ["/archive/a.jpg"] = true },
                sizes = { ["/archive/a.jpg"] = 1 },
            }
            local catalog, Handler = setup({ fs = fs })
            Handler.importPhotos({ source_path = "/card/a.jpg", copy_to = "/archive" })
            assert.is_nil(fs.copies)
            assert.are.same({ "/archive/a.jpg" }, importedPaths(catalog))

            fs.sizes["/archive/a.jpg"] = 2
            fs.exists["/card/b.jpg"] = true
            fs.exists["/archive/b.jpg"] = true
            fs.sizes["/archive/b.jpg"] = 2
            Handler.importPhotos({ source_path = "/card/b.jpg", copy_to = "/archive" })
            assert.are.equal("/archive/b-2.jpg", fs.copies[1][2])
        end)

        it("does not reuse a same-size file with different content", function()
            local fs = {
                exists = { ["/card/a.arw"] = true, ["/archive/a.arw"] = true },
                contents = { ["/card/a.arw"] = "new", ["/archive/a.arw"] = "old" },
            }
            local _, Handler = setup({ fs = fs })
            Handler.importPhotos({ source_path = "/card/a.arw", copy_to = "/archive" })
            assert.are.equal("/archive/a-2.arw", fs.copies[1][2])
        end)

        it("still copies a missing companion when reusing the main file", function()
            local fs = {
                exists = { ["/card/a.arw"] = true, ["/card/a.xmp"] = true, ["/archive/a.arw"] = true },
            }
            local _, Handler = setup({ fs = fs })
            Handler.importPhotos({ source_path = "/card/a.arw", copy_to = "/archive" })
            assert.are.same({ { "/card/a.xmp", "/archive/a.xmp" } }, fs.copies)
        end)

        it("copies a single raw's sidecar JPEG unless JPEGs stay separate", function()
            local fs = { exists = { ["/card/a.arw"] = true, ["/card/a.jpg"] = true } }
            local _, Handler = setup({ fs = fs })
            Handler.importPhotos({ source_path = "/card/a.arw", copy_to = "/archive" })
            assert.are.same({ { "/card/a.arw", "/archive/a.arw" }, { "/card/a.jpg", "/archive/a.jpg" } }, fs.copies)

            local separate = { exists = { ["/card/a.arw"] = true, ["/card/a.jpg"] = true } }
            local _, SeparateHandler = setup({ fs = separate })
            SeparateHandler.importPhotos({ source_path = "/card/a.arw", copy_to = "/archive", separate_jpegs = true })
            assert.are.same({ { "/card/a.arw", "/archive/a.arw" } }, separate.copies)
        end)

        it("fails a single import when the copy fails", function()
            local _, Handler = setup({ fs = { copyFails = true, exists = { ["/card/a.jpg"] = true } } })
            local ok, err = pcall(Handler.importPhotos, { source_path = "/card/a.jpg", copy_to = "/archive" })
            assert.is_false(ok)
            assert.truthy(tostring(err):find("could not copy", 1, true))
        end)
    end)

    describe("files already in the catalog", function()
        local function setupFolder(existingPaths, dirContents)
            local photos = {}
            for _, path in ipairs(existingPaths) do
                photos[#photos + 1] = helper.fakePhoto({ path = path, id = path })
            end
            return setup({
                photos = photos,
                fs = { directories = { ["/dir"] = true }, dirContents = dirContents },
            })
        end

        it("adds the new photo and reports the existing ones", function()
            local catalog, Handler = setupFolder({ "/dir/a.arw", "/dir/b.jpg" }, { "/dir/a.arw", "/dir/b.jpg", "/dir/c.arw" })
            local added = {}
            local addPhoto = catalog.addPhoto
            catalog.addPhoto = function(self, path)
                added[#added + 1] = path
                return addPhoto(self, path)
            end

            local r = Handler.importPhotos({ source_path = "/dir" })

            assert.are.same({ "/dir/c.arw" }, added)
            assert.are.equal(1, r.imported)
            assert.are.equal(2, r.already_in_catalog)
            assert.is_true(r.complete)
            assert.is_false(catalog:getQueriedInsideWriteAccess())
        end)

        it("does not count a sidecar JPEG as already in the catalog", function()
            local _, Handler = setupFolder({ "/dir/a.arw" }, { "/dir/a.arw", "/dir/a.jpg" })

            local r = Handler.importPhotos({ source_path = "/dir" })

            assert.are.equal(0, r.imported)
            assert.are.equal(1, r.already_in_catalog)
            assert.are.equal(1, r.skipped_sidecar_jpegs)
        end)

        it("reports a single file that is already in the catalog", function()
            local catalog, Handler = setup({
                photos = { helper.fakePhoto({ path = "/dir/a.arw", id = "/dir/a.arw" }) },
                fs = { exists = { ["/dir/a.arw"] = true } },
            })

            local r = Handler.importPhotos({ source_path = "/dir/a.arw" })

            assert.is_true(r.success)
            assert.are.equal(0, r.imported)
            assert.are.equal(1, r.already_in_catalog)
            assert.are.equal(1, #catalog:getAllPhotos())
        end)

        it("counts a file renamed in case only as already in the catalog", function()
            local _, Handler = setup({
                photos = { helper.fakePhoto({ path = "/dir/A.arw", id = "/dir/A.arw" }) },
                fs = {
                    caseInsensitiveVolume = true,
                    directories = { ["/dir"] = true },
                    dirContents = { "/dir/a.arw", "/dir/new.arw" },
                    exists = { ["/dir/a.arw"] = true, ["/dir/new.arw"] = true },
                },
            })

            local r = Handler.importPhotos({ source_path = "/dir" })

            assert.are.equal(1, r.imported)
            assert.are.equal(1, r.already_in_catalog)
        end)

        it("counts a lowercase path to an all-caps file on a case-insensitive volume", function()
            local _, Handler = setup({
                photos = { helper.fakePhoto({ path = "/dir/A.JPG", id = "/dir/A.JPG" }) },
                fs = { caseInsensitiveVolume = true, exists = { ["/dir/A.JPG"] = true } },
            })

            local r = Handler.importPhotos({ source_path = "/dir/a.jpg" })

            assert.are.equal(0, r.imported)
            assert.are.equal(1, r.already_in_catalog)
        end)

        describe("on a case-sensitive volume", function()
            local function volume(extra)
                local files = { ["/dir/A.jpg"] = true, ["/dir/a.jpg"] = true }
                for path in pairs(extra.exists or {}) do files[path] = true end
                local fs = {
                    directories = { ["/dir"] = true, ["/dest"] = true },
                    dirContents = extra.dirContents,
                    exists = files,
                }
                local catalog, Handler = setup({ photos = extra.photos, fs = fs })
                local added = {}
                local addPhoto = catalog.addPhoto
                catalog.addPhoto = function(self, path)
                    added[#added + 1] = path
                    return addPhoto(self, path)
                end
                catalog.getFolderByPath = function(_, folderPath)
                    local inFolder = {}
                    for _, photo in ipairs(catalog:getAllPhotos()) do
                        if photo:getRawMetadata('path'):match("^(.*)/[^/]+$") == folderPath then
                            inFolder[#inFolder + 1] = photo
                        end
                    end
                    return { getPhotos = function() return inFolder end }
                end
                return Handler, added, fs
            end

            it("refuses a file beside a catalog entry that differs only in case", function()
                local Handler, added = volume({
                    photos = { helper.fakePhoto({ path = "/dir/A.jpg", id = "/dir/A.jpg" }) },
                })

                local ok, err = pcall(Handler.importPhotos, { source_path = "/dir/a.jpg" })

                assert.is_false(ok)
                assert.truthy(tostring(err):find("/dir/a.jpg: differs only in case from /dir/A.jpg", 1, true))
                assert.are.same({}, added)
            end)

            it("lists the file in failed and counts the catalog entry in a folder import", function()
                local Handler, added = volume({
                    photos = { helper.fakePhoto({ path = "/dir/A.jpg", id = "/dir/A.jpg" }) },
                    dirContents = { "/dir/A.jpg", "/dir/a.jpg" },
                })

                local r = Handler.importPhotos({ source_path = "/dir" })

                assert.are.equal(0, r.imported)
                assert.are.equal(1, r.already_in_catalog)
                assert.is_false(r.success)
                assert.are.equal(1, #r.failed)
                assert.are.equal("/dir/a.jpg", r.failed[1].path)
                assert.truthy(r.failed[1].error:find("differs only in case from /dir/A.jpg", 1, true))
                assert.are.same({}, added)
            end)

            it("imports the first of two spellings in one call and refuses the second", function()
                local Handler, added = volume({ dirContents = { "/dir/A.jpg", "/dir/a.jpg" } })

                local r = Handler.importPhotos({ source_path = "/dir" })

                assert.are.equal(1, r.imported)
                assert.are.same({ "/dir/A.jpg" }, added)
                assert.are.equal("/dir/a.jpg", r.failed[1].path)
            end)

            it("refuses it from the other side too", function()
                local Handler, added = volume({
                    photos = { helper.fakePhoto({ path = "/dir/a.jpg", id = "/dir/a.jpg" }) },
                })

                local ok, err = pcall(Handler.importPhotos, { source_path = "/dir/A.jpg" })

                assert.is_false(ok)
                assert.truthy(tostring(err):find("differs only in case from /dir/a.jpg", 1, true))
                assert.are.same({}, added)
            end)

            it("counts both spellings when the catalog already holds both", function()
                local Handler, added = volume({
                    photos = {
                        helper.fakePhoto({ path = "/dir/A.jpg", id = "/dir/A.jpg" }),
                        helper.fakePhoto({ path = "/dir/a.jpg", id = "/dir/a.jpg" }),
                    },
                    dirContents = { "/dir/A.jpg", "/dir/a.jpg" },
                })

                local r = Handler.importPhotos({ source_path = "/dir" })

                assert.are.equal(0, r.imported)
                assert.are.equal(2, r.already_in_catalog)
                assert.is_nil(r.failed)
                assert.are.same({}, added)
            end)

            it("refuses a copy_to target before copying the file", function()
                local Handler, added, fs = volume({
                    photos = { helper.fakePhoto({ path = "/dest/A.jpg", id = "/dest/A.jpg" }) },
                    exists = { ["/card/a.jpg"] = true, ["/dest/A.jpg"] = true },
                })

                local ok, err = pcall(Handler.importPhotos, { source_path = "/card/a.jpg", copy_to = "/dest" })

                assert.is_false(ok)
                assert.truthy(tostring(err):find("/dest/a.jpg: differs only in case from /dest/A.jpg", 1, true))
                assert.is_nil(fs.copies)
                assert.are.same({}, added)
            end)

            it("still counts the exact path as already in the catalog", function()
                local Handler, added = volume({
                    photos = { helper.fakePhoto({ path = "/dir/a.jpg", id = "/dir/a.jpg" }) },
                })

                local r = Handler.importPhotos({ source_path = "/dir/a.jpg" })

                assert.are.equal(0, r.imported)
                assert.are.equal(1, r.already_in_catalog)
                assert.are.same({}, added)
            end)
        end)

        it("counts an extension renamed to another case on a case-insensitive volume", function()
            local _, Handler = setup({
                photos = { helper.fakePhoto({ path = "/dir/A.ARW", id = "/dir/A.ARW" }) },
                fs = { caseInsensitiveVolume = true, exists = { ["/dir/a.ARW"] = true } },
            })

            local r = Handler.importPhotos({ source_path = "/dir/a.ARW" })

            assert.are.equal(0, r.imported)
            assert.are.equal(1, r.already_in_catalog)
        end)

        it("counts a path spelled in another case as the catalog entry", function()
            local catalog, Handler = setup({
                photos = { helper.fakePhoto({ path = "/dir/q.jpg", id = "/dir/q.jpg" }) },
                fs = { caseInsensitiveVolume = true, exists = { ["/dir/q.jpg"] = true } },
            })

            local r = Handler.importPhotos({ source_path = "/dir/Q.jpg" })

            assert.are.equal(0, r.imported)
            assert.are.equal(1, r.already_in_catalog)
            assert.are.equal(1, #catalog:getAllPhotos())
        end)

        it("leaves already_in_catalog out when nothing was there", function()
            local _, Handler = setupFolder({}, { "/dir/a.arw" })

            local r = Handler.importPhotos({ source_path = "/dir" })

            assert.is_nil(r.already_in_catalog)
        end)

        it("counts an NFC folder listing against the NFD path in the catalog", function()
            local catalog, Handler = setupFolder({ "/dir/cafe\204\129.jpg" }, { "/dir/caf\195\169.jpg" })
            catalog.addPhoto = function() error("failed to import photo") end

            local r = Handler.importPhotos({ source_path = "/dir" })

            assert.is_true(r.success)
            assert.are.equal(0, r.imported)
            assert.are.equal(1, r.already_in_catalog)
            assert.is_nil(r.failed)
        end)

        it("keeps the count of added photos and names the file that failed", function()
            local catalog, Handler = setupFolder({}, { "/dir/a.arw", "/dir/bad.arw" })
            local addPhoto = catalog.addPhoto
            catalog.addPhoto = function(self, path)
                if path == "/dir/bad.arw" then error("failed to import photo") end
                return addPhoto(self, path)
            end

            local r = Handler.importPhotos({ source_path = "/dir" })

            assert.is_false(r.success)
            assert.are.equal(1, r.imported)
            assert.are.equal(1, #r.failed)
            assert.are.equal("/dir/bad.arw", r.failed[1].path)
        end)

        it("still surfaces a file that fails for another reason", function()
            local catalog, Handler = setupFolder({ "/dir/a.arw" }, { "/dir/a.arw", "/dir/bad.arw", "/dir/c.arw" })
            catalog.addPhoto = function() error("failed to import photo") end

            local r = Handler.importPhotos({ source_path = "/dir" })

            assert.is_false(r.success)
            assert.are.equal(2, #r.failed)
            assert.truthy(r.failed[1].error:find("failed to import photo", 1, true))
        end)
    end)

    describe("a folder spelled in another case", function()
        local function caseSensitiveVolume(extra)
            local opts = {
                folders = extra.folders,
                photos = extra.photos,
                fs = {
                    directories = extra.directories or { ["/root"] = true, ["/root/Dir2"] = true, ["/root/dir2"] = true },
                    dirContents = extra.dirContents,
                    exists = extra.exists or {},
                },
            }
            local catalog, Handler = setup(opts)
            local added = {}
            local addPhoto = catalog.addPhoto
            catalog.addPhoto = function(self, path)
                added[#added + 1] = path
                return addPhoto(self, path)
            end
            return Handler, added, catalog
        end

        local function catalogWithDir2()
            local photo = helper.fakePhoto({ path = "/root/Dir2/a.jpg", id = "1" })
            return {
                folders = { helper.fakeFolder("/root", {}, { helper.fakeFolder("/root/Dir2", { photo }) }) },
                photos = { photo },
            }
        end

        it("refuses the file instead of letting Lightroom file it under the other folder", function()
            local setupOpts = catalogWithDir2()
            setupOpts.dirContents = { "/root/Dir2/a.jpg", "/root/dir2/a.jpg" }
            local Handler, added = caseSensitiveVolume(setupOpts)

            local r = Handler.importPhotos({ source_path = "/root" })

            assert.are.same({}, added)
            assert.is_false(r.success)
            assert.are.equal(0, r.imported)
            assert.are.equal(1, r.already_in_catalog)
            assert.are.equal("/root/dir2/a.jpg", r.failed[1].path)
            assert.truthy(r.failed[1].error:find("differs only in case from /root/Dir2", 1, true))
            assert.is_true(r.complete)
        end)

        it("answers again when the folder is imported a second time", function()
            local setupOpts = catalogWithDir2()
            setupOpts.dirContents = { "/root/Dir2/a.jpg", "/root/dir2/a.jpg" }
            local Handler = caseSensitiveVolume(setupOpts)

            local first = Handler.importPhotos({ source_path = "/root" })
            local second = Handler.importPhotos({ source_path = "/root" })

            assert.are.same(first, second)
        end)

        it("imports the first spelling of a new folder and refuses the second", function()
            local Handler, added = caseSensitiveVolume({
                dirContents = { "/root/Dir2/a.jpg", "/root/dir2/a.jpg", "/root/Dir2/b.jpg" },
            })

            local r = Handler.importPhotos({ source_path = "/root" })

            assert.are.same({ "/root/Dir2/a.jpg", "/root/Dir2/b.jpg" }, added)
            assert.are.equal(2, r.imported)
            assert.are.equal(1, #r.failed)
            assert.are.equal("/root/dir2/a.jpg", r.failed[1].path)
        end)

        it("refuses a file below a case-variant ancestor folder", function()
            local photo = helper.fakePhoto({ path = "/root/Dir2/sub/a.jpg", id = "1" })
            local Handler, added = caseSensitiveVolume({
                folders = { helper.fakeFolder("/root", {}, { helper.fakeFolder("/root/Dir2", {}, {
                    helper.fakeFolder("/root/Dir2/sub", { photo }),
                }) }) },
                photos = { photo },
                directories = { ["/root"] = true, ["/root/Dir2"] = true, ["/root/dir2"] = true,
                    ["/root/Dir2/sub"] = true, ["/root/dir2/sub"] = true },
                dirContents = { "/root/dir2/sub/b.jpg" },
            })

            local r = Handler.importPhotos({ source_path = "/root" })

            assert.are.same({}, added)
            assert.are.equal("/root/dir2/sub/b.jpg", r.failed[1].path)
        end)

        it("raises for a single file", function()
            local setupOpts = catalogWithDir2()
            setupOpts.exists = { ["/root/dir2/a.jpg"] = true }
            local Handler, added = caseSensitiveVolume(setupOpts)

            local ok, err = pcall(Handler.importPhotos, { source_path = "/root/dir2/a.jpg" })

            assert.is_false(ok)
            assert.truthy(tostring(err):find("differs only in case from /root/Dir2", 1, true))
            assert.are.same({}, added)
        end)

        it("refuses a case-variant folder that the copy would create", function()
            local Handler, added = caseSensitiveVolume({
                directories = { ["/src"] = true, ["/dest"] = true },
                dirContents = { "/src/Dir2/a.jpg", "/src/dir2/b.jpg" },
                exists = { ["/src/Dir2/a.jpg"] = true, ["/src/dir2/b.jpg"] = true },
            })

            local r = Handler.importPhotos({ source_path = "/src", copy_to = "/dest" })

            assert.are.same({ "/dest/Dir2/a.jpg" }, added)
            assert.are.equal(1, r.imported)
            assert.are.equal("/src/dir2/b.jpg", r.failed[1].path)
        end)

        it("remembers a folder only once its file is in the catalog", function()
            local Handler, added, catalog = caseSensitiveVolume({
                dirContents = { "/root/Dir2/a.jpg", "/root/dir2/b.jpg" },
            })
            local addPhoto = catalog.addPhoto
            catalog.addPhoto = function(self, path)
                if path == "/root/Dir2/a.jpg" then error("failed to import photo") end
                return addPhoto(self, path)
            end

            local r = Handler.importPhotos({ source_path = "/root" })

            assert.are.same({ "/root/dir2/b.jpg" }, added)
            assert.are.equal("/root/Dir2/a.jpg", r.failed[1].path)
            assert.are.equal(1, r.imported)
        end)

        it("copies nothing into a case-variant folder", function()
            local setupOpts = catalogWithDir2()
            setupOpts.directories = { ["/dir"] = true, ["/root"] = true, ["/root/Dir2"] = true, ["/root/dir2"] = true }
            setupOpts.dirContents = { "/dir/a.jpg" }
            setupOpts.exists = { ["/dir/a.jpg"] = true }
            local Handler, added = caseSensitiveVolume(setupOpts)

            local r = Handler.importPhotos({ source_path = "/dir", copy_to = "/root/dir2" })

            assert.are.same({}, added)
            assert.are.equal(1, #r.failed)
        end)

        it("treats the folder as the same one on a case-insensitive volume", function()
            local photo = helper.fakePhoto({ path = "/root/Dir2/a.jpg", id = "1" })
            local catalog, Handler = setup({
                folders = { helper.fakeFolder("/root", {}, { helper.fakeFolder("/root/Dir2", { photo }) }) },
                photos = { photo },
                fs = {
                    caseInsensitiveVolume = true,
                    directories = { ["/root"] = true, ["/root/Dir2"] = true },
                    dirContents = { "/root/dir2/a.jpg" },
                    exists = { ["/root/Dir2/a.jpg"] = true },
                },
            })

            local r = Handler.importPhotos({ source_path = "/root/dir2" })

            assert.is_true(r.success)
            assert.are.equal(1, r.already_in_catalog)
            assert.are.equal(1, #catalog:getAllPhotos())
        end)

        it("reads a catalog folder path with a trailing separator as the same folder", function()
            local photo = helper.fakePhoto({ path = "/root/Dir2/a.jpg", id = "1" })
            local Handler, added = caseSensitiveVolume({
                folders = { helper.fakeFolder("/root/", {}, { helper.fakeFolder("/root/Dir2", { photo }) }) },
                photos = { photo },
                dirContents = { "/root/Dir2/a.jpg", "/root/Dir2/b.jpg" },
            })

            local r = Handler.importPhotos({ source_path = "/root" })

            assert.are.same({ "/root/Dir2/b.jpg" }, added)
            assert.is_true(r.success)
        end)

        it("keeps a folder that is itself in the catalog in both spellings", function()
            local upper = helper.fakePhoto({ path = "/root/Dir2/a.jpg", id = "1" })
            local lower = helper.fakePhoto({ path = "/root/dir2/b.jpg", id = "2" })
            local Handler, added = caseSensitiveVolume({
                folders = { helper.fakeFolder("/root", {}, {
                    helper.fakeFolder("/root/Dir2", { upper }),
                    helper.fakeFolder("/root/dir2", { lower }),
                }) },
                photos = { upper, lower },
                dirContents = { "/root/dir2/b.jpg", "/root/dir2/c.jpg" },
            })

            local r = Handler.importPhotos({ source_path = "/root" })

            assert.are.same({ "/root/dir2/c.jpg" }, added)
            assert.is_true(r.success)
        end)
    end)

    describe("RAW+JPEG pairs", function()
        local function importFolder(dirContents, args)
            local catalog, Handler = setup({ fs = {
                directories = { ["/dir"] = true },
                dirContents = dirContents,
            } })
            args = args or {}
            args.source_path = "/dir"
            return Handler.importPhotos(args), importedPaths(catalog)
        end

        for _, case in ipairs({
            { name = "lowercase pair", files = { "/dir/a.cr3", "/dir/a.jpg" }, kept = { "/dir/a.cr3" } },
            { name = "mixed extension case", files = { "/dir/a.CR3", "/dir/a.jpg" }, kept = { "/dir/a.CR3" } },
            { name = "mixed extension case on a jpeg", files = { "/dir/A.nef", "/dir/A.jpg" }, kept = { "/dir/A.nef" } },
            { name = "jpeg listed before the raw", files = { "/dir/a.JPEG", "/dir/a.arw" }, kept = { "/dir/a.arw" } },
            { name = "jpe extension", files = { "/dir/a.nef", "/dir/a.jpe" }, kept = { "/dir/a.nef" } },
            { name = "several jpegs for one raw", files = { "/dir/a.raf", "/dir/a.jpg", "/dir/a.jpeg" }, kept = { "/dir/a.raf" } },
        }) do
            it("leaves out the JPEG: " .. case.name, function()
                local r, paths = importFolder(case.files)

                assert.are.same(case.kept, paths)
                assert.are.equal(1, r.imported)
                assert.are.equal(#case.files - 1, r.skipped_sidecar_jpegs)
                assert.are.equal(0, r.skipped)
                assert.is_nil(r.message)
            end)
        end

        for _, case in ipairs({
            { name = "JPEG without a raw", files = { "/dir/a.jpg", "/dir/b.cr3" } },
            { name = "same name in another folder", files = { "/dir/one/a.cr3", "/dir/two/a.jpg" } },
            { name = "non-JPEG next to a raw", files = { "/dir/a.cr3", "/dir/a.tif", "/dir/a.heic" } },
            { name = "JPEG next to a non-raw", files = { "/dir/a.png", "/dir/a.jpg" } },
            { name = "name differing in case", files = { "/dir/A.nef", "/dir/a.JPG" } },
            { name = "JPEG next to a DNG", files = { "/dir/a.dng", "/dir/a.jpg" } },
            { name = "JPEG next to an uppercase DNG", files = { "/dir/a.DNG", "/dir/a.JPEG" } },
        }) do
            it("keeps every file: " .. case.name, function()
                local r, paths = importFolder(case.files)

                assert.are.same(case.files, paths)
                assert.is_nil(r.skipped_sidecar_jpegs)
            end)
        end

        it("keeps the JPEG as its own photo with separate_jpegs", function()
            local files = { "/dir/a.cr3", "/dir/a.jpg" }

            local r, paths = importFolder(files, { separate_jpegs = true })

            assert.are.same(files, paths)
            assert.is_nil(r.skipped_sidecar_jpegs)
        end)

        it("adds only the raw to the collection and to remaining_paths", function()
            local added = {}
            local collection = {
                getName = function() return "Shoot" end,
                type = function() return "LrCollection" end,
                isSmartCollection = function() return false end,
                addPhotos = function(_, photos) added = photos end,
            }
            local catalog, Handler = setup({
                collections = { collection },
                fs = {
                    directories = { ["/dir"] = true },
                    dirContents = { "/dir/a.cr3", "/dir/a.jpg", "/dir/b.cr3", "/dir/b.jpg" },
                },
            })
            local context = {
                isCanceled = function() return #catalog:getAllPhotos() >= 1 end,
                report = function() end,
            }

            local r = Handler.importPhotos({ source_path = "/dir", collection_name = "Shoot" }, context)

            assert.are.same({ "/dir/b.cr3" }, r.remaining_paths)
            assert.are.equal(1, #added)
            assert.are.equal("/dir/a.cr3", added[1]:getRawMetadata('path'))
            assert.are.equal(2, r.skipped_sidecar_jpegs)
        end)

        for _, volume in ipairs({
            { name = "case-sensitive volume", caseInsensitiveVolume = false },
            { name = "case-insensitive volume", caseInsensitiveVolume = true },
        }) do
            for _, case in ipairs({
                { name = "lowercase raw", jpeg = "/dir/a.jpg", raw = "/dir/a.cr3" },
                { name = "uppercase raw", jpeg = "/dir/S1.JPG", raw = "/dir/S1.ARW" },
                { name = "jpeg extension", jpeg = "/dir/a.jpeg", raw = "/dir/a.nef" },
                { name = "mixed-case raw extension", jpeg = "/dir/a.jpg", raw = "/dir/a.Cr3" },
            }) do
                it("refuses a lone JPEG and names the raw as on disk: " .. case.name .. ", " .. volume.name, function()
                    local catalog, Handler = setup({ fs = {
                        caseInsensitiveVolume = volume.caseInsensitiveVolume,
                        exists = { [case.jpeg] = true, [case.raw] = true },
                    } })

                    local ok, err = pcall(Handler.importPhotos, { source_path = case.jpeg })

                    assert.is_false(ok)
                    assert.truthy(tostring(err):find("Import " .. case.raw .. " instead", 1, true))
                    assert.are.same({}, importedPaths(catalog))
                end)
            end
        end

        it("uses the JPEG's name on disk when the path spells it in another case", function()
            local catalog, Handler = setup({ fs = {
                caseInsensitiveVolume = true,
                exists = { ["/dir/S1.JPG"] = true, ["/dir/S1.ARW"] = true },
            } })

            local ok, err = pcall(Handler.importPhotos, { source_path = "/dir/s1.jpg" })

            assert.is_false(ok)
            assert.truthy(tostring(err):find("Import /dir/S1.ARW instead", 1, true))
            assert.are.same({}, importedPaths(catalog))
        end)

        it("imports a JPEG whose name on disk differs from its raw's, however the path spells it", function()
            local catalog, Handler = setup({ fs = {
                caseInsensitiveVolume = true,
                exists = { ["/dir/q.jpg"] = true, ["/dir/Q.ARW"] = true },
            } })

            local r = Handler.importPhotos({ source_path = "/dir/Q.jpg" })

            assert.are.equal(1, r.imported)
            assert.are.same({ "/dir/Q.jpg" }, importedPaths(catalog))
        end)

        it("prefers the exact name when a case-sensitive volume holds both spellings", function()
            local catalog, Handler = setup({ fs = {
                exists = { ["/dir/A.jpg"] = true, ["/dir/a.jpg"] = true, ["/dir/A.ARW"] = true },
            } })

            local r = Handler.importPhotos({ source_path = "/dir/a.jpg" })

            assert.are.equal(1, r.imported)
            assert.are.same({ "/dir/a.jpg" }, importedPaths(catalog))
        end)

        it("finds the raw when the path uses another Unicode form than the disk", function()
            local catalog, Handler = setup({ fs = {
                caseInsensitiveVolume = true,
                normalizationInsensitiveVolume = true,
                exists = { ["/dir/caf\195\169.jpg"] = true, ["/dir/caf\195\169.ARW"] = true },
            } })

            local ok, err = pcall(Handler.importPhotos, { source_path = "/dir/cafe\204\129.jpg" })

            assert.is_false(ok)
            assert.truthy(tostring(err):find("Import /dir/cafe\204\129.ARW instead", 1, true))
            assert.are.same({}, importedPaths(catalog))
        end)

        it("finds a mixed-case raw extension across Unicode forms on a case-sensitive volume", function()
            local catalog, Handler = setup({ fs = {
                normalizationInsensitiveVolume = true,
                exists = { ["/dir/caf\195\169.jpg"] = true, ["/dir/caf\195\169.ArW"] = true },
            } })

            local ok, err = pcall(Handler.importPhotos, { source_path = "/dir/cafe\204\129.jpg" })

            assert.is_false(ok)
            assert.truthy(tostring(err):find("Import /dir/cafe\204\129.ArW instead", 1, true))
            assert.are.same({}, importedPaths(catalog))
        end)

        it("imports a JPEG in another Unicode form when no raw is beside it", function()
            local _, Handler = setup({ fs = {
                normalizationInsensitiveVolume = true,
                exists = { ["/dir/caf\195\169.jpg"] = true },
            } })

            local r = Handler.importPhotos({ source_path = "/dir/cafe\204\129.jpg" })

            assert.are.equal(1, r.imported)
        end)

        it("imports a lone JPEG beside its raw with separate_jpegs", function()
            local catalog, Handler = setup({ fs = { exists = { ["/dir/a.jpg"] = true, ["/dir/a.cr3"] = true } } })

            local r = Handler.importPhotos({ source_path = "/dir/a.jpg", separate_jpegs = true })

            assert.are.equal(1, r.imported)
            assert.are.same({ "/dir/a.jpg" }, importedPaths(catalog))
        end)

        for _, case in ipairs({
            { name = "JPEG with no raw beside it", source = "/dir/a.jpg", others = { "/dir/a.png" } },
            { name = "JPEG beside a DNG", source = "/dir/a.jpg", others = { "/dir/a.dng", "/dir/a.DNG" } },
            { name = "raw with a JPEG beside it", source = "/dir/a.cr3", others = { "/dir/a.jpg" } },
            { name = "folder named like the raw", source = "/dir/a.jpg", directoryNamed = "/dir/a.cr3" },
            { name = "raw whose name differs in case", source = "/dir/q.jpg", others = { "/dir/Q.ARW" } },
            { name = "raw in another folder", source = "/dir/a.jpg", others = { "/dir/sub/a.cr3" } },
        }) do
            it("imports a single file: " .. case.name, function()
                local exists = { [case.source] = true }
                for _, other in ipairs(case.others or {}) do exists[other] = true end
                local catalog, Handler = setup({ fs = {
                    caseInsensitiveVolume = true,
                    exists = exists,
                    directories = case.directoryNamed and { [case.directoryNamed] = true } or {},
                } })

                local r = Handler.importPhotos({ source_path = case.source })

                assert.are.equal(1, r.imported)
                assert.are.same({ case.source }, importedPaths(catalog))
            end)
        end
    end)

    it("cancel keeps imports already committed and returns unprocessed paths", function()
        local catalog, Handler = setup({ fs = {
            directories = { ["/dir"] = true },
            dirContents = { "/dir/a.jpg", "/dir/b.jpg", "/dir/c.jpg" },
        } })
        local context = {
            isCanceled = function() return #catalog:getAllPhotos() >= 1 end,
            report = function() end,
        }

        local r = Handler.importPhotos({ source_path = "/dir" }, context)

        assert.are.equal(1, r.imported)
        assert.is_false(r.complete)
        assert.are.same({ "/dir/b.jpg", "/dir/c.jpg" }, r.remaining_paths)
        assert.are.equal(1, #catalog:getAllPhotos())
    end)

    it("imports a single photo", function()
        local catalog, Handler = setup({
            fs = { exists = { ["/photo.jpg"] = true }, directories = {} },
        })

        local r = Handler.importPhotos({ source_path = "/photo.jpg" })

        assert.is_true(r.success)
        assert.are.equal(1, r.imported)
    end)

    it("errors when source path does not exist", function()
        local _, Handler = setup({ fs = { exists = {} } })
        assert.has_error(function()
            Handler.importPhotos({ source_path = "/missing.jpg" })
        end)
    end)

    it("errors without source_path", function()
        local _, Handler = setup({ fs = {} })
        assert.has_error(function() Handler.importPhotos({}) end)
    end)

    it("imports multiple photos from directory and filters extensions", function()
        local catalog, Handler = setup({
            fs = {
                exists = { ["/dir"] = true },
                directories = { ["/dir"] = true },
                dirContents = { "/dir/a.jpg", "/dir/b.txt", "/dir/c.png", "/dir/d.dng" },
            },
        })

        local r = Handler.importPhotos({ source_path = "/dir" })
        assert.are.equal(3, r.imported)
    end)

    it("imports photos nested in subfolders", function()
        -- Photo libraries are organized as shoot/roll subfolders, so the source
        -- directory usually holds no photos itself. An immediate-directory walk
        -- enumerated nothing and failed with "No photos found to import"; the
        -- walk has to recurse.
        local _, Handler = setup({
            fs = {
                exists = { ["/dir"] = true },
                directories = { ["/dir"] = true },
                dirContents = {
                    "/dir/roll1/a.jpg",
                    "/dir/roll1/scans/b.tif",
                    "/dir/roll2/c.arw",
                },
            },
        })

        local r = Handler.importPhotos({ source_path = "/dir" })

        assert.is_true(r.success)
        assert.are.equal(3, r.imported)
    end)

    it("imports camera raw formats beyond Canon, Nikon and Sony, in any case", function()
        local _, Handler = setup({
            fs = {
                exists = { ["/dir"] = true },
                directories = { ["/dir"] = true },
                dirContents = {
                    "/dir/a.RAF", "/dir/b.CR3", "/dir/c.orf", "/dir/d.rw2", "/dir/e.pef",
                    "/dir/f.srw", "/dir/g.3fr", "/dir/h.iiq", "/dir/i.HEIC", "/dir/j.hif",
                },
            },
        })

        local r = Handler.importPhotos({ source_path = "/dir" })

        assert.are.equal(10, r.imported)
        assert.are.equal(0, r.skipped)
        assert.is_nil(r.skipped_by_extension)
        assert.is_nil(r.message)
    end)

    it("reports the files it skipped by extension", function()
        local _, Handler = setup({
            fs = {
                exists = { ["/dir"] = true },
                directories = { ["/dir"] = true },
                dirContents = { "/dir/a.raf", "/dir/a.xmp", "/dir/b.xmp", "/dir/notes.txt", "/dir/README" },
            },
        })

        local r = Handler.importPhotos({ source_path = "/dir" })

        assert.are.equal(1, r.imported)
        assert.are.equal(4, r.skipped)
        assert.are.same({ xmp = 2, txt = 1, [""] = 1 }, r.skipped_by_extension)
        assert.are.equal(
            "Skipped 4 files with unsupported extensions ((none): 1, txt: 1, xmp: 2)",
            r.message)
    end)

    it("names the skipped extensions when a folder has no importable photos", function()
        local _, Handler = setup({
            fs = {
                exists = { ["/dir"] = true },
                directories = { ["/dir"] = true },
                dirContents = { "/dir/clip.mov", "/dir/clip.xmp" },
            },
        })

        local ok, err = pcall(Handler.importPhotos, { source_path = "/dir" })

        assert.is_false(ok)
        assert.truthy(tostring(err):find("skipped files by extension: mov: 1, xmp: 1", 1, true))
    end)

    it("acquires catalog write access per photo, not once for the batch", function()
        -- A batch-wide write lock wedges the bridge for the whole multi-minute
        -- import (issue #128); each photo must get its own short transaction so
        -- the exclusive lock is released between photos.
        local catalog, Handler = setup({
            fs = {
                exists = { ["/dir"] = true },
                directories = { ["/dir"] = true },
                dirContents = { "/dir/a.jpg", "/dir/b.png", "/dir/c.dng" },
            },
        })

        local r = Handler.importPhotos({ source_path = "/dir" })

        assert.are.equal(3, r.imported)
        assert.are.equal(3, catalog:getWriteAccessCount())
    end)
end)
