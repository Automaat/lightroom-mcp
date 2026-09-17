local LrApplication = import 'LrApplication'

local PhotoLookup = require 'PhotoLookup'
local Log = require 'Log'

local OrganizationHandler = {}
local MAX_KEYWORDS_PER_REQUEST = 1000

local function validateKeywordLimit(keywords, fieldName)
    if keywords and #keywords > MAX_KEYWORDS_PER_REQUEST then
        error(fieldName .. " must contain at most " .. MAX_KEYWORDS_PER_REQUEST .. " keywords")
    end
end

function OrganizationHandler.setKeywords(args)
    if not args.photo_ids or #args.photo_ids == 0 then
        error("photo_ids is required")
    end
    validateKeywordLimit(args.add_keywords, "add_keywords")
    validateKeywordLimit(args.remove_keywords, "remove_keywords")

    -- Neither list means there is nothing to do; reporting "Updated keywords
    -- for 1 photos" for that claimed work that never happened.
    local hasAdds = args.add_keywords ~= nil and args.add_keywords[1] ~= nil
    local hasRemoves = args.remove_keywords ~= nil and args.remove_keywords[1] ~= nil
    if not hasAdds and not hasRemoves then
        error("add_keywords or remove_keywords is required")
    end

    local catalog = LrApplication.activeCatalog()
    local updatedCount = 0

    local addKeywordNames = {}
    local addSet = {}
    if args.add_keywords then
        for _, kw in ipairs(args.add_keywords) do
            if not addSet[kw] then
                addSet[kw] = true
                table.insert(addKeywordNames, kw)
            end
        end
    end

    local removeSet = {}
    if args.remove_keywords then
        for _, kw in ipairs(args.remove_keywords) do
            removeSet[kw] = true
        end
    end

    local resolved = PhotoLookup.resolveMany(catalog, args.photo_ids)

    catalog:withWriteAccessDo("Set Keywords", function()
        -- createKeyword is not idempotent within one write transaction.
        local keywordObjs = {}
        for _, kw in ipairs(addKeywordNames) do
            table.insert(keywordObjs, catalog:createKeyword(kw, {}, true, nil, true))
        end

        for _, entry in ipairs(resolved) do
            local photo = entry.photo
            if photo then
                for _, kwObj in ipairs(keywordObjs) do
                    photo:addKeyword(kwObj)
                end

                if next(removeSet) then
                    local existingKeywords = photo:getRawMetadata('keywords')
                    if existingKeywords then
                        for _, kw in ipairs(existingKeywords) do
                            if removeSet[kw:getName()] then
                                photo:removeKeyword(kw)
                            end
                        end
                    end
                end

                updatedCount = updatedCount + 1
            end
        end
    end)

    Log.info(string.format("Updated keywords for %d photos", updatedCount))

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

    -- Comparing a string to a number raised a raw Lua type error that leaked
    -- the handler's file and line to the client.
    if type(args.rating) ~= "number" then
        error("rating must be a number between 0 and 5")
    end

    if args.rating < 0 or args.rating > 5 then
        error("rating must be between 0 and 5")
    end

    local catalog = LrApplication.activeCatalog()
    local updatedCount = 0
    local missingIds = {}
    local missingCount = 0

    -- LrSDK rejects literal 0 on the rating field; nil means "no rating".
    local ratingValue = args.rating
    if ratingValue == 0 then ratingValue = nil end

    local resolved = PhotoLookup.resolveMany(catalog, args.photo_ids)

    catalog:withWriteAccessDo("Set Rating", function()
        for _, entry in ipairs(resolved) do
            if entry.photo then
                entry.photo:setRawMetadata('rating', ratingValue)
                updatedCount = updatedCount + 1
            else
                missingCount = missingCount + 1
                missingIds[missingCount] = tostring(entry.id)
            end
        end
    end)

    Log.info(string.format("Set rating to %d for %d photos", args.rating, updatedCount))

    return {
        success = true,
        updated = updatedCount,
        rating = args.rating,
        missing = missingIds,
        message = string.format("Set rating to %d for %d photos (%d ids not found)",
            args.rating, updatedCount, missingCount)
    }
end

return OrganizationHandler
