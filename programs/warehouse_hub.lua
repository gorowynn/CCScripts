--===========================================================================
-- warehouse_hub.lua
-- Central computer. Hosts on rednet, receives warehouse snapshots from one or
-- more warehouse_node computers, and renders a live stock view on a monitor.
--
-- Hardware: Computer + Wireless/Ender Modem + (optional) Advanced Monitor.
-- Run:  warehouse_hub
-- Controls: 'r' redraws; 'q' quits. Auto-refreshes on every incoming report.
--===========================================================================

local CONFIG = {
    PROT       = "colony_warehouse", -- must match warehouse_node.lua
    HOST_NAME  = "colony_hub",       -- rednet host id (informational)
    STALE_SEC  = 30,                 -- mark a node stale if no report within this window
    SCALE      = 0.5,                -- monitor text scale (0.5 = dense)
    SIDE       = nil,                -- nil = auto-detect monitor; or "left"/"top"/...
}

local term, colors, keys, peripheral, rednet, os, sleep, parallel, textutils, printError,
      pairs, ipairs, tostring, string, math, table =
      term, colors, keys, peripheral, rednet, os, sleep, parallel, textutils, printError,
      pairs, ipairs, tostring, string, math, table

---------------------------------------------------------------- state
-- nodes[name] = { time=os.time(), day=os.day(), total=N, types=N, items={...} }
local nodes = {}

---------------------------------------------------------------- locate hardware
local function findMonitor()
    if CONFIG.SIDE then return peripheral.wrap(CONFIG.SIDE) end
    return peripheral.find("monitor")
end

local function findModemSide()
    for _, side in ipairs(rs.getSides()) do
        if peripheral.isPresent(side) and peripheral.getType(side) == "modem" then
            return side
        end
    end
    return nil
end

---------------------------------------------------------------- rendering
local out -- term or monitor (redirected target)

local function line(y, text, bg, fg)
    if bg then out.setBackgroundColor(bg) end
    if fg then out.setTextColor(fg) end
    out.setCursorPos(1, y)
    out.clearLine()
    out.write(text)
end

local W, H
local function size() W, H = out.getSize() end

local function header(now)
    line(1, " COLONY WAREHOUSE  ", colors.gray, colors.white)
    local totalItems, totalTypes, nodeCount = 0, 0, 0
    for _, n in pairs(nodes) do
        totalItems, totalTypes = totalItems + n.total, totalTypes + n.types
        nodeCount = nodeCount + 1
    end
    line(2, (" %d node(s)  |  %d item types  |  %d items total  |  %s")
            :format(nodeCount, totalTypes, totalItems, textutils.formatTime(now, true)),
         colors.black, colors.lightGray)
    line(3, (" " .. string.rep("-", W - 2)), colors.black, colors.gray)
end

local function render()
    local now = os.time()
    size()
    out.setBackgroundColor(colors.black)
    out.clear()
    header(now)

    local y = 4
    for name, n in pairs(nodes) do
        if y > H then break end
        -- os.time() is in minecraft-hours; convert age to seconds
        local ageSec = (os.day() == n.day) and math.max(0, now - n.time) * 50 or 9999
        local stale  = ageSec > CONFIG.STALE_SEC
        line(y, (" [%s]  %d types / %d items%s")
                :format(name, n.types, n.total, stale and "  (stale)" or ""),
             colors.black, stale and colors.red or colors.green)
        y = y + 1

        for _, it in ipairs(n.items) do
            if y > H then break end
            local txt = ("   %s"):format(it.name)
            local cnt = tostring(it.count)
            local pad = W - #txt - #cnt - 1
            if pad < 1 then
                txt = txt:sub(1, math.max(1, W - #cnt - 2)) .. "."
                pad = math.max(1, W - #txt - #cnt - 1)
            end
            line(y, txt .. (" "):rep(pad) .. cnt, colors.black, colors.white)
            y = y + 1
        end
        y = y + 1
    end

    if y <= H then
        line(H, " r=redraw  q=quit ", colors.gray, colors.white)
    end
end

---------------------------------------------------------------- main
local modemSide = findModemSide()
if not modemSide then error("No modem found. Attach a wireless or ender modem.") end

local monitor = findMonitor()
rednet.open(modemSide)
rednet.host(CONFIG.PROT, CONFIG.HOST_NAME)

if monitor then
    monitor.setTextScale(CONFIG.SCALE)
end
out = monitor or term

print(("warehouse_hub: hosting '%s' on protocol '%s'. %s")
      :format(CONFIG.HOST_NAME, CONFIG.PROT,
              monitor and "Rendering on monitor." or "No monitor; terminal only."))
print("Listening for warehouse_node reports...")

render()

local function listenNet()
    while true do
        local _, msg = rednet.receive(CONFIG.PROT)
        if type(msg) == "table" and msg.node and msg.items then
            nodes[msg.node] = msg
            render()
        end
    end
end

local function listenKeys()
    while true do
        local _, key = os.pullEvent("key")
        if key == keys.r then render()
        elseif key == keys.q then break end
    end
end

local function tick()
    while true do sleep(5); render() end  -- refresh staleness colours
end

local ok, err = pcall(function()
    parallel.waitForAny(listenNet, listenKeys, tick)
end)

rednet.unhost(CONFIG.PROT, CONFIG.HOST_NAME)
if not ok then printError(tostring(err)) end
