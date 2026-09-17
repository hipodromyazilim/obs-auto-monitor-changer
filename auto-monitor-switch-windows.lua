obs = obslua

local enabled           = true
local poll_ms           = 250
local ignore_obs_window = true
local verbose           = false

local rects     = {} 
local managed   = {} 
local last_name = nil
local timer_on  = false

local function log(m)  if verbose then print("[AMS] " .. m) end end
local function warn(m) print("[AMS] " .. m) end

local ffi_ok, ffi = pcall(require, "ffi")
local user32, kernel32

if ffi_ok then
    pcall(function()
        ffi.cdef [[
            typedef void* HWND;
            typedef void* HMONITOR;
            typedef struct { long left; long top; long right; long bottom; } RECT;
            typedef struct {
                unsigned long cbSize;
                RECT rcMonitor; RECT rcWork;
                unsigned long dwFlags;
                char szDevice[32];
            } MONITORINFOEXA;
            HWND GetForegroundWindow(void);
            HMONITOR MonitorFromWindow(HWND, unsigned long);
            int GetMonitorInfoA(HMONITOR, MONITORINFOEXA*);
            unsigned long GetWindowThreadProcessId(HWND, unsigned long*);
            unsigned long GetCurrentProcessId(void);
        ]]
    end)
    local ok1, l1 = pcall(ffi.load, "user32")   ; if ok1 then user32 = l1 end
    local ok2, l2 = pcall(ffi.load, "kernel32") ; if ok2 then kernel32 = l2 end
end

local function get_focus_point()
    if not user32 then return nil end
    local hwnd = user32.GetForegroundWindow()
    if hwnd == nil then return nil end

    if ignore_obs_window and kernel32 then
        local pid = ffi.new("unsigned long[1]")
        user32.GetWindowThreadProcessId(hwnd, pid)
        if pid[0] == kernel32.GetCurrentProcessId() then return nil end
    end

    local hmon = user32.MonitorFromWindow(hwnd, 2)
    if hmon == nil then return nil end

    local mi = ffi.new("MONITORINFOEXA")
    mi.cbSize = ffi.sizeof("MONITORINFOEXA")
    if user32.GetMonitorInfoA(hmon, mi) == 0 then return nil end

    local l, t = tonumber(mi.rcMonitor.left),  tonumber(mi.rcMonitor.top)
    local r, b = tonumber(mi.rcMonitor.right), tonumber(mi.rcMonitor.bottom)
    return (l + r) / 2, (t + b) / 2
end

local function parse_rect(label)
    if not label then return nil end
    local w, h, x, y = string.match(label,
        "(%d+)%s*[xX]%s*(%d+)%s*@%s*(%-?%d+)%s*,%s*(%-?%d+)")
    if not w then return nil end
    return tonumber(x), tonumber(y), tonumber(w), tonumber(h)
end

local CAPTURE_IDS  = { monitor_capture = true }
local SETTING_KEYS = { "monitor_id", "monitor" }

local function get_source_rect(source)
    local settings = obs.obs_source_get_settings(source)
    local props    = obs.obs_source_properties(source)
    local x, y, w, h

    if props ~= nil then
        for _, key in ipairs(SETTING_KEYS) do
            local p = obs.obs_properties_get(props, key)
            if p ~= nil then
                local fmt   = obs.obs_property_list_format(p)
                local count = obs.obs_property_list_item_count(p)
                for i = 0, count - 1 do
                    local hit = false
                    if fmt == obs.OBS_COMBO_FORMAT_STRING then
                        hit = (obs.obs_property_list_item_string(p, i)
                               == obs.obs_data_get_string(settings, key))
                    elseif fmt == obs.OBS_COMBO_FORMAT_INT then
                        hit = (obs.obs_property_list_item_int(p, i)
                               == obs.obs_data_get_int(settings, key))
                    end
                    if hit then
                        x, y, w, h = parse_rect(obs.obs_property_list_item_name(p, i))
                        break
                    end
                end
            end
            if x ~= nil then break end
        end
        obs.obs_properties_destroy(props)
    end

    obs.obs_data_release(settings)
    return x, y, w, h
end

local function rebuild_index()
    rects, managed = {}, {}
    local sources = obs.obs_enum_sources()
    if sources ~= nil then
        for _, src in ipairs(sources) do
            if CAPTURE_IDS[obs.obs_source_get_unversioned_id(src)] then
                local name = obs.obs_source_get_name(src)
                managed[name] = true
                local x, y, w, h = get_source_rect(src)
                if x ~= nil then
                    table.insert(rects, { x = x, y = y, w = w, h = h, name = name })
                    log(string.format("'%s' -> %dx%d @ %d,%d", name, w, h, x, y))
                else
                    warn(string.format("Could not resolve monitor for source '%s', skipping.", name))
                end
            end
        end
        obs.source_list_release(sources)
    end
    if #rects == 0 then warn("No Display Capture source found.") end
end

local function find_source(px, py)
    for _, r in ipairs(rects) do
        if px >= r.x and px < r.x + r.w and py >= r.y and py < r.y + r.h then
            return r.name
        end
    end
    local best, bd
    for _, r in ipairs(rects) do
        local dx, dy = px - (r.x + r.w / 2), py - (r.y + r.h / 2)
        local d = dx * dx + dy * dy
        if bd == nil or d < bd then best, bd = r.name, d end
    end
    return best
end

local function apply_to_scene(scene, active_name)
    local items = obs.obs_scene_enum_items(scene)
    if items == nil then return end
    for _, item in ipairs(items) do
        local src  = obs.obs_sceneitem_get_source(item)
        local name = obs.obs_source_get_name(src)
        if managed[name] then
            obs.obs_sceneitem_set_visible(item, name == active_name)
        elseif obs.obs_sceneitem_is_group(item) then
            local grp = obs.obs_group_from_source(src)
            if grp ~= nil then apply_to_scene(grp, active_name) end
        end
    end
    obs.sceneitem_list_release(items)
end

local function activate(name)
    local scene_src = obs.obs_frontend_get_current_scene()
    if scene_src == nil then return end
    local scene = obs.obs_scene_from_source(scene_src)
    if scene ~= nil then
        apply_to_scene(scene, name)
        log("active source -> " .. name)
    end
    obs.obs_source_release(scene_src)
end

local function tick()
    if not enabled then return end
    local px, py = get_focus_point()
    if px == nil then return end
    if #rects == 0 then rebuild_index() end
    local name = find_source(px, py)
    if name == nil or name == last_name then return end
    last_name = name
    activate(name)
end

local function restart_timer()
    if timer_on then obs.timer_remove(tick) timer_on = false end
    if enabled and user32 then obs.timer_add(tick, poll_ms) timer_on = true end
end

local function on_event(event)
    if event == obs.OBS_FRONTEND_EVENT_FINISHED_LOADING
        or event == obs.OBS_FRONTEND_EVENT_SCENE_COLLECTION_CHANGED
        or event == obs.OBS_FRONTEND_EVENT_SCENE_LIST_CHANGED then
        rebuild_index()
        last_name = nil
    elseif event == obs.OBS_FRONTEND_EVENT_SCENE_CHANGED then
        last_name = nil
    end
end

function script_description()
    return [[<b>Auto Monitor Switch</b> (Windows)<br/>
Odaktaki pencere hangi monitordeyse, o monitorun <i>Display Capture</i> kaynagini
otomatik gorunur yapar, digerlerini gizler.<br/>
Sahne ve kaynak adlari otomatik bulunur, elle isim girmek gerekmez.]]
end

function script_properties()
    local p = obs.obs_properties_create()
    obs.obs_properties_add_bool(p, "enabled", "Etkin")
    obs.obs_properties_add_int_slider(p, "poll_ms", "Kontrol araligi (ms)", 50, 2000, 50)
    obs.obs_properties_add_bool(p, "ignore_obs_window", "OBS penceresine gecince degistirme")
    obs.obs_properties_add_bool(p, "verbose", "Ayrintili log")
    obs.obs_properties_add_button(p, "rescan", "Kaynaklari yeniden tara", function()
        rebuild_index()
        last_name = nil
        warn("Sources found: " .. #rects)
        for _, r in ipairs(rects) do
            warn(string.format("  '%s' -> %dx%d @ %d,%d", r.name, r.w, r.h, r.x, r.y))
        end
        return true
    end)
    return p
end

function script_defaults(s)
    obs.obs_data_set_default_bool(s, "enabled", true)
    obs.obs_data_set_default_int(s, "poll_ms", 250)
    obs.obs_data_set_default_bool(s, "ignore_obs_window", true)
    obs.obs_data_set_default_bool(s, "verbose", false)
end

function script_update(s)
    enabled           = obs.obs_data_get_bool(s, "enabled")
    poll_ms           = obs.obs_data_get_int(s, "poll_ms")
    ignore_obs_window = obs.obs_data_get_bool(s, "ignore_obs_window")
    verbose           = obs.obs_data_get_bool(s, "verbose")
    last_name         = nil
    restart_timer()
end

function script_load(s)
    if not ffi_ok or not user32 then
        warn("ERROR: Could not access Win32 API. This file is for Windows.")
        return
    end
    obs.obs_frontend_add_event_callback(on_event)
    rebuild_index()
    restart_timer()
end

function script_unload()
    if timer_on then obs.timer_remove(tick) timer_on = false end
end
