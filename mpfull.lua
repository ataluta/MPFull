--[[
* mpfull - Plays a sound (and can stand you up) when your MP fills to full.
* Ashita v4
*
* Commands:
*   /mpfull                Show or hide the settings window
*   /mpfull test           Play the alert sound
*   /mpfull toggle         Turn the sound alert on or off
*   /mpfull stand          Turn auto-stand on or off
*   /mpfull sound <name>   Pick a sound from the sounds folder (e.g. /mpfull sound chime)
*   /mpfull custom [path]  Use your own .wav from anywhere on your PC
*
* Any .wav file dropped into the addon's sounds folder also shows up in the window.
--]]

addon.name    = 'mpfull'
addon.author  = 'CHARLIE'
addon.version = '1.2'
addon.desc    = 'Plays a sound (and can stand you up) when your MP fills to full.'
addon.link    = ''

require('common')
local bit      = require('bit')
local chat     = require('chat')
local imgui    = require('imgui')
local settings = require('settings')

local STATUS_RESTING = 33     -- entity status while /heal'ing
local CHECK_INTERVAL = 0.25   -- seconds between MP checks
local ZONE_SETTLE    = 5      -- seconds to ignore MP readings around a zone change
local MAX_PATH       = 260
local MANA_BLUE      = { 0.33, 0.58, 1.00, 1.00 }
local ERROR_RED      = { 1.00, 0.45, 0.45, 1.00 }

local default_settings = T{
    alert_enabled = true,
    auto_stand    = false,
    sound         = 'chime.wav',   -- pick from the sounds folder
    use_custom    = false,         -- true = play custom_path instead
    custom_path   = '',            -- full path to any .wav on disk
    show_window   = true,
}

local mpfull = {
    settings      = settings.load(default_settings),
    sounds        = {},          -- .wav files found in the sounds folder
    is_open       = { true },    -- imgui window state
    custom_buf    = { '' },      -- text box contents for the custom path
    custom_err    = nil,         -- why the custom file can't be played (nil = fine)
    custom_warned = false,       -- fallback warning already printed for this path
    armed         = false,       -- true once MP has been seen below max
    last_max      = 0,
    last_check    = 0,
    hold_until    = 0,
}

--[[
* Helpers
--]]

local function msg(text)
    print(chat.header(addon.name):append(chat.message(text)))
end

local function save(key, value)
    mpfull.settings[key] = value
    settings.save()
end

local function sound_dir()
    return ('%s\\sounds\\'):fmt(addon.path)
end

-- 'double_beep.wav' -> 'Double beep'
local function pretty(file)
    local name = file:gsub('%.[Ww][Aa][Vv]$', ''):gsub('[_%-]+', ' ')
    return (name:gsub('^%l', string.upper))
end

-- Trims spaces and the quotes File Explorer's "Copy as path" adds.
local function clean_path(path)
    path = (path or ''):gsub('^%s+', ''):gsub('%s+$', '')
    return (path:gsub('^"(.*)"$', '%1'))
end

-- Returns true, or false plus a short reason the file can't be played.
local function check_wav(path)
    if path == '' then
        return false, 'No file chosen'
    end
    if not path:lower():match('%.wav$') then
        return false, 'That file is not a .wav'
    end
    local f = io.open(path, 'rb')
    if f == nil then
        return false, 'File not found'
    end
    local head = f:read(12) or ''
    f:close()
    if head:sub(1, 4) ~= 'RIFF' or head:sub(9, 12) ~= 'WAVE' then
        return false, 'Not a valid .wav file'
    end
    return true
end

local function set_custom_path(path)
    mpfull.settings.custom_path = clean_path(path)
    local _, err = check_wav(mpfull.settings.custom_path)
    mpfull.custom_err = err
    mpfull.custom_warned = false
end

local function scan_sounds()
    local dir = sound_dir()
    if not ashita.fs.exists(dir) then
        ashita.fs.create_dir(dir)
    end

    local list = {}
    for _, f in ipairs(ashita.fs.get_dir(dir, '.*', true) or {}) do
        if f:lower():match('%.wav$') and not f:find('[\\/]') then
            list[#list + 1] = f
        end
    end
    table.sort(list, function (a, b) return a:lower() < b:lower() end)
    mpfull.sounds = list
end

-- Keep the list pick pointing at a file that actually exists.
local function validate_sound()
    local current = (mpfull.settings.sound or ''):lower()
    for _, f in ipairs(mpfull.sounds) do
        if f:lower() == current then
            mpfull.settings.sound = f
            return
        end
    end
    if #mpfull.sounds > 0 then
        save('sound', mpfull.sounds[1])
    end
end

local function sync_from_settings()
    validate_sound()
    set_custom_path(mpfull.settings.custom_path)
    mpfull.custom_buf[1] = mpfull.settings.custom_path
    mpfull.is_open[1] = mpfull.settings.show_window
end

local function select_list(file)
    mpfull.settings.use_custom = false
    save('sound', file)
end

local function select_custom()
    save('use_custom', true)
end

--[[
* Sound playback
--]]

local function play_list(file)
    local path = sound_dir() .. (file or '')
    if file == nil or file == '' or not ashita.fs.exists(path) then
        print(chat.header(addon.name):append(chat.error('Sound file not found: ')):append(chat.warning(path)))
        return false
    end
    ashita.misc.play_sound(path)
    return true
end

-- Re-checks the custom file (it may have been added or moved) and plays it if usable.
local function play_custom()
    local ok, err = check_wav(mpfull.settings.custom_path)
    mpfull.custom_err = err
    if ok then
        ashita.misc.play_sound(mpfull.settings.custom_path)
    end
    return ok
end

-- Plays the chosen alert sound. A custom file that can't be played falls back to the list pick.
local function play_alert()
    local s = mpfull.settings
    if s.use_custom then
        if play_custom() then
            return
        end
        if not mpfull.custom_warned then
            mpfull.custom_warned = true
            msg(('Custom .wav not usable (%s). Playing %s instead.'):fmt(mpfull.custom_err:lower(), pretty(s.sound)))
        end
    end
    play_list(s.sound)
end

--[[
* MP tracking
--]]

local function is_resting()
    local mm = AshitaCore:GetMemoryManager()
    local index = mm:GetParty():GetMemberTargetIndex(0)
    return index ~= 0 and mm:GetEntity():GetStatus(index) == STATUS_RESTING
end

local function on_mp_full()
    if mpfull.settings.alert_enabled then
        play_alert()
    end
    if mpfull.settings.auto_stand and is_resting() then
        AshitaCore:GetChatManager():QueueCommand(1, '/heal off')
    end
end

local function check_mp()
    local now = os.clock()
    if now - mpfull.last_check < CHECK_INTERVAL then
        return
    end
    mpfull.last_check = now

    local mm     = AshitaCore:GetMemoryManager()
    local player = mm:GetPlayer()
    local max_mp = player:GetMPMax()
    local mp     = mm:GetParty():GetMemberMP(0)

    -- Zoning, no MP pool, or max MP just changed (job or gear swap): reset and wait.
    if now < mpfull.hold_until or player:GetIsZoning() ~= 0 or max_mp == 0 or max_mp ~= mpfull.last_max then
        mpfull.last_max = max_mp
        mpfull.armed = false
        return
    end

    if mp < max_mp then
        mpfull.armed = true
    elseif mpfull.armed then
        mpfull.armed = false
        on_mp_full()
    end
end

--[[
* Settings window
--]]

local function set_window(open)
    mpfull.is_open[1] = open
    if mpfull.settings.show_window ~= open then
        save('show_window', open)
    end
end

local function render()
    if not mpfull.is_open[1] then
        return
    end

    local s = mpfull.settings
    local flags = bit.bor(ImGuiWindowFlags_AlwaysAutoResize, ImGuiWindowFlags_NoCollapse)

    if imgui.Begin('MP Full', mpfull.is_open, flags) then
        -- Live MP gauge
        local mm      = AshitaCore:GetMemoryManager()
        local max_mp  = mm:GetPlayer():GetMPMax()
        local mp      = mm:GetParty():GetMemberMP(0)
        local fill    = 0
        local overlay = 'No MP to track'
        if max_mp > 0 then
            fill    = math.min(mp / max_mp, 1)
            overlay = ('%d / %d MP%s'):fmt(mp, max_mp, is_resting() and ' (resting)' or '')
        end
        imgui.PushStyleColor(ImGuiCol_PlotHistogram, MANA_BLUE)
        imgui.ProgressBar(fill, { -1, 0 }, overlay)
        imgui.PopStyleColor(1)
        imgui.Spacing()

        -- Options
        local alert = { s.alert_enabled }
        if imgui.Checkbox('Play a sound when MP is full', alert) then
            save('alert_enabled', alert[1])
        end

        local stand = { s.auto_stand }
        if imgui.Checkbox('Stand up when MP is full', stand) then
            save('auto_stand', stand[1])
        end
        imgui.ShowHelp('While you are resting, sends /heal off as soon as your MP is full.')

        -- Sound picker (one checked at a time)
        imgui.Spacing()
        imgui.Separator()
        imgui.Text('Sound')

        if #mpfull.sounds == 0 then
            imgui.TextDisabled('No .wav files in the sounds folder.\nAdd some, then click Rescan.')
        end

        for i, file in ipairs(mpfull.sounds) do
            if imgui.SmallButton(('Play##mpfull_play_%d'):fmt(i)) then
                play_list(file)
            end
            imgui.SameLine()
            local checked = { not s.use_custom and file == s.sound }
            if imgui.Checkbox(('%s##mpfull_sound_%d'):fmt(pretty(file), i), checked) and checked[1] then
                select_list(file)
                play_list(file)
            end
        end

        -- Custom .wav from anywhere on disk
        local row_x = imgui.GetCursorPosX()
        if imgui.SmallButton('Play##mpfull_play_custom') then
            play_custom()
        end
        imgui.SameLine()
        local indent = imgui.GetCursorPosX() - row_x
        local custom = { s.use_custom }
        if imgui.Checkbox('Custom .wav##mpfull_custom', custom) and custom[1] then
            select_custom()
            play_custom()
        end
        imgui.ShowHelp('Any .wav on your PC. In File Explorer, Shift+right-click the file, choose "Copy as path", then paste it into the box below.')

        imgui.Indent(indent)
        imgui.SetNextItemWidth(imgui.GetFontSize() * 18)
        if imgui.InputTextWithHint('##mpfull_custom_path', 'C:\\path\\to\\sound.wav', mpfull.custom_buf, MAX_PATH) then
            set_custom_path(mpfull.custom_buf[1])
        end
        if imgui.IsItemDeactivatedAfterEdit() then
            mpfull.custom_buf[1] = s.custom_path   -- show the cleaned-up path
            settings.save()
        end

        if s.custom_path == '' then
            if s.use_custom then
                imgui.TextDisabled('Paste the full path to a .wav file.')
            end
        elseif mpfull.custom_err ~= nil then
            imgui.TextColored(ERROR_RED, mpfull.custom_err .. '.')
        end
        if s.use_custom and mpfull.custom_err ~= nil and #mpfull.sounds > 0 then
            imgui.TextDisabled(('Until then, alerts play %s.'):fmt(pretty(s.sound)))
        end
        imgui.Unindent(indent)

        -- Folder tools
        imgui.Spacing()
        if imgui.Button('Rescan') then
            scan_sounds()
            validate_sound()
            set_custom_path(s.custom_path)
        end
        imgui.SameLine()
        if imgui.Button('Open folder') then
            ashita.misc.open_url(sound_dir())
        end
        if imgui.IsItemHovered() then
            imgui.SetTooltip(sound_dir())
        end
    end
    imgui.End()

    -- Window closed with its X button.
    if not mpfull.is_open[1] then
        set_window(false)
    end
end

--[[
* Commands
--]]

local function use_custom(raw)
    if raw ~= nil and raw ~= '' then
        set_custom_path(raw)
    else
        set_custom_path(mpfull.settings.custom_path)   -- refresh the file check
    end
    mpfull.custom_buf[1] = mpfull.settings.custom_path
    select_custom()

    if mpfull.settings.custom_path == '' then
        msg('Custom .wav selected. Set its path in the window or with /mpfull custom <path>.')
    elseif mpfull.custom_err ~= nil then
        msg(('Custom .wav selected, but it is not usable (%s).'):fmt(mpfull.custom_err:lower()))
    else
        msg(('Custom .wav set to %s'):fmt(mpfull.settings.custom_path))
    end
end

--[[
* Events
--]]

settings.register('settings', 'mpfull_settings_update', function (s)
    if s ~= nil then
        mpfull.settings = s
    end
    sync_from_settings()
    settings.save()
end)

ashita.events.register('load', 'mpfull_load', function ()
    scan_sounds()
    sync_from_settings()
end)

ashita.events.register('unload', 'mpfull_unload', function ()
    settings.save()
end)

ashita.events.register('command', 'mpfull_command', function (e)
    local args = e.command:args()
    if #args == 0 or args[1]:lower() ~= '/mpfull' then
        return
    end
    e.blocked = true

    local sub = (args[2] or ''):lower()

    if sub == '' then
        set_window(not mpfull.is_open[1])
    elseif sub == 'test' then
        play_alert()
    elseif sub == 'toggle' then
        save('alert_enabled', not mpfull.settings.alert_enabled)
        msg(('Sound alert %s.'):fmt(mpfull.settings.alert_enabled and 'on' or 'off'))
    elseif sub == 'stand' then
        save('auto_stand', not mpfull.settings.auto_stand)
        msg(('Auto-stand %s.'):fmt(mpfull.settings.auto_stand and 'on' or 'off'))
    elseif sub == 'custom' then
        -- Use the raw text so Windows paths (backslashes, spaces, quotes) come through untouched.
        use_custom(e.command:match('^%s*%S+%s+%S+%s+(.-)%s*$'))
    elseif sub == 'sound' and #args >= 3 then
        scan_sounds()
        local want = args:concat(' ', 3):lower():gsub('%.wav$', '')
        if want == 'custom' then
            use_custom(nil)
            return
        end
        for _, f in ipairs(mpfull.sounds) do
            local base = f:lower():gsub('%.wav$', '')
            if base == want or pretty(f):lower() == want then
                select_list(f)
                msg(('Sound set to %s.'):fmt(pretty(f)))
                return
            end
        end
        msg(('No sound named "%s" in the sounds folder.'):fmt(args:concat(' ', 3)))
    else
        msg('Commands: /mpfull (window), test, toggle, stand, sound <name>, custom [path]')
    end
end)

ashita.events.register('packet_in', 'mpfull_packet_in', function (e)
    -- 0x000A = zone in, 0x000B = zone out
    if e.id == 0x000A or e.id == 0x000B then
        mpfull.armed = false
        mpfull.hold_until = os.clock() + ZONE_SETTLE
    end
end)

ashita.events.register('d3d_present', 'mpfull_present', function ()
    check_mp()
    render()
end)
