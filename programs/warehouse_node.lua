--===========================================================================
-- warehouse_node.lua
-- Reads an adjacent MineColonies Warehouse (or any chest/inventory) and
-- broadcasts its contents over rednet so a central hub can display them.
--
-- Hardware: Computer + Wireless/Ender Modem, placed adjacent to the warehouse.
-- Run:  warehouse_node
--===========================================================================

local CONFIG = {
    PROT     = "colony_warehouse", -- rednet protocol
    PERIOD   = 5,                  -- seconds between snapshots
    INV_SIDE = nil,                -- nil = auto-detect adjacent inventory; or "left"/"top"/...
    NODE_NAME= "warehouse",        -- identifies this node in reports (set per-hut if you add more)
}

local peripheral, rednet, os, textutils, rs, sleep, print, error, pairs, ipairs, table =
      peripheral, rednet, os, textutils, rs, sleep, print, error, pairs, ipairs, table

---------------------------------------------------------------- locate hardware
-- a side that has a peripheral implementing .list() = an inventory we can read
local function findInventorySide()
    if CONFIG.INV_SIDE then return CONFIG.INV_SIDE end
    for _, side in ipairs(rs.getSides()) do
        if peripheral.isPresent(side) then
            local ok, p = pcall(peripheral.wrap, side)
            if ok and p and p.list then return side end
        end
    end
    return nil
end

local function findModemSide()
    for _, side in ipairs(rs.getSides()) do
        if peripheral.isPresent(side) and peripheral.getType(side) == "modem" then
            return side
        end
    end
    return nil
end

---------------------------------------------------------------- snapshot
-- returns a flat, sorted list of {id, name, count} (merged across slots)
local function snapshot(inv)
    local merged = {}
    local ok, list = pcall(inv.list)
    if not ok or type(list) ~= "table" then return {} end
    for slot, info in pairs(list) do
        local id = info.name or "?"
        local detail = nil
        local dok = pcall(function() detail = inv.getItemDetail(slot) end)
        local name = (dok and detail and (detail.displayName or detail.name)) or id
        local entry = merged[id]
        if not entry then
            entry = { id = id, name = name, count = 0 }
            merged[id] = entry
        end
        entry.count = entry.count + (info.count or 0)
    end
    local out = {}
    for _, e in pairs(merged) do table.insert(out, e) end
    table.sort(out, function(a, b) return a.count > b.count end)
    return out
end

---------------------------------------------------------------- main
local invSide  = findInventorySide()
local modemSide= findModemSide()
if not invSide   then error("No adjacent inventory found. Place this computer next to the warehouse.") end
if not modemSide then error("No modem found. Attach a wireless or ender modem.") end

rednet.open(modemSide)
local inv = peripheral.wrap(invSide)
print(("warehouse_node: reading inventory on side '%s', broadcasting on '%s' every %ds")
      :format(invSide, CONFIG.PROT, CONFIG.PERIOD))

while true do
    local items = snapshot(inv)
    local total = 0
    for _, it in ipairs(items) do total = total + it.count end
    local msg = {
        node   = CONFIG.NODE_NAME,
        side   = invSide,
        time   = os.time(),
        day    = os.day(),
        total  = total,
        types  = #items,
        items  = items,
    }
    -- broadcast: hub listens on the same protocol and picks it up
    rednet.broadcast(msg, CONFIG.PROT)
    print(("[" .. textutils.formatTime(os.time(), true) .. "] sent %d types, %d items")
          :format(#items, total))
    sleep(CONFIG.PERIOD)
end
