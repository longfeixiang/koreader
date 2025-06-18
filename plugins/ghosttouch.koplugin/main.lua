-- Ghost Touch Recorder Plugin for KOReader
-- Focuses on recording ghost touch points and managing related settings.
-- Actual blocking logic will be implemented by modifying UIManager.lua.

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local DataStorage = require("datastorage") -- 用于设置
local LuaSettings = require("luasettings") -- 用于设置
local GlobalUIManager = require("ui/uimanager") -- 用于显示部件和消息
local InfoMessage = require("ui/widget/infomessage") -- 用于用户反馈
local InputDialog = require("ui/widget/inputdialog") -- 用于用户输入配置
local FFIUtil = require("ffi/util") -- 用于模板函数
local _ = require("gettext") -- 用于本地化
local T = FFIUtil.template -- 模板函数的快捷方式
local logger = require("logger") -- 用于日志记录
local InputContainer = require("ui/widget/container/inputcontainer") -- 用于触摸区域
local Device = require("device")
local Screen = Device.screen

-- Helper function for safe logging
local function safe_log(level, ...)
    if logger and type(logger[level]) == "function" then
        logger[level](...)
    else
        local parts = {os.date("%Y-%m-%d %H:%M:%S"), "Fallback Log:", level}
        local args = {...}
        for i = 1, #args do
            table.insert(parts, tostring(args[i]))
        end
        print(table.concat(parts, " "))
    end
end

-- Define the GhostTouchRecorder plugin class
local GhostTouchRecorder = WidgetContainer:extend{
    name = "ghost_touch_recorder", -- Renamed to reflect its new focus
    settings = nil,
    settings_file_name = "ghost_touch_recorder_settings.lua", -- Changed settings file name
    input_capture_widget = nil, -- 用于存储 InputContainer 实例
    record_timer = nil,

    defaults = {
        is_recording = false, -- Is the plugin currently in recording mode?
        recorded_points = {}, -- Table to store {x, y} coordinates
        record_duration_seconds = 60, -- 记录时长，单位：秒 (1分钟)
        block_radius_pixels = 60, -- 屏蔽半径，单位：像素 (Managed by this plugin, used by UIManager mod)
        plugin_enabled = true, -- General switch for the plugin's data collection/management
    }
}

-- Helper function to get the correct UIManager instance
function GhostTouchRecorder:_getUIManager()
    if self.ui and self.ui.uimanager then
        return self.ui.uimanager
    end
    return GlobalUIManager
end

-- init() 在 KOReader 加载插件时调用
function GhostTouchRecorder:init()
    self:_initSettings()

    if self.ui and self.ui.menu and self.ui.menu.registerToMainMenu then
        self.ui.menu:registerToMainMenu(self)
    else
        safe_log("warn", self.name .. ": 无法注册到主菜单，self.ui.menu 不可用。")
    end

    -- Ensure recording is off on startup
    if self.settings:readSetting("is_recording") then
        safe_log("info", self.name .. ": 上次会话中记录模式是激活的，现在设为非激活。")
        self.settings:saveSetting("is_recording", false)
        self.settings:flush()
    end
end

-- 初始化或加载插件设置
function GhostTouchRecorder:_initSettings()
    local settings_path = DataStorage:getSettingsDir() .. "/" .. self.settings_file_name
    self.settings = LuaSettings:open(settings_path)

    local defaults_applied = false
    for key, value in pairs(self.defaults) do
        if self.settings:readSetting(key) == nil then
            self.settings:saveSetting(key, value)
            defaults_applied = true
            safe_log("info", self.name .. ": 已应用默认设置 ", key)
        end
    end

    if defaults_applied then
        self.settings:flush()
    end
end

-- addToMainMenu() 由 KOReader 的菜单系统调用
function GhostTouchRecorder:addToMainMenu(menu_items)
    menu_items.ghost_touch_recorder = {
        text = _("鬼触记录器"), -- Updated menu text
        sub_item_table_func = function()
            return self:_getSubMenuItems()
        end,
    }
end

-- _getSubMenuItems() 定义子菜单项
function GhostTouchRecorder:_getSubMenuItems()
    local UIManager = self:_getUIManager()
    local is_recording_active = self.settings:readSetting("is_recording") or self.defaults.is_recording
    local current_block_radius = self.settings:readSetting("block_radius_pixels") or self.defaults.block_radius_pixels
    local current_record_duration_min = math.floor((self.settings:readSetting("record_duration_seconds") or self.defaults.record_duration_seconds) / 60)
    local plugin_enabled = self.settings:readSetting("plugin_enabled")
    if plugin_enabled == nil then plugin_enabled = self.defaults.plugin_enabled end

    local sub_menu = {
        {
            text = plugin_enabled and _("禁用鬼触数据管理") or _("启用鬼触数据管理"),
            callback = function()
                self:_togglePluginEnabledState()
                if UIManager and self.ui and self.ui.menu then UIManager:setDirty(self.ui.menu, "full") end
            end,
            keep_menu_open = true,
        },
        {
            text = is_recording_active and _("取消记录鬼触") or T(_("激活记录鬼触 (%1分钟)"), current_record_duration_min),
            callback = function()
                if not plugin_enabled then
                    if UIManager then UIManager:show(InfoMessage:new{text=_("插件当前已禁用。请先启用。"), timeout=3}) end
                    return
                end
                self:_toggleRecordingState()
                if UIManager and self.ui and self.ui.menu then UIManager:setDirty(self.ui.menu, "full") end
            end,
            keep_menu_open = true,
            separator_before = true,
        },
        {
            text = _("清除所有已记录的点"),
            callback = function()
                if not plugin_enabled then
                    if UIManager then UIManager:show(InfoMessage:new{text=_("插件当前已禁用。"), timeout=3}) end
                    return
                end
                self:_clearRecordedPoints()
                if UIManager and self.ui and self.ui.menu then UIManager:setDirty(self.ui.menu, "full") end
            end,
            keep_menu_open = true,
        },
        {
            text = T(_("设置屏蔽半径 (%1 px)"), current_block_radius),
            callback = function()
                if not plugin_enabled then
                    if UIManager then UIManager:show(InfoMessage:new{text=_("插件当前已禁用。"), timeout=3}) end
                    return
                end
                self:_promptForBlockRadius()
            end,
            keep_menu_open = true,
        },
        {
            text = T(_("设置记录时长 (%1 分钟)"), current_record_duration_min),
            callback = function()
                if not plugin_enabled then
                    if UIManager then UIManager:show(InfoMessage:new{text=_("插件当前已禁用。"), timeout=3}) end
                    return
                end
                self:_promptForRecordDuration()
            end,
            keep_menu_open = true,
        },
    }
    return sub_menu
end

function GhostTouchRecorder:_togglePluginEnabledState()
    local UIManager = self:_getUIManager()
    local current_enabled_state = self.settings:readSetting("plugin_enabled")
    if current_enabled_state == nil then current_enabled_state = self.defaults.plugin_enabled end
    local new_enabled_state = not current_enabled_state
    self.settings:saveSetting("plugin_enabled", new_enabled_state)
    self.settings:flush()

    local message = new_enabled_state and _("鬼触数据管理已启用。") or _("鬼触数据管理已禁用。")
    if UIManager then UIManager:show(InfoMessage:new{ text = message, timeout = 2 }) end
    safe_log("info", self.name .. ": Plugin enabled state set to: " .. tostring(new_enabled_state))

    -- If disabling and recording was active, stop recording
    if not new_enabled_state and self.settings:readSetting("is_recording") then
        self:_stopRecordingAndHideOverlay(true) -- Pass true to indicate it's a forced stop
    end
end

-- 切换记录状态
function GhostTouchRecorder:_toggleRecordingState()
    local is_currently_recording = self.settings:readSetting("is_recording")
    if is_currently_recording then
        self:_stopRecordingAndHideOverlay()
    else
        self:_startRecordingAndShowOverlay()
    end
end

-- 开始记录并显示 InputContainer 覆盖层
function GhostTouchRecorder:_startRecordingAndShowOverlay()
    local UIManager = self:_getUIManager()
    if not UIManager then
        safe_log("error", self.name .. ": UIManager is nil in _startRecordingAndShowOverlay!")
        return
    end
    safe_log("info", self.name .. ": _startRecordingAndShowOverlay called.")

    if self.record_timer then
        UIManager:unschedule(self.record_timer)
        self.record_timer = nil
        safe_log("info", self.name .. ": Previous record timer unscheduled.")
    end

    self.settings:saveSetting("is_recording", true)
    self.settings:saveSetting("recorded_points", {})
    self.settings:flush()
    safe_log("info", self.name .. ": Settings updated - is_recording: true, points cleared.")

    if self.input_capture_widget then
        safe_log("debug", self.name .. ": Existing input_capture_widget found, hiding it first.")
        self:_stopRecordingAndHideOverlay(true) -- Pass true for forced stop if any
    end

    safe_log("debug", self.name .. ": Creating new InputContainer for capture.")
    self.input_capture_widget = InputContainer:new{
        dimen = Screen:getSize(),
    }

    if not self.input_capture_widget then
        safe_log("error", self.name .. ": Failed to create input_capture_widget (InputContainer:new returned nil)!")
        self.settings:saveSetting("is_recording", false)
        self.settings:flush()
        return
    end
    safe_log("info", self.name .. ": input_capture_widget (InputContainer) created successfully.")

    self.input_capture_widget:registerTouchZones({
        {
            id = "ghost_touch_record_tap",
            ges = "tap",
            screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
            handler = function(ges)
                safe_log("debug", self.name .. ": InputContainer tap handler triggered!")
                local UIManager_handler = self:_getUIManager()
                if not UIManager_handler then
                    safe_log("error", self.name .. ": UIManager is nil in tap handler!")
                    return true
                end
                local pos = ges.pos
                if not pos then
                    safe_log("warn", self.name .. ": Tap handler - ges has no position.")
                    return true
                end
                local points = self.settings:readSetting("recorded_points") or {}
                table.insert(points, {x = pos.x, y = pos.y})
                self.settings:saveSetting("recorded_points", points)
                self.settings:flush()
                safe_log("info", T(self.name .. ": 记录点于 (%1, %2)"), pos.x, pos.y)
                UIManager_handler:show(InfoMessage:new{
                    text = T(_("记录点: (%1, %2)"), math.floor(pos.x), math.floor(pos.y)),
                    timeout = 1,
                })
                return true
            end
        },
    })
    safe_log("info", self.name .. ": Touch zones registered on InputContainer.")

    UIManager:show(self.input_capture_widget)
    safe_log("info", self.name .. ": InputContainer shown via UIManager.")

    if type(UIManager.grabInput) == "function" then
        UIManager:grabInput(self.input_capture_widget)
        safe_log("info", self.name .. ": InputContainer grabInput called.")
    else
        safe_log("warn", self.name .. ": UIManager.grabInput is not a function.")
    end

    local duration_seconds = self.settings:readSetting("record_duration_seconds") or self.defaults.record_duration_seconds
    local duration_minutes = math.floor(duration_seconds / 60)
    UIManager:show(InfoMessage:new{
        text = T(_("记录模式已激活。请点击屏幕。%1分钟后自动结束。"), duration_minutes),
        timeout = 5,
    })

    self.record_timer = UIManager:scheduleIn(duration_seconds, function()
        safe_log("info", self.name .. ": Record timer expired. Stopping recording mode.")
        if self.settings:readSetting("is_recording") then
            self:_stopRecordingAndHideOverlay()
        end
        self.record_timer = nil
    end)
    safe_log("info", self.name .. ": Record timer scheduled for " .. duration_seconds .. " seconds.")
end

-- 停止记录并隐藏 InputContainer 覆盖层
function GhostTouchRecorder:_stopRecordingAndHideOverlay(forced_stop)
    safe_log("debug", self.name .. ": _stopRecordingAndHideOverlay called. Forced: " .. tostring(forced_stop))
    local UIManager = self:_getUIManager()

    if self.input_capture_widget then
        safe_log("debug", self.name .. ": Closing input_capture_widget (InputContainer).")
        if UIManager then
            if type(UIManager.ungrabInput) == "function" then
                UIManager:ungrabInput(self.input_capture_widget)
                safe_log("info", self.name .. ": InputContainer ungrabInput called.")
            else
                safe_log("warn", self.name .. ": UIManager.ungrabInput is not a function.")
            end
            UIManager:close(self.input_capture_widget)
        else
            safe_log("error", self.name .. ": UIManager is nil, cannot properly close input_capture_widget.")
        end
        self.input_capture_widget = nil
        safe_log("info", self.name .. ": InputContainer overlay hidden and instance cleared.")
    else
        safe_log("debug", self.name .. ": _stopRecordingAndHideOverlay called but no input_capture_widget to hide.")
    end

    local was_recording = self.settings:readSetting("is_recording")
    if self.settings then
        self.settings:saveSetting("is_recording", false)
        self.settings:flush()
        safe_log("info", self.name .. ": Settings updated - is_recording: false.")
    end

    if self.record_timer then
        if UIManager then UIManager:unschedule(self.record_timer) end
        self.record_timer = nil
        safe_log("info", self.name .. ": Record timer explicitly unscheduled.")
    end

    if was_recording and not forced_stop then -- Only show summary if it wasn't a forced stop due to disabling plugin
        local points = self.settings:readSetting("recorded_points") or {}
        local num_points = #points
        local points_str = ""
        if num_points > 0 then
            for i = 1, math.min(num_points, 3) do
                points_str = points_str .. string.format("(%d,%d) ", math.floor(points[i].x), math.floor(points[i].y))
            end
            if num_points > 3 then
                points_str = points_str .. "..."
            end
        end
        local message_text
        if num_points > 0 then
            message_text = T(_("记录结束。共记录 %1 个点: %2"), num_points, points_str)
        else
            message_text = _("记录结束。未记录任何点。")
        end
        if UIManager then
            UIManager:show(InfoMessage:new{ text = message_text, timeout = 5,})
        else
            safe_log("error", self.name .. ": UIManager is nil, cannot show recorded points message.")
        end
    end
end

-- 清除所有已记录的点
function GhostTouchRecorder:_clearRecordedPoints()
    local UIManager = self:_getUIManager()
    self.settings:saveSetting("recorded_points", {})
    self.settings:flush()
    if UIManager then
        UIManager:show(InfoMessage:new{
            text = _("所有已记录的鬼触点已清除。"),
            timeout = 2,
        })
    end
    safe_log("info", self.name .. ": All recorded points cleared.")
end

-- 提示用户输入屏蔽半径
function GhostTouchRecorder:_promptForBlockRadius()
    local UIManager = self:_getUIManager()
    if not UIManager then
        safe_log("error", self.name .. ": UIManager is nil in _promptForBlockRadius!")
        return
    end

    local current_radius = self.settings:readSetting("block_radius_pixels") or self.defaults.block_radius_pixels
    local input_dialog

    input_dialog = InputDialog:new{
        title = _("设置屏蔽半径 (像素)"),
        input_text = tostring(current_radius),
        input_type = "number",
        buttons = {
            {
                {
                    text = _("取消"),
                    id = "cancel_radius",
                    callback = function()
                        UIManager:close(input_dialog)
                    end,
                },
                {
                    text = _("确定"),
                    id = "ok_radius",
                    is_default = true,
                    callback = function()
                        local input_value = input_dialog:getInputValue()
                        UIManager:close(input_dialog)
                        local new_radius = tonumber(input_value)
                        if new_radius and new_radius > 0 and new_radius <= 200 then
                            self.settings:saveSetting("block_radius_pixels", new_radius)
                            self.settings:flush()
                            UIManager:show(InfoMessage:new{ text = T(_("屏蔽半径已设置为 %1 像素。"), new_radius), timeout = 2 })
                            if self.ui and self.ui.menu then UIManager:setDirty(self.ui.menu, "full") end
                            safe_log("info", self.name .. ": Block radius set to " .. new_radius)
                        else
                            UIManager:show(InfoMessage:new{ text = _("无效的半径值 (1-200)。"), timeout = 2 })
                        end
                    end,
                },
            }
        },
    }
    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end

-- 新增：提示用户输入记录时长
function GhostTouchRecorder:_promptForRecordDuration()
    local UIManager = self:_getUIManager()
    if not UIManager then
        safe_log("error", self.name .. ": UIManager is nil in _promptForRecordDuration!")
        return
    end

    local current_duration_seconds = self.settings:readSetting("record_duration_seconds") or self.defaults.record_duration_seconds
    local current_duration_min = math.floor(current_duration_seconds / 60)
    local input_dialog

    input_dialog = InputDialog:new{
        title = _("设置记录时长 (分钟)"),
        input_text = tostring(current_duration_min),
        input_type = "number",
        buttons = {
            {
                {
                    text = _("取消"),
                    id = "cancel_duration",
                    callback = function()
                        UIManager:close(input_dialog)
                    end,
                },
                {
                    text = _("确定"),
                    id = "ok_duration",
                    is_default = true,
                    callback = function()
                        local input_value = input_dialog:getInputValue()
                        UIManager:close(input_dialog)
                        local new_duration_min = tonumber(input_value)
                        if new_duration_min and new_duration_min >= 1 and new_duration_min <= 60 then
                            local new_duration_seconds = new_duration_min * 60
                            self.settings:saveSetting("record_duration_seconds", new_duration_seconds)
                            self.settings:flush()
                            UIManager:show(InfoMessage:new{ text = T(_("记录时长已设置为 %1 分钟。"), new_duration_min), timeout = 2 })
                            if self.ui and self.ui.menu then UIManager:setDirty(self.ui.menu, "full") end
                            safe_log("info", self.name .. ": Record duration set to " .. new_duration_seconds .. " seconds.")
                        else
                            UIManager:show(InfoMessage:new{ text = _("无效的时长 (1-60 分钟)。"), timeout = 2 })
                        end
                    end,
                },
            }
        },
    }
    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end

-- Interface function to check if recording is active
function GhostTouchRecorder:isRecordingActive()
    return self.settings:readSetting("is_recording") or self.defaults.is_recording
end

-- 插件模块必须返回插件类
return GhostTouchRecorder
