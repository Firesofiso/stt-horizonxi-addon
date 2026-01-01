require 'common'

_addon.name = 'stt-horizonxi'
_addon.author = 'OpenAI'
_addon.version = '0.1.0'
_addon.desc = 'Speech-to-Text integration for HorizonXI.'

local default_config = {
    enabled = true,
}

local config = default_config
local config_path = string.format('%ssettings.json', _addon.path)

local function load_settings()
    config = ashita.settings.load_merged(config_path, default_config)
end

local function save_settings()
    ashita.settings.save(config_path, config)
end

local function print_status(message)
    AshitaCore:GetChatManager():QueueCommand(-1, string.format('/echo [STT] %s', message))
end

local function set_enabled(state)
    config.enabled = state
    save_settings()
    print_status(string.format('Speech-to-Text %s.', state and 'enabled' or 'disabled'))
end

local function toggle_enabled()
    set_enabled(not config.enabled)
end

local function trim(text)
    if text == nil then
        return ''
    end

    return text:gsub('^%s+', ''):gsub('%s+$', '')
end

local function handle_transcribed_text(message, chat_command)
    if not config.enabled then
        return false
    end

    local trimmed = trim(message)
    if trimmed == '' then
        return false
    end

    local command = chat_command or '/say'
    AshitaCore:GetChatManager():QueueCommand(-1, string.format('%s %s', command, trimmed))
    return true
end

ashita.events.register('load', 'stt_load', function()
    load_settings()
    print_status(string.format('Loaded; Speech-to-Text is currently %s.', config.enabled and 'enabled' or 'disabled'))
end)

ashita.events.register('unload', 'stt_unload', function()
    save_settings()
end)

ashita.events.register('command', 'stt_command', function(e)
    local args = e.command:args()
    if #args == 0 or args[1] ~= '/stt' then
        return
    end

    e.blocked = true

    local sub = args[2] and args[2]:lower() or ''
    if sub == 'toggle' or sub == 't' then
        toggle_enabled()
    else
        print_status('Commands: /stt toggle')
    end
end)

-- Expose a simple interface for other modules to respect the enabled state.
stt = {
    send_transcript = handle_transcribed_text,
    is_enabled = function()
        return config.enabled
    end,
}
