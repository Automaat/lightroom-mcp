local LrApplication = import 'LrApplication'
local LrLogger = import 'LrLogger'

local logger = LrLogger('LightroomMCP')

local SearchHandler = {}

function SearchHandler.searchPhotos(args)
    local catalog = LrApplication.activeCatalog()
    local results = {}

    catalog:withReadAccessDo(function()
        local allPhotos = catalog:getAllPhotos()

        for _, photo in ipairs(allPhotos) do
            local match = true

            -- Filter by filename
            if args.filename and match then
                local fileName = photo:getFormattedMetadata('fileName')
                if not fileName or not fileName:lower():find(args.filename:lower(), 1, true) then
                    match = false
                end
            end

            -- Filter by rating
            if args.rating and match then
                local rating = photo:getRawMetadata('rating')
                if rating ~= args.rating then
                    match = false
                end
            end

            -- Filter by keywords
            if args.keywords and #args.keywords > 0 and match then
                local photoKeywords = photo:getRawMetadata('keywords')
                local keywordNames = {}
                if photoKeywords then
                    for _, kw in ipairs(photoKeywords) do
                        table.insert(keywordNames, kw:getName())
                    end
                end

                for _, searchKw in ipairs(args.keywords) do
                    local found = false
                    for _, photoKw in ipairs(keywordNames) do
                        if photoKw:lower() == searchKw:lower() then
                            found = true
                            break
                        end
                    end
                    if not found then
                        match = false
                        break
                    end
                end
            end

            -- Filter by date range
            if args.start_date and match then
                local captureTime = photo:getRawMetadata('dateTimeOriginal')
                if captureTime and captureTime < args.start_date then
                    match = false
                end
            end

            if args.end_date and match then
                local captureTime = photo:getRawMetadata('dateTimeOriginal')
                if captureTime and captureTime > args.end_date then
                    match = false
                end
            end

            if match then
                table.insert(results, {
                    id = photo.localIdentifier,
                    path = photo:getRawMetadata('path'),
                    filename = photo:getFormattedMetadata('fileName'),
                    rating = photo:getRawMetadata('rating'),
                    dateTimeOriginal = photo:getFormattedMetadata('dateTimeOriginal'),
                })
            end
        end
    end)

    logger:info(string.format("Search found %d photos", #results))

    return {
        count = #results,
        photos = results
    }
end

return SearchHandler
