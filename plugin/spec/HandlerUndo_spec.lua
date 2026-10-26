local helper = require 'spec_helper'

local function setup(states)
    local reads, undos = 0, 0
    helper.installImport({
        LrUndo = {
            canUndo = function()
                reads = reads + 1
                return states[reads]
            end,
            undo = function() undos = undos + 1 end,
        },
    })
    package.loaded.HandlerUndo = nil
    return require 'HandlerUndo', function() return reads, undos end
end

describe("HandlerUndo.undoLastStep", function()
    it("undoes exactly once and reports the post-call availability", function()
        local handler, counts = setup({ true, false })
        assert.are.same({ undone = true, can_undo = false }, handler.undoLastStep({ confirm = true }))
        local reads, undos = counts()
        assert.are.equal(2, reads)
        assert.are.equal(1, undos)
    end)

    it("reports another available undo without invoking it", function()
        local handler, counts = setup({ true, true })
        assert.are.same({ undone = true, can_undo = true }, handler.undoLastStep({ confirm = true }))
        local _, undos = counts()
        assert.are.equal(1, undos)
    end)

    it("succeeds without undoing when history is empty", function()
        local handler, counts = setup({ false, false })
        assert.are.same({ undone = false, can_undo = false }, handler.undoLastStep({ confirm = true }))
        local _, undos = counts()
        assert.are.equal(0, undos)
    end)

    it("rejects missing confirmation before accessing Lightroom", function()
        local handler, counts = setup({ true })
        assert.has_error(function() handler.undoLastStep({}) end)
        assert.has_error(function() handler.undoLastStep(nil) end)
        local reads, undos = counts()
        assert.are.equal(0, reads)
        assert.are.equal(0, undos)
    end)

    for _, confirm in ipairs({ false, "true", 1, {} }) do
        it("rejects confirmation of type " .. type(confirm), function()
            local handler, counts = setup({ true })
            assert.has_error(function() handler.undoLastStep({ confirm = confirm }) end)
            local reads, undos = counts()
            assert.are.equal(0, reads)
            assert.are.equal(0, undos)
        end)
    end
end)
