local Blitbuffer = require("ffi/blitbuffer")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local Dispatcher = require("dispatcher")
local Geometry = require("core/geometry")
local Draw = require("core/draw")
local PenInput = require("core/pen")
local Bigme = require("core/bigme")
local Paged = require("core/mapping/paged")
local Reflow = require("core/mapping/reflow")
local StrokeStore = require("core/store")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local Event = require("ui/event")
local ButtonDialog = require("ui/widget/buttondialog")
local ButtonSelector = require("ui/widget/buttonselector")
local InputDialog = require("ui/widget/inputdialog")
local SpinWidget = require("ui/widget/spinwidget")
local Widget = require("ui/widget/widget")
local Geom = require("ui/geometry")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local util = require("util")
local time = require("ui/time")
local _ = require("gettext")
local T = require("ffi/util").template

local Screen = Device.screen

local Version = require("version")

local MIN_KOREADER_VERSION = 202607020060 -- nightly v2026.07.2-60-g74f37d14c
local current_version = Version:getNormalizedCurrentVersion()

if not current_version or current_version < MIN_KOREADER_VERSION then
    local warned = false
    local IncompatibleVersion = InputContainer:extend{
        name = "stylus_annotations",
        is_doc_only = true,
        init = function()
            if warned then return end
            warned = true
            UIManager:show(InfoMessage:new{
                text = T(
                    _("The Stylus annotations plugin requires 202607020060 (nightly) build of KOReader from 2026.08.12 or later.\n"
                      .. "Current version: %1"),
                    Version:getShortVersion()),
            })
        end,
    }
    return IncompatibleVersion
end

local SAVE_DELAY_MS = 800
local HOLD_MOVE_THRESHOLD_PX = 15
local LIVE_REFRESH_INTERVAL_MS = 33
local FAST_LIVE_REFRESH_INTERVAL_MS = 16
local LIVE_MOVE_THRESHOLD_PX = 1
local LIVE_MOVE_THRESHOLD_PX2 = LIVE_MOVE_THRESHOLD_PX * LIVE_MOVE_THRESHOLD_PX
local LIVE_MODE_DEFERRED = "deferred"
local LIVE_MODE_ACCURATE = "live_accurate"
local LIVE_MODE_FAST = "live_fast"
-- Draw live ink through Bigme's handwriting canvas (Base.apk's path): the
-- bridge's worker thread paints and commits with the 1029 waveform, and
-- KOReader repaints the finished strokes once the pen has been idle for
-- BIGME_FINALIZE_DELAY_S. Set to false to fall back to KOReader rendering.
local USE_BIGME_OEM_CANVAS_LIVE_INK = true
-- HandwritingManager commits the normal surface ~100 ms after the last ink.
local BIGME_FINALIZE_DELAY_S = 0.15
-- Lua only consumes stroke data when the OEM canvas draws the preview.
local BIGME_POLL_INTERVAL_S = 0.008
local BIGME_DIRECT_INK_POLL_INTERVAL_S = 0.016
local DEFAULT_HOLD_INTERVAL_MS = 500
local DEFAULT_HOLD_PAN_RATE = 30
local LOW_HOLD_PAN_RATE = 5

local MIN_STROKE_WIDTH = 1
local MAX_STROKE_WIDTH = 30
local DEFAULT_WIDTH = 2
local DEFAULT_COLOR = "orange"
local WIDTH_CHOICES = { 1, 2, 3, 5, 8, 12 }

local FULL_SCREEN_ZONE = {
    ratio_x = 0, ratio_y = 0,
    ratio_w = 1, ratio_h = 1,
}

local function holdIntervalSeconds()
    local ms = G_reader_settings:readSetting("ges_hold_interval_ms") or DEFAULT_HOLD_INTERVAL_MS
    return ms / 1000
end

-- Same pan rate KOReader uses for finger text selection.
local function holdPanIntervalSeconds()
    local rate = G_reader_settings:readSetting("hold_pan_rate")
        or (Screen.low_pan_rate and LOW_HOLD_PAN_RATE or DEFAULT_HOLD_PAN_RATE)
    return 1 / rate
end

local function clampToScreen(x, y, w, h)
    return Geometry.clampRect(x, y, w, h, Screen:getWidth(), Screen:getHeight())
end

local PREVIEW_POINTS = {
    {10.8,1.1}, {8.3,4.3}, {6.2,14.0}, {4.3,28.0}, {2.9,40.9}, {1.4,55.9},
    {0.4,68.8}, {0.0,81.7}, {0.4,94.6}, {2.9,100.0}, {5.2,98.9}, {8.1,92.5},
    {10.1,86.0}, {12.6,78.5}, {15.1,69.9}, {17.6,61.3}, {20.1,52.7}, {22.6,43.0},
    {25.1,34.4}, {27.3,25.8}, {29.6,19.4}, {31.7,11.8}, {34.2,5.4}, {36.6,0.0},
    {38.9,1.1}, {39.3,12.9}, {39.1,26.9}, {38.9,38.7}, {39.1,54.8}, {41.0,66.7},
    {43.9,68.8}, {46.6,64.5}, {49.5,58.1}, {51.8,51.6}, {53.8,46.2}, {56.5,41.9},
    {59.2,39.8}, {62.1,43.0}, {64.2,49.5}, {66.5,60.2}, {68.9,66.7}, {72.5,66.7},
    {74.9,62.4}, {77.8,57.0}, {81.0,49.5}, {84.3,40.9}, {87.6,33.3}, {90.5,28.0},
    {93.0,22.6}, {95.9,19.4}, {98.1,20.4}, {99.6,31.2}, {100.0,38.7},
}

local WidthPreview = Widget:extend{
    dimen = nil,
    padding = 12,
    paintTo = function(self, bb, x, y)
        local w = self:get_width() * self:get_zoom()
        local pad = self.padding
        local draw_w = self.dimen.w - 2 * pad
        local draw_h = self.dimen.h - 2 * pad
        local pts = {}
        for i = 1, #PREVIEW_POINTS do
            pts[i] = {
                x = x + pad + PREVIEW_POINTS[i][1] / 100 * draw_w,
                y = y + pad + PREVIEW_POINTS[i][2] / 100 * draw_h,
            }
        end
        Draw.stampPath(bb, pts, 0, 0, w / 2, Blitbuffer.COLOR_BLACK)
    end,
}

local StylusAnnotations = InputContainer:extend{
    name = "stylus_annotations",
    is_doc_only = true,

    store = nil,

    touch_zones_registered = false,

    current_stroke = nil,
    pen_x = 0,
    pen_y = 0,
    eraser_active = false,

    hold_timer = nil,
    hold_start_x = 0,
    hold_start_y = 0,

    pen_selecting = false,
    pen_select_pos = nil,
    pen_select_pan_time = nil,

    selected_strokes = {},
    selection_backup = nil,
    selection_backup_x = 0,
    selection_backup_y = 0,
    dirty_region = nil,
    live_mode = LIVE_MODE_ACCURATE,
    live_snapshot = nil,
    live_dirty = nil,
    last_refresh_time = 0,
    pending_save = nil,
    eraser_refresh_timer = nil,
    bigme_start_timer = nil,
    bigme_poll_timer = nil,
    bigme_direct_ink = false,
    bigme_ink_style_key = nil,
    bigme_writable_spec = nil,
    bigme_mirror_hooks = nil,
    bigme_finalize_timer = nil,
    bigme_pending_region = nil,
    bigme_restart_timer = nil,
}

function StylusAnnotations:init()
    self.stroke_id_counter = 0

    self.view = self.ui.view

    self.mapper = (self.ui.paging and Paged:new(self) or Reflow:new(self))
    self.store = StrokeStore:new(self.mapper, logger)

    self:loadSettings()

    self.view:registerViewModule("stylus_annotations", self)

    self.ui.menu:registerToMainMenu(self)

    Dispatcher:registerAction("stylus_annotations_toggle", {
        category = "none",
        event = "StylusAnnotationsToggle",
        title = _("Stylus annotations: toggle drawing"),
        reader = true,
    })

    self.pen_input = PenInput:new(self)
    self.pen_input:register()
    self:setupTouchZones()

    logger.info("StylusAnnotations: initialized, strokes =", #self.store.strokes,
        "eink =", Device:hasEinkScreen(), "live_mode =", self.live_mode)
end

function StylusAnnotations:onReaderReady()
    self:loadStrokes()
    -- Like Base.apk's generateBoxAnnot: turn ink annotations found in the PDF
    -- (our own copies and other apps' ink) into strokes, then bring the PDF's
    -- copies in line with our strokes. Normally everything already matches
    -- (nothing imported, nothing written).
    self:importPdfInkAnnotations()
    self:schedulePdfStylusSync(0)
    self.ui:handleEvent(Event:new("UpdatePos"))
    if Device:isAndroid() then
        if self.bigme_start_timer then
            UIManager:unschedule(self.bigme_start_timer)
        end
        self.bigme_start_timer = function()
            self.bigme_start_timer = nil
            self:startBigmeInput()
        end
        UIManager:nextTick(self.bigme_start_timer)
    end
end

function StylusAnnotations:syncBigmeInkStyle(force)
    if not self.bigme_direct_ink then return false end
    -- Strokes are rendered at width * zoom (set by mapper:initStroke). The
    -- OEM worker draws before Lua sees the pen-down, so use the zoom of the
    -- visible page now; otherwise the preview is thinner than the final ink.
    local pages = self.mapper:getVisiblePages()
    local zoom = pages and pages[1] and self.mapper:getZoom(pages[1]) or 1
    local stroke = { width = self.width, color = self.color, alpha = 1.0, zoom = zoom }
    -- Send the real stroke color; the bridge turns non-black colors into the
    -- dither pattern the bilevel handwriting layer can show (as Base.apk
    -- does), so the ink does not change shade when KOReader repaints it.
    local color = Draw.getRenderColor(stroke, self.ui.highlight):getColorRGB32()
    local argb = string.format("%02X%02X%02X%02X", 0xFF, color.r, color.g, color.b)
    local width = self:getStrokeScreenWidth(stroke)
    local sx, sy = 1, 1
    local view_width = self.pen_input and self.pen_input.bigme_width
    local view_height = self.pen_input and self.pen_input.bigme_height
    if view_width and Screen:getWidth() > 0 then
        sx = view_width / Screen:getWidth()
    end
    if view_height and Screen:getHeight() > 0 then
        sy = view_height / Screen:getHeight()
    end
    width = width * sx
    local enabled = self.live_mode == LIVE_MODE_FAST
        and self:isEnabled() and not self:isOverlayActive()
        and not self.pen_selecting
    local key = table.concat({ enabled and "1" or "0", string.format("%.3f", width), argb }, ",")
    if force or key ~= self.bigme_ink_style_key then
        if not Bigme.setDirectInkStyle(enabled, width, argb) then
            self.bigme_direct_ink = false
            self.bigme_ink_style_key = nil
            logger.warn("StylusAnnotations: could not configure Bigme worker renderer")
            return false
        end
        self.bigme_ink_style_key = key
    end

    local rects = self.mapper:getWritableRects()
    local spec = ""
    if rects then
        local parts = {}
        for i, r in ipairs(rects) do
            parts[i] = string.format("%d,%d,%d,%d",
                math.floor(r.x * sx), math.floor(r.y * sy),
                math.ceil((r.x + r.w) * sx), math.ceil((r.y + r.h) * sy))
        end
        -- No page on screen: nothing is writable.
        spec = #parts > 0 and table.concat(parts, ";") or "0,0,0,0"
    end
    if force or spec ~= self.bigme_writable_spec then
        Bigme.setWritableRects(spec)
        self.bigme_writable_spec = spec
    end
    return true
end

function StylusAnnotations:startBigmeInput()
    if self.bigme_poll_timer then return end
    if not Bigme.probe() then
        logger.info("StylusAnnotations: Bigme handwriting API not available; using KOReader input")
        return
    end

    local started, width, height = Bigme.start()
    if not started then
        logger.warn("StylusAnnotations: Bigme input bridge unavailable:", width)
        return
    end
    self.pen_input:setBigmeActive(true, width, height)
    local oem_canvas_available = Bigme.hasDirectInk()
    self.bigme_direct_ink = USE_BIGME_OEM_CANVAS_LIVE_INK and oem_canvas_available
    self.bigme_ink_style_key = nil
    logger.info("StylusAnnotations: using Bigme input bridge, view =", width, height)
    logger.info("StylusAnnotations: Bigme OEM Canvas available =", oem_canvas_available,
        "live ink enabled =", self.bigme_direct_ink)
    if self.bigme_direct_ink then
        self:startBigmeScreenMirror()
        self:syncBigmeInkStyle(true)
    end

    self.bigme_poll_timer = function()
        if not Bigme.bridge then
            self.bigme_poll_timer = nil
            return
        end
        -- Update the preview state before handling points, so an overlay
        -- that just opened stops OEM ink as early as possible.
        if self.bigme_direct_ink then
            self:syncBigmeInkStyle()
        end
        local batch, direct_ink_available = Bigme.drain()
        if batch and batch ~= "" then
            -- Coalescing moves saves Lua rendering work, but with the OEM
            -- preview Lua only records points: keep them all, so the final
            -- repaint matches the ink already on screen.
            local coalesce_moves = not self.bigme_direct_ink
            local pending_move
            local function dispatchBigmeEvent(event)
                self.pen_input:onBigmeEvent(
                    event[1], event[2], event[3], event[4], event[5])
            end
            for event in batch:gmatch("[^;]+") do
                local event_type, x, y, pressure, tool_type = event:match(
                    "^(%-?%d+),(%-?%d+),(%-?%d+),(%-?%d+),(%-?%d+),%-?%d+$")
                if event_type then
                    local decoded = {
                        tonumber(event_type), tonumber(x), tonumber(y),
                        tonumber(pressure), tonumber(tool_type),
                    }
                    if decoded[1] == 2 and coalesce_moves then
                        if pending_move and pending_move[5] ~= decoded[5] then
                            dispatchBigmeEvent(pending_move)
                        end
                        pending_move = decoded
                    else
                        if pending_move then
                            dispatchBigmeEvent(pending_move)
                            pending_move = nil
                        end
                        dispatchBigmeEvent(decoded)
                    end
                end
            end
            if pending_move then dispatchBigmeEvent(pending_move) end
        end
        if self.bigme_direct_ink and not direct_ink_available then
            self.bigme_direct_ink = false
            logger.warn("StylusAnnotations: Bigme OEM Canvas failed; falling back to KOReader live refresh")
            self:finalizeBigmeInk()
            if self.current_stroke and self.dirty_region then
                self:refreshRegion(self.dirty_region)
            end
        end
        if self.bigme_poll_timer then
            UIManager:scheduleIn(self:bigmePollInterval(), self.bigme_poll_timer)
        end
    end
    UIManager:scheduleIn(self:bigmePollInterval(), self.bigme_poll_timer)
end

function StylusAnnotations:bigmePollInterval()
    return self.bigme_direct_ink and BIGME_DIRECT_INK_POLL_INTERVAL_S
        or BIGME_POLL_INTERVAL_S
end

-- Queue a finished OEM-previewed stroke for KOReader's repaint. Like
-- HandwritingManager, the normal surface is only committed once the pen has
-- been idle, so quick consecutive strokes are not interrupted by refreshes.
function StylusAnnotations:queueBigmeFinalize(region)
    if region then
        self.bigme_pending_region = Geometry.mergeRect(self.bigme_pending_region,
            region.x, region.y, region.w, region.h)
    end
    if self.bigme_finalize_timer then
        UIManager:unschedule(self.bigme_finalize_timer)
    end
    self.bigme_finalize_timer = function()
        self.bigme_finalize_timer = nil
        self:finalizeBigmeInk()
    end
    UIManager:scheduleIn(BIGME_FINALIZE_DELAY_S, self.bigme_finalize_timer)
end

function StylusAnnotations:cancelBigmeFinalizeTimer()
    if self.bigme_finalize_timer then
        UIManager:unschedule(self.bigme_finalize_timer)
        self.bigme_finalize_timer = nil
    end
end

-- Repaint pending strokes now. The strokes are already in the store, so the
-- dialog repaint draws them; refreshRegion re-enables normal commits right
-- before KOReader posts that repaint.
function StylusAnnotations:finalizeBigmeInk()
    self:cancelBigmeFinalizeTimer()
    local region = self.bigme_pending_region
    self.bigme_pending_region = nil
    if region then
        self:refreshRegion(region)
    end
end

function StylusAnnotations:stopBigmeInput()
    self:finalizeBigmeInk()
    if self.bigme_restart_timer then
        UIManager:unschedule(self.bigme_restart_timer)
        self.bigme_restart_timer = nil
    end
    if self.bigme_poll_timer then
        UIManager:unschedule(self.bigme_poll_timer)
        self.bigme_poll_timer = nil
    end
    self.pen_input:setBigmeActive(false)
    self:stopBigmeScreenMirror()
    Bigme.close()
    self.bigme_direct_ink = false
    self.bigme_ink_style_key = nil
end

-- The framebuffer refresh implementations KOReader calls with the physical
-- rect it posts to the panel (ffi/framebuffer_android.lua).
local SCREEN_REFRESH_IMPS = {
    "refreshFullImp", "refreshPartialImp", "refreshFlashPartialImp",
    "refreshUIImp", "refreshFlashUIImp", "refreshFastImp",
}

-- A Bigme handwriting commit shows the service canvas as-is inside its rect,
-- so the canvas must hold what the panel shows. Give the bridge KOReader's
-- framebuffer and report every refreshed rect; it copies them between
-- strokes. Without this, commit rects show white (or black) around the ink.
function StylusAnnotations:startBigmeScreenMirror()
    self:stopBigmeScreenMirror()
    local bb = Screen.full_bb or Screen.bb
    if not bb or bb:getType() ~= Blitbuffer.TYPE_BBRGB32 or bb:getRotation() ~= 0 then
        logger.info("StylusAnnotations: Bigme screen mirror unsupported for this framebuffer")
        return false
    end
    if not Bigme.setScreenBuffer(bb) then
        logger.warn("StylusAnnotations: Bigme screen mirror unavailable")
        return false
    end
    local saved = {}
    for _, name in ipairs(SCREEN_REFRESH_IMPS) do
        local original = Screen[name]
        if original then
            saved[name] = rawget(Screen, name) or false
            Screen[name] = function(fb, x, y, w, h, ...)
                local r1, r2, r3 = original(fb, x, y, w, h, ...)
                pcall(function()
                    local current = fb.full_bb or fb.bb
                    if current ~= Bigme.screen_bb then
                        -- Framebuffer reallocated (resize): hand over the new one.
                        Bigme.setScreenBuffer(current)
                    else
                        Bigme.screenUpdated(x or 0, y or 0,
                            w or current:getWidth(), h or current:getHeight(),
                            current:getInverse() == 1)
                    end
                end)
                return r1, r2, r3
            end
        end
    end
    self.bigme_mirror_hooks = saved
    logger.info("StylusAnnotations: Bigme screen mirror enabled")
    return true
end

function StylusAnnotations:stopBigmeScreenMirror()
    local saved = self.bigme_mirror_hooks
    if not saved then return end
    for name, original in pairs(saved) do
        rawset(Screen, name, original or nil)
    end
    self.bigme_mirror_hooks = nil
end

-- Bigme's canvas and view layout are bound to the window geometry; rebuild
-- the client after rotation or resize, as HandwritingManager restarts on
-- viewChanged.
function StylusAnnotations:onSetDimensions()
    if not self.bigme_poll_timer or self.bigme_restart_timer then return end
    self.bigme_restart_timer = function()
        self.bigme_restart_timer = nil
        if self.current_stroke then self:endStroke() end
        self:stopBigmeInput()
        self:startBigmeInput()
    end
    UIManager:nextTick(self.bigme_restart_timer)
end

-- Page changes repaint the whole view; make sure it is not held back by the
-- handwriting layer.
function StylusAnnotations:onPageUpdate()
    if self.bigme_direct_ink then self:finalizeBigmeInk() end
end

function StylusAnnotations:onPosUpdate()
    if self.bigme_direct_ink then self:finalizeBigmeInk() end
end

function StylusAnnotations:onCloseDocument()
    if self.pending_save then
        UIManager:unschedule(self.pending_save)
        self.pending_save = nil
    end
    self:cancelHoldTimer()
    self.pen_selecting = false
    self.pen_select_pos = nil
    if self.bigme_start_timer then
        UIManager:unschedule(self.bigme_start_timer)
        self.bigme_start_timer = nil
    end
    if self.eraser_refresh_timer then
        UIManager:unschedule(self.eraser_refresh_timer)
        self.eraser_refresh_timer = nil
    end
    -- The document view is going away; Bigme.close() restores normal commits.
    self:cancelBigmeFinalizeTimer()
    self.bigme_pending_region = nil
    if self.pdf_sync_timer then
        UIManager:unschedule(self.pdf_sync_timer)
        self.pdf_sync_timer = nil
    end
    self:stopBigmeInput()
    if self.current_stroke then
        self:endStroke()
    end
    self.current_stroke = nil
    self:cancelLive()
    self.pen_input:unregister()
    self:saveStrokes()
end

function StylusAnnotations:isEnabled()
    return G_reader_settings:readSetting("stylus_annotations_enabled") ~= false
end

function StylusAnnotations:setEnabled(enabled)
    G_reader_settings:saveSetting("stylus_annotations_enabled", enabled)
end

function StylusAnnotations:liveInkEnabled()
    return self.live_mode ~= LIVE_MODE_DEFERRED
end

function StylusAnnotations:updateLiveMode(enabled)
    if enabled then
        -- Some Android e-ink readers (including Bigme) report themselves as
        -- non-e-ink to KOReader. Use the incremental path there as well, so a
        -- growing stroke is not repeatedly restored and repainted in full.
        self.live_mode = (Device:hasEinkScreen() or Device:isAndroid())
            and LIVE_MODE_FAST or LIVE_MODE_ACCURATE
    else
        self.live_mode = LIVE_MODE_DEFERRED
    end
end

function StylusAnnotations:isPenSelectEnabled()
    return G_reader_settings:readSetting("stylus_annotations_pen_select") ~= false
end

function StylusAnnotations:loadSettings()
    local ds = self.ui.doc_settings
    local live_ink_enabled = ds:readSetting("stylus_annotations_live_ink") ~= false
    self:updateLiveMode(live_ink_enabled)
    self.width = ds:readSetting("stylus_annotations_width") or DEFAULT_WIDTH
    self.color = ds:readSetting("stylus_annotations_color") or DEFAULT_COLOR
end

function StylusAnnotations:saveSettings()
    local ds = self.ui.doc_settings
    ds:saveSetting("stylus_annotations_live_ink", self:liveInkEnabled())
    ds:saveSetting("stylus_annotations_width", self.width)
    ds:saveSetting("stylus_annotations_color", self.color)
end

function StylusAnnotations:isPenActive()
    return self.pen_input and self.pen_input:isPenActive() or false
end

function StylusAnnotations:isOverlayActive()
    local top = UIManager:getTopmostVisibleWidget()
    if not top then return false end
    return (top.name or top.id) ~= "ReaderUI"
end

function StylusAnnotations:setupTouchZones()
    if self.touch_zones_registered then return end
    self.ui:registerTouchZones({
        {
            id = "stylus_annotations_tap",
            ges = "tap",
            screen_zone = FULL_SCREEN_ZONE,
            overrides = {
                "readerfooter_holding",
                "readerfooter_tap",
                "readerconfigmenu_tap",
                "readerconfigmenu_ext_tap",
                "tap_forward",
                "tap_backward",
                "readermenu_tap",
                "readermenu_ext_tap",
                "tap_top_left_corner",
                "tap_top_right_corner",
                "tap_left_bottom_corner",
                "tap_right_bottom_corner",
            },
            handler = function(ges)
                return self:onStrokeTap(ges)
            end,
        },

        {
            id = "stylus_annotations_hold",
            ges = "hold",
            screen_zone = FULL_SCREEN_ZONE,
            overrides = {
                "readerhighlight_hold",
                "readerfooter_hold",
            },
            handler = function(ges)
                return self:onStrokeHold(ges)
            end,
        },
    })
    self.touch_zones_registered = true
end

function StylusAnnotations:selectStrokeAt(ges, chain)
    if self.current_stroke then return true end
    if self:isPenActive() then return true end
    if self:isOverlayActive() then return false end
    local stroke = self:findStrokeAt(ges)
    if not stroke then return false end
    if chain then
        self:showStrokeMenu(self.store:selectStrokesChain(stroke))
    else
        self:showStrokeMenu({ stroke })
    end
    return true
end

function StylusAnnotations:onStrokeTap(ges)
    return self:selectStrokeAt(ges)
end

function StylusAnnotations:onStrokeHold(ges)
    return self:selectStrokeAt(ges, true)
end

function StylusAnnotations:findStrokeAt(ges)
    if not ges or not ges.pos then return nil end
    return self.store:findStrokeAt(ges.pos.x, ges.pos.y)
end

function StylusAnnotations:startStroke(x, y)
    self.stroke_id_counter = self.stroke_id_counter + 1
    -- Keep writing without a normal refresh between strokes.
    self:cancelBigmeFinalizeTimer()
    local stroke = {
        id = tostring(self.stroke_id_counter),
        width = self.width,
        color = self.color,
        alpha = 1.0,
        datetime = os.time(),
    }
    if not self.mapper:initStroke(stroke, x, y) then
        self.stroke_id_counter = self.stroke_id_counter - 1
        return
    end
    self.current_stroke = stroke
    self.pen_x, self.pen_y = x, y
    self.last_flush_x, self.last_flush_y = x, y
    self.dirty_region = nil
    self.live_dirty = nil
    self.last_refresh_time = 0
    self.stroke_timing = {
        start = time.now(),
        snapshot_ms = 0,
        paint_ms = 0,
        flush_count = 0,
        finalize_ms = 0,
    }

    if self.live_mode ~= LIVE_MODE_DEFERRED then
        local bigme_fast_preview = self.live_mode == LIVE_MODE_FAST
            and self.pen_input and self.pen_input.bigme_active
        if not bigme_fast_preview then
            self:takeLiveSnapshot()
        end
        if self.live_mode == LIVE_MODE_FAST and not self.bigme_direct_ink then
            local sw = self:getStrokeScreenWidth(stroke)
            Draw.stampDisc(Screen.bb, x, y, sw / 2,
                Draw.getRenderColor(stroke, self.ui.highlight))
        end
    end

    self.hold_start_x, self.hold_start_y = x, y
    self:scheduleHoldTimer()
    return true
end

function StylusAnnotations:addStrokePoint(x, y)
    local stroke = self.current_stroke
    if not stroke then return false end
    if not self.mapper:addPoint(stroke, x, y) then return false end

    local sw = self:getStrokeScreenWidth(stroke)
    local pad = math.floor(sw / 2) + 1
    local seg_x = math.min(self.pen_x, x) - pad
    local seg_y = math.min(self.pen_y, y) - pad
    local seg_w = math.abs(x - self.pen_x) + 2 * pad
    local seg_h = math.abs(y - self.pen_y) + 2 * pad
    if self.live_mode == LIVE_MODE_FAST and not self.bigme_direct_ink then
        self:stampLiveSegment(stroke, x, y, sw,
            Draw.getRenderColor(stroke, self.ui.highlight))
    end
    self:accumulateSegment(seg_x, seg_y, seg_w, seg_h)

    self.pen_x, self.pen_y = x, y

    if self.hold_timer
        and (math.abs(x - self.hold_start_x) > HOLD_MOVE_THRESHOLD_PX
            or math.abs(y - self.hold_start_y) > HOLD_MOVE_THRESHOLD_PX) then
        self:cancelHoldTimer()
    end
    return true
end

function StylusAnnotations:stampLiveSegment(stroke, x, y, sw, color)
    local t0 = time.now()
    Draw.stampPath(Screen.bb, {
        { x = self.pen_x, y = self.pen_y },
        { x = x, y = y },
    }, 0, 0, sw / 2, color)
    if self.stroke_timing then
        self.stroke_timing.paint_ms = self.stroke_timing.paint_ms
            + time.to_ms(time.now() - t0)
    end
end

function StylusAnnotations:takeLiveSnapshot()
    local t0 = time.now()
    if self.live_snapshot then
        self.live_snapshot:free()
        self.live_snapshot = nil
    end
    self.live_snapshot = Screen.bb:copy()
    if self.stroke_timing then
        self.stroke_timing.snapshot_ms = time.to_ms(time.now() - t0)
    end
end

function StylusAnnotations:accumulateSegment(x, y, w, h)
    self.dirty_region = Geometry.mergeRect(self.dirty_region, x, y, w, h)
    if self.live_mode ~= LIVE_MODE_DEFERRED then
        self.live_dirty = Geometry.mergeRect(self.live_dirty, x, y, w, h)
        if self.bigme_direct_ink and self.live_mode == LIVE_MODE_FAST then return end
        if self.live_mode == LIVE_MODE_FAST and not self.live_snapshot then
            self:flushFastIncremental()
            return
        end
        self:flushLiveThrottled()
    end
end

function StylusAnnotations:flushFastIncremental()
    local ld = self.live_dirty
    if not ld or ld.w <= 0 or ld.h <= 0 then return end
    local now = time.now()
    if time.to_ms(now - self.last_refresh_time) < self:liveRefreshInterval() then return end
    self.last_refresh_time = now
    self.live_dirty = nil
    local dx, dy, dw, dh = clampToScreen(ld.x, ld.y, ld.w, ld.h)
    if dx then
        UIManager:setDirty(nil, "fast", Geom:new{x = dx, y = dy, w = dw, h = dh})
    end
    if self.stroke_timing then
        self.stroke_timing.flush_count = self.stroke_timing.flush_count + 1
    end
end

function StylusAnnotations:scheduleHoldTimer()
    self:cancelHoldTimer()
    self.hold_timer = function()
        self.hold_timer = nil
        self:onStrokeHoldTimer()
    end
    UIManager:scheduleIn(holdIntervalSeconds(), self.hold_timer)
end

function StylusAnnotations:cancelHoldTimer()
    if self.hold_timer then
        UIManager:unschedule(self.hold_timer)
        self.hold_timer = nil
    end
end

function StylusAnnotations:onStrokeHoldTimer()
    local stroke = self.current_stroke
    if not stroke then return end
    local dx = self.pen_x - self.hold_start_x
    local dy = self.pen_y - self.hold_start_y
    if dx * dx + dy * dy > HOLD_MOVE_THRESHOLD_PX * HOLD_MOVE_THRESHOLD_PX then return end
    local held = self.store:findStrokeAt(self.hold_start_x, self.hold_start_y)
    if not held and self:isPenSelectEnabled() then
        self:startPenSelection(self.pen_x, self.pen_y)
        return
    end
    self:onStrokeCancel()
    if held then
        self:showStrokeMenu({ held })
    end
end

-- Holding the pen still hands the contact over to ReaderHighlight, like a
-- finger long-press does (its touch zones never see the pen's events): on an
-- existing highlight it opens the highlight menu (its tap handler), anywhere
-- else it turns the rest of the contact into a text selection (its hold,
-- hold_pan and hold_release handlers).
function StylusAnnotations:penSelectionGesture(x, y)
    return {
        ges = "hold",
        pos = Geom:new{ x = x, y = y, w = 0, h = 0 },
        time = time.realtime(),
    }
end

function StylusAnnotations:startPenSelection(x, y)
    local highlight = self.ui.highlight
    -- Stop the OEM ink before the stroke is dropped, so the bridge does not
    -- draw the rest of this contact.
    self.pen_selecting = true
    self:syncBigmeInkStyle()
    self:onStrokeCancel()
    local ok, handled = false, false
    if highlight and #self.view.highlight.visible_boxes > 0 then
        ok, handled = pcall(highlight.onTap, highlight, nil, self:penSelectionGesture(x, y))
        if not ok then
            logger.err("StylusAnnotations: pen hold on highlight failed:", handled)
        elseif handled then
            self.pen_selecting = false
            self:syncBigmeInkStyle()
            return true
        end
        ok, handled = false, false
    end
    if highlight then
        ok, handled = pcall(highlight.onHold, highlight, nil, self:penSelectionGesture(x, y))
        if not ok then
            logger.err("StylusAnnotations: pen selection failed to start:", handled)
        end
    end
    if not (ok and handled and highlight.hold_pos) then
        -- No text under the pen (or something else took the hold, e.g. an
        -- image viewer): the contact just continues as ordinary writing.
        self.pen_selecting = false
        self:syncBigmeInkStyle()
        return false
    end
    self.pen_select_pos = nil
    self.pen_select_pan_time = time.now()
    return true
end

function StylusAnnotations:flushPenSelectionPan()
    local pos = self.pen_select_pos
    if not pos then return end
    self.pen_select_pos = nil
    self.pen_select_pan_time = time.now()
    local highlight = self.ui.highlight
    local ok, err = pcall(highlight.onHoldPan, highlight, nil,
        self:penSelectionGesture(pos.x, pos.y))
    if not ok then
        logger.err("StylusAnnotations: pen selection pan failed:", err)
    end
end

function StylusAnnotations:penSelectionMove(x, y)
    if not self.pen_selecting then return end
    self.pen_select_pos = { x = x, y = y }
    local elapsed = time.to_s(time.now() - self.pen_select_pan_time)
    if elapsed >= holdPanIntervalSeconds() then
        self:flushPenSelectionPan()
    end
end

function StylusAnnotations:endPenSelection()
    if not self.pen_selecting then return end
    self:flushPenSelectionPan()
    self.pen_selecting = false
    self.pen_select_pos = nil
    self:syncBigmeInkStyle()
    local highlight = self.ui.highlight
    local ok, err = pcall(highlight.onHoldRelease, highlight)
    if not ok then
        logger.err("StylusAnnotations: pen selection release failed:", err)
    end
end

function StylusAnnotations:onStrokeCancel()
    self.current_stroke = nil
    self.dirty_region = nil
    self.stroke_timing = nil
    self:cancelLive()
    self:cancelBigmeFinalizeTimer()
    self.bigme_pending_region = nil
    local direct_ink = self.bigme_direct_ink
    UIManager:setDirty(self.view.dialog, function()
        if direct_ink then Bigme.commitNormal() end
        return "partial"
    end)
end

function StylusAnnotations:endStroke()
    self:cancelHoldTimer()
    local stroke = self.current_stroke
    local region = self.dirty_region
    self.current_stroke = nil
    self.dirty_region = nil
    if not stroke or #stroke.points == 0 then
        self.stroke_timing = nil
        return
    end

    stroke.points = self.store:decimatePoints(stroke)

    self.store:add(stroke)

    self:scheduleSave()

    if self.live_mode == LIVE_MODE_DEFERRED then
        self:renderStrokeToScreen(stroke)
        self:refreshRegion(region)
    elseif self.live_mode == LIVE_MODE_FAST then
        if self.bigme_direct_ink then
            self:queueBigmeFinalize(region or self.live_dirty)
        elseif self.live_snapshot then
            self:finalizeLiveStroke(stroke, region or self.live_dirty)
        else
            self:renderStrokeToScreen(stroke)
            self:refreshRegion(region or self.live_dirty)
        end
    else
        local ld = self.live_dirty
        if ld and (ld.w > 0 or ld.h > 0) then
            self:flushLive(region or ld, stroke)
        end
    end
    self:cancelLive()
    self:logStrokeTiming(stroke)
end

function StylusAnnotations:finalizeLiveStroke(stroke, region)
    if not self.live_snapshot then return end
    local t0 = time.now()
    region = region or self:getSelectionRect(stroke, Screen:getWidth(), Screen:getHeight())
    if not region then return end
    local rx, ry, rw, rh = clampToScreen(region.x, region.y, region.w, region.h)
    if not rx then return end
    Screen.bb:blitFrom(self.live_snapshot, rx, ry, rx, ry, rw, rh)
    self:renderStrokeToScreen(stroke)
    UIManager:setDirty(nil, "ui", Geom:new{x = rx, y = ry, w = rw, h = rh})
    if self.stroke_timing then
        self.stroke_timing.finalize_ms = time.to_ms(time.now() - t0)
    end
end

function StylusAnnotations:logStrokeTiming(stroke)
    local t = self.stroke_timing
    self.stroke_timing = nil
    if not t then return end
    local total_ms = time.to_ms(time.now() - t.start)
    logger.info("StylusAnnotations: stroke points=", #stroke.points,
        "total_ms=", total_ms,
        "snapshot_ms=", t.snapshot_ms,
        "paint_ms=", t.paint_ms,
        "flush_count=", t.flush_count,
        "finalize_ms=", t.finalize_ms)
end

function StylusAnnotations:liveRefreshInterval()
    if self.live_mode == LIVE_MODE_FAST then
        return FAST_LIVE_REFRESH_INTERVAL_MS
    end
    return LIVE_REFRESH_INTERVAL_MS
end

function StylusAnnotations:flushLiveThrottled()
    if self.live_mode == LIVE_MODE_DEFERRED or not self.live_snapshot then return end
    local ld = self.live_dirty
    if not ld or ld.w <= 0 or ld.h <= 0 then return end
    local now = time.now()
    if time.to_ms(now - self.last_refresh_time) < self:liveRefreshInterval() then return end
    local dx = self.pen_x - self.last_flush_x
    local dy = self.pen_y - self.last_flush_y
    if dx * dx + dy * dy < LIVE_MOVE_THRESHOLD_PX2 then return end
    self.last_refresh_time = now
    self.last_flush_x, self.last_flush_y = self.pen_x, self.pen_y
    self.live_dirty = nil
    self:flushLive(ld, self.current_stroke)
end

function StylusAnnotations:flushLive(ld, stroke)
    if not self.live_snapshot then return end
    if self.live_mode == LIVE_MODE_FAST then
        local dx, dy, dw, dh = clampToScreen(ld.x, ld.y, ld.w, ld.h)
        if dx then
            UIManager:setDirty(nil, "fast", Geom:new{x = dx, y = dy, w = dw, h = dh})
        end
        if self.stroke_timing then
            self.stroke_timing.flush_count = self.stroke_timing.flush_count + 1
        end
        return
    end
    local bb = Screen.bb
    local restore = self.dirty_region or ld
    local rx, ry, rw, rh = clampToScreen(restore.x, restore.y, restore.w, restore.h)
    if not rx then return end
    bb:blitFrom(self.live_snapshot, rx, ry, rx, ry, rw, rh)
    if stroke then
        self:renderStrokeToScreen(stroke)
    end
    local dx, dy, dw, dh = clampToScreen(ld.x, ld.y, ld.w, ld.h)
    if dx then
        UIManager:setDirty(nil, "ui", Geom:new{x = dx, y = dy, w = dw, h = dh})
    end
end

function StylusAnnotations:cancelLive()
    if self.live_snapshot then
        self.live_snapshot:free()
        self.live_snapshot = nil
    end
    self.live_dirty = nil
end

function StylusAnnotations:renderStrokeToScreen(stroke)
    self.mapper:renderStrokeToScreen(stroke)
end

function StylusAnnotations:refreshRegion(region)
    -- The callback runs after KOReader has repainted the dialog and right
    -- before it posts the frame: re-enable Bigme's normal commits there, so
    -- the handwriting layer is replaced by exactly this frame.
    local direct_ink = self.bigme_direct_ink
    local rx, ry, rw, rh
    if region then
        rx, ry, rw, rh = clampToScreen(region.x, region.y, region.w, region.h)
    end
    if not rx then
        rx, ry, rw, rh = 0, 0, Screen:getWidth(), Screen:getHeight()
    end
    local rect = Geom:new{x = rx, y = ry, w = rw, h = rh}
    UIManager:setDirty(self.view.dialog, function()
        if direct_ink and not Bigme.commitNormal() then
            -- A new stroke started before this repaint was posted; the
            -- panel keeps showing handwriting, so repaint again after it.
            self:queueBigmeFinalize(rect)
        end
        return "partial", rect
    end)
end

function StylusAnnotations:paintTo(bb, x, y)
    self.mapper:paintTo(bb, x, y)
end

function StylusAnnotations:getStrokeScreenWidth(stroke)
    return self.mapper:getStrokeScreenWidth(stroke)
end

function StylusAnnotations:getVisiblePages()
    return self.mapper:getVisiblePages()
end

function StylusAnnotations:getPageZoom(page)
    return self.mapper:getZoom(page)
end

function StylusAnnotations:getSelectionRect(stroke, width, height)
    return self.store:getSelectionRect(stroke, width, height)
end

function StylusAnnotations:selectionsEqual(a, b)
    if #a ~= #b then return false end
    for _, sa in ipairs(a) do
        local found = false
        for _, sb in ipairs(b) do
            if sa == sb then
                found = true
                break
            end
        end
        if not found then return false end
    end
    return true
end

function StylusAnnotations:setSelection(strokes)
    if self:selectionsEqual(self.selected_strokes, strokes) then return end
    if #self.selected_strokes > 0 then self:clearSelection() end
    self.selected_strokes = strokes

    self:grabSelectionBackup()
    self:paintSelectionToScreen()
end

function StylusAnnotations:clearSelection()
    if #self.selected_strokes == 0 then return end
    self.selected_strokes = {}
    self:restoreSelectionBackup()
end

function StylusAnnotations:grabSelectionBackup()
    local width, height = Screen:getWidth(), Screen:getHeight()
    local x0, y0, x1, y1
    for _, stroke in ipairs(self.selected_strokes) do
        local rx, ry, rw, rh = self:getSelectionRect(stroke, width, height)
        if rx then
            if not x0 or rx < x0 then x0 = rx end
            if not y0 or ry < y0 then y0 = ry end
            if not x1 or rx + rw > x1 then x1 = rx + rw end
            if not y1 or ry + rh > y1 then y1 = ry + rh end
        end
    end
    if not x0 then return end
    local bw, bh = x1 - x0, y1 - y0
    if self.selection_backup then self.selection_backup:free() end
    self.selection_backup = Blitbuffer.new(bw, bh, Screen.bb:getType())
    self.selection_backup:blitFrom(Screen.bb, 0, 0, x0, y0, bw, bh)
    self.selection_backup_x, self.selection_backup_y = x0, y0
end

function StylusAnnotations:paintSelectionToScreen()
    self.mapper:paintSelection(Screen.bb, 0, 0)
    self:refreshRegion()
end

function StylusAnnotations:restoreSelectionBackup()
    local backup = self.selection_backup
    if backup then
        local x, y = self.selection_backup_x, self.selection_backup_y
        local w, h = backup:getWidth(), backup:getHeight()
        Screen.bb:blitFrom(backup, x, y, 0, 0, w, h)
        backup:free()
        self.selection_backup = nil
        self:refreshRegion({ x = x, y = y, w = w, h = h })
    end
end

function StylusAnnotations:showStrokeMenu(strokes)
    self:setSelection(strokes)
    local dialog
    dialog = ButtonDialog:new{
        width_factor = 0.45,
        anchor = function()
            local x0, y0, x1, y1 = self.store:getSelectionUnionBox(strokes)
            if not x0 then return end
            return Geometry.paddedRect(x0, y0, x1, y1, Geometry.strokePad(strokes[1].width, strokes[1].zoom))
        end,
        tap_close_callback = function()
            self:clearSelection()
        end,
        buttons = {
            {
                {
                    text = "\u{F48E}",
                    callback = function()
                        local count = #strokes
                        self:closeStrokeDialog(dialog, function()
                            self:deleteStrokes(strokes, count > 1)
                        end)
                    end,
                },
                {
                    text = _("Color"),
                    callback = function()
                        self:closeStrokeDialog(dialog, function()
                            self:chooseStrokeColor(strokes)
                        end)
                    end,
                },
                {
                    text = _("Width"),
                    callback = function()
                        self:closeStrokeDialog(dialog, function()
                            self:chooseStrokeWidth(strokes)
                        end)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog, "[ui]")
end

function StylusAnnotations:closeStrokeDialog(dialog, action)
    self:clearSelection()
    UIManager:close(dialog)
    action()
end

function StylusAnnotations:showColorPicker(current, apply)

    local values = {}
    local palette = Draw.getColorPalette()
    for i, c in ipairs(palette) do
        values[i] = { c[1], c[2], Draw.getPaletteColor(c[2], self.ui.highlight) }
    end
    local selector
    selector = ButtonSelector:new{
        current_value = current,
        values = values,
        callback = function(value)
            apply(value)
            UIManager:close(selector)
        end,
    }
    UIManager:show(selector)
end

function StylusAnnotations:chooseStrokeColor(strokes)
    self:showColorPicker(strokes[1].color, function(value)
        self:setStrokeColor(strokes, value)
    end)
end

function StylusAnnotations:choosePenColor()
    self:showColorPicker(self.color, function(value)
        self.color = value
        self:saveSettings()
    end)
end

function StylusAnnotations:setStrokeAttribute(strokes, attribute, value)
    self.store:setAttribute(strokes, attribute, value)
    self:scheduleSave()
    UIManager:setDirty(self.view.dialog, "partial")
end

function StylusAnnotations:setStrokeColor(strokes, color)
    self:setStrokeAttribute(strokes, "color", color)
end

function StylusAnnotations:chooseStrokeWidth(strokes)
    self:showWidthPicker{
        start = strokes[1].width,
        on_apply = function(value)
            self:setStrokeWidth(strokes, value)
        end,
    }
end

function StylusAnnotations:setStrokeWidth(strokes, width)
    self:setStrokeAttribute(strokes, "width", width)
end

function StylusAnnotations:choosePenWidth()
    self:showWidthPicker{
        start = self.width,
        on_apply = function(value)
            self.width = value
            self:saveSettings()
        end,
    }
end

function StylusAnnotations:showWidthPicker(opts)
    local zoom = self:getPageZoom((self:getVisiblePages() or {})[1])
    local start = opts.start or self.width
    local on_apply = opts.on_apply

    local index, use_presets = nil, false
    for i, w in ipairs(WIDTH_CHOICES) do
        if w == start then index, use_presets = i, true break end
    end

    local spin
    spin = SpinWidget:new{
        title_text = _("Width..."),
        wrap = true,
        value_table = use_presets and WIDTH_CHOICES or nil,
        value_index = index,
        value = start,
        value_min = MIN_STROKE_WIDTH,
        value_max = MAX_STROKE_WIDTH,
        value_step = 1,
        value_hold_step = 2,
        precision = "%d",
        ok_always_enabled = true,
        extra_text = _("Custom..."),
        extra_callback = function()

            local input_dialog
            input_dialog = InputDialog:new{
                title = _("Custom width"),
                input_type = "number",
                input_hint = T(_("%1 - %2 (current: %3)"), MIN_STROKE_WIDTH, MAX_STROKE_WIDTH, start),
                buttons = {
                    {
                        {
                            text = _("Cancel"),
                            id = "close",
                            callback = function()
                                UIManager:close(input_dialog)
                            end,
                        },
                        {
                            text = _("OK"),
                            is_enter_default = true,
                            callback = function()
                                local v = tonumber(input_dialog:getInputText())
                                if v and v >= MIN_STROKE_WIDTH and v <= MAX_STROKE_WIDTH then
                                    v = math.floor(v + 0.5)
                                    UIManager:close(input_dialog)
                                    self:showWidthPicker{
                                        start = v,
                                        on_apply = on_apply,
                                    }
                                else
                                    UIManager:show(InfoMessage:new{
                                        text = T(_("Invalid width (%1 - %2)"), MIN_STROKE_WIDTH, MAX_STROKE_WIDTH),
                                        timeout = 2,
                                    })
                                end
                            end,
                        },
                    },
                },
            }
            UIManager:show(input_dialog)
        end,
        callback = function()
            on_apply(spin.value_widget:getValue())
        end,
    }

    local avail_w = spin:getAddedWidgetAvailableWidth()
    local ph = math.floor(avail_w / 5.2)
    spin:addWidget(WidthPreview:new{
        dimen = Geom:new{ w = avail_w, h = ph },
        get_zoom = function() return zoom end,
        get_width = function()
            return spin.value_widget and spin.value_widget:getValue() or start
        end,
    })
    UIManager:show(spin)
end

function StylusAnnotations:addToMainMenu(menu_items)
    menu_items.stylus_annotations = {
        text = _("Stylus annotations"),
        sorting_hint = "typeset",
        sub_item_table = {
            {
                text = _("Enable drawing"),
                checked_func = function()
                    return self:isEnabled()
                end,
                callback = function()
                    self:onStylusAnnotationsToggle()
                end,
            },
            {
                text = _("Hold pen still to select text or edit highlight"),
                checked_func = function()
                    return self:isPenSelectEnabled()
                end,
                callback = function()
                    G_reader_settings:saveSetting("stylus_annotations_pen_select",
                        not self:isPenSelectEnabled())
                end,
            },
            {
                text = _("Live refresh"),
                checked_func = function()
                    return self:liveInkEnabled()
                end,
                callback = function()
                    self:updateLiveMode(self.live_mode == LIVE_MODE_DEFERRED)
                    self:saveSettings()
                    local state = self.live_mode == LIVE_MODE_DEFERRED and _("off") or _("on")
                    UIManager:show(InfoMessage:new{
                        text = T(_("Live refresh: %1"), state),
                        timeout = 1,
                    })
                end,
            },
            {
                text_func = function()
                    return T(_("Width: %1"), self.width)
                end,
                callback = function()
                    self:choosePenWidth()
                end,
            },
            {
                text_func = function()
                    return T(_("Color: %1"), Draw.colorDisplayName(self.color))
                end,
                callback = function()
                    self:choosePenColor()
                end,
            },
            {
                text_func = function()
                    return self.bigme_poll_timer and _("Bigme input: on")
                        or _("Bigme input: off (tap to connect)")
                end,
                callback = function()
                    if self.bigme_poll_timer then
                        self:stopBigmeInput()
                    else
                        self:startBigmeInput()
                    end
                end,
            },
            {
                text = _("Delete strokes on the current page"),
                callback = function()
                    self:deleteAllStrokesOnPage()
                end,
            },
            {
                text = _("Delete all strokes in the document"),
                callback = function()
                    self:deleteAllStrokes()
                end,
            },
        },
    }
end

function StylusAnnotations:onStylusAnnotationsToggle()
    self:setEnabled(not self:isEnabled())
    local state = self:isEnabled() and _("on") or _("off")
    UIManager:show(InfoMessage:new{
        text = T(_("Stylus annotations drawing: %1"), state),
        timeout = 1,
    })
    return true
end

function StylusAnnotations:deleteStrokes(strokes, notify)
    local removed = self.store:remove(strokes)
    self:scheduleSave()
    self:schedulePdfStylusSync(0)
    UIManager:setDirty(self.view.dialog, "partial")
    if notify ~= false then
        self:notifyStrokeDeleted(removed)
    end
end

function StylusAnnotations:scheduleEraserRefresh()
    if self.eraser_refresh_timer then return end
    self.eraser_refresh_timer = function()
        self.eraser_refresh_timer = nil
        UIManager:setDirty(self.view.dialog, "partial")
    end
    UIManager:scheduleIn(0.033, self.eraser_refresh_timer)
end

function StylusAnnotations:eraseStrokesAlong(x1, y1, x2, y2)
    local removed = self.store:eraseAlong(x1, y1, x2, y2)
    if removed > 0 then
        self:scheduleSave()
        self:scheduleEraserRefresh()
        -- Once the eraser pauses, drop the PDF copies of erased strokes.
        self:schedulePdfStylusSync(0.3)
    end
    return removed
end

function StylusAnnotations:notifyStrokeDeleted(count)
    local text
    if count == 1 then
        text = _("1 stroke deleted")
    else
        text = T(_("%1 strokes deleted"), count)
    end
    UIManager:show(InfoMessage:new{
        text = text,
        timeout = 2,
    })
end

function StylusAnnotations:confirmDeleteStrokes(text, count, remove)
    if count == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No strokes to delete."),
            timeout = 2,
        })
        return
    end
    UIManager:show(ConfirmBox:new{
        text = text,
        ok_text = _("Delete"),
        ok_callback = function()
            local removed = remove()
            self:scheduleSave()
            self:schedulePdfStylusSync(0)
            UIManager:setDirty(self.view.dialog, "partial")
            self:notifyStrokeDeleted(removed)
        end,
    })
end

function StylusAnnotations:deleteAllStrokesOnPage()
    local pages = self:getVisiblePages()
    if not pages then return end
    local count = 0
    for _, page in ipairs(pages) do
        count = count + #(self.store.strokes_by_page[page] or {})
    end
    self:confirmDeleteStrokes(
        T(_("Delete all %1 strokes on this page?"), count), count,
        function()
            return self.store:removeByPage(pages)
        end)
end

function StylusAnnotations:deleteAllStrokes()
    local total = #self.store.strokes
    self:confirmDeleteStrokes(
        T(_("Delete all %1 strokes for this document?"), total), total,
        function()
            return self.store:removeAll()
        end)
end

function StylusAnnotations:getStrokesFilePath()
    local sidecar_dir = self.ui.doc_settings and self.ui.doc_settings.doc_sidecar_dir
    if sidecar_dir then
        return sidecar_dir .. "/stylus_annotations.lua", sidecar_dir
    end
    return nil
end

function StylusAnnotations:scheduleSave()

    if self.pending_save then
        UIManager:unschedule(self.pending_save)
    end
    self.pending_save = function()
        self.pending_save = nil
        self:saveStrokes()
    end
    UIManager:scheduleIn(SAVE_DELAY_MS / 1000, self.pending_save)
end

function StylusAnnotations:saveStrokes()
    local filepath, sidecar_dir = self:getStrokesFilePath()
    if not filepath then
        logger.warn("StylusAnnotations: no sidecar dir available, skipping save")
        return
    end
    local ok, err = util.makePath(sidecar_dir)
    if not ok and err then
        logger.warn("StylusAnnotations: failed to create sidecar dir:", err)
    end
    self.store:save(filepath)
end

-- With "Write highlights into PDF" on, this KOReader build copies our
-- strokes into the PDF as ink annotations ("KOReaderStylus:...") on pause,
-- suspend and close (ReaderHighlight:syncStylusAnnotationsToPdf). MuPDF draws
-- those copies under our strokes, so deleting a stroke must also delete its
-- copy, or it seems to stay. Let KOReader's own sync bring the in-memory PDF
-- in line with our strokes; it only touches annotations that changed, and
-- KOReader writes the file on pause/close as usual.
function StylusAnnotations:syncPdfStylusCopies()
    local doc = self.ui.document
    local highlight = self.ui.highlight
    if not (doc and doc.is_pdf and doc.syncStylusAnnotations
        and highlight and highlight.highlight_write_into_pdf) then
        return false
    end
    local was_edited = doc.is_edited
    local ok, result = pcall(doc.syncStylusAnnotations, doc,
        self.store.strokes, highlight, Screen.night_mode)
    if not ok then
        logger.warn("StylusAnnotations: could not sync PDF stroke copies:", result)
        return false
    end
    if doc.is_edited and not was_edited then
        logger.info("StylusAnnotations: removed PDF copies of deleted strokes")
    end
    return result == true
end

local function nearestColorName(rgb, highlight)
    if not rgb then return "black" end
    local best, best_d
    for _, entry in ipairs(Draw.getColorPalette()) do
        local name = entry[2]
        local c = Draw.getPaletteColor(name, highlight):getColorRGB32()
        local dr, dg, db = c.r - rgb.r, c.g - rgb.g, c.b - rgb.b
        local d = dr * dr + dg * dg + db * db
        if not best_d or d < best_d then
            best, best_d = name, d
        end
    end
    return best or "black"
end

-- Import ink annotations from the PDF as strokes: our own copies whose stroke
-- is missing from the sidecar (e.g. written by another device, or left by a
-- failed save) and ink written by other apps. Other apps' annotations are then
-- deleted from the in-memory PDF; the next sync writes them back as our own
-- copies, so they can be erased like any stroke. Only with "Write highlights
-- into PDF" on: otherwise KOReader would never write them back and closing
-- the book would drop them from the PDF.
function StylusAnnotations:importPdfInkAnnotations()
    local doc = self.ui.document
    local highlight = self.ui.highlight
    if not (self.ui.paging and doc and doc.is_pdf and doc.getInkAnnotations
        and doc.deleteForeignInkAnnotations
        and highlight and highlight.highlight_write_into_pdf) then
        return 0
    end
    local ok, annotations = pcall(doc.getInkAnnotations, doc)
    if not ok then
        logger.warn("StylusAnnotations: could not read PDF ink annotations:", annotations)
        return 0
    end
    if #annotations == 0 then return 0 end

    -- Strokes are stored (and exported) at quarter-point precision; compare
    -- at that precision so our own copies match their strokes exactly.
    local function strokeKey(page, points)
        local parts = { tostring(page) }
        for i = 1, #points do
            parts[#parts + 1] = tostring(Geometry.pack(points[i]))
        end
        return table.concat(parts, ",")
    end
    local known = {}
    for _, stroke in ipairs(self.store.strokes) do
        if stroke.page and stroke.points then
            known[strokeKey(stroke.page, stroke.points)] = true
        end
    end

    local zoom = self.view.state and self.view.state.zoom or 1
    local now = os.time()
    local imported, foreign = 0, 0
    for _, annotation in ipairs(annotations) do
        if not annotation.is_stylus then foreign = foreign + 1 end
        local color = nearestColorName(annotation.color, highlight)
        for _, vertices in ipairs(annotation.strokes) do
            local points = {}
            for _, p in ipairs(vertices) do
                points[#points + 1] = Geometry.unpack(Geometry.pack(p.x))
                points[#points + 1] = Geometry.unpack(Geometry.pack(p.y))
            end
            local key = strokeKey(annotation.page, points)
            if #points >= 2 and not known[key] then
                known[key] = true
                imported = imported + 1
                self.store:add({
                    id = "pdf-" .. now .. "-" .. imported,
                    page = annotation.page,
                    points = points,
                    width = annotation.width,
                    color = color,
                    alpha = annotation.opacity,
                    zoom = zoom,
                    datetime = now,
                })
            end
        end
    end
    if imported > 0 then
        self:scheduleSave()
    end
    if foreign > 0 then
        local del_ok, err = pcall(doc.deleteForeignInkAnnotations, doc)
        if not del_ok then
            logger.warn("StylusAnnotations: could not replace other apps' ink:", err)
        end
    end
    logger.info("StylusAnnotations: PDF ink annotations =", #annotations,
        "imported strokes =", imported, "from other apps =", foreign)
    return imported
end

-- delay: seconds to wait for further deletions (eraser), 0 = next tick.
function StylusAnnotations:schedulePdfStylusSync(delay)
    if self.pdf_sync_timer then
        UIManager:unschedule(self.pdf_sync_timer)
    end
    self.pdf_sync_timer = function()
        self.pdf_sync_timer = nil
        if self:syncPdfStylusCopies() then
            -- Only scheduled after deletions: re-render the page so the
            -- removed copies disappear.
            UIManager:setDirty(self.view.dialog, "partial")
        end
    end
    UIManager:scheduleIn(delay or 0, self.pdf_sync_timer)
end

function StylusAnnotations:loadStrokes()
    local filepath = self:getStrokesFilePath()
    if not filepath then
        self.store:load(nil)
        return
    end
    local migrated = self.store:load(filepath)
    if migrated then
        self:scheduleSave()
    end
end

return StylusAnnotations
