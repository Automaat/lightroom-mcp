describe('AI metadata provider', function()
    it('declares two private string fields under the initial schema', function()
        local provider = require 'AiMetadataDefinition'
        assert.are.equal(1, provider.schemaVersion)
        assert.are.same({
            { id = 'aiScore', dataType = 'string', version = 1 },
            { id = 'aiReason', dataType = 'string', version = 1 },
        }, provider.metadataFieldsForPhotos)
        assert.are.equal('AiMetadataDefinition.lua', (require 'Info').LrMetadataProvider)
    end)
end)
