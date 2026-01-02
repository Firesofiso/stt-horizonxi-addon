require 'common'

_addon.name = 'stt-horizonxi'
_addon.author = 'OpenAI'
_addon.version = '0.1.0'
_addon.desc = 'Speech-to-Text integration for HorizonXI.'

local default_config = {
    enabled = true,
    channel = {
        mode = 'say',
    },
}

local config = default_config
local default_channel_command = '/say'
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

local channel_modes = {
    s = { command = '/say' },
    say = { command = '/say' },
    p = { command = '/p' },
    party = { command = '/p' },
    l = { command = '/l' },
    ls = { command = '/l' },
    linkshell = { command = '/l' },
    y = { command = '/yell' },
    yell = { command = '/yell' },
    sh = { command = '/sh' },
    shout = { command = '/sh' },
    t = { command = '/t', requires_target = true },
    tell = { command = '/t', requires_target = true },
}

local function is_valid_channel(mode)
    return channel_modes[mode] ~= nil
end

local function build_chat_command_prefix(channel_config)
    local selected = (channel_config and channel_config.mode) and channel_config or config.channel or default_config.channel
    local normalized_mode = (selected.mode or ''):lower()
    local mode_info = channel_modes[normalized_mode] or channel_modes[default_config.channel.mode]

    if mode_info.requires_target then
        local target = trim(selected.target)
        if target == '' then
            local fallback_info = channel_modes[default_config.channel.mode]
            return fallback_info and fallback_info.command or default_channel_command
        end

        return string.format('%s %s', mode_info.command, target)
    end

    return mode_info.command
end

local function set_channel(mode, target)
    local normalized_mode = trim(mode and mode:lower() or '')
    if normalized_mode == '' then
        config.channel = {
            mode = default_config.channel.mode,
        }
        save_settings()
        print_status('Channel set to say (default).')
        return
    end

    if not is_valid_channel(normalized_mode) then
        print_status('Invalid channel. Valid options: s, p, t <name>, l, y, sh.')
        return
    end

    local mode_info = channel_modes[normalized_mode]
    if mode_info.requires_target then
        local cleaned_target = trim(target)
        if cleaned_target == '' then
            print_status('Tell channel requires a target name. Usage: /stt channel t <name>')
            return
        end

        config.channel = {
            mode = normalized_mode,
            target = cleaned_target,
        }
    else
        config.channel = {
            mode = normalized_mode,
        }
    end

    save_settings()
    if mode_info.requires_target then
        print_status(string.format('Channel set to tell %s.', config.channel.target))
    else
        print_status(string.format('Channel set to %s.', mode_info.command))
    end
end

local function simulate_enter_press()
    local input_manager = AshitaCore:GetInputManager()
    if input_manager == nil then
        return false
    end

    local keyboard = input_manager.GetKeyboard and input_manager:GetKeyboard() or nil
    if keyboard == nil or keyboard.QueueCommand == nil then
        return false
    end

    local ok = pcall(function()
        keyboard:QueueCommand(1, 0x1C, true, false, false)
        keyboard:QueueCommand(1, 0x1C, false, false, false)
    end)

    return ok
end

local function queue_chat_send(command_prefix, message)
    local manager = AshitaCore:GetCommandManager()
    local command = string.format('%s %s', command_prefix, message)

    if manager == nil then
        local chat_manager = AshitaCore:GetChatManager()
        if chat_manager == nil then
            print_status('Command manager is unavailable.')
            return false
        end

        chat_manager:QueueCommand(-1, command)
        simulate_enter_press()
        return true
    end

    manager:QueueCommand(1, command)
    simulate_enter_press()
    return true
end

local function parse_transcription_input(raw_text, override_prefix)
    local cleaned = trim(raw_text or '')
    if cleaned == '' then
        return nil, 'Empty transcription received.'
    end

    local words = {}
    for word in cleaned:gmatch('%S+') do
        table.insert(words, word)
    end

    if #words == 0 then
        return nil, 'No usable words in transcription.'
    end

    if words[#words]:lower() == 'send' then
        table.remove(words, #words)
    end

    if #words == 0 then
        return nil, 'No chat message found after removing Send keyword.'
    end

    local potential_channel = words[1]:lower()
    local channel_info = channel_modes[potential_channel]
    local channel_config
    local message_start_index = 1

    if channel_info ~= nil then
        message_start_index = 2
        if channel_info.requires_target then
            local target = words[2]
            if target == nil or trim(target) == '' then
                return nil, 'Tell channel requires a target name.'
            end

            channel_config = {
                mode = potential_channel,
                target = target,
            }
            message_start_index = 3
        else
            channel_config = { mode = potential_channel }
        end
    end

    local message_text = trim(table.concat(words, ' ', message_start_index))
    if message_text == '' then
        return nil, 'No chat text to send.'
    end

    local command_prefix = override_prefix or build_chat_command_prefix(channel_config)
    return {
        command_prefix = command_prefix,
        message = message_text,
        channel_mode = (channel_config and channel_config.mode) or (config.channel and config.channel.mode) or default_config.channel.mode,
    }
end

local function handle_transcribed_text(message, chat_command)
    if not config.enabled then
        return false
    end

    local parsed, reason = parse_transcription_input(message, chat_command)
    if parsed == nil then
        if reason ~= nil then
            print_status(reason)
        end
        return false
    end

    local sent = queue_chat_send(parsed.command_prefix, parsed.message)
    if sent then
        print_status(string.format('Sent to %s: %s', parsed.channel_mode, parsed.message))
    else
        print_status('Failed to send transcribed chat message.')
    end

    return sent
end

local function consume_provider_event(event)
    local text = nil

    if type(event) == 'table' then
        text = event.text or event.message or event.transcript or event.payload

        if text == nil and type(event.data) == 'table' then
            text = event.data.text or event.data.message or event.data.transcript
        end
    elseif type(event) == 'string' then
        text = event
    end

    if type(text) ~= 'string' then
        print_status('Received malformed transcription event; ignoring.')
        return
    end

    if not handle_transcribed_text(text) then
        print_status('Transcription could not be delivered to chat.')
    end
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
    elseif sub == 'channel' or sub == 'c' then
        local mode_arg = args[3]
        local target = table.concat(args, ' ', 4)
        set_channel(mode_arg, target)
    else
        print_status('Commands: /stt toggle | /stt channel <mode> [target]')
    end
end)

do
    local ok, err = pcall(function()
        ashita.events.register('stt_provider', 'stt_provider_hook', function(e)
            consume_provider_event(e)
        end)
    end)

    if not ok then
        print_status(string.format('Unable to register speech-to-text provider hook: %s', err))
    end
end

-- Expose a simple interface for other modules to respect the enabled state.
stt = {
    send_transcript = handle_transcribed_text,
    is_enabled = function()
        return config.enabled
    end,
    set_channel = set_channel,
    get_chat_command_prefix = function()
        return build_chat_command_prefix(config.channel)
    end,
}
