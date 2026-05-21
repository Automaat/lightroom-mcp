local JSON = require 'JSON'

describe("JSON", function()
    it("escapes Windows path backslashes when encoding strings", function()
        local encoded = JSON:encode({
            path = "C:\\gvv\\Photos\\Archve\\Source\\_GVV2154.NEF",
        })

        assert.is_not_nil(encoded:find('"path":"C:\\\\gvv\\\\Photos\\\\Archve\\\\Source\\\\_GVV2154.NEF"', 1, true))
    end)

    it("decodes escaped Windows path backslashes in strings", function()
        local decoded = JSON:decode('{"path":"C:\\\\gvv\\\\Photos\\\\Archve\\\\Source\\\\_GVV2154.NEF"}')

        assert.are.equal("C:\\gvv\\Photos\\Archve\\Source\\_GVV2154.NEF", decoded.path)
    end)
end)
