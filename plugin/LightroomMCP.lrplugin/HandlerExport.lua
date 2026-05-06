local LrApplication = import 'LrApplication'
local LrExportSession = import 'LrExportSession'
local LrLogger = import 'LrLogger'
local LrFileUtils = import 'LrFileUtils'
local LrPathUtils = import 'LrPathUtils'

local PhotoLookup = require 'PhotoLookup'

local logger = LrLogger('LightroomMCP')

local ExportHandler = {}

function ExportHandler.exportPhotos(args)
    if not args.photo_ids or #args.photo_ids == 0 then
        error("photo_ids is required")
    end

    if not args.destination then
        error("destination is required")
    end

    local catalog = LrApplication.activeCatalog()
    local exportedCount = 0

    catalog:withReadAccessDo(function()
        -- Find photos
        local photosToExport = {}
        local resolved = PhotoLookup.resolveMany(catalog, args.photo_ids)
        for _, entry in ipairs(resolved) do
            if entry.photo then
                table.insert(photosToExport, entry.photo)
            end
        end

        if #photosToExport == 0 then
            error("No photos found to export")
        end

        -- Prepare export settings
        local exportSettings = {
            LR_export_destinationType = 'sourceFolder',
            LR_export_destinationPathPrefix = args.destination,
            LR_format = args.format or 'JPEG',
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

        -- Execute export
        exportSession:doExportOnCurrentTask()
        exportedCount = #photosToExport

        logger:info(string.format("Exported %d photos to: %s", exportedCount, args.destination))
    end)

    return {
        success = true,
        exported = exportedCount,
        destination = args.destination,
        message = string.format("Exported %d photos to %s", exportedCount, args.destination)
    }
end

return ExportHandler
