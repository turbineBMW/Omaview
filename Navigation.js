.pragma library

// Stateless Lua dispatchers evaluated inside Hyprland. Every decision reads the
// compositor at dispatch time, including when several keys arrive before QML's
// next snapshot. Nothing is loaded from the user's Hyprland configuration.
function focus(direction) {
    if (["l", "r", "u", "d"].indexOf(direction) < 0) return ""
    return `function()
        local window = hl.get_active_window()
        local workspace = window and window.workspace or hl.get_active_workspace()
        if not workspace then return end
        if workspace.tiled_layout == "scrolling" and window and not window.floating then
            hl.dispatch(hl.dsp.layout("focus ${direction}"))
        else
            hl.dispatch(hl.dsp.focus({ direction = "${direction}" }))
        end
    end`
}

function stepWorkspace(direction) {
    if (direction !== -1 && direction !== 1) return ""
    return `function()
        local active = hl.get_active_workspace()
        if not active or active.special or not active.monitor then return end
        local target = nil
        local highest = 0
        local direction = ${direction}
        for _, workspace in ipairs(hl.get_workspaces()) do
            if not workspace.special and workspace.id > 0 then
                highest = math.max(highest, workspace.id)
                if workspace.monitor and workspace.monitor.id == active.monitor.id then
                    local distance = (workspace.id - active.id) * direction
                    if distance > 0 and (not target or distance < (target.id - active.id) * direction) then
                        target = workspace
                    end
                end
            end
        end
        if target then
            hl.dispatch(hl.dsp.focus({ workspace = target }))
        elseif direction > 0 and active.windows > 0 then
            hl.dispatch(hl.dsp.focus({ workspace = tostring(highest + 1) }))
        end
    end`
}
