local AiMaskParts = require 'AiMaskParts'

describe("AiMaskParts", function()
    it("lists the people parts and landscape categories Lightroom offers", function()
        assert.are.same({
            "face_skin", "iris_and_pupil", "body_skin", "hair", "lips", "facial_hair",
            "eye_sclera", "eyebrows", "clothes", "teeth", "entire_person",
        }, AiMaskParts.PEOPLE_NAMES)
        assert.are.same({
            "architecture", "mountains", "artificial_ground", "natural_ground",
            "vegetation", "sky", "water", "snow",
        }, AiMaskParts.LANDSCAPE_NAMES)
    end)

    it("builds an all-people part as sub type 3 without digests or instance ids", function()
        local request = AiMaskParts.parsePeople({ parts = { "clothes" } })

        local entry = AiMaskParts.newEntry(request.specs[1], request)

        local component = entry.CorrectionMasks[1]
        assert.are.equal("Correction", entry.What)
        assert.are.equal("People - Clothes", entry.CorrectionName)
        assert.are.equal("Mask/Image", component.What)
        assert.are.equal(3, component.MaskSubType)
        assert.are.equal(11, component.MaskSubCategoryID)
        assert.are.equal(1, component.MaskVersion)
        assert.are.equal("0.500000 0.500000", component.ReferencePoint)
        assert.are.equal(0, component.ErrorReason)
        assert.is_nil(component.InstanceIDs)
        assert.is_nil(component.MaskDigest)
        assert.is_nil(component.MaskID)
        assert.is_nil(entry.CorrectionID)
        assert.are.equal(0, entry.LocalExposure2012)
        assert.are.equal(1, entry.CorrectionAmount)
    end)

    it("builds a one-person part as sub type 0 with a zero-based instance", function()
        local request = AiMaskParts.parsePeople({ parts = { "teeth" }, person = 3 })

        local entry = AiMaskParts.newEntry(request.specs[1], request)

        local component = entry.CorrectionMasks[1]
        assert.are.equal("Person 3 - Teeth", entry.CorrectionName)
        assert.are.equal(0, component.MaskSubType)
        assert.are.equal(12, component.MaskSubCategoryID)
        assert.are.same({ { InstanceID = 2 } }, component.InstanceIDs)
    end)

    it("builds a landscape category as sub type 0 with its 5000x id", function()
        local request = AiMaskParts.parseLandscape({ categories = { "snow", "mountains" } })

        local snow = AiMaskParts.newEntry(request.specs[1], request).CorrectionMasks[1]
        local mountains = AiMaskParts.newEntry(request.specs[2], request).CorrectionMasks[1]

        assert.are.equal(0, snow.MaskSubType)
        assert.are.equal(50008, snow.MaskSubCategoryID)
        assert.are.equal(50002, mountains.MaskSubCategoryID)
        assert.is_nil(snow.InstanceIDs)
    end)

    it("rejects non-string and non-list input", function()
        assert.has_error(function() AiMaskParts.parsePeople({ parts = "hair" }) end)
        assert.has_error(function() AiMaskParts.parsePeople({ parts = { 5 } }) end)
        assert.has_error(function() AiMaskParts.parseLandscape({ categories = { true } }) end)
        assert.has_error(function() AiMaskParts.parsePeople({ parts = { "hair" }, person = "1" }) end)
    end)
end)
