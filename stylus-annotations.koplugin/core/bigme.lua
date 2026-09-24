local logger = require("logger")

local Bigme = {}
local MODULE_SOURCE = debug.getinfo(1, "S").source
local BRIDGE_CLASS = "org.koreader.bigme.BigmeInputBridge"
local BRIDGE_DEX_NAME = "BigmeInputBridge-1.dex"

local function trace(step)
    logger.info("Bigme input bridge stage:", step)
end

local function clearException(jni)
    local exception = jni.env[0].ExceptionOccurred(jni.env)
    if exception ~= nil then
        jni.env[0].ExceptionClear(jni.env)
        jni.env[0].DeleteLocalRef(jni.env, exception)
        return true
    end
    return false
end

local function loadClass(jni, class_loader, name)
    trace("loadClass " .. name)
    local java_name = jni.env[0].NewStringUTF(jni.env, name)
    local clazz = jni:callObjectMethod(
        class_loader,
        "loadClass",
        "(Ljava/lang/String;)Ljava/lang/Class;",
        java_name
    )
    jni.env[0].DeleteLocalRef(jni.env, java_name)
    local threw = clearException(jni)
    trace("loadClass returned " .. name .. ": " .. tostring(clazz ~= nil and not threw))
    return clazz, threw
end

local function newJavaObject(jni, class_loader, class_name, parameter_names, arguments)
    local clazz = loadClass(jni, class_loader, class_name)
    if clazz == nil then return nil end

    local class_class = loadClass(jni, class_loader, "java.lang.Class")
    local object_class = loadClass(jni, class_loader, "java.lang.Object")
    if class_class == nil or object_class == nil then
        jni.env[0].DeleteLocalRef(jni.env, clazz)
        if class_class ~= nil then jni.env[0].DeleteLocalRef(jni.env, class_class) end
        if object_class ~= nil then jni.env[0].DeleteLocalRef(jni.env, object_class) end
        return nil
    end

    local parameter_types = jni.env[0].NewObjectArray(
        jni.env, #parameter_names, class_class, nil)
    local arguments_array = jni.env[0].NewObjectArray(
        jni.env, #arguments, object_class, nil)
    if parameter_types == nil or arguments_array == nil then
        clearException(jni)
        if parameter_types ~= nil then jni.env[0].DeleteLocalRef(jni.env, parameter_types) end
        if arguments_array ~= nil then jni.env[0].DeleteLocalRef(jni.env, arguments_array) end
        jni.env[0].DeleteLocalRef(jni.env, clazz)
        jni.env[0].DeleteLocalRef(jni.env, class_class)
        jni.env[0].DeleteLocalRef(jni.env, object_class)
        return nil
    end

    local ok = true
    for i, name in ipairs(parameter_names) do
        local parameter_class = loadClass(jni, class_loader, name)
        if parameter_class == nil then
            ok = false
            break
        end
        jni.env[0].SetObjectArrayElement(jni.env, parameter_types, i - 1, parameter_class)
        jni.env[0].DeleteLocalRef(jni.env, parameter_class)
        if clearException(jni) then
            ok = false
            break
        end
    end
    if ok then
        for i, argument in ipairs(arguments) do
            jni.env[0].SetObjectArrayElement(jni.env, arguments_array, i - 1, argument)
            if clearException(jni) then
                ok = false
                break
            end
        end
    end

    local constructor
    if ok then
        trace("looking up constructor for " .. class_name)
        constructor = jni:callObjectMethod(
            clazz,
            "getConstructor",
            "([Ljava/lang/Class;)Ljava/lang/reflect/Constructor;",
            parameter_types
        )
        if constructor == nil or clearException(jni) then ok = false end
    end

    local instance
    if ok then
        trace("creating instance of " .. class_name)
        instance = jni:callObjectMethod(
            constructor,
            "newInstance",
            "([Ljava/lang/Object;)Ljava/lang/Object;",
            arguments_array
        )
        if instance == nil or clearException(jni) then ok = false end
    end

    if constructor ~= nil then jni.env[0].DeleteLocalRef(jni.env, constructor) end
    jni.env[0].DeleteLocalRef(jni.env, parameter_types)
    jni.env[0].DeleteLocalRef(jni.env, arguments_array)
    jni.env[0].DeleteLocalRef(jni.env, clazz)
    jni.env[0].DeleteLocalRef(jni.env, class_class)
    jni.env[0].DeleteLocalRef(jni.env, object_class)
    if not ok and instance ~= nil then
        jni.env[0].DeleteLocalRef(jni.env, instance)
        instance = nil
    end
    return instance
end

local function readAndCopyBridgeDex(jni, activity_object, class_loader)
    local source = MODULE_SOURCE:gsub("^@", "")
    local plugin_dir = source:match("^(.*)/core/bigme%.lua$")
    if not plugin_dir then
        return nil, "cannot determine plugin directory from " .. source
    end
    local source_path = plugin_dir .. "/core/bigme/BigmeInputBridge.dex"
    local input = io.open(source_path, "rb")
    if not input then return nil, "bridge DEX not found: " .. source_path end
    local contents = input:read("*a")
    input:close()
    if not contents or #contents == 0 then return nil, "bridge DEX is empty" end

    local cache_dir = jni:callObjectMethod(
        activity_object, "getCodeCacheDir", "()Ljava/io/File;")
    if cache_dir == nil or clearException(jni) then
        return nil, "could not access Android code cache"
    end
    local cache_path_ref = jni:callObjectMethod(
        cache_dir, "getAbsolutePath", "()Ljava/lang/String;")
    if cache_path_ref == nil or clearException(jni) then
        jni.env[0].DeleteLocalRef(jni.env, cache_dir)
        return nil, "could not resolve Android code cache path"
    end
    local cache_path = jni:to_string(cache_path_ref)
    jni.env[0].DeleteLocalRef(jni.env, cache_path_ref)

    local dex_path = cache_path .. "/" .. BRIDGE_DEX_NAME
    local cached = io.open(dex_path, "rb")
    if cached then
        local existing = cached:read("*a")
        cached:close()
        if existing ~= contents then
            os.remove(dex_path)
            cached = nil
        end
    end
    if not cached then
        local output = io.open(dex_path, "wb")
        if not output then
            jni.env[0].DeleteLocalRef(jni.env, cache_dir)
            return nil, "could not copy bridge DEX to app code cache"
        end
        output:write(contents)
        output:close()
    end

    jni.env[0].DeleteLocalRef(jni.env, cache_dir)
    return dex_path, cache_path
end

local function logAndroid(android, level, message)
    logger[level](message)
    local log_names = { info = "LOGI", warn = "LOGW" }
    local log_method = android[log_names[level]]
    if log_method then pcall(log_method, message) end
end

function Bigme.probe()
    local ok, android = pcall(require, "android")
    if not ok or not android or not android.jni or not android.app or not android.app.activity then
        return false
    end

    local activity = android.app.activity
    local probe_ok, client_found, listener_found = pcall(function()
        return android.jni:context(activity.vm, function(jni)
            local activity_class = jni:callObjectMethod(
                activity.clazz, "getClass", "()Ljava/lang/Class;")
            local class_loader = activity_class and jni:callObjectMethod(
                activity_class, "getClassLoader", "()Ljava/lang/ClassLoader;")
            if activity_class == nil or class_loader == nil or clearException(jni) then
                if class_loader ~= nil then jni.env[0].DeleteLocalRef(jni.env, class_loader) end
                if activity_class ~= nil then jni.env[0].DeleteLocalRef(jni.env, activity_class) end
                return false, false
            end

            local client_class, client_failed = loadClass(
                jni, class_loader, "com.xrz.HandwrittenClient")
            local listener_class, listener_failed = loadClass(
                jni, class_loader, "com.xrz.HandwrittenClient$InputListener")
            local found_client = client_class ~= nil and not client_failed
            local found_listener = listener_class ~= nil and not listener_failed
            if client_class ~= nil then jni.env[0].DeleteLocalRef(jni.env, client_class) end
            if listener_class ~= nil then jni.env[0].DeleteLocalRef(jni.env, listener_class) end
            jni.env[0].DeleteLocalRef(jni.env, class_loader)
            jni.env[0].DeleteLocalRef(jni.env, activity_class)
            return found_client, found_listener
        end)
    end)

    if not probe_ok then
        logAndroid(android, "warn", "Bigme API probe failed: " .. tostring(client_found))
        return false
    end
    local message = "Bigme API probe: HandwrittenClient visible = " .. tostring(client_found)
        .. ", InputListener visible = " .. tostring(listener_found)
    logAndroid(android, "info", message)
    return client_found and listener_found
end

function Bigme.start()
    if Bigme.bridge then return true, Bigme.width, Bigme.height end
    trace("start requested")
    local ok, android = pcall(require, "android")
    if not ok or not android or not android.jni or not android.app or not android.app.activity then
        return false, "KOReader Android JNI bridge unavailable"
    end
    local activity = android.app.activity
    local start_ok, started, global_bridge, result3, result4, result5 = pcall(function()
        return android.jni:context(activity.vm, function(jni)
            trace("JNI context entered")
            trace("getting Activity class")
            local activity_class = jni:callObjectMethod(
                activity.clazz, "getClass", "()Ljava/lang/Class;")
            trace("Activity class retrieved")
            trace("getting app class loader")
            local class_loader = activity_class and jni:callObjectMethod(
                activity_class, "getClassLoader", "()Ljava/lang/ClassLoader;")
            trace("app class loader retrieved")
            if activity_class == nil or class_loader == nil or clearException(jni) then
                if class_loader ~= nil then jni.env[0].DeleteLocalRef(jni.env, class_loader) end
                if activity_class ~= nil then jni.env[0].DeleteLocalRef(jni.env, activity_class) end
                return false, nil, "could not get KOReader class loader"
            end

            trace("copying bridge DEX to code cache")
            local dex_path, cache_path_or_error = readAndCopyBridgeDex(
                jni, activity.clazz, class_loader)
            trace("bridge DEX copied")
            if not dex_path then
                jni.env[0].DeleteLocalRef(jni.env, class_loader)
                jni.env[0].DeleteLocalRef(jni.env, activity_class)
                return false, nil, cache_path_or_error
            end

            local dex_path_ref = jni.env[0].NewStringUTF(jni.env, dex_path)
            local optimized_path_ref = jni.env[0].NewStringUTF(jni.env, cache_path_or_error)
            local library_path_ref = jni.env[0].NewStringUTF(jni.env, "")
            local dex_loader = newJavaObject(
                jni, class_loader, "dalvik.system.DexClassLoader",
                { "java.lang.String", "java.lang.String", "java.lang.String", "java.lang.ClassLoader" },
                {
                    dex_path_ref,
                    optimized_path_ref,
                    library_path_ref,
                    class_loader,
                }
            )
            if dex_path_ref ~= nil then jni.env[0].DeleteLocalRef(jni.env, dex_path_ref) end
            if optimized_path_ref ~= nil then
                jni.env[0].DeleteLocalRef(jni.env, optimized_path_ref)
            end
            if library_path_ref ~= nil then
                jni.env[0].DeleteLocalRef(jni.env, library_path_ref)
            end
            trace("DexClassLoader constructor returned")
            if dex_loader == nil then
                jni.env[0].DeleteLocalRef(jni.env, class_loader)
                jni.env[0].DeleteLocalRef(jni.env, activity_class)
                return false, nil, "could not create Bigme bridge class loader"
            end

            local bridge_class, bridge_class_failed = loadClass(
                jni, dex_loader, BRIDGE_CLASS)
            trace("bridge class lookup returned")
            if bridge_class == nil or bridge_class_failed then
                jni.env[0].DeleteLocalRef(jni.env, dex_loader)
                jni.env[0].DeleteLocalRef(jni.env, class_loader)
                jni.env[0].DeleteLocalRef(jni.env, activity_class)
                return false, nil, "could not load Bigme bridge class"
            end
            local bridge = jni:callObjectMethod(
                bridge_class, "newInstance", "()Ljava/lang/Object;")
            trace("bridge instance created")
            if bridge == nil or clearException(jni) then
                jni.env[0].DeleteLocalRef(jni.env, bridge_class)
                jni.env[0].DeleteLocalRef(jni.env, dex_loader)
                jni.env[0].DeleteLocalRef(jni.env, class_loader)
                jni.env[0].DeleteLocalRef(jni.env, activity_class)
                return false, nil, "could not instantiate Bigme bridge"
            end

            trace("calling Java bridge start")
            local response = jni:callObjectMethod(
                bridge,
                "start",
                "(Landroid/content/Context;)Ljava/lang/String;",
                activity.clazz
            )
            local response_text = response and jni:to_string(response) or ""
            trace("Java bridge start returned: " .. response_text)
            if response ~= nil then jni.env[0].DeleteLocalRef(jni.env, response) end
            local success = response_text:match("^OK,(%d+),(%d+)$")
            if not success or clearException(jni) then
                jni.env[0].DeleteLocalRef(jni.env, bridge)
                jni.env[0].DeleteLocalRef(jni.env, bridge_class)
                jni.env[0].DeleteLocalRef(jni.env, dex_loader)
                jni.env[0].DeleteLocalRef(jni.env, class_loader)
                jni.env[0].DeleteLocalRef(jni.env, activity_class)
                return false, nil, response_text ~= "" and response_text
                    or "Bigme bridge did not start"
            end

            local direct_ink = jni:callBooleanMethod(
                bridge, "isDirectInkAvailable", "()Z")
            local direct_ink_failed = clearException(jni)

            local global_ref = jni.env[0].NewGlobalRef(jni.env, bridge)
            jni.env[0].DeleteLocalRef(jni.env, bridge)
            jni.env[0].DeleteLocalRef(jni.env, bridge_class)
            jni.env[0].DeleteLocalRef(jni.env, dex_loader)
            jni.env[0].DeleteLocalRef(jni.env, class_loader)
            jni.env[0].DeleteLocalRef(jni.env, activity_class)
            if global_ref == nil then return false, nil, "could not retain Bigme bridge" end
            local width, height = response_text:match("^OK,(%d+),(%d+)$")
            -- Do not place nil between multiple callback return values: the JNI
            -- context wrapper truncates the values after that nil on this port.
            return true, global_ref, tonumber(width), tonumber(height),
                direct_ink and not direct_ink_failed
        end)
    end)

    local failure
    local width, height, direct_ink
    if started then
        width, height, direct_ink = result3, result4, result5
    else
        failure = result3
    end

    if not start_ok or not started or not global_bridge then
        local message = start_ok and failure or started
        logAndroid(android, "warn", "Bigme input bridge unavailable: " .. tostring(message))
        return false, tostring(message)
    end
    Bigme.bridge = global_bridge
    Bigme.width = tonumber(width)
    Bigme.height = tonumber(height)
    Bigme.direct_ink = direct_ink == true
    if not Bigme.width or not Bigme.height then
        Bigme.width, Bigme.height = nil, nil
    end
    logAndroid(android, "info", "Bigme input bridge connected")
    return true, Bigme.width, Bigme.height
end

function Bigme.hasDirectInk()
    return Bigme.direct_ink == true
end

function Bigme.setDirectInkStyle(enabled, width, argb)
    if not Bigme.bridge or not Bigme.hasDirectInk() then return false end
    local ok, android = pcall(require, "android")
    if not ok or not android or not android.jni or not android.app or not android.app.activity then
        return false
    end
    local state = enabled and "1" or "0"
    local config = string.format("%s,%.3f,%s", state,
        math.max(1, tonumber(width) or 1), argb or "FFFF9500")
    local success, configured = pcall(function()
        return android.jni:context(android.app.activity.vm, function(jni)
            local text = jni.env[0].NewStringUTF(jni.env, config)
            if text == nil or clearException(jni) then return false end
            local result = jni:callBooleanMethod(Bigme.bridge, "setDirectInkStyle",
                "(Ljava/lang/String;)Z", text)
            jni.env[0].DeleteLocalRef(jni.env, text)
            if clearException(jni) then return false end
            return result
        end)
    end)
    return success and configured or false
end

-- Hand KOReader's RGBA32 framebuffer to the bridge as a direct ByteBuffer
-- (no copy). The bridge mirrors it into the handwriting canvas, because a
-- handwriting commit shows that canvas as-is inside the commit rect.
function Bigme.setScreenBuffer(bb)
    if not Bigme.bridge or not Bigme.hasDirectInk() or not bb then return false end
    local ok, android = pcall(require, "android")
    if not ok or not android or not android.jni or not android.app or not android.app.activity then
        return false
    end
    local ffi = require("ffi")
    local geometry = string.format("%d,%d,%d,%d", tonumber(bb.stride),
        bb:getWidth(), bb:getHeight(), bb:getInverse() == 1 and 1 or 0)
    local success, enabled = pcall(function()
        return android.jni:context(android.app.activity.vm, function(jni)
            local buffer = jni.env[0].NewDirectByteBuffer(jni.env,
                ffi.cast("void*", bb.data), tonumber(bb.stride) * bb:getHeight())
            if buffer == nil or clearException(jni) then return false end
            local text = jni.env[0].NewStringUTF(jni.env, geometry)
            if text == nil or clearException(jni) then
                jni.env[0].DeleteLocalRef(jni.env, buffer)
                return false
            end
            local result = jni:callBooleanMethod(Bigme.bridge, "setScreenBuffer",
                "(Ljava/nio/ByteBuffer;Ljava/lang/String;)Z", buffer, text)
            jni.env[0].DeleteLocalRef(jni.env, text)
            jni.env[0].DeleteLocalRef(jni.env, buffer)
            if clearException(jni) then return false end
            return result
        end)
    end)
    if success and enabled then
        -- The bridge reads this memory later; keep the buffer alive.
        Bigme.screen_bb = bb
        return true
    end
    Bigme.screen_bb = nil
    return false
end

-- KOReader posted (x, y, w, h) of its framebuffer to the panel.
function Bigme.screenUpdated(x, y, w, h, inverse)
    if not Bigme.bridge or not Bigme.screen_bb then return end
    local ok, android = pcall(require, "android")
    if not ok or not android or not android.jni or not android.app or not android.app.activity then
        return
    end
    local spec = string.format("%d,%d,%d,%d,%d", x, y, w, h, inverse and 1 or 0)
    pcall(function()
        android.jni:context(android.app.activity.vm, function(jni)
            local text = jni.env[0].NewStringUTF(jni.env, spec)
            if text == nil or clearException(jni) then return end
            jni:callVoidMethod(Bigme.bridge, "screenUpdated", "(Ljava/lang/String;)V", text)
            jni.env[0].DeleteLocalRef(jni.env, text)
            clearException(jni)
        end)
    end)
end

-- spec: "left,top,right,bottom;..." in Bigme view coordinates, "" = anywhere.
function Bigme.setWritableRects(spec)
    if not Bigme.bridge or not Bigme.hasDirectInk() then return false end
    local ok, android = pcall(require, "android")
    if not ok or not android or not android.jni or not android.app or not android.app.activity then
        return false
    end
    local success, configured = pcall(function()
        return android.jni:context(android.app.activity.vm, function(jni)
            local text = jni.env[0].NewStringUTF(jni.env, spec or "")
            if text == nil or clearException(jni) then return false end
            local result = jni:callBooleanMethod(Bigme.bridge, "setWritableRects",
                "(Ljava/lang/String;)Z", text)
            jni.env[0].DeleteLocalRef(jni.env, text)
            if clearException(jni) then return false end
            return result
        end)
    end)
    return success and configured or false
end

-- Re-enable Bigme's normal surface commits right before KOReader posts the
-- repaint that contains finished strokes (Base.apk's onUpdateViewContent).
-- Returns false only while the bridge is still drawing a stroke; the caller
-- should retry after it (normal commits stay suspended meanwhile). Without a
-- bridge there is nothing to wait for, so that counts as committed.
function Bigme.commitNormal()
    if not Bigme.bridge or not Bigme.hasDirectInk() then return true end
    local ok, android = pcall(require, "android")
    if not ok or not android or not android.jni or not android.app or not android.app.activity then
        return true
    end
    local success, committed = pcall(function()
        return android.jni:context(android.app.activity.vm, function(jni)
            local result = jni:callBooleanMethod(Bigme.bridge, "commitNormal", "()Z")
            if clearException(jni) then return true end
            return result
        end)
    end)
    if not success then return true end
    return committed ~= false
end

function Bigme.drain()
    if not Bigme.bridge then return nil, false end
    local ok, android = pcall(require, "android")
    if not ok or not android or not android.jni or not android.app or not android.app.activity then
        return nil, false
    end
    local success, batch, direct_ink_available = pcall(function()
        return android.jni:context(android.app.activity.vm, function(jni)
            local response = jni:callObjectMethod(
                Bigme.bridge, "drain", "()Ljava/lang/String;")
            local result = response and jni:to_string(response) or ""
            if response ~= nil then jni.env[0].DeleteLocalRef(jni.env, response) end
            if clearException(jni) then return result, false end
            local available = jni:callBooleanMethod(
                Bigme.bridge, "isDirectInkAvailable", "()Z")
            if clearException(jni) then return result, false end
            return result, available
        end)
    end)
    if not success then return nil, false end
    return batch, direct_ink_available
end

function Bigme.close()
    if not Bigme.bridge then return end
    local ok, android = pcall(require, "android")
    if ok and android and android.jni and android.app and android.app.activity then
        pcall(function()
            android.jni:context(android.app.activity.vm, function(jni)
                jni:callVoidMethod(Bigme.bridge, "close", "()V")
                clearException(jni)
                jni.env[0].DeleteGlobalRef(jni.env, Bigme.bridge)
            end)
        end)
    end
    Bigme.bridge = nil
    Bigme.screen_bb = nil
    Bigme.direct_ink = false
    Bigme.width, Bigme.height = nil, nil
end

return Bigme
