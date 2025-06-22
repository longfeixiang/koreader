local BlockedPoints = {
    name = "BlockedPoints"
}

local blocked_points_table = {}

-- {"handler":"onGesture","args":[{"ges":"touch","pos":{"h":0,"x":26,"w":0,"y":836},"time":2496472712432}]}

-- Requires G_reader_settings and json.lua
-- G_reader_settings is a global, no need to require it.
local JSON = require("dkjson")
local logger = require("logger") -- 用于日志记录
local inspect = require("inspect")

-- Helper function for safe logging
local function safe_log(level, ...)
    if logger and type(logger[level]) == "function" then
        logger[level](...)
    else
        local parts = { os.date("%Y-%m-%d %H:%M:%S"), "Fallback Log:", level }
        local args = { ... }
        for i = 1, #args do
            table.insert(parts, tostring(args[i]))
        end
        print(table.concat(parts, " "))
    end
end

function BlockedPoints.loadBlockedPoints()
    if not G_reader_settings then
        print("Warning: G_reader_settings not available to BlockedPoints module.")
        blocked_points_table = {}
        return
    end
    local blocked_points_json = G_reader_settings:readSetting("blocked_points_list")
    if blocked_points_json then
        local success, decoded_table = pcall(JSON.decode, blocked_points_json)
        if success and type(decoded_table) == "table" then
            blocked_points_table = decoded_table
        else
            blocked_points_table = {}
        end
    else
        blocked_points_table = {}
    end
end

function BlockedPoints.saveBlockedPoints()
    if not G_reader_settings then
        print("Warning: G_reader_settings not available to BlockedPoints module. Cannot save.")
        return
    end
    local success, encoded_json = pcall(JSON.encode, blocked_points_table)
    if success then
        G_reader_settings:saveSetting("blocked_points_list", encoded_json)
    else
        -- Handle encoding error, perhaps log it
        print("Error encoding blocked points to JSON")
    end
end

function BlockedPoints.isBlocked(pos)
    safe_log("info", BlockedPoints.name .. inspect(pos))
    for _, point in ipairs(blocked_points_table) do
        local distance = math.sqrt((pos.x - point.x) ^ 2 + (pos.y - point.y) ^ 2)
        if distance <= point.radius then
            return true
        end
    end
    return false
end

function BlockedPoints.clearAllPoints()
    blocked_points_table = {}
    BlockedPoints.saveBlockedPoints()
end

function BlockedPoints.replaceBlockedPoints(points_list)
    blocked_points_table = points_list
    BlockedPoints.saveBlockedPoints()
end

-- Initialize by loading blocked points
BlockedPoints.loadBlockedPoints()

return BlockedPoints
