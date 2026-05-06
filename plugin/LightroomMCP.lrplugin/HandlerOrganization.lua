local LrApplication = import 'LrApplication'
local LrLogger = import 'LrLogger'

local PhotoLookup = require 'PhotoLookup'

local logger = LrLogger('LightroomMCP')

local OrganizationHandler = {}

function OrganizationHandler.setKeywords(args)
    if not args.photo_ids or #args.photo_ids == 0 then
        error("photo_ids is required")
    end

    local catalog = LrApplication.activeCatalog()
    local updatedCount = 0

    catalog:withWriteAccessDo("Set Keywords", function()
        local resolved = PhotoLookup.resolveMany(catalog, args.photo_ids)
        for _, entry in ipairs(resolved) do
            local photo = entry.photo
            if photo then
                -- Add keywords
                if args.add_keywords and #args.add_keywords > 0 then
                    for _, kw in ipairs(args.add_keywords) do
                        photo:addKeyword(catalog:createKeyword(kw, {}, true, nil, true))
                    end
                end

                -- Remove keywords
                if args.remove_keywords and #args.remove_keywords > 0 then
                    local existingKeywords = photo:getRawMetadata('keywords')
                    if existingKeywords then
                        for _, kw in ipairs(existingKeywords) do
                            for _, removeKw in ipairs(args.remove_keywords) do
                                if kw:getName() == removeKw then
                                    photo:removeKeyword(kw)
                                end
                            end
                        end
                    end
                end

                updatedCount = updatedCount + 1
            end
        end
    end)

    logger:info(string.format("Updated keywords for %d photos", updatedCount))

    return {
        success = true,
        updated = updatedCount,
        message = string.format("Updated keywords for %d photos", updatedCount)
    }
end

function OrganizationHandler.setRating(args)
    if not args.photo_ids or #args.photo_ids == 0 then
        error("photo_ids is required")
    end

    if not args.rating then
        error("rating is required")
    end

    if args.rating < 0 or args.rating > 5 then
        error("rating must be between 0 and 5")
    end

    local catalog = LrApplication.activeCatalog()
    local updatedCount = 0

    -- LrSDK rejects literal 0 on the rating field; nil means "no rating".
    local ratingValue = args.rating
    if ratingValue == 0 then ratingValue = nil end

    catalog:withWriteAccessDo("Set Rating", function()
        local resolved = PhotoLookup.resolveMany(catalog, args.photo_ids)
        for _, entry in ipairs(resolved) do
            if entry.photo then
                entry.photo:setRawMetadata('rating', ratingValue)
                updatedCount = updatedCount + 1
            end
        end
    end)

    logger:info(string.format("Set rating to %d for %d photos", args.rating, updatedCount))

    return {
        success = true,
        updated = updatedCount,
        rating = args.rating,
        message = string.format("Set rating to %d for %d photos", args.rating, updatedCount)
    }
end

return OrganizationHandler
