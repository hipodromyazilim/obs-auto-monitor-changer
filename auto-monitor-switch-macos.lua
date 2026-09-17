obs = obslua

local enabled           = true
local poll_ms           = 250
local ignore_obs_window = true
local verbose           = false

local entries   = {}
local managed   = {}
local last_name = nil
local timer_on  = false

local function log(m)  if verbose then print("[AMS] " .. m) end end
local function warn(m) print("[AMS] " .. m) end

local ffi_ok, ffi = pcall(require, "ffi")
local cg, cf, my_pid

local kCFStringEncodingUTF8      = 0x08000100
local kCFNumberIntType           = 9
local kCGWindowListOptionOnScreenOnly       = 1
local kCGWindowListExcludeDesktopElements   = 16

local function init_mac()
    if not ffi_ok then
        warn("ERROR: LuaJIT ffi not available.")
        return false
    end

    pcall(function()
        ffi.cdef [[
            typedef signed long CFIndex;
            typedef const void* CFTypeRef;
            typedef const struct __CFArray*      CFArrayRef;
            typedef const struct __CFDictionary* CFDictionaryRef;
            typedef const struct __CFString*     CFStringRef;
            typedef const struct __CFNumber*     CFNumberRef;
            typedef struct __CFUUID*             CFUUIDRef;
            typedef unsigned int CGDirectDisplayID;
            typedef unsigned int CGWindowID;
            typedef double CGFloat;
            typedef struct { CGFloat x; CGFloat y; } CGPoint;
            typedef struct { CGFloat width; CGFloat height; } CGSize;
            typedef struct { CGPoint origin; CGSize size; } CGRect;

            CFArrayRef  CGWindowListCopyWindowInfo(unsigned int option, CGWindowID relativeTo);
            CFIndex     CFArrayGetCount(CFArrayRef);
            const void* CFArrayGetValueAtIndex(CFArrayRef, CFIndex);
            const void* CFDictionaryGetValue(CFDictionaryRef, const void*);
            CFStringRef CFStringCreateWithCString(void*, const char*, unsigned int);
            bool        CFStringGetCString(CFStringRef, char*, CFIndex, unsigned int);
            void        CFRelease(CFTypeRef);
            bool        CFNumberGetValue(CFNumberRef, CFIndex, void*);
            bool        CGRectMakeWithDictionaryRepresentation(CFDictionaryRef, CGRect*);
            int         CGGetDisplaysWithPoint(CGPoint, unsigned int, CGDirectDisplayID*, unsigned int*);
            int         CGGetActiveDisplayList(unsigned int, CGDirectDisplayID*, unsigned int*);
            CGDirectDisplayID CGMainDisplayID(void);
            CFUUIDRef   CGDisplayCreateUUIDFromDisplayID(CGDirectDisplayID);
            CFStringRef CFUUIDCreateString(void*, CFUUIDRef);
            int getpid(void);
        ]]
    end)

    local ok1, l1 = pcall(ffi.load, "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
    local ok2, l2 = pcall(ffi.load, "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
    if not ok1 or not ok2 then
        warn("ERROR: Could not load CoreGraphics/CoreFoundation. This file is for macOS.")
        return false
    end
    cg, cf = l1, l2
    my_pid = ffi.C.getpid()
    return true
end

local keys = {}
local function key(name)
    if keys[name] == nil then
        keys[name] = cf.CFStringCreateWithCString(nil, name, kCFStringEncodingUTF8)
    end
    return keys[name]
end

local function cfstring_to_lua(cfstr)
    if cfstr == nil then return nil end
    local buf = ffi.new("char[?]", 256)
    if cf.CFStringGetCString(cfstr, buf, 256, kCFStringEncodingUTF8) then
        return ffi.string(buf)
    end
    return nil
end

local function cfnumber_to_int(num)
    if num == nil then return nil end
    local out = ffi.new("int[1]")
    if cf.CFNumberGetValue(ffi.cast("CFNumberRef", num), kCFNumberIntType, out) then
        return out[0]
    end
    return nil
end

local function get_focus_point()
    if not cg then return nil end
    local opts = kCGWindowListOptionOnScreenOnly + kCGWindowListExcludeDesktopElements
    local list = cg.CGWindowListCopyWindowInfo(opts, 0)
    if list == nil then return nil end

    local px, py
    local count = tonumber(cf.CFArrayGetCount(list))
    for i = 0, count - 1 do
        local dict = ffi.cast("CFDictionaryRef", cf.CFArrayGetValueAtIndex(list, i))
        if dict ~= nil then
            local layer = cfnumber_to_int(cf.CFDictionaryGetValue(dict, key("kCGWindowLayer")))
            local pid   = cfnumber_to_int(cf.CFDictionaryGetValue(dict, key("kCGWindowOwnerPID")))
            local skip  = (layer ~= 0) or (ignore_obs_window and pid == my_pid)
            if not skip then
                local bounds = cf.CFDictionaryGetValue(dict, key("kCGWindowBounds"))
                if bounds ~= nil then
                    local r = ffi.new("CGRect")
                    if cg.CGRectMakeWithDictionaryRepresentation(ffi.cast("CFDictionaryRef", bounds), r) then
                        if r.size.width > 1 and r.size.height > 1 then
                            px = r.origin.x + r.size.width / 2
                            py = r.origin.y + r.size.height / 2
                            break
                        end
                    end
                end
            end
        end
    end

    cf.CFRelease(ffi.cast("CFTypeRef", list))
    return px, py
end

local function display_at(px, py)
    local pt = ffi.new("CGPoint", { x = px, y = py })
    local ids = ffi.new("CGDirectDisplayID[8]")
    local n   = ffi.new("unsigned int[1]")
    if cg.CGGetDisplaysWithPoint(pt, 8, ids, n) ~= 0 or n[0] == 0 then return nil end
    local did = ids[0]

    local uuid_str
    local uuid = cg.CGDisplayCreateUUIDFromDisplayID(did)
    if uuid ~= nil then
        local s = cf.CFUUIDCreateString(nil, uuid)
        uuid_str = cfstring_to_lua(s)
        if s ~= nil then cf.CFRelease(ffi.cast("CFTypeRef", s)) end
        cf.CFRelease(ffi.cast("CFTypeRef", uuid))
    end

    local idx
    local all = ffi.new("CGDirectDisplayID[16]")
    local an  = ffi.new("unsigned int[1]")
    if cg.CGGetActiveDisplayList(16, all, an) == 0 then
        for i = 0, an[0] - 1 do
            if all[i] == did then idx = i break end
        end
    end

    return tonumber(did), uuid_str, idx
end

local CAPTURE_IDS = {
    display_capture = true,
    screen_capture  = true,
}

local function scan_source(source)
    local s = obs.obs_source_get_settings(source)

    local is_display = true
    if obs.obs_data_has_user_value(s, "type") then
        is_display = (obs.obs_data_get_int(s, "type") == 0)
    end

    local uuid, num, is_default
    if obs.obs_data_has_user_value(s, "display_uuid") then
        uuid = obs.obs_data_get_string(s, "display_uuid")
    end
    if obs.obs_data_has_user_value(s, "display") then
        num = obs.obs_data_get_int(s, "display")
    end
    if uuid == nil and num == nil then
        is_default = true
    end

    obs.obs_data_release(s)
    if not is_display then return nil end
    return { uuid = uuid, num = num, is_default = is_default }
end

local function rebuild_index()
    entries, managed = {}, {}
    local sources = obs.obs_enum_sources()
    if sources ~= nil then
        for _, src in ipairs(sources) do
            if CAPTURE_IDS[obs.obs_source_get_unversioned_id(src)] then
                local name = obs.obs_source_get_name(src)
                local e = scan_source(src)
                if e then
                    e.name = name
                    managed[name] = true
                    table.insert(entries, e)
                    log(string.format("'%s' -> uuid=%s num=%s default=%s",
                        name, tostring(e.uuid), tostring(e.num), tostring(e.is_default)))
                else
                    log(string.format("'%s' is not a display capture (window/app), skipping.", name))
                end
            end
        end
        obs.source_list_release(sources)
    end
    if #entries == 0 then warn("No matchable screen capture source found.") end
end

local function find_source(did, uuid, idx)
    local main_id = tonumber(cg.CGMainDisplayID())
    for _, e in ipairs(entries) do
        if e.uuid and uuid and e.uuid:lower() == uuid:lower() then return e.name end
    end
    for _, e in ipairs(entries) do
        if e.num and (e.num == did or (idx and e.num == idx)) then return e.name end
    end
    for _, e in ipairs(entries) do
        if e.is_default and did == main_id then return e.name end
    end
    return nil
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
    if not enabled or not cg then return end
    local px, py = get_focus_point()
    if px == nil then return end

    local did, uuid, idx = display_at(px, py)
    if did == nil then return end

    if #entries == 0 then rebuild_index() end
    local name = find_source(did, uuid, idx)
    if name == nil then
        rebuild_index()
        name = find_source(did, uuid, idx)
    end
    if name == nil or name == last_name then return end

    last_name = name
    activate(name)
end

local function restart_timer()
    if timer_on then obs.timer_remove(tick) timer_on = false end
    if enabled and cg then obs.timer_add(tick, poll_ms) timer_on = true end
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
    return [[<b>Auto Monitor Switch</b> (macOS, deneysel)<br/>
En ondeki pencere hangi ekrandaysa, o ekranin yakalama kaynagini otomatik
gorunur yapar, digerlerini gizler.<br/>
<small>Sadece <i>Display/Screen Capture</i> tipindeki (pencere veya uygulama degil)
kaynaklar yonetilir. OBS'in Ekran Kaydi izni acik olmalidir.</small>]]
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
        warn("Sources found: " .. #entries)
        for _, e in ipairs(entries) do
            warn(string.format("  '%s' uuid=%s num=%s default=%s",
                e.name, tostring(e.uuid), tostring(e.num), tostring(e.is_default)))
        end
        if cg then
            local px, py = get_focus_point()
            if px then
                local did, uuid = display_at(px, py)
                warn(string.format("  currently focused screen: id=%s uuid=%s",
                    tostring(did), tostring(uuid)))
            end
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
    if not init_mac() then
        warn("Script inactive.")
        return
    end
    obs.obs_frontend_add_event_callback(on_event)
    rebuild_index()
    restart_timer()
end

function script_unload()
    if timer_on then obs.timer_remove(tick) timer_on = false end
end
