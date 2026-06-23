local LrApplication = import 'LrApplication'
local LrExportSession = import 'LrExportSession'
local LrFileUtils = import 'LrFileUtils'
local LrPathUtils = import 'LrPathUtils'

local PhotoLookup = require 'PhotoLookup'
local Log = require 'Log'

local ExportHandler = {}

function ExportHandler.exportPhotos(args)
    if not args.photo_ids or #args.photo_ids == 0 then
        error("photo_ids is required")
    end

    if not args.destination then
        error("destination is required")
    end

    local catalog = LrApplication.activeCatalog()

    -- Resolve photos under read access, then RELEASE the lock before
    -- exporting. doExportOnCurrentTask() can run for minutes on a large
    -- batch; holding catalog read access for that whole span blocks every
    -- other handler (list_collections, get_selected_photos, ...) and on
    -- macOS wedged the bridge until a manual restart (issue #128).
    -- LrExportSession acquires its own catalog access during rendering, so
    -- the lock is only needed for the lookup itself.
    local photosToExport = {}
    catalog:withReadAccessDo(function()
        local resolved = PhotoLookup.resolveMany(catalog, args.photo_ids)
        for _, entry in ipairs(resolved) do
            if entry.photo then
                table.insert(photosToExport, entry.photo)
            end
        end
    end)

    if #photosToExport == 0 then
        error("No photos found to export")
    end

    -- destinationType=specificFolder makes LR honour
    -- LR_export_destinationPathPrefix; sourceFolder ignores it and
    -- writes next to the original. LR_format is set in the
    -- format-specific block below.
    local exportSettings = {
        LR_export_destinationType = 'specificFolder',
        LR_export_destinationPathPrefix = args.destination,
        LR_export_useSubfolder = false,
        LR_jpeg_quality = args.quality or 90,
    }

    -- Set dimensions if specified
    if args.width or args.height then
        exportSettings.LR_size_doConstrain = true
        exportSettings.LR_size_maxWidth = args.width
        exportSettings.LR_size_maxHeight = args.height
        exportSettings.LR_size_resizeType = 'longEdge'
    end

    -- Handle different formats
    if args.format == 'jpeg' or args.format == 'JPEG' or not args.format then
        exportSettings.LR_format = 'JPEG'
        exportSettings.LR_export_colorSpace = 'sRGB'
    elseif args.format == 'png' or args.format == 'PNG' then
        exportSettings.LR_format = 'PNG'
    elseif args.format == 'tiff' or args.format == 'TIFF' then
        exportSettings.LR_format = 'TIFF'
        exportSettings.LR_tiff_compressionMethod = 'compressionMethod_LZW'
    elseif args.format == 'original' or args.format == 'ORIGINAL' then
        exportSettings.LR_format = 'ORIGINAL'
    end

    -- Create export session
    local exportSession = LrExportSession {
        photosToExport = photosToExport,
        exportSettings = exportSettings,
    }

    -- Execute export (outside the read-access block above)
    exportSession:doExportOnCurrentTask()
    local exportedCount = #photosToExport

    Log.info(string.format("Exported %d photos to: %s", exportedCount, args.destination))

    return {
        success = true,
        exported = exportedCount,
        destination = args.destination,
        message = string.format("Exported %d photos to %s", exportedCount, args.destination)
    }
end

return ExportHandler
