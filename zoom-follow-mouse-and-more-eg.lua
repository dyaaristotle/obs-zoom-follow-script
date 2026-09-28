-- ============================================================================
-- Zoom, Follow Mouse and MORE for OBS Studio
-- Version 2.2.0 (2026)
-- ============================================================================

local obs = obslua
local ffi = require("ffi")
-- LuaJIT bitwise library, used for capability-based source detection.
-- Guarded: if unavailable we fall back to a manual single-bit test (see has_flag).
local ok_bit, bit = pcall(require, "bit")
if not ok_bit then bit = nil end

-- ============================================================================
-- CONSTANTS
-- ============================================================================

local ZOOM_HOTKEY_NAME = "zoom_and_follow.zoom.toggle"
local FOLLOW_HOTKEY_NAME = "zoom_and_follow.follow.toggle"
local CROP_FILTER_NAME = "zoom_and_follow_crop"
local MAX_DISPLAYS = 32 -- Maximum displays for macOS

-- Default values (will be overridden by script settings)
local DEFAULT_UPDATE_INTERVAL = 16 -- milliseconds (approximately 60 FPS)
local DEFAULT_MOUSE_CACHE_DURATION = 8 -- milliseconds (max 120 FPS)
local DEFAULT_ZOOM_ANIMATION_DURATION = 300 -- milliseconds
local DEFAULT_ZOOM_OUT_DURATION = 500 -- milliseconds
local DEFAULT_SCENE_TRANSITION_DURATION = 300 -- milliseconds
local DEFAULT_MOUSE_DEADZONE = 3 -- pixels: minimum mouse movement to trigger crop update
local DEFAULT_CROP_UPDATE_THRESHOLD = 2 -- pixels: minimum crop change to trigger update
local DEFAULT_CROP_EDGE_THRESHOLD = 5 -- pixels: increased threshold when crop is at edges
local MAX_ZOOM_VALUE = 100.0 -- Maximum zoom multiplier; practical limit depends on source resolution
local DEFAULT_MONITOR_WIDTH = 1920
local DEFAULT_MONITOR_HEIGHT = 1080

-- Known "capture" source ids.
-- NOTE: Since v2.2.0 source detection is CAPABILITY-BASED (see source_produces_video):
-- any source flagged OBS_SOURCE_VIDEO is accepted, regardless of its id. This list is
-- now only a RANKING HINT — when a scene contains several video sources (e.g. a logo
-- image plus a screen capture) the script prefers a "known capture" over a generic
-- video source. It is also the fallback allowlist on very old OBS builds where the
-- capability flags are not exposed.
local VALID_SOURCE_TYPES = {
    "ffmpeg_source",
    "browser_source",
    "vlc_source",
    "monitor_capture",
    "window_capture",
    "game_capture",
    "dshow_input",
    "av_capture_input",
    -- macOS (plugins/mac-capture)
    "display_capture",   -- Display Capture (legacy)
    "screen_capture",    -- macOS Screen Capture (ScreenCaptureKit)
    -- Linux (Wayland/PipeWire + linux-capture)
    "pipewire-screen-capture-source",   -- Screen Capture (PipeWire) — current id
    "pipewire-window-capture-source",   -- Window Capture (PipeWire) — current id
    "pipewire-desktop-capture-source",  -- Screen/Window Capture (PipeWire) — legacy/obsolete id
    "xshm_input",        -- Screen capture X11 (XSHM)
    "xshm_input_v2",     -- Screen capture X11 v2
    "xcomposite_input"   -- Window Capture (Xcomposite)
}

-- ============================================================================
-- FFI PLATFORM MODULE
-- ============================================================================

local ffi_platform = {
    initialized = false,
    os_type = nil,
    -- Windows
    windows_loaded = false,
    -- Linux
    x11 = nil,
    xrandr = nil,
    x11_display = nil,
    x11_root = nil,
    -- macOS
    core_graphics = nil,
    core_graphics_load_path = nil,
    init_error = nil,
    -- Monitors cache
    monitors = {},
    -- Mouse position cache
    mouse_cache = {x = 0, y = 0, timestamp = 0}
}

-- Forward declaration. The mouse reader is defined before the general logger,
-- but it still needs a throttled diagnostic path once the script is running.
local debug_trace

-- Initialize FFI definitions for Windows
local function init_windows_ffi()
    if ffi_platform.windows_loaded then
        return true
    end
    
    local success, err = pcall(function()
        ffi.cdef[[
            typedef long BOOL;
            typedef void* HANDLE;
            typedef HANDLE HMONITOR;
            typedef struct {
                long left;
                long top;
                long right;
                long bottom;
            } RECT;
            typedef struct {
                unsigned long cbSize;
                RECT rcMonitor;
                RECT rcWork;
                unsigned long dwFlags;
            } MONITORINFO;
            typedef BOOL (*MONITORENUMPROC)(HMONITOR, void*, RECT*, long);
            
            BOOL EnumDisplayMonitors(void*, void*, MONITORENUMPROC, long);
            BOOL GetMonitorInfoA(HMONITOR, MONITORINFO*);
            typedef struct { long x; long y; } POINT;
            bool GetCursorPos(POINT* point);
        ]]
        ffi_platform.windows_loaded = true
    end)
    
    if not success then
        return false, err
    end
    return true
end

-- Initialize FFI definitions and handles for Linux
local function init_linux_ffi()
    if ffi_platform.x11_display ~= nil then
        return true
    end
    
    local success, err = pcall(function()
        ffi.cdef[[
            typedef struct {
                int x, y;
                int width, height;
            } XRRMonitorInfo;
            
            typedef void* Display;
            typedef unsigned long Window;
            
            Display* XOpenDisplay(const char*);
            void XCloseDisplay(Display*);
            Window DefaultRootWindow(Display*);
            XRRMonitorInfo* XRRGetMonitors(Display*, Window, int, int*);
            void XRRFreeMonitors(XRRMonitorInfo*);
            
            typedef struct {
                int x, y;
                int dummy1, dummy2, dummy3;
                int dummy4, dummy5, dummy6;
            } XButtonEvent;
            
            int XQueryPointer(Display*, Window, Window*, Window*, int*, int*, int*, int*, unsigned int*);
        ]]
        
        ffi_platform.x11 = ffi.load("X11")
        ffi_platform.xrandr = ffi.load("Xrandr")
        
        ffi_platform.x11_display = ffi_platform.x11.XOpenDisplay(nil)
        if ffi_platform.x11_display ~= nil then
            ffi_platform.x11_root = ffi_platform.x11.DefaultRootWindow(ffi_platform.x11_display)
        end
    end)
    
    if not success then
        return false, err
    end
    
    if ffi_platform.x11_display == nil then
        return false, "Failed to open X11 display"
    end
    
    return true
end

-- Initialize FFI definitions and handles for macOS
local function init_macos_ffi()
    if ffi_platform.core_graphics ~= nil then
        return true
    end
    
    local success, err = pcall(function()
        ffi.cdef[[
            // Use private type names so script reloads do not collide with
            // CoreGraphics declarations from another Lua script.
            typedef unsigned int zm_cg_display_id_t;
            typedef unsigned int zm_cg_display_count_t;
            typedef struct { double x; double y; } zm_cg_point_t;
            typedef struct { double width; double height; } zm_cg_size_t;
            typedef struct {
                zm_cg_point_t origin;
                zm_cg_size_t size;
            } zm_cg_rect_t;
            
            int CGGetActiveDisplayList(zm_cg_display_count_t maxDisplays, zm_cg_display_id_t *activeDisplays, zm_cg_display_count_t *displayCount);
            zm_cg_rect_t CGDisplayBounds(zm_cg_display_id_t display);
            zm_cg_point_t CGEventGetLocation(void* event);
            void* CGEventCreate(void* source);
            void CFRelease(void* cf);
        ]]
        
        -- On macOS, the short name is not reliably discoverable from OBS's
        -- embedded LuaJIT runtime. Try the framework binary explicitly first,
        -- then retain the short-name fallback for other environments.
        local framework_paths = {
            "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
            "CoreGraphics"
        }
        local load_errors = {}
        for _, framework_path in ipairs(framework_paths) do
            local loaded, library_or_error = pcall(ffi.load, framework_path, true)
            if loaded then
                ffi_platform.core_graphics = library_or_error
                ffi_platform.core_graphics_load_path = framework_path
                return
            end
            load_errors[#load_errors + 1] = framework_path .. ": " .. tostring(library_or_error)
        end
        error("Unable to load CoreGraphics: " .. table.concat(load_errors, " | "))
    end)
    
    if not success then
        return false, err
    end
    
    return true
end

-- Initialize FFI platform module
function ffi_platform.init()
    if ffi_platform.initialized then
        return true
    end
    
    ffi_platform.os_type = ffi.os
    local success, err
    
    if ffi_platform.os_type == "Windows" then
        success, err = init_windows_ffi()
    elseif ffi_platform.os_type == "Linux" then
        success, err = init_linux_ffi()
    elseif ffi_platform.os_type == "OSX" then
        success, err = init_macos_ffi()
    else
        -- Fallback for unknown OS
        ffi_platform.monitors = {{left = 0, top = 0, right = app_state.default_monitor_width, bottom = app_state.default_monitor_height}}
        ffi_platform.initialized = true
        return true
    end
    
    if not success then
        ffi_platform.init_error = err
        return false, err
    end
    
    ffi_platform.initialized = true
    ffi_platform.init_error = nil
    return true
end

-- Get monitors information
function ffi_platform.get_monitors()
    if not ffi_platform.initialized then
        return {}
    end
    
    if #ffi_platform.monitors > 0 then
        return ffi_platform.monitors
    end
    
    local monitors = {}
    
    if ffi_platform.os_type == "Windows" then
        local function enum_callback(hMonitor, _, _, _)
            local mi = ffi.new("MONITORINFO")
            mi.cbSize = ffi.sizeof("MONITORINFO")
            if ffi.C.GetMonitorInfoA(hMonitor, mi) ~= 0 then
                table.insert(monitors, {
                    left = mi.rcMonitor.left,
                    top = mi.rcMonitor.top,
                    right = mi.rcMonitor.right,
                    bottom = mi.rcMonitor.bottom
                })
            end
            return true
        end
        
        local callback = ffi.cast("MONITORENUMPROC", enum_callback)
        ffi.C.EnumDisplayMonitors(nil, nil, callback, 0)
        callback:free()
        
    elseif ffi_platform.os_type == "Linux" then
        if ffi_platform.x11_display ~= nil then
            local count = ffi.new("int[1]")
            local info = ffi_platform.xrandr.XRRGetMonitors(ffi_platform.x11_display, ffi_platform.x11_root, 1, count)
            
            if info ~= nil then
                for i = 0, count[0] - 1 do
                    table.insert(monitors, {
                        left = info[i].x,
                        top = info[i].y,
                        right = info[i].x + info[i].width,
                        bottom = info[i].y + info[i].height
                    })
                end
                ffi_platform.xrandr.XRRFreeMonitors(info)
            end
        end
        
    elseif ffi_platform.os_type == "OSX" then
        if ffi_platform.core_graphics ~= nil then
            local active_displays = ffi.new("zm_cg_display_id_t[?]", MAX_DISPLAYS)
            local display_count = ffi.new("zm_cg_display_count_t[1]")
            
            if ffi_platform.core_graphics.CGGetActiveDisplayList(MAX_DISPLAYS, active_displays, display_count) == 0 then
                for i = 0, display_count[0] - 1 do
                    local bounds = ffi_platform.core_graphics.CGDisplayBounds(active_displays[i])
                    table.insert(monitors, {
                        left = bounds.origin.x,
                        top = bounds.origin.y,
                        right = bounds.origin.x + bounds.size.width,
                        bottom = bounds.origin.y + bounds.size.height
                    })
                end
            end
        end
    else
        -- Fallback for unknown OS
        monitors = {{left = 0, top = 0, right = app_state.default_monitor_width, bottom = app_state.default_monitor_height}}
    end
    
    ffi_platform.monitors = monitors
    local monitor_parts = {}
    for i, monitor in ipairs(monitors) do
        monitor_parts[#monitor_parts + 1] = string.format("%d:[%.0f,%.0f]-[%.0f,%.0f] %.0fx%.0f",
            i, monitor.left, monitor.top, monitor.right, monitor.bottom,
            monitor.right - monitor.left, monitor.bottom - monitor.top)
    end
    debug_trace("monitors", 0, string.format("OS=%s CoreGraphics=%s count=%d %s",
        tostring(ffi_platform.os_type), tostring(ffi_platform.core_graphics ~= nil),
        #monitors, #monitor_parts > 0 and table.concat(monitor_parts, "; ") or "<none>"))
    return monitors
end

-- Get mouse position with caching
function ffi_platform.get_mouse_pos()
    if not ffi_platform.initialized then
        return 0, 0
    end
    
    -- Check cache validity
    local current_time = obs.os_gettime_ns() / 1000000 -- Convert to milliseconds
    local cache_duration = app_state and app_state.mouse_cache_duration or DEFAULT_MOUSE_CACHE_DURATION
    if current_time - ffi_platform.mouse_cache.timestamp < cache_duration then
        return ffi_platform.mouse_cache.x, ffi_platform.mouse_cache.y
    end
    
    local x, y = 0, 0
    local success = false
    local failure_reason = nil
    local previous_timestamp = ffi_platform.mouse_cache.timestamp
    
    if ffi_platform.os_type == "Windows" then
        local success_pcall, x_result, y_result = pcall(function()
            local point = ffi.new("POINT[1]")
            if ffi.C.GetCursorPos(point) then
                return point[0].x, point[0].y
            end
            return 0, 0
        end)
        if success_pcall then
            x, y = x_result, y_result
            success = true
        end
        
    elseif ffi_platform.os_type == "Linux" then
        if ffi_platform.x11_display ~= nil then
            local success_pcall, x_result, y_result = pcall(function()
                local root_x = ffi.new("int[1]")
                local root_y = ffi.new("int[1]")
                local win_x = ffi.new("int[1]")
                local win_y = ffi.new("int[1]")
                local mask = ffi.new("unsigned int[1]")
                local child = ffi.new("Window[1]")
                local child_revert = ffi.new("Window[1]")
                
                if ffi_platform.x11.XQueryPointer(ffi_platform.x11_display, ffi_platform.x11_root, 
                                                  child_revert, child, root_x, root_y, win_x, win_y, mask) ~= 0 then
                    return root_x[0], root_y[0]
                end
                return 0, 0
            end)
            if success_pcall then
                x, y = x_result, y_result
                success = true
            end
        end
        
    elseif ffi_platform.os_type == "OSX" then
        if ffi_platform.core_graphics ~= nil then
        local success_pcall, x_result, y_result = pcall(function()
            local event = ffi_platform.core_graphics.CGEventCreate(nil)
            if event ~= nil then
                local point = ffi_platform.core_graphics.CGEventGetLocation(event)
                ffi_platform.core_graphics.CFRelease(event)
                return point.x, point.y
            end
            error("CGEventCreate returned nil")
        end)
        if success_pcall then
            x, y = x_result, y_result
            success = true
        else
            failure_reason = tostring(x_result)
        end
    end
    end
    
    -- Update cache
    if success then
        ffi_platform.mouse_cache.x = x
        ffi_platform.mouse_cache.y = y
        ffi_platform.mouse_cache.timestamp = current_time
        -- Removed app_state dependency - ffi_platform should be independent
        debug_trace("mouse-sample", 500, string.format(
            "read=OK os=%s raw=(%.1f,%.1f) cache_age=%.1fms",
            tostring(ffi_platform.os_type), x, y,
            current_time - previous_timestamp))
    else
        debug_trace("mouse-failure", 500, string.format(
            "read=FAIL os=%s raw=(%.1f,%.1f) CoreGraphics=%s reason=%s",
            tostring(ffi_platform.os_type), x, y,
            tostring(ffi_platform.core_graphics ~= nil), tostring(failure_reason or "unknown")))
    end
    
    return x, y
end

-- Cleanup FFI platform resources
function ffi_platform.cleanup()
    if ffi_platform.os_type == "Linux" and ffi_platform.x11_display ~= nil then
        pcall(function()
            ffi_platform.x11.XCloseDisplay(ffi_platform.x11_display)
        end)
        ffi_platform.x11_display = nil
        ffi_platform.x11_root = nil
        ffi_platform.x11 = nil
        ffi_platform.xrandr = nil
    end
    
    ffi_platform.monitors = {}
    ffi_platform.mouse_cache = {x = 0, y = 0, timestamp = 0}
    ffi_platform.initialized = false
end

-- ============================================================================
-- STATE MANAGEMENT
-- ============================================================================

local app_state = {
    zoom = {
        active = false,
        value = 3.0,
        current = 1.0,
        target = 1.0,
        start_time = 0
    },
    follow = {
        active = false,
        auto = false, -- "Auto-follow while zoomed" option (opt-in, default OFF)
        speed = 0.2,
        force_update = false -- Recenter immediately when follow is enabled
    },
    source = nil,
    source_scene_item = nil, -- Scene item reference for getting transformations
    source_is_nested = false, -- True when the chosen source was reached via a nested scene/group
    original_transform = nil, -- Scene-item transform captured before zooming
    original_transform_source_size = nil, -- Source dimensions used with original_transform
    zoom_transform_active = false,
    preferred_source_name = "", -- Optional: name of the source to prefer (empty = automatic)
    crop_filter = nil,
    crop_filter_owned = false, -- Track if filter was created by us (needs release) or borrowed (no release)
    original_crop = nil,
    current_crop = nil,
    target_crop = nil,
    last_mouse_pos = {x = 0, y = 0}, -- Track last mouse position for deadzone calculation
    last_crop = {left = 0, top = 0, right = 0, bottom = 0}, -- Track last crop values to prevent unnecessary updates
    current_scene = nil,
    current_filter_target = nil,
    cleanup_in_progress = false, -- Flag to prevent timer creation during cleanup
    monitors = {},
    zoom_hotkey_id = nil,
    follow_hotkey_id = nil,
    debug_mode = false,
    -- Configurable parameters
    update_interval = DEFAULT_UPDATE_INTERVAL,
    mouse_cache_duration = DEFAULT_MOUSE_CACHE_DURATION,
    zoom_animation_duration = DEFAULT_ZOOM_ANIMATION_DURATION,
    zoom_out_duration = DEFAULT_ZOOM_OUT_DURATION,
    scene_transition_duration = DEFAULT_SCENE_TRANSITION_DURATION,
    mouse_deadzone = DEFAULT_MOUSE_DEADZONE,
    crop_update_threshold = DEFAULT_CROP_UPDATE_THRESHOLD,
    crop_edge_threshold = DEFAULT_CROP_EDGE_THRESHOLD,
    default_monitor_width = DEFAULT_MONITOR_WIDTH,
    default_monitor_height = DEFAULT_MONITOR_HEIGHT
}

-- Validate state consistency
local function validate_state()
    if app_state.zoom.active and not app_state.source then
        app_state.zoom.active = false
        app_state.follow.active = false
        return false
    end
    if app_state.follow.active and not app_state.zoom.active then
        app_state.follow.active = false
        return false
    end
    return true
end

-- Reset state to default
local function reset_state()
    app_state.zoom.active = false
    app_state.zoom.current = 1.0
    app_state.zoom.target = 1.0
    app_state.follow.active = false
    app_state.follow.force_update = false
    app_state.current_crop = nil
    app_state.target_crop = nil
    app_state.source_scene_item = nil
    app_state.source_is_nested = false
    app_state.original_transform = nil
    app_state.original_transform_source_size = nil
    app_state.zoom_transform_active = false
end

-- ============================================================================
-- UTILITY FUNCTIONS
-- ============================================================================

-- Enhanced logging function with levels
-- Only shows logs when debug_mode is enabled
local function log(level, message)
    -- Only show logs if debug_mode is enabled
    if not app_state.debug_mode then
        return
    end
    
    local prefix = "[Zoom and Follow]"
    if level == "error" then
        print(prefix .. " [ERROR] " .. message)
    elseif level == "warning" then
        print(prefix .. " [WARNING] " .. message)
    else
        print(prefix .. " " .. message)
    end
end

-- Detailed diagnostics are enabled by the existing Debug Mode setting. Every
-- high-frequency path uses a key-specific throttle so we can observe timer,
-- mouse, mapping, and crop behaviour without producing thousands of lines per
-- second in the OBS log.
local debug_trace_times = {}
local debug_trace_sequence = 0
debug_trace = function(key, interval_ms, message)
    if not app_state or not app_state.debug_mode then
        return
    end

    local now = obs.os_gettime_ns() / 1000000
    local last = debug_trace_times[key] or -math.huge
    if interval_ms > 0 and now - last < interval_ms then
        return
    end
    debug_trace_times[key] = now
    debug_trace_sequence = debug_trace_sequence + 1
    log("info", string.format("[DEBUG][%s][%s][#%d] %s",
        os.date("%Y-%m-%d %H:%M:%S"), key, debug_trace_sequence, message))
end

-- Test a capability bit in an output-flags value.
-- Uses the LuaJIT bit library when available. The no-bit-library fallback is only
-- valid for a SINGLE-BIT mask — which is all we pass here (OBS_SOURCE_VIDEO == 1<<0).
local function has_flag(flags, mask)
    if not flags or not mask or mask == 0 then
        return false
    end
    if bit then
        return bit.band(flags, mask) ~= 0
    end
    -- Fallback without the bit library (single-bit mask only)
    return (math.floor(flags / mask) % 2) == 1
end

-- Is this a "known capture" source id? Used only as a ranking hint / legacy fallback.
local function is_known_capture_type(source_id)
    if not source_id then
        return false
    end
    for _, valid_type in ipairs(VALID_SOURCE_TYPES) do
        if source_id == valid_type then
            return true
        end
    end
    return false
end

-- Capability-based check: does this source PRODUCE VIDEO?
-- Robust across OS / OBS version / locale because it does not depend on the
-- source id string. Scenes and groups are intentionally rejected here (the
-- traversal in find_valid_video_source recurses into them). Falls back to the
-- legacy id allowlist on very old OBS builds that do not expose the flags.
local function source_produces_video(source)
    if not source then
        return false
    end

    -- Only plain inputs are zoom targets; scenes/groups are handled by recursion.
    if obs.obs_source_get_type(source) ~= obs.OBS_SOURCE_TYPE_INPUT then
        return false
    end

    local source_id = obs.obs_source_get_id(source) or ""
    -- Never target our own crop filter or a generic filter source.
    if source_id == "crop_filter" or source_id == CROP_FILTER_NAME then
        return false
    end

    -- Primary path: capability flags.
    if obs.OBS_SOURCE_VIDEO ~= nil then
        local flags = nil
        pcall(function()
            flags = obs.obs_source_get_output_flags(source)
        end)
        if flags then
            -- OBS_SOURCE_VIDEO (bit 0) is set for BOTH sync and async video sources
            -- (OBS_SOURCE_ASYNC_VIDEO = OBS_SOURCE_ASYNC | OBS_SOURCE_VIDEO), so this
            -- single test already covers every video-producing source.
            if has_flag(flags, obs.OBS_SOURCE_VIDEO) then
                return true
            end
            -- Flags available but no video bit -> definitely not a video source.
            return false
        end
    end

    -- Fallback for old OBS builds without the capability flags: legacy allowlist.
    return is_known_capture_type(source_id)
end

-- Find a valid video source in the current scene.
--
-- Walks the scene graph depth-first, descending into BOTH nested scenes AND
-- groups (groups are not scenes: obs_scene_from_source returns nil for them, so
-- they need obs_group_from_source — this is what made captures inside groups
-- invisible before). Every video-producing leaf is collected as a candidate,
-- then one is chosen by priority:
--   1. the source whose name matches "Preferred Source" (if set),
--   2. the first "known capture" (so a logo/overlay is never picked over a
--      real screen capture),
--   3. otherwise the first video source found (depth-first / lowest layer).
-- This satisfies the "pick the original source from the lowest scene layer"
-- request while keeping the previous behaviour for simple scenes intact.
local function find_valid_video_source()
    local current_scene = obs.obs_frontend_get_current_scene()
    if not current_scene then
        log("info", "No current scene found")
        return nil
    end

    local scene = obs.obs_scene_from_source(current_scene)
    local candidates = {}   -- { source, scene_item, known, nested }
    local visited = {}      -- guard against scene/group cycles (keyed by name)

    -- Recursively walk a list of scene items, collecting video leaves.
    local function walk(items, nested)
        if not items then
            return
        end
        for _, item in ipairs(items) do
            local src = obs.obs_sceneitem_get_source(item)
            if src then
                local is_group = obs.obs_sceneitem_is_group ~= nil
                    and obs.obs_sceneitem_is_group(item)

                if is_group then
                    -- GROUP: enumerate via obs_group_from_source (NOT obs_scene_from_source)
                    local gname = obs.obs_source_get_name(src) or ""
                    if not visited[gname] then
                        visited[gname] = true
                        local gscene = nil
                        pcall(function()
                            gscene = obs.obs_group_from_source(src)
                        end)
                        if gscene then
                            local gitems = obs.obs_scene_enum_items(gscene)
                            walk(gitems, true)
                            obs.sceneitem_list_release(gitems)
                        end
                    end
                elseif obs.obs_source_get_type(src) == obs.OBS_SOURCE_TYPE_SCENE then
                    -- NESTED SCENE
                    local sname = obs.obs_source_get_name(src) or ""
                    if not visited[sname] then
                        visited[sname] = true
                        local nested_scene = obs.obs_scene_from_source(src)
                        if nested_scene then
                            local nested_items = obs.obs_scene_enum_items(nested_scene)
                            walk(nested_items, true)
                            obs.sceneitem_list_release(nested_items)
                        end
                    end
                elseif source_produces_video(src) then
                    -- VIDEO LEAF
                    table.insert(candidates, {
                        source = src,
                        scene_item = item,
                        known = is_known_capture_type(obs.obs_source_get_id(src) or ""),
                        nested = nested
                    })
                end
            end
        end
    end

    local items = obs.obs_scene_enum_items(scene)
    walk(items, false)
    obs.sceneitem_list_release(items)
    -- Release scene (protected with pcall)
    pcall(function()
        obs.obs_source_release(current_scene)
    end)

    -- Selection: preferred name > known capture > first video leaf.
    local chosen = nil
    local pref = app_state.preferred_source_name
    if pref and pref ~= "" then
        for _, c in ipairs(candidates) do
            if obs.obs_source_get_name(c.source) == pref then
                chosen = c
                break
            end
        end
        if not chosen then
            log("warning", "Preferred source '" .. pref .. "' not found in scene; using automatic selection")
        end
    end
    if not chosen then
        for _, c in ipairs(candidates) do
            if c.known then
                chosen = c
                break
            end
        end
    end
    if not chosen and #candidates > 0 then
        chosen = candidates[1]
    end

    if chosen then
        -- Note: sources from scene items are managed by OBS, no addref/release needed.
        app_state.source_scene_item = chosen.scene_item
        app_state.source_is_nested = chosen.nested
        log("info", "Found valid video source: " .. (obs.obs_source_get_name(chosen.source) or "?")
            .. (chosen.nested and " (nested)" or ""))
        return chosen.source
    end

    log("info", "No valid video source found in the current scene")
    app_state.source_scene_item = nil
    app_state.source_is_nested = false
    return nil
end

-- ============================================================================
-- ANIMATION SYSTEM
-- ============================================================================

-- Easing functions
local function ease_linear(t)
    return t
end

local function ease_in_out(t)
    return t * t * (3.0 - 2.0 * t)
end

local function ease_out(t)
    return 1.0 - (1.0 - t) * (1.0 - t)
end

-- Generic animation function
local function animate_value(start_value, target_value, duration, easing_func, callback)
    local start_time = obs.os_gettime_ns() / 1000000 -- Convert to milliseconds
    local easing = easing_func or ease_linear
    
    local function animate()
        local current_time = obs.os_gettime_ns() / 1000000
        local elapsed = current_time - start_time
        local progress = math.min(elapsed / duration, 1.0)
        
        local eased_progress = easing(progress)
        local current_value = start_value + (target_value - start_value) * eased_progress
        
        if callback then
            callback(current_value, progress)
        end
        
        if progress < 1.0 then
            return true -- Continue animation
        else
            return false -- Animation complete
        end
    end
    
    return animate
end

-- ============================================================================
-- CROP & FILTER MANAGEMENT
-- ============================================================================

-- Get a source's pixel dimensions reliably.
-- Uses the rendered width/height first (same reference resolution the crop filter
-- operates on, and identical to v2.1.0), and falls back to the native base size
-- only when the rendered size is momentarily 0 (e.g. right after filter_add).
-- Returns 0,0 on failure.
local function get_source_dimensions(source)
    if not source then
        return 0, 0
    end
    local w, h = 0, 0
    pcall(function()
        w = obs.obs_source_get_width(source)
        h = obs.obs_source_get_height(source)
    end)
    if not w or w <= 0 or not h or h <= 0 then
        pcall(function()
            if obs.obs_source_get_base_width then
                w = obs.obs_source_get_base_width(source)
                h = obs.obs_source_get_base_height(source)
            end
        end)
    end
    return w or 0, h or 0
end

-- Validate source has valid dimensions
local function validate_source_dimensions(source)
    if not source then
        return false, "Source is nil"
    end
    
    local success, width_result, height_result = pcall(function()
        return obs.obs_source_get_width(source), obs.obs_source_get_height(source)
    end)
    
    if not success then
        return false, "Failed to get source dimensions"
    end
    
    if not width_result or not height_result then
        return false, "Source dimensions are nil"
    end
    
    if width_result == 0 or height_result == 0 then
        return false, string.format("Source has invalid dimensions: %dx%d", width_result, height_result)
    end
    
    return true, width_result, height_result
end

-- Apply crop filter to target source
local function apply_crop_filter(target_source)
    if not target_source then
        log("warning", "Cannot apply crop filter: target source is nil")
        return false
    end
    
    -- Validate source dimensions before applying filter
    local is_valid, width, height = validate_source_dimensions(target_source)
    if not is_valid then
        log("error", "Cannot apply crop filter: " .. tostring(width))
        return false
    end
    
    local parent_source = obs.obs_frontend_get_current_scene()
    if not parent_source then
        log("warning", "Cannot get current scene")
        return
    end
    
    local filter_target = obs.obs_source_get_type(target_source) == obs.OBS_SOURCE_TYPE_SCENE and parent_source or target_source
    
    -- Remove filter from previous source/scene if it exists
    if app_state.current_filter_target and app_state.current_filter_target ~= filter_target then
        local old_filter = obs.obs_source_get_filter_by_name(app_state.current_filter_target, CROP_FILTER_NAME)
        if old_filter then
            -- Note: obs_source_get_filter_by_name returns borrowed reference, no need to release
            pcall(function()
                obs.obs_source_filter_remove(app_state.current_filter_target, old_filter)
            end)
        end
    end
    
    -- Release old filter reference if it was created by us (not a borrowed reference)
    if app_state.crop_filter and app_state.crop_filter_owned then
        -- Only release if we created it (protected with pcall)
        pcall(function()
            obs.obs_source_release(app_state.crop_filter)
        end)
        app_state.crop_filter = nil
        app_state.crop_filter_owned = false
    end
    
    -- Always create a new filter to ensure clean state
    -- Remove any existing filter first
    local existing_filter = obs.obs_source_get_filter_by_name(filter_target, CROP_FILTER_NAME)
    if existing_filter then
        -- Remove existing filter first
        pcall(function()
            obs.obs_source_filter_remove(filter_target, existing_filter)
        end)
        log("info", "Removed existing crop filter before creating new one")
    end
    
    -- Create new filter (must be released when done)
    app_state.crop_filter = obs.obs_source_create("crop_filter", CROP_FILTER_NAME, nil, nil)
    if app_state.crop_filter then
        obs.obs_source_filter_add(filter_target, app_state.crop_filter)
        app_state.crop_filter_owned = true
        log("info", "Crop filter created and applied to " .. obs.obs_source_get_name(filter_target))
    else
        log("error", "Failed to create crop filter")
    end
    
    app_state.current_filter_target = filter_target
    -- Release parent source (protected with pcall)
    pcall(function()
        obs.obs_source_release(parent_source)
    end)
    
    -- Always log filter application details for debugging
    local filter_target_name = obs.obs_source_get_name(filter_target) or "unknown"
    log("info", string.format("Filter applied - Target: %s, size: %dx%d, type: %s", 
        filter_target_name, width, height, 
        obs.obs_source_get_type(filter_target) == obs.OBS_SOURCE_TYPE_SCENE and "SCENE" or "SOURCE"))
    
    return true
end

-- Update crop (keeping original implementation for OBS limitations)
local function update_crop(left, top, right, bottom)
    if not app_state.crop_filter then
        return
    end
    
    -- Validate filter is still valid
    local filter_valid = pcall(function()
        obs.obs_source_get_name(app_state.crop_filter)
    end)
    
    if not filter_valid then
        log("warning", "Crop filter became invalid")
        app_state.crop_filter = nil
        return
    end
    
    local settings = obs.obs_data_create()
    local left_int = math.floor(left + 0.5)
    local top_int = math.floor(top + 0.5)
    local right_int = math.floor(right + 0.5)
    local bottom_int = math.floor(bottom + 0.5)
    
    obs.obs_data_set_int(settings, "left", left_int)
    obs.obs_data_set_int(settings, "top", top_int)
    obs.obs_data_set_int(settings, "right", right_int)
    obs.obs_data_set_int(settings, "bottom", bottom_int)
    
    
    local update_success = pcall(function()
        obs.obs_source_update(app_state.crop_filter, settings)
    end)
    
    if not update_success then
        log("warning", "Failed to update crop filter")
    end
    
    obs.obs_data_release(settings)
end

-- Simple informational message about CTRL+F
-- Note: OBS API doesn't provide a reliable way to detect if source is fitted to screen
-- So we just show an informational message suggesting to use CTRL+F
local function show_fit_to_screen_info()
    if app_state.debug_mode then
        log("info", "💡 Tip: For best zoom results, press CTRL+F to fit source to screen before activating zoom")
    end
end

-- OBS 32 exposes scene-item transforms through the info2 API. Keep the older
-- info/transform names as fallbacks so the script remains usable on older OBS
-- builds. The crop filter changes the source dimensions, but it does not scale
-- the scene item. Zoom therefore needs to update both the crop and the item
-- transform.
local function get_sceneitem_transform(item)
    if not item or not obs.obs_transform_info then
        return nil
    end

    local getter = obs.obs_sceneitem_get_info2
        or obs.obs_sceneitem_get_transform
        or obs.obs_sceneitem_get_info
    if not getter then
        return nil
    end

    local info = obs.obs_transform_info()
    local ok = pcall(function()
        getter(item, info)
    end)
    if not ok then
        return nil
    end
    return info
end

local function set_sceneitem_transform(item, info)
    if not item or not info then
        return false
    end

    local setter = obs.obs_sceneitem_set_info2
        or obs.obs_sceneitem_set_transform
        or obs.obs_sceneitem_set_info
    if not setter then
        return false
    end

    return pcall(function()
        setter(item, info)
    end)
end

-- Return the scene-space offset from an item's position to its top-left corner.
-- OBS alignment flags are 1=left, 2=right, 4=top, 8=bottom; zero means center.
local function alignment_top_left_offset(alignment, width, height)
    local flags = alignment or 0
    local horizontal = math.floor(flags) % 4
    local vertical = math.floor(flags / 4) % 4

    local x = 0
    if horizontal == 2 then
        x = -width
    elseif horizontal == 0 then
        x = -width / 2
    end

    local y = 0
    if vertical == 2 then
        y = -height
    elseif vertical == 0 then
        y = -height / 2
    end

    return x, y
end

-- Read the OBS base canvas dimensions. Follow positioning is expressed in
-- canvas coordinates, so the target source pixel can be placed at the actual
-- center of the 1:1 output instead of at the source item's original position.
local function get_canvas_dimensions()
    if obs.obs_video_info and obs.obs_get_video_info then
        local ok_info, info = pcall(function()
            return obs.obs_video_info()
        end)
        if ok_info and info then
            local ok_get, populated = pcall(function()
                return obs.obs_get_video_info(info)
            end)
            local width = tonumber(info.base_width) or 0
            local height = tonumber(info.base_height) or 0
            if ok_get and populated ~= false and width > 0 and height > 0 then
                return width, height, "obs_video_info"
            end
        end
    end

    return nil, nil, "unavailable"
end

-- Capture and restore the scene-item transform around a zoom session. This is
-- intentionally separate from the source filter so an interrupted zoom or a
-- script reload cannot leave the scene item permanently enlarged or displaced.
local function capture_original_sceneitem_transform(src_w, src_h)
    app_state.original_transform = get_sceneitem_transform(app_state.source_scene_item)
    app_state.original_transform_source_size = {w = src_w, h = src_h}
    app_state.zoom_transform_active = false

    if not app_state.original_transform then
        log("warning", "Scene-item transform API unavailable; zoom will crop without scaling")
        return false
    end
    return true
end

local function restore_original_sceneitem_transform()
    if app_state.original_transform and app_state.source_scene_item then
        if not set_sceneitem_transform(app_state.source_scene_item, app_state.original_transform) then
            log("warning", "Could not restore the original scene-item transform")
        end
    end
    app_state.original_transform = nil
    app_state.original_transform_source_size = nil
    app_state.zoom_transform_active = false
end

-- Scale and reposition the scene item so the crop viewport occupies the same
-- scene-space footprint as the uncropped source. This is the missing operation
-- that turns a crop into a visual magnification.
local function update_sceneitem_zoom_transform(crop, src_w, src_h)
    local original = app_state.original_transform
    local item = app_state.source_scene_item
    if not original or not item or src_w <= 0 or src_h <= 0 then
        return false
    end

    local view_w = math.max(1, src_w - crop.left - crop.right)
    local view_h = math.max(1, src_h - crop.top - crop.bottom)
    local original_scale_x = original.scale.x
    local original_scale_y = original.scale.y
    if not original_scale_x or original_scale_x == 0 then original_scale_x = 1 end
    if not original_scale_y or original_scale_y == 0 then original_scale_y = 1 end

    local original_width = src_w * original_scale_x
    local original_height = src_h * original_scale_y
    local original_offset_x, original_offset_y = alignment_top_left_offset(
        original.alignment, original_width, original_height)
    local original_top_left_x = original.pos.x + original_offset_x
    local original_top_left_y = original.pos.y + original_offset_y

    -- Keep the viewport center fixed while its dimensions change. Using the
    -- actual crop dimensions here also keeps animation smooth between the
    -- configured zoom level and the unzoomed state.
    local focus_x = crop.left + view_w / 2
    local focus_y = crop.top + view_h / 2
    local new_scale_x = original_scale_x * src_w / view_w
    local new_scale_y = original_scale_y * src_h / view_h
    local new_width = view_w * new_scale_x
    local new_height = view_h * new_scale_y
    local new_top_left_x = original_top_left_x
        + focus_x * original_scale_x
        - (focus_x - crop.left) * new_scale_x
    local new_top_left_y = original_top_left_y
        + focus_y * original_scale_y
        - (focus_y - crop.top) * new_scale_y
    local new_offset_x, new_offset_y = alignment_top_left_offset(
        original.alignment, new_width, new_height)

    local current = get_sceneitem_transform(item)
    if not current then
        return false
    end
    current.scale.x = new_scale_x
    current.scale.y = new_scale_y
    current.pos.x = new_top_left_x - new_offset_x
    current.pos.y = new_top_left_y - new_offset_y

    local ok = set_sceneitem_transform(item, current)
    if ok and not app_state.zoom_transform_active then
        app_state.zoom_transform_active = true
        log("info", string.format("Scene-item transform zoom enabled: scale %.3fx%.3f",
            new_scale_x, new_scale_y))
    end
    return ok
end

-- Reposition the zoomed scene item so the mapped mouse pixel is at the center
-- of the OBS canvas. The crop filter defines which source rectangle is shown;
-- this transform defines where that rectangle is placed in the output.
--
-- The item is clamped to the canvas bounds. Near an edge there may not be
-- enough source pixels to put the cursor exactly at center without exposing
-- transparent pixels, so the nearest valid position is used instead.
local function update_sceneitem_follow_transform(crop, src_w, src_h, target_x, target_y)
    local original = app_state.original_transform
    local item = app_state.source_scene_item
    if not original or not item or src_w <= 0 or src_h <= 0 then
        return false, nil, nil, nil, nil, nil
    end

    if original.rot and math.abs(original.rot) > 0.001 then
        debug_trace("follow-transform-warning", 0,
            string.format("unsupported rotation %.3f; retaining zoom transform", original.rot))
        return false, nil, nil, nil, nil, nil
    end

    local canvas_w, canvas_h, canvas_source = get_canvas_dimensions()
    if not canvas_w or not canvas_h then
        debug_trace("follow-transform-warning", 1000,
            "OBS canvas dimensions unavailable; retaining previous scene-item position")
        return false, nil, nil, nil, nil, nil
    end

    local view_w = math.max(1, src_w - crop.left - crop.right)
    local view_h = math.max(1, src_h - crop.top - crop.bottom)
    local original_scale_x = original.scale.x
    local original_scale_y = original.scale.y
    if not original_scale_x or original_scale_x == 0 then original_scale_x = 1 end
    if not original_scale_y or original_scale_y == 0 then original_scale_y = 1 end

    local new_scale_x = original_scale_x * src_w / view_w
    local new_scale_y = original_scale_y * src_h / view_h
    local new_width = view_w * new_scale_x
    local new_height = view_h * new_scale_y

    local desired_top_left_x = canvas_w / 2 - (target_x - crop.left) * new_scale_x
    local desired_top_left_y = canvas_h / 2 - (target_y - crop.top) * new_scale_y

    local min_top_left_x = math.min(0, canvas_w - new_width)
    local max_top_left_x = math.max(0, canvas_w - new_width)
    local min_top_left_y = math.min(0, canvas_h - new_height)
    local max_top_left_y = math.max(0, canvas_h - new_height)
    local top_left_x = math.max(min_top_left_x, math.min(max_top_left_x, desired_top_left_x))
    local top_left_y = math.max(min_top_left_y, math.min(max_top_left_y, desired_top_left_y))

    local new_offset_x, new_offset_y = alignment_top_left_offset(
        original.alignment, new_width, new_height)
    local current = get_sceneitem_transform(item)
    if not current then
        return false, canvas_w, canvas_h, desired_top_left_x, desired_top_left_y, canvas_source
    end

    current.scale.x = new_scale_x
    current.scale.y = new_scale_y
    current.pos.x = top_left_x - new_offset_x
    current.pos.y = top_left_y - new_offset_y

    local ok = set_sceneitem_transform(item, current)
    if ok and not app_state.zoom_transform_active then
        app_state.zoom_transform_active = true
        log("info", string.format(
            "Scene-item follow transform enabled: canvas %dx%d, scale %.3fx%.3f",
            canvas_w, canvas_h, new_scale_x, new_scale_y))
    end

    return ok, canvas_w, canvas_h, desired_top_left_x, desired_top_left_y, canvas_source,
        top_left_x, top_left_y
end

-- OLD FUNCTION REMOVED - Unreliable detection logic
-- The function check_source_fitted_to_screen() was removed because:
-- 1. Canvas dimensions from obs_video_info() are often 0x0
-- 2. Scale information cannot be retrieved reliably (obs_sceneitem_get_scale fails)
-- 3. Detection was inaccurate and showed warnings even when CTRL+F was applied
-- Replaced with simple informational message: show_fit_to_screen_info()


-- ============================================================================
-- ANIMATION HANDLERS
-- ============================================================================

-- Architecture: single named timer + state machine + lerp between FIXED crops.
-- Crops are calculated ONCE at animation start, then we only lerp.
-- This eliminates flickering caused by recalculating crop every frame.

local zoom_state = "idle" -- "idle" | "zooming_in" | "zoomed_in" | "zooming_out"
local zoom_timer_running = false

local zoom_anim = {
    start_time = 0,
    duration = 0,
    -- Fixed crop endpoints: set once, never change during animation
    start_crop = {left = 0, top = 0, right = 0, bottom = 0},
    end_crop   = {left = 0, top = 0, right = 0, bottom = 0},
    -- Source pixel that must remain centered during zoom-in.
    focus_source = nil,
}

local function lerp(a, b, t)
    return a + (b - a) * t
end

local function copy_crop(c)
    return {left = c.left, top = c.top, right = c.right, bottom = c.bottom}
end

-- Return the monitor rectangle the screen-space point (x, y) is on.
-- Falls back to the first detected monitor, then to the configured default size.
local function monitor_at(x, y)
    local fallback = app_state.monitors[1] or {
        left = 0, top = 0,
        right = app_state.default_monitor_width,
        bottom = app_state.default_monitor_height
    }
    for _, m in ipairs(app_state.monitors) do
        if x >= m.left and x < m.right and y >= m.top and y < m.bottom then
            return m
        end
    end
    return fallback
end

-- Map a screen-space mouse position to SOURCE PIXEL coordinates.
--
-- Cases:
--  * monitor size == source size (the common Windows/Linux native, non-scaled
--    case): returns the EXACT integer translation (mouse - origin) — byte-for-byte
--    identical to v2.1.0, no float division.
--  * monitor size != source size (macOS Retina 2x, Windows display scaling, or a
--    source whose resolution differs from the monitor): scales the cursor's
--    position from monitor space into source pixels. This is the fix for issue #8
--    ("centers but won't follow") and is HiDPI-safe.
--  * cursor outside the monitor: recenters on the source middle (as v2.1.0 did).
local function map_mouse_to_source(mouse_x, mouse_y, monitor, src_w, src_h)
    local mon_w = monitor.right - monitor.left
    local mon_h = monitor.bottom - monitor.top
    if mon_w <= 0 or mon_h <= 0 then
        return src_w / 2, src_h / 2
    end

    local rel_x = mouse_x - monitor.left
    local rel_y = mouse_y - monitor.top

    -- Cursor outside this monitor -> recenter to source middle (v2.1.0 behaviour).
    if rel_x < 0 or rel_x > mon_w or rel_y < 0 or rel_y > mon_h then
        return src_w / 2, src_h / 2
    end

    -- Fast path: identical pixel sizes -> exact translation, no rounding.
    if mon_w == src_w and mon_h == src_h then
        return rel_x, rel_y
    end

    -- Scaled mapping: defer the divide to minimize floating-point error.
    return rel_x * src_w / mon_w, rel_y * src_h / mon_h
end

-- Single named tick: handles zooming_in, zooming_out, and follow
local function on_zoom_tick()
    if not app_state then return end

    if not app_state.source then
        obs.timer_remove(on_zoom_tick)
        zoom_timer_running = false
        return
    end
    local ok = pcall(function() obs.obs_source_get_width(app_state.source) end)
    if not ok then
        app_state.zoom.active = false
        app_state.follow.active = false
        app_state.source = nil
        app_state.source_scene_item = nil
        obs.timer_remove(on_zoom_tick)
        zoom_timer_running = false
        return
    end

    -- === ANIMATION (zoom-in or zoom-out) ===
    if zoom_state == "zooming_in" or zoom_state == "zooming_out" then
        local now = obs.os_gettime_ns() / 1000000
        local t = math.min((now - zoom_anim.start_time) / zoom_anim.duration, 1.0)

        -- Lerp between the two FIXED crop endpoints
        local crop = {
            left   = lerp(zoom_anim.start_crop.left,   zoom_anim.end_crop.left,   t),
            top    = lerp(zoom_anim.start_crop.top,    zoom_anim.end_crop.top,    t),
            right  = lerp(zoom_anim.start_crop.right,  zoom_anim.end_crop.right,  t),
            bottom = lerp(zoom_anim.start_crop.bottom, zoom_anim.end_crop.bottom, t),
        }

        update_crop(crop.left, crop.top, crop.right, crop.bottom)
        app_state.last_crop = copy_crop(crop)
        app_state.current_crop = crop

        local transform_dims = app_state._src_dims
        if transform_dims then
            if zoom_state == "zooming_in" and zoom_anim.focus_source then
                update_sceneitem_follow_transform(
                    crop,
                    transform_dims.w,
                    transform_dims.h,
                    zoom_anim.focus_source.x,
                    zoom_anim.focus_source.y)
            else
                update_sceneitem_zoom_transform(crop, transform_dims.w, transform_dims.h)
            end
        end

        -- Update zoom.current proportionally for consistency
        if zoom_state == "zooming_in" then
            app_state.zoom.current = lerp(1.0, app_state.zoom.value, t)
        else
            app_state.zoom.current = lerp(zoom_anim._start_zoom_level, 1.0, t)
        end

        -- Transition when animation completes
        if t >= 1.0 then
            if zoom_state == "zooming_in" then
                app_state.zoom.current = app_state.zoom.value
                zoom_state = "zoomed_in"
                log("info", "Zoom in complete")
                if not app_state.follow.active then
                    obs.timer_remove(on_zoom_tick)
                    zoom_timer_running = false
                end

            elseif zoom_state == "zooming_out" then
                -- Reset everything
                app_state.zoom.current = 1.0
                app_state.zoom.active = false
                app_state.current_crop = nil
                app_state.last_crop = {left = 0, top = 0, right = 0, bottom = 0}
                zoom_anim.focus_source = nil
                zoom_state = "idle"
                obs.timer_remove(on_zoom_tick)
                zoom_timer_running = false

                -- Restore the exact scene-item transform before removing the
                -- crop filter so the source returns to its original layout.
                restore_original_sceneitem_transform()

                -- Remove crop filter
                if app_state.crop_filter and app_state.current_filter_target then
                    pcall(function()
                        obs.obs_source_filter_remove(app_state.current_filter_target, app_state.crop_filter)
                    end)
                    if app_state.crop_filter_owned then
                        pcall(function() obs.obs_source_release(app_state.crop_filter) end)
                    end
                    app_state.crop_filter = nil
                    app_state.crop_filter_owned = false
                    app_state.current_filter_target = nil
                end
                log("info", "Zoom out complete, filter removed")
            end
        end
        return
    end

    -- === FOLLOW MODE (zoomed_in + follow active) ===
    -- Keep a fixed-size source viewport and place the mapped mouse pixel at
    -- the center of the OBS canvas. Crop and scene-item translation are both
    -- required: crop selects the magnified rectangle, while translation makes
    -- the selected mouse pixel land at the output center.
    if zoom_state == "zoomed_in" and app_state.follow.active then
        local mx, my = ffi_platform.get_mouse_pos()
        local dx = math.abs(mx - app_state.last_mouse_pos.x)
        local dy = math.abs(my - app_state.last_mouse_pos.y)
        local dist = math.sqrt(dx * dx + dy * dy)
        local force_update = app_state.follow.force_update

        debug_trace("follow-tick", 250, string.format(
            "tick=YES state=%s timer=%s zoom=%.3f mouse=(%.1f,%.1f) last=(%.1f,%.1f) delta=(%.1f,%.1f) dist=%.1f deadzone=%d force=%s",
            tostring(zoom_state), tostring(zoom_timer_running), app_state.zoom.current,
            mx, my, app_state.last_mouse_pos.x, app_state.last_mouse_pos.y,
            dx, dy, dist, app_state.mouse_deadzone, tostring(force_update)))

        if dist < app_state.mouse_deadzone and not force_update then
            app_state.last_mouse_pos = {x = mx, y = my}
            debug_trace("follow-deadzone", 500, string.format(
                "mouse movement ignored: dist=%.1f < deadzone=%d", dist, app_state.mouse_deadzone))
            return
        end

        local dims = app_state._src_dims
        if not dims then return end
        local src_w, src_h = dims.w, dims.h

        -- Fixed viewport size at current zoom (never changes during follow)
        local view_w = math.max(4, math.min(math.floor(src_w / app_state.zoom.current), src_w))
        local view_h = math.max(4, math.min(math.floor(src_h / app_state.zoom.current), src_h))

        -- Current viewport center (derived from current_crop)
        local cur = app_state.current_crop or {left = 0, top = 0, right = 0, bottom = 0}
        local cur_cx = cur.left + view_w / 2
        local cur_cy = cur.top  + view_h / 2

        -- Target center = mouse position mapped into source pixel coords (HiDPI-safe)
        local monitor = monitor_at(mx, my)
        local tgt_cx, tgt_cy = map_mouse_to_source(mx, my, monitor, src_w, src_h)

        debug_trace("follow-map", 250, string.format(
            "monitor=[%.0f,%.0f]-[%.0f,%.0f] %.0fx%.0f source=%dx%d target=(%.1f,%.1f) current_center=(%.1f,%.1f) view=%dx%d",
            monitor.left, monitor.top, monitor.right, monitor.bottom,
            monitor.right - monitor.left, monitor.bottom - monitor.top,
            src_w, src_h, tgt_cx, tgt_cy, cur_cx, cur_cy, view_w, view_h))

        -- Aim the viewport center directly at the mapped mouse pixel. The
        -- clamp is essential at the source edges because a finite image cannot
        -- keep an edge pixel at the output center without showing blank space.
        local spd = app_state.follow.speed
        local max_left = math.max(0, src_w - view_w)
        local max_top = math.max(0, src_h - view_h)
        local target_left = math.max(0, math.min(max_left, tgt_cx - view_w / 2))
        local target_top = math.max(0, math.min(max_top, tgt_cy - view_h / 2))
        local new_left = math.max(0, math.min(max_left,
            math.floor(cur.left + (target_left - cur.left) * spd + 0.5)))
        local new_top = math.max(0, math.min(max_top,
            math.floor(cur.top + (target_top - cur.top) * spd + 0.5)))
        local final = {
            left   = new_left,
            top    = new_top,
            right  = src_w - (new_left + view_w),
            bottom = src_h - (new_top  + view_h),
        }

        update_crop(final.left, final.top, final.right, final.bottom)
        app_state.last_crop = copy_crop(final)
        app_state.current_crop = final
        local transform_ok, canvas_w, canvas_h, desired_x, desired_y, canvas_source,
            actual_x, actual_y = update_sceneitem_follow_transform(
                final, src_w, src_h, tgt_cx, tgt_cy)
        app_state.follow.force_update = false
        local actual_center_x = canvas_w and canvas_w / 2 or nil
        local actual_center_y = canvas_h and canvas_h / 2 or nil
        debug_trace("follow-result", 250, string.format(
            "crop=[%d,%d,%d,%d] target_source=(%.1f,%.1f) target_crop_left=%.1f target_crop_top=%.1f new_center=(%.1f,%.1f) canvas=%sx%s desired_item_top_left=(%s,%s) actual_item_top_left=(%s,%s) canvas_center=(%s,%s) canvas_source=%s transform=%s",
            final.left, final.top, final.right, final.bottom,
            tgt_cx, tgt_cy, target_left, target_top,
            new_left + view_w / 2, new_top + view_h / 2,
            tostring(canvas_w), tostring(canvas_h), tostring(desired_x), tostring(desired_y),
            tostring(actual_x), tostring(actual_y), tostring(actual_center_x),
            tostring(actual_center_y), tostring(canvas_source), tostring(transform_ok)))
        debug_trace("follow-result-detail", 250, string.format(
            "crop_center_source=(%.1f,%.1f) delta_to_mouse=(%.1f,%.1f) canvas=%sx%s desired_item_top_left=(%s,%s) actual_item_top_left=(%s,%s) canvas_center=(%s,%s) canvas_source=%s transform=%s",
            new_left + view_w / 2, new_top + view_h / 2,
            tgt_cx - (new_left + view_w / 2), tgt_cy - (new_top + view_h / 2),
            tostring(canvas_w), tostring(canvas_h), tostring(desired_x), tostring(desired_y),
            tostring(actual_x), tostring(actual_y), tostring(actual_center_x),
            tostring(actual_center_y), tostring(canvas_source), tostring(transform_ok)))
        app_state.last_mouse_pos = {x = mx, y = my}
    end
end

-- Helper: ensure the tick timer is running
local function ensure_zoom_timer()
    if not zoom_timer_running then
        debug_trace("timer-start", 0, string.format(
            "starting timer interval=%dms zoom_state=%s zoom_active=%s follow_active=%s source=%s",
            app_state.update_interval, tostring(zoom_state), tostring(app_state.zoom.active),
            tostring(app_state.follow.active), app_state.source and obs.obs_source_get_name(app_state.source) or "<nil>"))
        obs.timer_add(on_zoom_tick, app_state.update_interval)
        zoom_timer_running = true
    else
        debug_trace("timer-already-running", 1000, string.format(
            "timer already running zoom_state=%s zoom_active=%s follow_active=%s",
            tostring(zoom_state), tostring(app_state.zoom.active), tostring(app_state.follow.active)))
    end
end

-- Helper: stop the tick timer
local function stop_zoom_timer()
    if zoom_timer_running then
        debug_trace("timer-stop", 0, string.format(
            "stopping timer zoom_state=%s zoom_active=%s follow_active=%s",
            tostring(zoom_state), tostring(app_state.zoom.active), tostring(app_state.follow.active)))
        obs.timer_remove(on_zoom_tick)
        zoom_timer_running = false
    end
end

-- Pure crop math from known dimensions. Does NOT query OBS for source size
-- (after filter_add, obs_source_get_width returns 0 for ~1 frame).
-- Uses the shared monitor_at() / map_mouse_to_source() helpers (defined earlier).
local function calc_zoom_crop(mouse_x, mouse_y, zoom_level, src_w, src_h)
    if src_w <= 0 or src_h <= 0 or zoom_level <= 1.0 then
        return {left = 0, top = 0, right = 0, bottom = 0}
    end

    local monitor = monitor_at(mouse_x, mouse_y)
    local mx_src, my_src = map_mouse_to_source(mouse_x, mouse_y, monitor, src_w, src_h)

    local view_w = math.max(4, math.min(math.floor(src_w / zoom_level), src_w))
    local view_h = math.max(4, math.min(math.floor(src_h / zoom_level), src_h))

    local cx = math.max(0, math.min(math.floor(mx_src - view_w / 2), src_w - view_w))
    local cy = math.max(0, math.min(math.floor(my_src - view_h / 2), src_h - view_h))

    return {
        left   = cx,
        top    = cy,
        right  = src_w - (cx + view_w),
        bottom = src_h - (cy + view_h)
    }
end

-- Start smooth zoom-in. src_w/src_h are pre-filter dimensions (must be passed
-- when starting from idle because obs_source_get_width returns 0 after filter_add).
-- When interrupting zoom-out, pass nil and saved _src_dims will be used.
local function start_zoom_in(src_w, src_h)
    local mx, my = ffi_platform.get_mouse_pos()

    -- Priority: 1) passed args, 2) saved session dims, 3) query source
    if (not src_w or src_w <= 0) and app_state._src_dims then
        src_w = app_state._src_dims.w
        src_h = app_state._src_dims.h
    end
    if (not src_w or src_w <= 0) then
        src_w, src_h = get_source_dimensions(app_state.source)
    end
    if not src_w or src_w <= 0 or not src_h or src_h <= 0 then
        log("error", "Cannot start zoom in: no valid dimensions")
        return
    end

    app_state._src_dims = {w = src_w, h = src_h}

    -- Capture the mouse position in source-pixel coordinates once. The crop
    -- and scene-item transform then use this same anchor for every animation
    -- frame, so the zoom grows around the point under the mouse.
    local focus_monitor = monitor_at(mx, my)
    local focus_x, focus_y = map_mouse_to_source(mx, my, focus_monitor, src_w, src_h)
    zoom_anim.focus_source = {x = focus_x, y = focus_y}
    debug_trace("zoom-anchor", 0, string.format(
        "mouse=(%.1f,%.1f) monitor=[%.1f,%.1f]-[%.1f,%.1f] source=%dx%d anchor_source=(%.1f,%.1f)",
        mx, my, focus_monitor.left, focus_monitor.top,
        focus_monitor.right, focus_monitor.bottom, src_w, src_h, focus_x, focus_y))

    local target = calc_zoom_crop(mx, my, app_state.zoom.value, src_w, src_h)

    -- If current crop exists (e.g. interrupting zoom-out), use it as start
    if app_state.last_crop and (app_state.last_crop.left ~= 0 or app_state.last_crop.top ~= 0
        or app_state.last_crop.right ~= 0 or app_state.last_crop.bottom ~= 0) then
        zoom_anim.start_crop = copy_crop(app_state.last_crop)
    else
        zoom_anim.start_crop = {left = 0, top = 0, right = 0, bottom = 0}
    end
    zoom_anim.end_crop = copy_crop(target)
    zoom_anim.start_time = obs.os_gettime_ns() / 1000000
    zoom_anim.duration = app_state.zoom_animation_duration
    zoom_anim._start_zoom_level = app_state.zoom.current

    zoom_state = "zooming_in"
    app_state.zoom.active = true
    app_state.zoom.target = app_state.zoom.value
    -- Opt-in auto-follow (default OFF): start tracking immediately so the viewport
    -- follows the mouse without a second hotkey. Keeping follow.active true also
    -- keeps the tick timer alive past the zoom-in completion (see on_zoom_tick).
    -- The Follow hotkey still works as a live freeze/unfreeze toggle.
    if app_state.follow.auto then
        app_state.follow.active = true
        app_state.follow.force_update = true
    end
    app_state.last_mouse_pos = {x = mx, y = my}
    ensure_zoom_timer()
    log("info", string.format("Zoom in: crop [%d,%d,%d,%d] -> [%d,%d,%d,%d] over %d ms",
        zoom_anim.start_crop.left, zoom_anim.start_crop.top,
        zoom_anim.start_crop.right, zoom_anim.start_crop.bottom,
        zoom_anim.end_crop.left, zoom_anim.end_crop.top,
        zoom_anim.end_crop.right, zoom_anim.end_crop.bottom,
        zoom_anim.duration))
end

-- Start smooth zoom-out: from current crop to {0,0,0,0}
local function start_zoom_out()
    if not app_state or app_state.cleanup_in_progress then return end

    zoom_anim.focus_source = nil
    zoom_anim.start_crop = copy_crop(app_state.last_crop or {left = 0, top = 0, right = 0, bottom = 0})
    zoom_anim.end_crop = {left = 0, top = 0, right = 0, bottom = 0}
    zoom_anim.start_time = obs.os_gettime_ns() / 1000000
    zoom_anim.duration = app_state.zoom_out_duration
    zoom_anim._start_zoom_level = app_state.zoom.current

    zoom_state = "zooming_out"
    ensure_zoom_timer()
    log("info", string.format("Zoom out: crop [%d,%d,%d,%d] -> [0,0,0,0] over %d ms",
        zoom_anim.start_crop.left, zoom_anim.start_crop.top,
        zoom_anim.start_crop.right, zoom_anim.start_crop.bottom,
        zoom_anim.duration))
end

-- ============================================================================
-- HOTKEY HANDLERS
-- ============================================================================

-- Handler for zoom hotkey
local function on_zoom_hotkey(pressed)
    if not pressed then
        return
    end
    
    -- Validate or find source
    if not app_state.source then
        app_state.source = find_valid_video_source()
        if not app_state.source then
            log("warning", "No valid video source found in the current scene")
            return
        end
    else
        local source_valid = pcall(function() obs.obs_source_get_width(app_state.source) end)
        if not source_valid then
            log("warning", "Source became invalid, searching for new one")
            app_state.source = nil
            app_state.source = find_valid_video_source()
            if not app_state.source then
                log("warning", "No valid video source found in the current scene")
                return
            end
        end
    end
    
    local is_valid, error_msg = validate_source_dimensions(app_state.source)
    if not is_valid then
        log("error", "Cannot activate zoom: " .. tostring(error_msg))
        return
    end
    
    show_fit_to_screen_info()
    
    -- Toggle: if zoomed in or zooming in -> zoom out; if idle or zooming out -> zoom in
    if zoom_state == "zoomed_in" or zoom_state == "zooming_in" then
        log("info", "Deactivating zoom")
        app_state.follow.active = false
        app_state.follow.force_update = false
        start_zoom_out()

    elseif zoom_state == "zooming_out" then
        -- Interrupt zoom-out: reuse existing filter, start zoom-in from current level
        log("info", "Interrupting zoom-out, reversing to zoom-in")
        app_state.follow.active = false
        app_state.follow.force_update = false
        start_zoom_in()

    else
        -- Starting from idle: need fresh filter
        log("info", "Activating zoom from idle")
        stop_zoom_timer()

        -- Clean up old filter if present
        if app_state.crop_filter and app_state.current_filter_target then
            pcall(function()
                obs.obs_source_filter_remove(app_state.current_filter_target, app_state.crop_filter)
            end)
            if app_state.crop_filter_owned then
                pcall(function() obs.obs_source_release(app_state.crop_filter) end)
            end
            app_state.crop_filter = nil
            app_state.crop_filter_owned = false
            app_state.current_filter_target = nil
        end
        
        local is_valid2, error_msg2 = validate_source_dimensions(app_state.source)
        if not is_valid2 then
            log("error", "Cannot activate zoom: " .. tostring(error_msg2))
            return
        end
        
        -- Capture dimensions BEFORE applying filter (after filter_add, get_width returns 0)
        local pre_w, pre_h = get_source_dimensions(app_state.source)

        -- Capture the scene-item transform before the filter changes the
        -- source dimensions. The transform is updated during zoom and restored
        -- exactly when zoom-out completes.
        capture_original_sceneitem_transform(pre_w, pre_h)
        
        app_state.zoom.current = 1.0
        app_state.follow.active = false
        app_state.follow.force_update = false
        app_state.current_crop = nil
        app_state.last_mouse_pos = {x = 0, y = 0}
        app_state.last_crop = {left = 0, top = 0, right = 0, bottom = 0}
        
        local filter_applied = apply_crop_filter(app_state.source)
        if not filter_applied then
            log("error", "Failed to apply crop filter - zoom cancelled")
            return
        end
        
        if not app_state.original_crop then
            app_state.original_crop = {left = 0, top = 0, right = 0, bottom = 0}
        end
        
        start_zoom_in(pre_w, pre_h)
    end
end

-- Handler for follow hotkey
local function on_follow_hotkey(pressed)
    if not pressed then
        return
    end

    debug_trace("follow-hotkey", 0, string.format(
        "received pressed=%s zoom_state=%s zoom_active=%s follow_active(before)=%s timer=%s source=%s",
        tostring(pressed), tostring(zoom_state), tostring(app_state.zoom.active),
        tostring(app_state.follow.active), tostring(zoom_timer_running),
        app_state.source and obs.obs_source_get_name(app_state.source) or "<nil>"))
    
    if not app_state.zoom.active then
        log("warning", "Follow can only be activated when zoom is active")
        debug_trace("follow-rejected", 0, "zoom is not active")
        return
    end
    
    app_state.follow.active = not app_state.follow.active
    if app_state.follow.active then
        -- Do not wait for the next physical mouse movement. The first follow
        -- tick must recalculate the crop and place the current mouse pixel at
        -- the center of the output canvas immediately.
        app_state.follow.force_update = true
        ensure_zoom_timer()
        log("info", string.format("Follow activated - speed: %.2f", app_state.follow.speed))
        debug_trace("follow-enabled", 0, string.format(
            "follow_active=%s timer=%s speed=%.3f zoom_state=%s force_update=%s last_mouse=(%.1f,%.1f)",
            tostring(app_state.follow.active), tostring(zoom_timer_running), app_state.follow.speed,
            tostring(zoom_state), tostring(app_state.follow.force_update),
            app_state.last_mouse_pos.x, app_state.last_mouse_pos.y))
    else
        app_state.follow.force_update = false
        log("info", "Follow deactivated")
        debug_trace("follow-disabled", 0, string.format(
            "follow_active=%s timer=%s zoom_state=%s last_crop=[%d,%d,%d,%d]",
            tostring(app_state.follow.active), tostring(zoom_timer_running), tostring(zoom_state),
            app_state.last_crop.left, app_state.last_crop.top,
            app_state.last_crop.right, app_state.last_crop.bottom))
        if zoom_state == "zoomed_in" then
            stop_zoom_timer()
            log("info", "Timer stopped - follow off, zoom static")
        end
    end
end

-- ============================================================================
-- SCENE CHANGE HANDLER
-- ============================================================================

-- Handle scene changes
local function on_scene_change()
    local new_scene = obs.obs_frontend_get_current_scene()
    if new_scene ~= app_state.current_scene then
        app_state.current_scene = new_scene

        -- The current scene item may be replaced below. Restore its transform
        -- before dropping the reference during a scene change.
        restore_original_sceneitem_transform()
        
        -- Remove filter from previous scene if it exists
        if app_state.current_filter_target then
            local old_filter = obs.obs_source_get_filter_by_name(app_state.current_filter_target, CROP_FILTER_NAME)
            if old_filter then
                -- Note: obs_source_get_filter_by_name returns borrowed reference, no need to release
                pcall(function()
                    obs.obs_source_filter_remove(app_state.current_filter_target, old_filter)
                end)
            end
        end
        
        -- Note: Sources from scene items are managed by OBS, no need to release
        app_state.source = nil
        app_state.source_scene_item = nil
        
        -- Release old filter reference only if we created it
        -- Filters obtained with obs_source_get_filter_by_name are borrowed and shouldn't be released
        if app_state.crop_filter and app_state.crop_filter_owned then
            pcall(function()
                obs.obs_source_release(app_state.crop_filter)
            end)
            app_state.crop_filter = nil
            app_state.crop_filter_owned = false
        end
        
        -- Find new valid video source in the new scene
        app_state.source = find_valid_video_source()
        
        if app_state.source then
            -- Apply filter to the new source
            apply_crop_filter(app_state.source)
            
            if app_state.zoom.active then
                -- Capture dimensions before they go to 0 after filter_add
                local sw, sh = get_source_dimensions(app_state.source)
                if sw > 0 and sh > 0 then
                    app_state._src_dims = {w = sw, h = sh}
                end
                local dims = app_state._src_dims
                if dims then
                    local mouse_x, mouse_y = ffi_platform.get_mouse_pos()
                    local target_crop = calc_zoom_crop(mouse_x, mouse_y, app_state.zoom.current, dims.w, dims.h)
                    update_crop(target_crop.left, target_crop.top, target_crop.right, target_crop.bottom)
                    app_state.last_crop = copy_crop(target_crop)
                    app_state.current_crop = target_crop
                    app_state.last_mouse_pos = {x = mouse_x, y = mouse_y}
                end
                if app_state.follow.active then
                    ensure_zoom_timer()
                end
            else
                -- If zoom wasn't active, ensure the filter is set without zoom
                update_crop(0, 0, 0, 0)
            end
        else
            -- If no valid source is found, deactivate zoom
            app_state.zoom.active = false
            app_state.follow.active = false
            app_state.follow.force_update = false
            stop_zoom_timer()
            zoom_state = "idle"
            log("warning", "Zoom deactivated: no valid video source in the new scene")
        end
    end
    -- Release scene (protected with pcall)
    pcall(function()
        obs.obs_source_release(new_scene)
    end)
end

-- ============================================================================
-- SETTINGS VALIDATION
-- ============================================================================

-- Validate settings
local function validate_settings(settings)
    local zoom_val = obs.obs_data_get_double(settings, "zoom_value")
    local follow_spd = obs.obs_data_get_double(settings, "follow_speed")
    
    if zoom_val < 1.1 or zoom_val > MAX_ZOOM_VALUE then
        log("warning", "Zoom value out of range, clamping to valid range")
        obs.obs_data_set_double(settings, "zoom_value", math.max(1.1, math.min(MAX_ZOOM_VALUE, zoom_val)))
    end
    
    if follow_spd < 0.01 or follow_spd > 1.0 then
        log("warning", "Follow speed out of range, clamping to valid range")
        obs.obs_data_set_double(settings, "follow_speed", math.max(0.01, math.min(1.0, follow_spd)))
    end
end

-- ============================================================================
-- RESOURCE CLEANUP
-- ============================================================================

-- Cleanup all resources
local function cleanup_all_resources()
    -- CRITICAL: Set cleanup flag FIRST to prevent new timers
    if app_state then
        app_state.cleanup_in_progress = true
        
        -- Remove zoom tick timer
        stop_zoom_timer()
        zoom_state = "idle"
        log("info", "Zoom timer removed during cleanup")
    end

    restore_original_sceneitem_transform()
    
    -- Remove crop filter (protected with pcall to prevent crashes)
    if app_state.crop_filter and app_state.current_filter_target then
        pcall(function()
            obs.obs_source_filter_remove(app_state.current_filter_target, app_state.crop_filter)
        end)
        -- Release filter only if we created it (protected with pcall)
        if app_state.crop_filter_owned then
            pcall(function()
                obs.obs_source_release(app_state.crop_filter)
            end)
        end
        app_state.crop_filter = nil
        app_state.crop_filter_owned = false
        app_state.current_filter_target = nil
    end
    
    -- Note: Sources from scene items are managed by OBS, no need to release
    app_state.source = nil
    app_state.source_scene_item = nil
    
    -- Release scene reference (protected with pcall to prevent crashes)
    if app_state.current_scene then
        pcall(function()
            obs.obs_source_release(app_state.current_scene)
        end)
        app_state.current_scene = nil
    end
    
    -- Cleanup FFI platform
    ffi_platform.cleanup()
    
    -- Reset state (after all timers are removed)
    if app_state then
        reset_state()
    end
end

-- ============================================================================
-- OBS CALLBACKS
-- ============================================================================

-- Script description
function script_description()
    return "Zoom and follow mouse for OBS Studio. Capability-based source detection (works with any video source, nested scenes and groups), HiDPI-aware tracking, multi-monitor support. Version 2.2.0"
end

-- Script properties
function script_properties()
    local props = obs.obs_properties_create()
    
    -- Main settings
    obs.obs_properties_add_float_slider(props, "zoom_value", "Zoom Value", 1.1, MAX_ZOOM_VALUE, 0.1)
    obs.obs_properties_add_int(props, "zoom_animation_duration", "Zoom In Duration (ms)", 1, 60000, 1)
    obs.obs_properties_add_int(props, "zoom_out_duration", "Zoom Out Duration (ms)", 1, 60000, 1)
    obs.obs_properties_add_float_slider(props, "follow_speed", "Follow Speed", 0.01, 1.0, 0.01)

    -- Auto-follow: when ON, the viewport tracks the mouse as soon as you zoom in,
    -- without pressing the Follow hotkey. Default OFF (no change for existing users).
    obs.obs_properties_add_bool(props, "auto_follow", "Auto-follow while zoomed (no separate hotkey)")

    -- Optional: prefer a specific source by name. Useful with nested scenes / groups
    -- or when a scene has several captures. Empty = automatic (first capture found).
    local src_list = obs.obs_properties_add_list(props, "preferred_source_name",
        "Preferred Source (optional)", obs.OBS_COMBO_TYPE_EDITABLE, obs.OBS_COMBO_FORMAT_STRING)
    obs.obs_property_list_add_string(src_list, "(automatic — first capture found)", "")
    local all_sources = obs.obs_enum_sources()
    if all_sources then
        for _, src in ipairs(all_sources) do
            if source_produces_video(src) then
                local name = obs.obs_source_get_name(src)
                if name then
                    obs.obs_property_list_add_string(src_list, name, name)
                end
            end
        end
        obs.source_list_release(all_sources)
    end

    -- Advanced settings group
    local advanced_group = obs.obs_properties_create()
    obs.obs_properties_add_int(advanced_group, "update_interval", "Update Interval (ms)", 8, 100, 1)
    obs.obs_properties_add_int(advanced_group, "mouse_deadzone", "Mouse Deadzone (pixels)", 1, 10, 1)
    obs.obs_properties_add_int(advanced_group, "crop_update_threshold", "Crop Update Threshold (pixels)", 1, 10, 1)
    obs.obs_properties_add_int(advanced_group, "crop_edge_threshold", "Crop Edge Threshold (pixels)", 1, 20, 1)
    obs.obs_properties_add_int(advanced_group, "scene_transition_duration", "Scene Transition Duration (ms)", 100, 1000, 50)
    obs.obs_properties_add_int(advanced_group, "mouse_cache_duration", "Mouse Cache Duration (ms)", 4, 32, 1)
    obs.obs_properties_add_int(advanced_group, "default_monitor_width", "Default Monitor Width", 640, 7680, 1)
    obs.obs_properties_add_int(advanced_group, "default_monitor_height", "Default Monitor Height", 480, 4320, 1)
    obs.obs_properties_add_group(props, "advanced", "Advanced Settings", obs.OBS_GROUP_NORMAL, advanced_group)
    
    -- Debug
    obs.obs_properties_add_bool(props, "debug_mode", "Enable Debug Mode")
    
    return props
end

-- Default values
function script_defaults(settings)
    obs.obs_data_set_default_double(settings, "zoom_value", 2.0)
    obs.obs_data_set_default_int(settings, "zoom_animation_duration", DEFAULT_ZOOM_ANIMATION_DURATION)
    obs.obs_data_set_default_int(settings, "zoom_out_duration", DEFAULT_ZOOM_OUT_DURATION)
    obs.obs_data_set_default_double(settings, "follow_speed", 1.0)
    obs.obs_data_set_default_bool(settings, "auto_follow", false)
    obs.obs_data_set_default_string(settings, "preferred_source_name", "")
    obs.obs_data_set_default_bool(settings, "debug_mode", false)
    
    -- Advanced settings defaults
    obs.obs_data_set_default_int(settings, "update_interval", DEFAULT_UPDATE_INTERVAL)
    obs.obs_data_set_default_int(settings, "mouse_deadzone", DEFAULT_MOUSE_DEADZONE)
    obs.obs_data_set_default_int(settings, "crop_update_threshold", DEFAULT_CROP_UPDATE_THRESHOLD)
    obs.obs_data_set_default_int(settings, "crop_edge_threshold", DEFAULT_CROP_EDGE_THRESHOLD)
    obs.obs_data_set_default_int(settings, "scene_transition_duration", DEFAULT_SCENE_TRANSITION_DURATION)
    obs.obs_data_set_default_int(settings, "mouse_cache_duration", DEFAULT_MOUSE_CACHE_DURATION)
    obs.obs_data_set_default_int(settings, "default_monitor_width", DEFAULT_MONITOR_WIDTH)
    obs.obs_data_set_default_int(settings, "default_monitor_height", DEFAULT_MONITOR_HEIGHT)
end

-- Settings update
function script_update(settings)
    -- Validate settings first
    validate_settings(settings)
    
    -- Update main state with validated settings
    app_state.zoom.value = obs.obs_data_get_double(settings, "zoom_value")
    app_state.zoom_animation_duration = obs.obs_data_get_int(settings, "zoom_animation_duration") or DEFAULT_ZOOM_ANIMATION_DURATION
    app_state.zoom_out_duration = obs.obs_data_get_int(settings, "zoom_out_duration") or DEFAULT_ZOOM_OUT_DURATION
    app_state.follow.speed = obs.obs_data_get_double(settings, "follow_speed")
    app_state.follow.auto = obs.obs_data_get_bool(settings, "auto_follow")
    app_state.preferred_source_name = obs.obs_data_get_string(settings, "preferred_source_name") or ""
    app_state.debug_mode = obs.obs_data_get_bool(settings, "debug_mode")
    
    -- Update advanced configurable parameters
    app_state.update_interval = obs.obs_data_get_int(settings, "update_interval") or DEFAULT_UPDATE_INTERVAL
    app_state.mouse_deadzone = obs.obs_data_get_int(settings, "mouse_deadzone") or DEFAULT_MOUSE_DEADZONE
    app_state.crop_update_threshold = obs.obs_data_get_int(settings, "crop_update_threshold") or DEFAULT_CROP_UPDATE_THRESHOLD
    app_state.crop_edge_threshold = obs.obs_data_get_int(settings, "crop_edge_threshold") or DEFAULT_CROP_EDGE_THRESHOLD
    app_state.scene_transition_duration = obs.obs_data_get_int(settings, "scene_transition_duration") or DEFAULT_SCENE_TRANSITION_DURATION
    app_state.mouse_cache_duration = obs.obs_data_get_int(settings, "mouse_cache_duration") or DEFAULT_MOUSE_CACHE_DURATION
    app_state.default_monitor_width = obs.obs_data_get_int(settings, "default_monitor_width") or DEFAULT_MONITOR_WIDTH
    app_state.default_monitor_height = obs.obs_data_get_int(settings, "default_monitor_height") or DEFAULT_MONITOR_HEIGHT
    
    if app_state.zoom.active then
        app_state.zoom.target = app_state.zoom.value
    end
    
    validate_state()

    debug_trace("settings", 0, string.format(
        "zoom=%.3f follow_speed=%.3f auto_follow=%s interval=%dms deadzone=%d cache=%dms preferred=%q debug=%s",
        app_state.zoom.value, app_state.follow.speed, tostring(app_state.follow.auto),
        app_state.update_interval, app_state.mouse_deadzone, app_state.mouse_cache_duration,
        app_state.preferred_source_name, tostring(app_state.debug_mode)))
end

-- Script loading
function script_load(settings)
    -- Initialize FFI platform
    local success, err = ffi_platform.init()
    if not success then
        log("error", "Failed to initialize FFI platform: " .. tostring(err))
    end
    
    -- Get monitor information
    app_state.monitors = ffi_platform.get_monitors()
    log("info", "Detected " .. #app_state.monitors .. " monitor(s)")
    
    -- Register hotkeys
    app_state.zoom_hotkey_id = obs.obs_hotkey_register_frontend(ZOOM_HOTKEY_NAME, "Toggle Zoom", on_zoom_hotkey)
    app_state.follow_hotkey_id = obs.obs_hotkey_register_frontend(FOLLOW_HOTKEY_NAME, "Toggle Follow", on_follow_hotkey)
    
    -- Load saved hotkeys
    local zoom_hotkey_save_array = obs.obs_data_get_array(settings, ZOOM_HOTKEY_NAME)
    obs.obs_hotkey_load(app_state.zoom_hotkey_id, zoom_hotkey_save_array)
    obs.obs_data_array_release(zoom_hotkey_save_array)
    
    local follow_hotkey_save_array = obs.obs_data_get_array(settings, FOLLOW_HOTKEY_NAME)
    obs.obs_hotkey_load(app_state.follow_hotkey_id, follow_hotkey_save_array)
    obs.obs_data_array_release(follow_hotkey_save_array)
    
    -- Add event handler for scene changes
    obs.obs_frontend_add_event_callback(function(event)
        if event == obs.OBS_FRONTEND_EVENT_SCENE_CHANGED then
            on_scene_change()
        end
    end)
    
    -- Update settings
    script_update(settings)

    local monitor_parts = {}
    for i, monitor in ipairs(app_state.monitors) do
        monitor_parts[#monitor_parts + 1] = string.format("%d:[%.0f,%.0f]-[%.0f,%.0f]",
            i, monitor.left, monitor.top, monitor.right, monitor.bottom)
    end
    debug_trace("startup", 0, string.format(
        "script loaded version=2.2.0+transform+macos-debug os=%s ffi_initialized=%s CoreGraphics=%s path=%s init_error=%q monitors=%d %s",
        tostring(ffi_platform.os_type), tostring(ffi_platform.initialized),
        tostring(ffi_platform.core_graphics ~= nil),
        tostring(ffi_platform.core_graphics_load_path or "<none>"),
        tostring(ffi_platform.init_error or "<none>"), #app_state.monitors,
        #monitor_parts > 0 and table.concat(monitor_parts, "; ") or "<none>"))
    
    -- NOTE: Do NOT apply filter automatically at startup
    -- Filter will be applied only when zoom is activated via hotkey
    -- This prevents issues during script reload and conflicts with other scripts
    app_state.source = find_valid_video_source()
    if app_state.source and app_state.debug_mode then
        log("info", "Script loaded - source found but filter not applied until zoom is activated")
    end
end

-- Script saving
function script_save(settings)
    local zoom_hotkey_save_array = obs.obs_hotkey_save(app_state.zoom_hotkey_id)
    obs.obs_data_set_array(settings, ZOOM_HOTKEY_NAME, zoom_hotkey_save_array)
    obs.obs_data_array_release(zoom_hotkey_save_array)
    
    local follow_hotkey_save_array = obs.obs_hotkey_save(app_state.follow_hotkey_id)
    obs.obs_data_set_array(settings, FOLLOW_HOTKEY_NAME, follow_hotkey_save_array)
    obs.obs_data_array_release(follow_hotkey_save_array)
end

-- Script unloading
function script_unload()
    -- CRITICAL: Ensure all timers are stopped and filters removed before cleanup
    -- This prevents any operations on sources/scenes after script is unloaded
    if app_state then
        -- Stop zoom timer
        pcall(stop_zoom_timer)
        zoom_state = "idle"

        restore_original_sceneitem_transform()
        
        -- Remove filter but DO NOT release source references
        -- Sources are managed by OBS, we should never release them
        if app_state.crop_filter and app_state.current_filter_target then
            pcall(function()
                obs.obs_source_filter_remove(app_state.current_filter_target, app_state.crop_filter)
            end)
            -- Only release filter if we created it
            if app_state.crop_filter_owned then
                pcall(function()
                    obs.obs_source_release(app_state.crop_filter)
                end)
            end
        end
        
        -- Clear references (but DO NOT release sources - they're managed by OBS)
        app_state.source = nil
        app_state.source_scene_item = nil
        app_state.current_filter_target = nil
        app_state.crop_filter = nil
        app_state.crop_filter_owned = false
    end
    
    -- Cleanup FFI resources
    ffi_platform.cleanup()
    
    -- Reset state
    if app_state then
        reset_state()
    end
end
