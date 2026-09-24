local Device = require("device")
local Geometry = require("core/geometry")
local ffi = require("ffi")
local logger = require("logger")

local TOOL_TYPE_PEN = Device.input.TOOL_TYPE_PEN
local TOOL_TYPE_ERASER = Device.input.TOOL_TYPE_ERASER
local TOOL_TYPE_HIGHLIGHTER = Device.input.TOOL_TYPE_HIGHLIGHTER
local TOOL_TYPE_FINGER = Device.input.TOOL_TYPE_FINGER

local PenInput = {}

PenInput.current = nil
local gesture_hook_added = false
local event_hook_added = false

function PenInput:new(plugin)
    local o = {
        plugin = plugin,
        pen_active = false,
        pen_lift_pending = false,
        pen_lift_x = 0,
        pen_lift_y = 0,
        lift_match_radius = 20,
        eraser_active = false,
        eraser_x = nil,
        eraser_y = nil,
        bigme_active = false,
        bigme_pointer_tool = nil,
        bigme_width = nil,
        bigme_height = nil,
        bigme_logged_pen = false,
        bigme_eraser_removed = 0,
    }
    return setmetatable(o, { __index = PenInput })
end

function PenInput:isPenTool(slot)
    local tool = slot.tool or TOOL_TYPE_PEN
    return tool == TOOL_TYPE_PEN
        or tool == TOOL_TYPE_ERASER
        or tool == TOOL_TYPE_HIGHLIGHTER
end

function PenInput:transformCoordinates(x, y)
    local Screen = Device.screen
    return Geometry.transformForRotation(
        x, y, Screen:getTouchRotation(), Screen:getWidth(), Screen:getHeight())
end

function PenInput:isPenActive()
    return self.pen_active
end

function PenInput:setBigmeActive(active, width, height)
    self.bigme_active = active
    self.bigme_width = width
    self.bigme_height = height
    self.bigme_pointer_tool = nil
    self.bigme_logged_pen = false
    self.pen_active = false
    self:resetEraserState()
end

function PenInput:installGestureHook()
    local Input = Device.input
    if gesture_hook_added or not Input or not Input.registerGestureAdjustHook then return end
    gesture_hook_added = true
    Input:registerGestureAdjustHook(function(input, ges)
        local pen_input = PenInput.current
        if pen_input
            and not pen_input.plugin:isOverlayActive()
            and pen_input:isPenActive() then
            ges.ges = "none"
        elseif pen_input
            and not pen_input.plugin:isOverlayActive()
            and pen_input.pen_lift_pending then
            local dx = math.abs((ges.pos and ges.pos.x or 0) - pen_input.pen_lift_x)
            local dy = math.abs((ges.pos and ges.pos.y or 0) - pen_input.pen_lift_y)
            if dx <= pen_input.lift_match_radius and dy <= pen_input.lift_match_radius then
                ges.ges = "none"
            end
            pen_input.pen_lift_pending = false
        end
    end)
end

function PenInput:installEventHook()
    local Input = Device.input
    if event_hook_added or not Input or not Input.registerEventAdjustHook then return end
    event_hook_added = true
    local C = ffi.C
    local current_slot = -1
    local pen_slot_down = false
    Input:registerEventAdjustHook(function(input, ev)
        if ev.type ~= C.EV_ABS then return end
        if not input.pen_slot then return end
        if ev.code == C.ABS_MT_SLOT then
            current_slot = ev.value
        elseif ev.code == C.ABS_MT_TRACKING_ID then
            if current_slot == input.pen_slot then
                pen_slot_down = ev.value >= 0
            elseif ev.value >= 0 and pen_slot_down then
                -- Drop the touchscreen mirror of the pen before it reaches the
                -- GestureDetector (it would otherwise mirror every gesture).
                logger.dbg("PenInput: dropped mirror contact in slot", current_slot)
                ev.value = -1
            end
        end
    end)
end

function PenInput:register()
    self:installGestureHook()
    self:installEventHook()
    PenInput.current = self
    self:registerPlatformInput()
end

function PenInput:unregister()
    self:unregisterPlatformInput()
    if PenInput.current == self then
        PenInput.current = nil
    end
end

function PenInput:registerPlatformInput()
    local Input = Device.input
    if Input and Input.registerStylusCallback then
        Input:registerStylusCallback(function(input, slot)
            return self:onStylusEvent(input, slot)
        end)
    else
        logger.warn("PenInput: stylus callback API not available")
    end
end

function PenInput:unregisterPlatformInput()
    local Input = Device.input
    if Input and Input.unregisterStylusCallback then
        Input:unregisterStylusCallback()
    end
end

function PenInput:resetEraserState()
    self.eraser_active = false
    self.eraser_x, self.eraser_y = nil, nil
    self.plugin.eraser_active = false
end

function PenInput:onStylusEvent(input, slot)
    local plugin = self.plugin
    local x, y = self:transformCoordinates(slot.x or 0, slot.y or 0)
    local ret = false

    logger.dbg("PenInput:onStylusEvent",
        "slot=", slot.slot, "tool=", slot.tool, "id=", slot.id,
        "raw=", slot.x, slot.y, "pos=", x, y,
        "eraser=", self.eraser_active,
        "input_eraser=", input.stylus_eraser_active)

    if slot.tool == TOOL_TYPE_FINGER
        and input.pen_slot and slot.slot == input.pen_slot then
        if not (slot.id and slot.id >= 0) then
            self:resetEraserState()
        end
        return true
    end

    if not self:isPenTool(slot) then
        return false
    end

    if self.bigme_active then
        -- Bigme's framework callback supplies the authoritative coordinates and
        -- tool (including the reverse-tip eraser). Keep the evdev copy out of
        -- KOReader's gesture detector without processing it a second time.
        if not plugin:isEnabled() then
            return false
        end
        if plugin:isOverlayActive() then
            if not (slot.id and slot.id >= 0) then self.pen_active = false end
            return self.pen_active
        end
        return true
    end

    if plugin:isOverlayActive() then
        if self.pen_active then
            if not (slot.id and slot.id >= 0) then
                self.pen_active = false
            end
            return true
        end
        return false
    end

    local eraser_tool = slot.tool == TOOL_TYPE_ERASER
        or (slot.tool == TOOL_TYPE_PEN and input.stylus_eraser_active)
    if eraser_tool then
        return self:onEraserEvent(x, y, slot.id or -1)
    end

    self:resetEraserState()

    if slot.id and slot.id >= 0 then
        if not plugin:isEnabled() then return false end
        self.pen_lift_pending = false
        self.pen_active = true

        if plugin.current_stroke then
            plugin:addStrokePoint(x, y)
        else
            self.pen_lift_x = x
            self.pen_lift_y = y
            plugin:startStroke(x, y)
        end
        ret = true
    else
        local was_active = self.pen_active
        self.pen_active = false
        if plugin.current_stroke then
            plugin:endStroke()
            if was_active then
                self.pen_lift_pending = true
            end
        end

        if plugin:isEnabled() and was_active then
            ret = true
        end
    end
    return ret
end

function PenInput:onBigmeEvent(event_type, x, y, pressure, tool_type)
    local plugin = self.plugin
    local ACTION_DOWN, ACTION_MOVE, ACTION_UP, ACTION_LEAVE = 1, 2, 3, 4
    local TOOL_PEN, TOOL_ERASER, TOOL_FINGER = 0, 1, 2
    if tool_type == TOOL_FINGER then return end

    local screen = Device.screen
    if self.bigme_width and self.bigme_width > 0 then
        x = x * screen:getWidth() / self.bigme_width
    end
    if self.bigme_height and self.bigme_height > 0 then
        y = y * screen:getHeight() / self.bigme_height
    end

    if event_type == ACTION_UP or event_type == ACTION_LEAVE then
        if self.bigme_pointer_tool == TOOL_ERASER then
            logger.info("PenInput: Bigme eraser contact ended; strokes removed =",
                self.bigme_eraser_removed)
            self:resetEraserState()
        elseif self.bigme_pointer_tool == TOOL_PEN then
            local was_active = self.pen_active
            self.pen_active = false
            if plugin.current_stroke then
                plugin:endStroke()
                if was_active then
                    self.pen_lift_x, self.pen_lift_y = x, y
                    self.pen_lift_pending = true
                end
            end
        end
        self.bigme_pointer_tool = nil
        return
    end
    if event_type ~= ACTION_DOWN and event_type ~= ACTION_MOVE then return end

    if plugin:isOverlayActive() or not plugin:isEnabled() then
        if event_type == ACTION_DOWN then
            self.bigme_pointer_tool = nil
            self.pen_active = false
            self:resetEraserState()
        end
        return
    end

    if tool_type == TOOL_ERASER then
        if self.bigme_pointer_tool ~= TOOL_ERASER and event_type ~= ACTION_DOWN then
            return
        end
        if event_type == ACTION_DOWN then
            self.bigme_eraser_removed = 0
            logger.info("PenInput: Bigme eraser event received at", x, y,
                "visible strokes =", #plugin.store.strokes)
        end
        self.bigme_pointer_tool = TOOL_ERASER
        self.pen_active = false
        self:onEraserEvent(x, y, 1)
        return
    end
    if tool_type ~= TOOL_PEN then return end
    if self.bigme_pointer_tool ~= TOOL_PEN and event_type ~= ACTION_DOWN then return end

    if event_type == ACTION_DOWN and not self.bigme_logged_pen then
        self.bigme_logged_pen = true
        logger.info("PenInput: Bigme pen event received at", x, y)
    end
    self.bigme_pointer_tool = TOOL_PEN
    self:resetEraserState()
    self.pen_lift_pending = false
    self.pen_active = true
    if event_type == ACTION_DOWN then
        plugin:startStroke(x, y)
    elseif plugin.current_stroke then
        plugin:addStrokePoint(x, y)
    elseif not plugin.bigme_direct_ink then
        plugin:startStroke(x, y)
    end
    -- With the OEM preview a stroke only starts on pen-down: the bridge locks
    -- the preview to the writable area of the down point, like Base.apk.
end

function PenInput:onEraserEvent(x, y, id)
    local plugin = self.plugin
    if plugin:isOverlayActive() then
        self:resetEraserState()
        return false
    end
    if id >= 0 then
        if plugin.current_stroke then
            self.pen_active = false
            plugin:endStroke()
        end
        local from_x = self.eraser_active and self.eraser_x or x
        local from_y = self.eraser_active and self.eraser_y or y
        self.eraser_active = true
        plugin.eraser_active = true
        self.eraser_x, self.eraser_y = x, y
        self.bigme_eraser_removed = self.bigme_eraser_removed
            + plugin:eraseStrokesAlong(from_x, from_y, x, y)
        return true
    else
        self:resetEraserState()
        return true
    end
end

return PenInput
