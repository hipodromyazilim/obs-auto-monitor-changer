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
local x11, dpy, root, noop_handler, my_pid

local function init_x11()
    if not ffi_ok then
        warn("ERROR: LuaJIT ffi not available.")
        return false
    end

    pcall(function()
        ffi.cdef [[
            typedef struct _XDisplay Display;
            typedef unsigned long XID;
            typedef unsigned long Atom;
            typedef int (*XErrorHandlerFn)(Display*, void*);

            Display* XOpenDisplay(const char*);
            int   XCloseDisplay(Display*);
            XID   XDefaultRootWindow(Display*);
            Atom  XInternAtom(Display*, const char*, int);
            int   XGetWindowProperty(Display*, XID, Atom, long, long, int, Atom,
                                     Atom*, int*, unsigned long*, unsigned long*,
                                     unsigned char**);
            int   XFree(void*);
            int   XGetGeometry(Display*, XID, XID*, int*, int*, unsigned int*,
                               unsigned int*, unsigned int*, unsigned int*);
            int   XTranslateCoordinates(Display*, XID, XID, int, int, int*, int*, XID*);
            int   XSync(Display*, int);
            XErrorHandlerFn XSetErrorHandler(XErrorHandlerFn);
            int getpid(void);
        ]]
    end)

    for _, lib in ipairs({ "X11", "libX11.so.6", "libX11.so" }) do
        local ok, l = pcall(ffi.load, lib)
        if ok then x11 = l break end
    end
    if not x11 then
        warn("ERROR: Could not load libX11. Make sure the libx11-6 package is installed.")
        return false
    end

    dpy = x11.XOpenDisplay(nil)
    if dpy == nil then
        warn("ERROR: Could not connect to the X server (is DISPLAY set?).")
        return false
    end
    root = x11.XDefaultRootWindow(dpy)

    noop_handler = ffi.cast("XErrorHandlerFn", function(d, e) return 0 end)
    my_pid = ffi.C.getpid()
    return true
end

local function get_card_prop(win, atom_name)
    local a = x11.XInternAtom(dpy, atom_name, 1)
    if a == 0 then return nil end
    local at = ffi.new("Atom[1]")
    local af = ffi.new("int[1]")
    local ni = ffi.new("unsigned long[1]")
    local ba = ffi.new("unsigned long[1]")
    local pr = ffi.new("unsigned char*[1]")
    if x11.XGetWindowProperty(dpy, win, a, 0, 1, 0, 0, at, af, ni, ba, pr) ~= 0 then
        return nil
    end
    local val
    if ni[0] > 0 and pr[0] ~= nil then
        val = tonumber(ffi.cast("unsigned long*", pr[0])[0])
    end
    if pr[0] ~= nil then x11.XFree(pr[0]) end
    return val
end

local function get_focus_point()
    if not x11 then return nil end
    local prev = x11.XSetErrorHandler(noop_handler)
    local cx, cy

    repeat
        local win = get_card_prop(root, "_NET_ACTIVE_WINDOW")
        if win == nil or win == 0 then break end

        if ignore_obs_window then
            local pid = get_card_prop(win, "_NET_WM_PID")
            if pid ~= nil and pid == my_pid then break end
        end

        local rr = ffi.new("XID[1]")
        local gx, gy = ffi.new("int[1]"), ffi.new("int[1]")
        local gw, gh = ffi.new("unsigned int[1]"), ffi.new("unsigned int[1]")
        local gb, gd = ffi.new("unsigned int[1]"), ffi.new("unsigned int[1]")
        if x11.XGetGeometry(dpy, win, rr, gx, gy, gw, gh, gb, gd) == 0 then break end

        local ax, ay = ffi.new("int[1]"), ffi.new("int[1]")
        local child  = ffi.new("XID[1]")
        if x11.XTranslateCoordinates(dpy, win, root, 0, 0, ax, ay, child) == 0 then break end

        cx = ax[0] + gw[0] / 2
        cy = ay[0] + gh[0] / 2
    until true

    x11.XSync(dpy, 0)
    x11.XSetErrorHandler(prev)
    return cx, cy
end

local function parse_rect(label)
    if not label then return nil end
    local w, h, x, y = string.match(label,
        "(%d+)%s*[xX]%s*(%d+)%s*@%s*(%-?%d+)%s*,%s*(%-?%d+)")
    if not w then return nil end
    return tonumber(x), tonumber(y), tonumber(w), tonumber(h)
end

local CAPTURE_IDS  = { xshm_input = true }
local SETTING_KEYS = { "screen_id", "screen", "display" }

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
            local id = obs.obs_source_get_unversioned_id(src)
            if CAPTURE_IDS[id] then
                local name = obs.obs_source_get_name(src)
                managed[name] = true
                local x, y, w, h = get_source_rect(src)
                if x ~= nil then
                    table.insert(rects, { x = x, y = y, w = w, h = h, name = name })
                    log(string.format("'%s' -> %dx%d @ %d,%d", name, w, h, x, y))
                else
                    warn(string.format("Could not resolve screen for source '%s', skipping.", name))
                end
            elseif id == "pipewire-desktop-capture-source" then
                warn("PipeWire source skipped: the API can't tell which screen it captures. Use XSHM instead.")
            end
        end
        obs.source_list_release(sources)
    end
    if #rects == 0 then warn("No matchable XSHM source found.") end
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
    if enabled and x11 then obs.timer_add(tick, poll_ms) timer_on = true end
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
    return [[<b>Auto Monitor Switch</b> (Linux / X11)<br/>
Odaktaki pencere hangi ekrandaysa, o ekranin <i>Screen Capture (XSHM)</i>
kaynagini otomatik gorunur yapar, digerlerini gizler.<br/>
<small>Wayland oturumunda native pencereler goruntulenemez; Xorg oturumu onerilir.</small>]]
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
    if os.getenv("WAYLAND_DISPLAY") then
        warn("WARNING: Wayland session detected. Only XWayland windows are visible; "
             .. "for reliable operation, use an Xorg session.")
    end
    if not init_x11() then
        warn("Script inactive.")
        return
    end
    obs.obs_frontend_add_event_callback(on_event)
    rebuild_index()
    restart_timer()
end

function script_unload()
    if timer_on then obs.timer_remove(tick) timer_on = false end
    if x11 and dpy ~= nil then
        x11.XCloseDisplay(dpy)
        dpy = nil
    end
end
