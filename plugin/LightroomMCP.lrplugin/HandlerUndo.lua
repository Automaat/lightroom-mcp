local LrUndo = import 'LrUndo'

local HandlerUndo = {}

function HandlerUndo.undoLastStep(params)
    if type(params) ~= "table" or params.confirm ~= true then
        error("confirm must be true: Lightroom undo history is shared with user actions")
    end

    local undone = false
    if LrUndo.canUndo() then
        LrUndo.undo()
        undone = true
    end
    return {
        undone = undone,
        can_undo = LrUndo.canUndo(),
        message = undone and "Lightroom can merge recent plug-in writes into one undo step, so check every recent edit."
            or nil,
    }
end

return HandlerUndo
