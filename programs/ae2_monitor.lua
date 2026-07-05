--===========================================================================
-- ae2_monitor.lua  ·  SCADA Applied Energistics 2 monitor
--
-- Live, touch-driven dashboard for an AE2 / Extended AE2 ME network. Reads
-- the network through an Advanced Peripherals `me_bridge` and renders five
-- views on an Advanced Monitor. Visual chrome matches colony_monitor /
-- warehouse_hub: accent title bar (row 1), evenly-split tab bar (row 2),
-- faint footer (row H) with < / > nav, per-view accent colours.
--
--   DASHBOARD  -- energy bar, power in/out + net, item/fluid storage + types,
--                  craftable count, and a TOP-5 MOVERS preview.
--   MOVERS     -- headline view: items & fluids ranked by total flow rate
--                  (|in/s| + |out/s|) over the rate window, with in/out/net cols.
--   ITEMS      -- three leaderboards: TOP IN, TOP OUT, TOP STORED.
--   FLUIDS     -- same three leaderboards for fluids.
--   CRAFTING   -- every craftable, flagged `crafting` when active.
--
-- In/out = per-item stored-count delta between polls, accumulated over the
-- rate window (CONFIG.windowSec, default 5s) and divided by elapsed seconds ->
-- items/s. Stored count only reveals NET change per poll, so a poll whose count
-- rose attributes its delta to "in", a falling poll to "out". Resets on restart.
-- Ponytail: ring buffer, in-memory only; add disk log if you need history.
--
-- Hardware: Computer + Advanced Monitor (touch) + me_bridge adjacent or wired.
--
-- Requirements:
--   * Minecraft 1.21.1, CC:Tweaked 1.21.1
--   * Advanced Peripherals (me_bridge)  -- works with AE2 + Extended AE2
--
-- Controls:
--   * tap a TAB to switch view  (keys: left/right also cycle tabs)
--   * tap footer  < / >  (or left/right half of footer) to page lists
--   * keys:  r=redraw  R=reset counters  q=quit  up/down=page
--===========================================================================

local CONFIG = {
    textScale   = 0.5,     -- CC minimum; densest possible
    monitorSide = nil,     -- nil = auto-detect; or "left"/"top"/"network_3"
    bridgeSide  = nil,     -- nil = auto-detect (peripheral.find "me_bridge")
    refreshHz   = 10,      -- screen redraws per second (default 10 = every 0.1s)
    pollHz      = 2,       -- me_bridge polls per second (delta granularity)
    windowSec   = 5,       -- rate window: in/out/s averaged over this many seconds
    topN        = 10,      -- leaderboard size
}

--===========================================================================
--  GLOBALS  (local-captured for speed + lint)
--===========================================================================
local term, colors, keys, peripheral, os, string, math, table, pairs,
      ipairs, tostring, tonumber, printError =
      term, colors, keys, peripheral, os, string, math, table, pairs,
      ipairs, tostring, tonumber, printError

--===========================================================================
--  THEME  ·  matches warehouse_hub / colony_monitor palette
--===========================================================================
local THEME = {
    bg     = colors.black, panel = colors.black,
    text   = colors.white, dim   = colors.lightGray, faint = colors.gray,
    good   = colors.lime,  warn  = colors.yellow,    bad   = colors.red,
    info   = colors.cyan,  accent = colors.cyan,
    incol  = colors.lime,  outcol = colors.red,
    -- per-view accent (title bar + active tab)
    viewAccent = { colors.cyan, colors.lime, colors.yellow, colors.purple, colors.orange },
}
local BLIT = {}
do
    local map = { white=0, orange=1, magenta=2, lightBlue=3, yellow=4, lime=5,
        pink=6, gray=7, lightGray=8, cyan=9, purple=10, blue=11, brown=12,
        green=13, red=14, black=15 }
    for name, idx in pairs(map) do BLIT[colors[name]] = string.format("%x", idx) end
end
local function B(c) return BLIT[c] or BLIT[colors.white] end

--===========================================================================
--  DRAWING PRIMITIVES  (identical to warehouse_hub / colony_monitor)
--===========================================================================
local W, H
local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

local function writeAt(x, y, text, fg, bg)
    if not text or text == "" or y < 1 or y > H or x > W then return end
    if x < 1 then text = text:sub(2 - x); x = 1; if text == "" then return end end
    if x + #text - 1 > W then text = text:sub(1, W - x + 1) end
    term.setCursorPos(x, y)
    if bg then
        term.blit(text, string.rep(B(fg or colors.white), #text), string.rep(B(bg), #text))
    else
        term.setTextColor(fg or colors.white)
        term.write(text)
    end
end
local function fillRow(x, y, w, col)
    if w <= 0 or y < 1 or y > H then return end
    if x < 1 then w = w + (x - 1); x = 1 end
    if x > W then return end
    if x + w - 1 > W then w = W - x + 1 end
    if w <= 0 then return end
    term.setCursorPos(x, y)
    term.blit(string.rep(" ", w), string.rep(B(col), w), string.rep(B(col), w))
end
local function fillBox(x, y, w, h, col)
    for r = 0, h - 1 do fillRow(x, y + r, w, col) end
end
local function writeRight(xRight, y, text, fg, bg)
    writeAt(xRight - #text + 1, y, text, fg, bg)
end
local function clearScreen()
    term.setBackgroundColor(THEME.bg); term.clear()
end
local function gauge(x, y, w, ratio, fillCol, bgCol)
    ratio = clamp(ratio or 0, 0, 1)
    local fw = math.floor(ratio * w + 0.5)
    if fw > 0 then
        term.setCursorPos(x, y)
        term.blit(string.rep(" ", fw), string.rep(B(fillCol), fw), string.rep(B(fillCol), fw))
    end
    if fw < w then
        term.setCursorPos(x + fw, y)
        term.blit(string.rep(" ", w - fw), string.rep(B(bgCol), w - fw), string.rep(B(bgCol), w - fw))
    end
end
local function ratioColour(r)
    if r >= 0.66 then return THEME.good end
    if r >= 0.33 then return THEME.warn end
    return THEME.bad
end
local function clock()
    local t = os.time()
    return string.format("%02d:%02d", math.floor(t) % 24,
                         math.floor((t - math.floor(t)) * 60))
end

--===========================================================================
--  HELPERS
--===========================================================================
local function humanize(s)
    s = tostring(s or "?")
    if s:find(":") then s = s:gsub("^[%w_]+:", "") end
    if s:find("_") then s = s:gsub("_", " ") end
    return s:sub(1, 1):upper() .. s:sub(2)
end
local function cleanName(s)
    s = tostring(s or "")
    s = s:gsub("\194\167.", ""):gsub("&[%da-fk-or]", "")
    return s
end
local suffix = { "", "k", "M", "G", "T", "P" }
local function fmtNum(n)
    n = tonumber(n) or 0
    local neg = n < 0; n = math.abs(n)
    local i = 1
    while n >= 1000 and i < #suffix do n = n / 1000; i = i + 1 end
    local s
    if i == 1 then s = tostring(math.floor(n))
    else s = string.format("%.2f", n):gsub("%.?0+$", "") end
    return (neg and "-" or "") .. s .. suffix[i]
end
local function fmtSigned(n)
    n = tonumber(n) or 0
    return (n >= 0 and "+" or "") .. fmtNum(n)
end
local function fmtEnergy(n) return fmtNum(n) .. " AE" end

-- truncate text to width with an ellipsis char (\187 = >>)
local function trunc(s, w)
    if #s <= w then return s end
    if w < 2 then return s:sub(1, w) end
    return s:sub(1, w - 1) .. "\187"
end

--===========================================================================
--  ME BRIDGE
--===========================================================================
local bridge
local function detectBridge()
    if CONFIG.bridgeSide then
        bridge = peripheral.wrap(CONFIG.bridgeSide)
        return bridge ~= nil
    end
    bridge = peripheral.find("me_bridge") or peripheral.find("advancedperipherals:me_bridge")
    return bridge ~= nil
end

local function safeCall(method, ...)
    if not bridge or type(bridge[method]) ~= "function" then return nil end
    local ok, res = pcall(bridge[method], bridge, ...)
    if ok then return res end
    return nil
end

local function avgOf(res)
    if res == nil then return nil end
    if type(res) == "number" then return res end
    if type(res) == "table" then
        return res.avg or res.average or res.value or res[1]
    end
    return nil
end

local function keyOf(it) return it.name .. (it.nbt and ("/" .. it.nbt) or "") end

local function snapshot()
    local items  = safeCall("listItems")   or safeCall("getItems")   or {}
    local fluids = safeCall("listFluids")  or safeCall("getFluids")  or {}
    local craft  = safeCall("listCraftables") or safeCall("getCraftables") or {}
    local energy    = safeCall("getEnergy")    or 0
    local maxEnergy = safeCall("getMaxEnergy") or safeCall("getMaxStorage") or 0
    local pinj = avgOf(safeCall("getAvgPowerInjection"))
    local puse = avgOf(safeCall("getAvgPowerUsage"))
    local usedItem  = safeCall("getUsedItemStorage")
    local totalItem = safeCall("getTotalItemStorage")
    local usedFluid  = safeCall("getUsedFluidStorage")
    local totalFluid = safeCall("getTotalFluidStorage")

    local itemMap, itemCount, itemTypes = {}, 0, 0
    for _, it in ipairs(items) do
        local c = tonumber(it.count or it.amount or 0) or 0
        itemMap[keyOf(it)] = {
            name = it.name, nbt = it.nbt,
            display = cleanName(it.displayName) or humanize(it.name),
            count = c,
        }
        itemCount = itemCount + c; itemTypes = itemTypes + 1
    end
    local fluidMap, fluidAmount, fluidTypes = {}, 0, 0
    for _, fl in ipairs(fluids) do
        local a = tonumber(fl.amount or fl.count or fl.buckets or 0) or 0
        fluidMap[keyOf(fl)] = {
            name = fl.name, nbt = fl.nbt,
            display = cleanName(fl.displayName) or humanize(fl.name),
            amount = a,
        }
        fluidAmount = fluidAmount + a; fluidTypes = fluidTypes + 1
    end
    local craftNames = {}
    for _, c in ipairs(craft) do
        craftNames[keyOf(c)] = {
            name = c.name, nbt = c.nbt,
            display = cleanName(c.displayName) or humanize(c.name),
        }
    end
    return {
        items = itemMap, itemCount = itemCount, itemTypes = itemTypes,
        fluids = fluidMap, fluidAmount = fluidAmount, fluidTypes = fluidTypes,
        craftables = craftNames,
        energy = energy, maxEnergy = maxEnergy,
        pinj = pinj, puse = puse,
        usedItem = usedItem, totalItem = totalItem,
        usedFluid = usedFluid, totalFluid = totalFluid,
    }
end

--===========================================================================
--  RATE STATE  ·  rolling window of per-poll in/out deltas -> per-second rates
--
-- Stored count only reveals NET change, so "in" and "out" are per-poll
-- directional buckets: a poll whose count went UP attributes the delta to `din`,
-- a poll whose count went DOWN attributes |delta| to `dout`. We keep a ring of
-- recent polls (windowSec) and divide summed deltas by the elapsed window to
-- get items/s. Resets on restart or `R`. Ponytail: ring of N entries, fine.
--===========================================================================
-- history[kind] = list (oldest..newest) of { t=ms, d={ [key]={din,dout} } }
local history = { items = {}, fluids = {} }
-- display + current value lookup (latest snapshot)
local meta = { items = {}, fluids = {} }   -- meta[kind][key] = { display, cur }
local prev = { items = nil, fluids = nil }
local sinceStart = os.epoch("utc")  -- ponytail: retained for future uptime display

local function resetCounters()
    history = { items = {}, fluids = {} }
    meta    = { items = {}, fluids = {} }
    prev    = { items = nil, fluids = nil }
    sinceStart = os.epoch("utc")
end

-- push one poll's worth of per-item din/dout into the ring, then trim old
local function pushPoll(kind, map, valueField, nowMs)
    local prevMap = prev[kind]
    local entry = { t = nowMs, d = {} }
    if prevMap then
        for k, info in pairs(map) do
            local cur = info[valueField]
            local p = prevMap[k]
            local delta = p and (cur - p.value) or 0
            if delta ~= 0 then
                entry.d[k] = (delta > 0) and { delta, 0 } or { 0, -delta }
            end
            meta[kind][k] = { display = info.display, cur = cur }
        end
        -- items that vanished: full amount counts as out
        for k, info in pairs(prevMap) do
            if not map[k] then
                entry.d[k] = { 0, info.value }
                meta[kind][k] = { display = info.display, cur = 0 }
            end
        end
    else
        for k, info in pairs(map) do
            meta[kind][k] = { display = info.display, cur = info[valueField] }
        end
    end
    history[kind][#history[kind] + 1] = entry
    -- trim entries older than the window (keep at least the newest + one ref)
    local cutoff = nowMs - CONFIG.windowSec * 1000
    while #history[kind] > 2 and history[kind][1].t < cutoff do
        table.remove(history[kind], 1)
    end
    prev[kind] = {}
    for k, info in pairs(map) do prev[kind][k] = { value = info[valueField] } end
end

local function applySnapshot(s, nowMs)
    pushPoll("items",  s.items,  "count",  nowMs)
    pushPoll("fluids", s.fluids, "amount", nowMs)
end

-- summed din/dout over the window, divided by elapsed seconds -> per-second
local function ratesFor(kind, key)
    local h = history[kind]
    if #h < 2 then return 0, 0 end
    local dt = (h[#h].t - h[1].t) / 1000
    if dt <= 0 then return 0, 0 end
    local din, dout = 0, 0
    for i = 1, #h do
        local e = h[i].d[key]
        if e then din = din + e[1]; dout = dout + e[2] end
    end
    return din / dt, dout / dt
end

-- sorted top-N by per-second rate.
--   sortField: "in" | "out" | "flow" | "net" | "cur"
-- returns list of { key, display, inRate, outRate, netRate, flow, cur }
local function topBy(kind, sortField, n)
    local list = {}
    for k, m in pairs(meta[kind]) do
        local ir, or_ = ratesFor(kind, k)
        local net = ir - or_
        local flow = ir + or_
        list[#list + 1] = {
            key = k, display = m.display,
            inRate = ir, outRate = or_, netRate = net, flow = flow, cur = m.cur or 0,
        }
    end
    -- discard zero entries for flow-derived sorts so stale items fall off
    if sortField == "flow" or sortField == "in" or sortField == "out" or sortField == "net" then
        local filtered = {}
        for _, e in ipairs(list) do
            local v = (sortField == "flow" and e.flow) or
                      (sortField == "in" and e.inRate) or
                      (sortField == "out" and e.outRate) or
                      (sortField == "net" and math.abs(e.netRate)) or 0
            if v > 0 then filtered[#filtered + 1] = e end
        end
        list = filtered
    end
    table.sort(list, function(x, y)
        local xv = (sortField == "flow" and x.flow) or (sortField == "in" and x.inRate)
                or (sortField == "out" and x.outRate) or (sortField == "net" and math.abs(x.netRate))
                or (sortField == "cur" and x.cur) or 0
        local yv = (sortField == "flow" and y.flow) or (sortField == "in" and y.inRate)
                or (sortField == "out" and y.outRate) or (sortField == "net" and math.abs(y.netRate))
                or (sortField == "cur" and y.cur) or 0
        return xv > yv
    end)
    while #list > n do table.remove(list) end
    return list
end

--===========================================================================
--  APP / UI STATE
--===========================================================================
local curSnap = nil
local lastPollAt = 0
local lastError = nil

local VIEWS = {
    { key = "dashboard", name = "DASHBOARD" },
    { key = "movers",    name = "MOVERS" },
    { key = "items",     name = "ITEMS" },
    { key = "fluids",    name = "FLUIDS" },
    { key = "craft",     name = "CRAFTING" },
}
local VI = { DASH=1, MOVERS=2, ITEMS=3, FLUIDS=4, CRAFT=5 }

local app = { view = VI.DASH, page = {} }   -- page[viewIdx] = current page
local ui  = { tabs = {}, pages = {} }       -- pages[viewIdx] = max page (set during render)

local function poll()
    local ok, s = pcall(snapshot)
    if not ok then lastError = tostring(s); return end
    lastError = nil
    applySnapshot(s, os.epoch("utc"))
    curSnap = s
    lastPollAt = os.epoch("utc")
end

--===========================================================================
--  SHARED CHROME  ·  title bar, tab bar, footer  (matches colony_monitor)
--===========================================================================
local function drawTitleBar()
    local accent = THEME.viewAccent[app.view] or THEME.accent
    fillRow(1, 1, W, accent)
    writeAt(2, 1, "AE2  NETWORK", colors.white, accent)
    local right = clock()
    if curSnap and not lastError then right = right .. "  ONLINE"
    elseif lastError then right = right .. "  ERR"
    else right = right .. "  WAIT" end
    writeRight(W - 1, 1, right, colors.white, accent)
end

local function drawTabBar()
    local y = 2
    local n = #VIEWS
    local tabW = math.floor(W / n)
    ui.tabs = {}
    local x = 1
    for i, v in ipairs(VIEWS) do
        local w = (i == n) and (W - x + 1) or tabW
        local active = (i == app.view)
        local bg = active and THEME.viewAccent[i] or THEME.faint
        local fg = active and colors.white or THEME.dim
        fillRow(x, y, w, bg)
        local label = " " .. i .. " " .. v.name .. " "
        writeAt(x + math.floor((w - #label) / 2), y, label, fg, bg)
        ui.tabs[i] = { x1 = x, x2 = x + w - 1, y = y }
        x = x + w
    end
end

local function drawFooter(ctrl)
    local y = H
    fillRow(1, y, W, THEME.faint)
    writeAt(2, y, "<", ctrl.hasPrev and THEME.accent or THEME.faint, THEME.faint)
    writeAt(W - 1, y, ">", ctrl.hasNext and THEME.accent or THEME.faint, THEME.faint)
    if ctrl.center then ctrl.center(y) end
end

--===========================================================================
--  VIEW HELPERS
--===========================================================================
-- body region: rows 3 .. H-1
local function bodyRect()
    return 3, H - 1
end

local function ensurePage(viewIdx, maxPage)
    ui.pages[viewIdx] = maxPage
    if not app.page[viewIdx] then app.page[viewIdx] = 1 end
    app.page[viewIdx] = clamp(app.page[viewIdx], 1, maxPage)
    return app.page[viewIdx]
end

-- a labelled stat cell: writes label + value at (x,y), returns next-y
local function statRow(x, y, w, label, value, vcol)
    writeAt(x, y, label, THEME.dim)
    writeRight(x + w - 1, y, value, vcol or THEME.text)
    return y + 1
end

-- render a leaderboard column at (x,y) with width colW, listH rows
-- valField: "in"->inRate, "out"->outRate, "flow", "net", "cur"
local function fieldValue(e, valField)
    if valField == "in" then return e.inRate
    elseif valField == "out" then return e.outRate
    elseif valField == "net" then return e.netRate
    elseif valField == "flow" then return e.flow
    elseif valField == "cur" then return e.cur end
    return 0
end
local function leaderboardColumn(x, y, colW, listH, title, list, startIdx, valField, valUnit, valCol)
    writeAt(x, y, title, valCol)
    fillRow(x, y + 1, colW, THEME.faint)
    for i = 1, listH do
        local idx = startIdx + i - 1
        local e = list[idx]
        local yy = y + 1 + i
        if yy > y + 1 + listH then break end
        if e then
            writeAt(x, yy, string.format("%2d.", idx), THEME.faint)
            local nameMax = colW - 10
            writeAt(x + 4, yy, trunc(e.display, nameMax), THEME.text)
            writeRight(x + colW - 1, yy, fmtNum(fieldValue(e, valField)) .. valUnit, valCol)
        end
    end
end

--===========================================================================
--  VIEW 1  ·  DASHBOARD
--===========================================================================
local function viewDashboard(bodyY)
    if not curSnap then
        writeAt(2, bodyY + 2, "No data yet (waiting for first poll).", THEME.warn)
        return
    end
    local s = curSnap
    local bodyH = (H - 1) - bodyY + 1

    -- layout: left rail (stats) | gutter | right (movers preview)
    local railW = math.max(20, math.floor(W * 0.42))
    if railW > W - 26 then railW = W - 26 end
    local railX  = 2
    local rightX = railX + railW + 1
    local rightW = W - rightX - 1
    if rightW < 16 then rightW = 16 end

    -- ===== LEFT RAIL =====
    local ry = bodyY
    writeAt(railX, ry, "[ NETWORK ]", THEME.accent); ry = ry + 1
    fillRow(railX, ry, railW, THEME.faint); ry = ry + 1

    -- energy
    local er = s.maxEnergy and s.maxEnergy > 0 and (s.energy / s.maxEnergy) or 0
    ry = statRow(railX, ry, railW, "ENERGY", fmtEnergy(s.energy), ratioColour(er))
    gauge(railX, ry, railW, er, ratioColour(er), THEME.faint); ry = ry + 2

    -- power
    ry = statRow(railX, ry, railW, "POWER IN",
        s.pinj and (fmtNum(s.pinj) .. " AE/t") or "--", THEME.incol)
    ry = statRow(railX, ry, railW, "POWER OUT",
        s.puse and (fmtNum(s.puse) .. " AE/t") or "--", THEME.outcol)
    local net = (s.pinj or 0) - (s.puse or 0)
    ry = statRow(railX, ry, railW, "NET",
        string.format("%s%.1f AE/t", net >= 0 and "+" or "-", math.abs(net)),
        net >= 0 and THEME.good or THEME.bad)
    ry = ry + 1

    writeAt(railX, ry, "[ STORAGE ]", THEME.accent); ry = ry + 1
    fillRow(railX, ry, railW, THEME.faint); ry = ry + 1

    ry = statRow(railX, ry, railW, "ITEM TYPES", fmtNum(s.itemTypes), THEME.text)
    ry = statRow(railX, ry, railW, "ITEM COUNT", fmtNum(s.itemCount), THEME.text)
    if s.usedItem and s.totalItem and s.totalItem > 0 then
        local ur = s.usedItem / s.totalItem
        ry = statRow(railX, ry, railW, "ITEM BYTES",
            fmtNum(s.usedItem) .. "/" .. fmtNum(s.totalItem), ratioColour(ur))
        gauge(railX, ry, railW, ur, ratioColour(ur), THEME.faint); ry = ry + 2
    end
    ry = statRow(railX, ry, railW, "FLUID TYPES", fmtNum(s.fluidTypes), THEME.text)
    if s.usedFluid and s.totalFluid and s.totalFluid > 0 then
        local fr = s.usedFluid / s.totalFluid
        ry = statRow(railX, ry, railW, "FLUID BYTES",
            fmtNum(s.usedFluid) .. "/" .. fmtNum(s.totalFluid), ratioColour(fr))
    else
        ry = statRow(railX, ry, railW, "FLUID AMOUNT", fmtNum(s.fluidAmount) .. " mB", THEME.text)
    end
    local _, craftN = nil, 0
    do local c = 0; for _ in pairs(s.craftables) do c = c + 1 end craftN = c end
    ry = ry + 1
    ry = statRow(railX, ry, railW, "CRAFTABLE", fmtNum(craftN), THEME.info)
    ry = statRow(railX, ry, railW, "RATE WINDOW", CONFIG.windowSec .. "s", THEME.dim)

    -- ===== RIGHT: TOP MOVERS PREVIEW =====
    if rightX > W then return end
    local my = bodyY
    writeAt(rightX, my, "[ TOP MOVERS ]", THEME.viewAccent[VI.MOVERS]); my = my + 1
    fillRow(rightX, my, rightW, THEME.faint); my = my + 1

    -- header line
    local nameW = rightW - 18
    writeAt(rightX, my, trunc("ITEM", nameW), THEME.dim)
    writeRight(rightX + nameW + 4, my, "IN/s", THEME.incol)
    writeRight(rightX + nameW + 9, my, "OUT/s", THEME.outcol)
    writeRight(rightX + rightW - 1, my, "NET/s", THEME.dim)
    my = my + 1

    local movers = topBy("items", "flow", 5)
    if #movers == 0 then
        writeAt(rightX, my, "no flow in last "..CONFIG.windowSec.."s", THEME.faint)
    else
        for i = 1, #movers do
            if my > H - 1 then break end
            local e = movers[i]
            writeAt(rightX, my, trunc(e.display, nameW), THEME.text)
            writeRight(rightX + nameW + 4, my, fmtNum(e.inRate) .. "/s", THEME.incol)
            writeRight(rightX + nameW + 9, my, fmtNum(e.outRate) .. "/s", THEME.outcol)
            local ncol = e.netRate >= 0 and THEME.good or THEME.bad
            writeRight(rightX + rightW - 1, my, fmtSigned(e.netRate) .. "/s", ncol)
            my = my + 1
        end
    end
end

--===========================================================================
--  VIEW 2  ·  MOVERS  (items + fluids ranked by total flow)
--===========================================================================
local function viewMovers(bodyY)
    local _, bodyBot = bodyRect()
    local bodyH = bodyBot - bodyY + 1
    local colW = math.floor((W - 3) / 2)
    local xs = { 2, colW + 3 }
    local listH = bodyH - 2  -- title + header line

    local items  = topBy("items", "flow", 999)
    local fluids = topBy("fluids", "flow", 999)
    local maxPage = math.max(1, math.ceil(math.max(#items, #fluids) / listH))
    local pg = ensurePage(VI.MOVERS, maxPage)
    local startIdx = (pg - 1) * listH + 1

    for ci = 1, 2 do
        local kind = (ci == 1) and "items" or "fluids"
        local list = (ci == 1) and items or fluids
        local x = xs[ci]
        local title = string.format("%s MOVERS  /s", string.upper(kind:sub(1,1))..kind:sub(2))
        writeAt(x, bodyY, title, THEME.viewAccent[VI.MOVERS])
        fillRow(x, bodyY + 1, colW, THEME.faint)
        -- column sub-header
        local nameW = colW - 22
        writeAt(x, bodyY + 2, "ITEM", THEME.dim)
        writeRight(x + nameW + 5,  bodyY + 2, "IN/s", THEME.incol)
        writeRight(x + nameW + 10, bodyY + 2, "OUT/s", THEME.outcol)
        writeRight(x + nameW + 16, bodyY + 2, "NET/s", THEME.dim)
        for i = 1, listH do
            local idx = startIdx + i - 1
            local e = list[idx]
            local yy = bodyY + 2 + i
            if yy > bodyBot then break end
            if e then
                writeAt(x, yy, string.format("%2d.", idx), THEME.faint)
                writeAt(x + 4, yy, trunc(e.display, nameW), THEME.text)
                writeRight(x + nameW + 5,  yy, fmtNum(e.inRate) .. "/s", THEME.incol)
                writeRight(x + nameW + 10, yy, fmtNum(e.outRate) .. "/s", THEME.outcol)
                local ncol = e.netRate >= 0 and THEME.good or THEME.bad
                writeRight(x + nameW + 16, yy, fmtSigned(e.netRate) .. "/s", ncol)
            end
        end
    end
end

--===========================================================================
--  VIEW 3 / 4  ·  ITEMS / FLUIDS  (three leaderboards: IN / OUT / STORED)
--===========================================================================
local function viewLeaderboard(kind)
    local bodyY = 3
    local _, bodyBot = bodyRect()
    local bodyH = bodyBot - bodyY + 1
    local colW = math.floor((W - 3) / 3)
    local xs = { 2, colW + 3, 2 * (colW + 1) + 1 }
    local listH = bodyH - 1
    local unit = (kind == "fluids") and "/s mB" or "/s"
    local viewIdx = (kind == "fluids") and VI.FLUIDS or VI.ITEMS

    local colDefs = {
        { title = "TOP IN/s",    field = "in", col = THEME.incol },
        { title = "TOP OUT/s",   field = "out", col = THEME.outcol },
        { title = "TOP STORED",  field = "cur", col = THEME.viewAccent[viewIdx] },
    }
    local lists = {}
    local total = 0
    for ci, d in ipairs(colDefs) do
        lists[ci] = topBy(kind, d.field, 999)
        if #lists[ci] > total then total = #lists[ci] end
    end
    local maxPage = math.max(1, math.ceil(total / listH))
    local pg = ensurePage(viewIdx, maxPage)
    local startIdx = (pg - 1) * listH + 1

    for ci, d in ipairs(colDefs) do
        leaderboardColumn(xs[ci], bodyY, colW, listH, d.title, lists[ci],
                          startIdx, d.field, unit, d.col)
    end
end

--===========================================================================
--  VIEW 5  ·  CRAFTING
--===========================================================================
local function viewCraft()
    local bodyY = 3
    local _, bodyBot = bodyRect()
    local bodyH = bodyBot - bodyY + 1
    if not curSnap then writeAt(2, bodyY, "waiting for data...", THEME.faint) return end
    local keys = {}
    for _, v in pairs(curSnap.craftables) do keys[#keys + 1] = v end
    table.sort(keys, function(a, b) return a.display < b.display end)

    writeAt(2, bodyY, "CRAFTABLES:", THEME.dim)
    writeAt(14, bodyY, fmtNum(#keys), THEME.viewAccent[VI.CRAFT])

    local listH = bodyH - 2
    local maxPage = math.max(1, math.ceil(#keys / listH))
    local pg = ensurePage(VI.CRAFT, maxPage)
    local startIdx = (pg - 1) * listH + 1
    fillRow(2, bodyY + 1, W - 2, THEME.faint)
    local nameW = W - 12
    for i = 1, listH do
        local idx = startIdx + i - 1
        local e = keys[idx]
        local yy = bodyY + 1 + i
        if yy > bodyBot then break end
        if e then
            writeAt(2, yy, trunc(e.display, nameW), THEME.text)
            -- ponytail: isItemCrafting is per-item RPC; sample first 20 rows only
            if idx <= 20 and bridge and bridge.isItemCrafting then
                if safeCall("isItemCrafting", { name = e.display }) then
                    writeRight(W - 2, yy, "crafting", THEME.warn)
                end
            end
        end
    end
end

--===========================================================================
--  RENDER
--===========================================================================
local function render()
    clearScreen()
    drawTitleBar()
    drawTabBar()

    local bodyY = 3
    local bodyBot = H - 1
    -- ponytail: body is blanked by clearScreen; no per-view fill needed
    if     app.view == VI.DASH   then viewDashboard(bodyY)
    elseif app.view == VI.MOVERS then viewMovers(bodyY)
    elseif app.view == VI.ITEMS  then viewLeaderboard("items")
    elseif app.view == VI.FLUIDS then viewLeaderboard("fluids")
    elseif app.view == VI.CRAFT  then viewCraft() end

    -- footer: per-view page state
    local ctrl = { hasPrev = false, hasNext = false }
    if app.view == VI.DASH then
        ctrl.center = function(y)
            writeAt(math.floor((W - 14) / 2) + 1, y, "r=redraw R=reset", THEME.dim, THEME.faint)
        end
    else
        local pages = ui.pages[app.view] or 1
        local pg = app.page[app.view] or 1
        ctrl.hasPrev = pg > 1
        ctrl.hasNext = pg < pages
        ctrl.center = function(y)
            local s = string.format("page %d / %d   R=reset", pg, pages)
            writeAt(math.floor((W - #s) / 2) + 1, y, s, THEME.dim, THEME.faint)
        end
    end
    drawFooter(ctrl)
end

--===========================================================================
--  INPUT
--===========================================================================
local function selectView(i)
    i = clamp(i, 1, #VIEWS)
    if app.view ~= i then app.view = i; render() end
end

local function onPage(dir)
    local pg = app.page[app.view] or 1
    app.page[app.view] = clamp(pg + dir, 1, ui.pages[app.view] or 1)
end

local function handleTouch(x, y)
    -- tab bar: row 2
    if y == 2 then
        for i, t in ipairs(ui.tabs) do
            if x >= t.x1 and x <= t.x2 then selectView(i); return end
        end
        return
    end
    -- footer: row H  (left half prev, right half next)
    if y == H then
        if x <= 3 then onPage(-1)
        elseif x >= W - 2 then onPage(1) end
    end
end

local function handleKey(k)
    if k == keys.left then selectView((app.view - 2) % #VIEWS + 1)
    elseif k == keys.right then selectView(app.view % #VIEWS + 1)
    elseif k == keys.up   or k == keys.equals then onPage(1)
    elseif k == keys.down or k == keys.minus then onPage(-1)
    elseif k == keys.q then return "quit"
    end
end

local function handleChar(ch)
    if ch == "q" then return "quit" end
    if ch == "R" then resetCounters(); return "redraw" end
    if ch == "r" then return "redraw" end
end

--===========================================================================
--  MAIN
--===========================================================================
local function attachMonitor()
    local mon
    if CONFIG.monitorSide then mon = peripheral.wrap(CONFIG.monitorSide)
    else mon = peripheral.find("monitor") end
    if not mon then
        printError("ae2_monitor: no monitor found (set CONFIG.monitorSide)")
        return false
    end
    term.redirect(mon)
    mon.setTextScale(CONFIG.textScale)
    W, H = term.getSize()
    return true
end

local function main()
    if not attachMonitor() then return end
    if not detectBridge() then
        clearScreen()
        writeAt(2, 2, "No me_bridge peripheral detected.", THEME.bad)
        writeAt(2, 3, "Place an Advanced Peripherals me_bridge adjacent", THEME.dim)
        writeAt(2, 4, "to (or wired onto) this computer and the AE2 network.", THEME.dim)
        return
    end

    poll()  -- prime first snapshot
    local refreshInterval = 1 / CONFIG.refreshHz
    local pollInterval    = 1 / CONFIG.pollHz
    local nextPoll = os.epoch("utc") + pollInterval * 1000
    local timer = os.startTimer(refreshInterval)

    while true do
        local ev = { os.pullEvent() }
        local e = ev[1]
        if e == "timer" and ev[2] == timer then
            if os.epoch("utc") >= nextPoll then
                poll()
                nextPoll = os.epoch("utc") + pollInterval * 1000
            end
            render()
            timer = os.startTimer(refreshInterval)
        elseif e == "monitor_touch" or e == "touch" then
            handleTouch(ev[3], ev[4]); render()
        elseif e == "key" then
            local act = handleKey(ev[2])
            if act == "quit" then break end
            render()
        elseif e == "char" then
            local act = handleChar(ev[2])
            if act == "quit" then break end
            -- ponytail: redraw handled by next timer tick (~0.1s)
        elseif e == "monitor_resize" then
            W, H = term.getSize(); render()
        end
    end
end

main()
term.redirect(term.native())
