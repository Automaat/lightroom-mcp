local JSON = require 'JSON'

describe("JSON", function()
    it("escapes Windows path backslashes when encoding strings", function()
        local encoded = JSON:encode({
            path = "C:\\gvv\\Photos\\Archive\\Source\\_GVV2154.NEF",
        })

        assert.is_not_nil(encoded:find('"path":"C:\\\\gvv\\\\Photos\\\\Archive\\\\Source\\\\_GVV2154.NEF"', 1, true))
    end)

    it("decodes escaped Windows path backslashes in strings", function()
        local decoded = JSON:decode('{"path":"C:\\\\gvv\\\\Photos\\\\Archive\\\\Source\\\\_GVV2154.NEF"}')

        assert.are.equal("C:\\gvv\\Photos\\Archive\\Source\\_GVV2154.NEF", decoded.path)
    end)

    it("does not treat escaped Windows path letters as JSON control escapes", function()
        local decoded = JSON:decode('{"path":"C:\\\\new\\\\test\\\\raw"}')

        assert.are.equal("C:\\new\\test\\raw", decoded.path)
    end)

    describe("unicode escapes", function()
        it("decodes ASCII and Latin-1 code points", function()
            local decoded = JSON:decode('{"a":"\\u0041","e":"\\u00e9"}')

            assert.are.equal("A", decoded.a)
            assert.are.equal("\195\169", decoded.e)
        end)

        it("decodes control code points that have no short escape", function()
            local decoded = JSON:decode('{"s":"a\\u0000b\\u001fc"}')

            assert.are.equal("a\0b\31c", decoded.s)
        end)

        it("pairs surrogates into one code point", function()
            local decoded = JSON:decode('{"s":"\\ud83d\\ude00"}')

            assert.are.equal("\240\159\152\128", decoded.s)
        end)

        it("replaces a lone surrogate rather than failing the whole request", function()
            local decoded = JSON:decode('{"s":"\\ud800x"}')

            assert.are.equal("\239\191\189x", decoded.s)
        end)

        it("rejects a malformed escape", function()
            assert.has_error(function() JSON:decode('{"s":"\\u00zz"}') end)
        end)
    end)

    describe("numbers", function()
        it("decodes exponent notation", function()
            local decoded = JSON:decode('{"a":1e5,"b":1E5,"c":1.5e2,"d":1e-3,"e":1e+308}')

            assert.are.equal(100000, decoded.a)
            assert.are.equal(100000, decoded.b)
            assert.are.equal(150, decoded.c)
            assert.are.equal(0.001, decoded.d)
            assert.are.equal(1e308, decoded.e)
        end)

        it("still decodes plain integers and decimals", function()
            local decoded = JSON:decode('{"a":42,"b":-7,"c":150.5}')

            assert.are.equal(42, decoded.a)
            assert.are.equal(-7, decoded.b)
            assert.are.equal(150.5, decoded.c)
        end)
    end)

    it("escapes control characters when encoding so the server can parse back", function()
        local encoded = JSON:encode({ s = "a\0b\1c\31d\8e" })

        assert.is_not_nil(encoded:find('\\u0000', 1, true))
        assert.is_not_nil(encoded:find('\\u0001', 1, true))
        assert.is_not_nil(encoded:find('\\u001f', 1, true))
        assert.is_not_nil(encoded:find('\\b', 1, true))
    end)

    it("encodes an empty table as an array so clients can iterate results", function()
        local encoded = JSON:encode({ changes = {}, count = 0 })

        assert.is_not_nil(encoded:find('"changes":[]', 1, true))
    end)

    it("still encodes populated arrays and objects distinctly", function()
        local encoded = JSON:encode({ list = { 1, 2 }, obj = { a = 1 } })

        assert.is_not_nil(encoded:find('"list":[1,2]', 1, true))
        assert.is_not_nil(encoded:find('"obj":{"a":1}', 1, true))
    end)

    it("round-trips a string through encode and decode", function()
        local original = "tab\there\nnewline \0nul \1soh émoji 😀 quote\" back\\slash"
        local decoded = JSON:decode(JSON:encode({ s = original }))

        assert.are.equal(original, decoded.s)
    end)
end)
