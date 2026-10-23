local AiMaskParts = {}

local MAX_PERSON_NUMBER = 1000

local ALL_PEOPLE_SUBTYPE = 3
local ONE_PERSON_SUBTYPE = 0
local LANDSCAPE_SUBTYPE = 0
local MASK_VERSION = 1
local CENTRE_REFERENCE_POINT = "0.500000 0.500000"
local NO_ERROR = 0

local PEOPLE_PARTS = {
    { name = "face_skin", category = 2, label = "Facial Skin" },
    { name = "iris_and_pupil", category = 3, label = "Iris and Pupil" },
    { name = "body_skin", category = 4, label = "Body Skin" },
    { name = "hair", category = 5, label = "Hair" },
    { name = "lips", category = 6, label = "Lips" },
    { name = "facial_hair", category = 7, label = "Facial Hair" },
    { name = "eye_sclera", category = 8, label = "Eye Sclera" },
    { name = "eyebrows", category = 9, label = "Eyebrows" },
    { name = "clothes", category = 11, label = "Clothes" },
    { name = "teeth", category = 12, label = "Teeth" },
    { name = "entire_person", category = 20036, label = "Person", needsPerson = true },
}

local LANDSCAPE_CATEGORIES = {
    { name = "architecture", category = 50001, label = "Architecture" },
    { name = "mountains", category = 50002, label = "Mountains" },
    { name = "artificial_ground", category = 50003, label = "Artificial Ground" },
    { name = "natural_ground", category = 50004, label = "Natural Ground" },
    { name = "vegetation", category = 50005, label = "Vegetation" },
    { name = "sky", category = 50006, label = "Sky" },
    { name = "water", category = 50007, label = "Water" },
    { name = "snow", category = 50008, label = "Snow" },
}

local ZEROED_LOCAL_FIELDS = {
    "LocalExposure", "LocalContrast", "LocalClarity", "LocalBrightness",
    "LocalTemperature", "LocalTint", "LocalExposure2012", "LocalContrast2012", "LocalHighlights2012",
    "LocalShadows2012", "LocalWhites2012", "LocalBlacks2012", "LocalTexture", "LocalClarity2012",
    "LocalDehaze", "LocalHue", "LocalSaturation", "LocalSharpness", "LocalLuminanceNoise",
    "LocalMoire", "LocalDefringe", "LocalToningHue", "LocalToningSaturation", "LocalGrain",
}

local function indexByName(list)
    local byName, names = {}, {}
    for _, spec in ipairs(list) do
        byName[spec.name] = spec
        names[#names + 1] = spec.name
    end
    return byName, names
end

local PEOPLE_BY_NAME, PEOPLE_NAMES = indexByName(PEOPLE_PARTS)
local LANDSCAPE_BY_NAME, LANDSCAPE_NAMES = indexByName(LANDSCAPE_CATEGORIES)

AiMaskParts.PEOPLE_NAMES = PEOPLE_NAMES
AiMaskParts.LANDSCAPE_NAMES = LANDSCAPE_NAMES

local function requireNames(value, field, byName, names)
    if type(value) ~= "table" or #value == 0 then
        error(field .. " must be a non-empty list of: " .. table.concat(names, ", "))
    end
    local specs, seen = {}, {}
    for _, name in ipairs(value) do
        local spec = type(name) == "string" and byName[name] or nil
        if not spec then
            error("Unknown " .. field .. " " .. tostring(name) .. "; valid values: " .. table.concat(names, ", "))
        end
        if seen[name] then
            error("Duplicate " .. field .. " " .. name)
        end
        seen[name] = true
        specs[#specs + 1] = spec
    end
    return specs
end

local function requirePerson(value)
    if value == nil then return nil end
    if type(value) ~= "number" or value ~= math.floor(value) or value < 1 or value > MAX_PERSON_NUMBER then
        error("person must be a whole number from 1 (Lightroom's \"Person 1\")")
    end
    return value
end

function AiMaskParts.parsePeople(args)
    local specs = requireNames(args.parts, "part", PEOPLE_BY_NAME, PEOPLE_NAMES)
    local person = requirePerson(args.person)
    for _, spec in ipairs(specs) do
        if spec.needsPerson and not person then
            error(spec.name .. " needs person: Lightroom has no all-people form of it")
        end
    end
    return { kind = "people", specs = specs, person = person }
end

function AiMaskParts.parseLandscape(args)
    return { kind = "landscape", specs = requireNames(args.categories, "category", LANDSCAPE_BY_NAME, LANDSCAPE_NAMES) }
end

local function newComponent(spec, request)
    local subType = LANDSCAPE_SUBTYPE
    local name = spec.label
    if request.kind == "people" then
        subType = request.person and ONE_PERSON_SUBTYPE or ALL_PEOPLE_SUBTYPE
        name = request.person and ("Person " .. request.person .. " - " .. spec.label) or ("People - " .. spec.label)
    end
    local component = {
        What = "Mask/Image",
        MaskActive = true,
        MaskInverted = false,
        MaskBlendMode = 0,
        MaskValue = 1,
        MaskVersion = MASK_VERSION,
        MaskName = name,
        MaskSubType = subType,
        MaskSubCategoryID = spec.category,
        ReferencePoint = CENTRE_REFERENCE_POINT,
        ErrorReason = NO_ERROR,
    }
    if request.kind == "people" and request.person then
        component.InstanceIDs = { { InstanceID = request.person - 1 } }
    end
    return component, name
end

function AiMaskParts.newEntry(spec, request)
    local component, name = newComponent(spec, request)
    local entry = {
        What = "Correction",
        CorrectionName = name,
        CorrectionActive = true,
        CorrectionAmount = 1,
        CorrectionMasks = { component },
        CorrectionReferenceX = 0.5,
        CorrectionReferenceY = 0.5,
        LocalCurveRefineSaturation = 100,
    }
    for _, field in ipairs(ZEROED_LOCAL_FIELDS) do entry[field] = 0 end
    return entry
end

return AiMaskParts
