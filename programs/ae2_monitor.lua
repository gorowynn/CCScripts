--===========================================================================
-- ae2_monitor.lua  ·  SCADA Applied Energistics 2 monitor
--
-- Live, touch-driven dashboard for an AE2 / Extended AE2 ME network. Reads
-- the network through an Advanced Peripherals `me_bridge` peripheral every
-- few seconds and renders four views on an Advanced Monitor:
--
--   OVERVIEW   -- energy bar, power in/out, item + fluid storage, type counts,
--                  current top-5 by stored amount, crafting summary.
--   TOP ITEMS  -- rolling leaderboards since start: Top-10 IN, Top-10 OUT,
--                  Top-10 STORED. Reset counters with the `R` key / footer.
--   TOP FLUIDS -- same three leaderboards for fluids.
--   CRAFTING   -- craftable items + whether each is currently being crafted.
--
-- In/out = delta of stored count per item between polls, accumulated since
-- script start (or last reset). No disk persistence: numbers reset on
-- restart. Ponytail: in-memory only, add disk log if you need history.
--
-- Hardware: Computer + Advanced Monitor (touch) + me_bridge adjacent or wired.
--
-- Requirements:
--   * Minecraft 1.21.1, CC:Tweaked 1.21.1
--   * Advanced Peripherals (me_bridge)  -- works with AE2 + Extended AE2
--
-- Controls:
--   * tap a TAB to switch view
--   * tap footer  < / >  (or left/right half of footer) to page lists
--   * keys: r=redraw  R=reset counters  q=quit  up/down=page
--===========================================================================

local CONFIG = {
    textScale   = 0.5,     -- CC minimum; densest possible
    monitorSide = nil,     -- nil = auto-detect; or "left"/"top"/"network_3"
    bridgeSide  = nil,     -- nil = auto-detect (peripheral.find "me_bridge")
    refresh     = 2,       -- seconds between automatic re-renders (clock/stale)
    poll        = 3,       -- seconds between ME network polls (delta window)
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
--  THEME  ·  SCADA dark palette (matches warehouse_hub / colony_monitor)
--===========================================================================
local THEME = {
    bg     = colors.black, panel = colors.black,
    text   = colors.white, dim   = colors.lightGray, faint = colors.gray,
    good   = colors.lime,  warn  = colors.yellow,    bad   = colors.red,
    info   = colors.cyan,  accent = colors.cyan,     incol  = colors.lime,
    outcol = colors.red,
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
--  DRAWING PRIMITIVES
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

-- strip MC formatting codes (§X / &X) from display names
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

local function fmtEnergy(n)
    n = tonumber(n) or 0
    return fmtNum(n) .. " AE"
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

-- pcall + shape-tolerant getter: returns nil if method missing / errors
local function safeCall(method, ...)
    if not bridge or type(bridge[method]) ~= "function" then return nil end
    local ok, res = pcall(bridge[method], bridge, ...)
    if ok then return res end
    return nil
end

-- normalise the various avg-power shapes AP returns ({avg=..,count=..} | number | nil)
local function avgOf(res)
    if res == nil then return nil end
    if type(res) == "number" then return res end
    if type(res) == "table" then
        return res.avg or res.average or res.value or res[1]
    end
    return nil
end

local function keyOf(item)
    -- fingerprint: name + nbt so distinct NBT variants don't merge
    return item.name .. (item.nbt and ("/" .. item.nbt) or "")
end

local function snapshot()
    -- one read pass over the network; returns a normalised table or nil
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
--  DELTA / LEADERBOARD STATE  (in-process; resets on restart or `R`)
--===========================================================================
-- accum: { [key] = { display=, inAmt=, outAmt=, cur= } }
local accum = { items = {}, fluids = {} }
local prev = { items = nil, fluids = nil }  -- last snapshot map (key->count/amount)
local sinceStart = os.epoch("utc")

local function resetCounters()
    accum = { items = {}, fluids = {} }
    prev = { items = nil, fluids = nil }
    sinceStart = os.epoch("utc")
end

local function noteDeltas(map, kind, valueField)
    local prevMap = prev[kind]
    local acc = accum[kind]
    if not map then return end
    if prevMap then
        -- items present before: compute delta
        for k, info in pairs(map) do
            local cur = info[valueField]
            local p = prevMap[k]
            local delta = p and (cur - p[valueField]) or 0
            local a = acc[k] or { display = info.display, inAmt = 0, outAmt = 0, cur = cur }
            if delta > 0 then a.inAmt = a.inAmt + delta
            elseif delta < 0 then a.outAmt = a.outAmt + (-delta) end
            a.cur = cur; a.display = info.display
            acc[k] = a
        end
        -- items gone since last poll count as fully out
        for k, info in pairs(prevMap) do
            if not map[k] then
                local a = acc[k] or { display = info.display, inAmt = 0, outAmt = 0, cur = 0 }
                a.outAmt = a.outAmt + info[valueField]; a.cur = 0
                acc[k] = a
            end
        end
    end
    prev[kind] = {}
    for k, info in pairs(map) do prev[kind][k] = { [valueField] = info[valueField], display = info.display } end
end

local function applySnapshot(s)
    noteDeltas(s.items, "items", "count")
    noteDeltas(s.fluids, "fluids", "amount")
end

-- return top-N entries of `accum[kind]` sorted by `field` desc
local function topEntries(kind, field, n)
    local list = {}
    for k, a in pairs(accum[kind]) do
        if (a[field] or 0) > 0 then list[#list + 1] = { key = k, display = a.display, value = a[field] or 0, cur = a.cur or 0 } end
    end
    table.sort(list, function(x, y) return x.value > y.value end)
    while #list > n do table.remove(list) end
    return list
end

local function uptimeStr()
    local ms = os.epoch("utc") - sinceStart
    local s = math.floor(ms / 1000)
    local h = math.floor(s / 3600); s = s % 3600
    local m = math.floor(s / 60); s = s % 60
    if h > 0 then return string.format("%dh%02dm", h, m) end
    if m > 0 then return string.format("%dm%02ds", m, s) end
    return string.format("%ds", s)
end

--===========================================================================
--  STATE
--===========================================================================
local curSnap = nil          -- latest snapshot
local lastPollAt = 0
local lastError = nil
local view = 1               -- 1=overview 2=items 3=fluids 4=crafting
local views = { "OVERVIEW", "TOP ITEMS", "TOP FLUIDS", "CRAFTING" }
local page = 1

local function poll()
    local ok, s = pcall(snapshot)
    if not ok then lastError = tostring(s); return end
    lastError = nil
    applySnapshot(s)
    curSnap = s
    lastPollAt = os.epoch("utc")
end

--===========================================================================
--  UI · HEADER / FOOTER / TABS
--===========================================================================
local headerH = 2
local footerH = 2

local function drawHeader()
    fillRow(1, 1, W, THEME.bg)
    writeAt(2, 1, "AE2 MONITOR", THEME.accent)
    if curSnap then
        writeAt(15, 1, "online", THEME.good)
    else
        writeAt(15, 1, lastError and "ERR" or "init", THEME.bad)
    end
    writeRight(W - 1, 1, clock(), THEME.dim)
    fillRow(1, 2, W, THEME.faint)
    writeAt(2, 2, "cnt " .. uptimeStr(), THEME.dim)
    if lastError then
        local e = lastError:sub(1, math.max(1, W - 30))
        writeAt(15, 2, e, THEME.bad)
    end
end

local function drawTabs()
    local y = headerH + 1
    fillRow(1, y, W, THEME.bg)
    local x = 2
    for i, name in ipairs(views) do
        local active = (i == view)
        local label = " " .. name .. " "
        local col = active and THEME.accent or THEME.dim
        writeAt(x, y, label, col)
        x = x + #label + 1
    end
    return y
end

local function contentRect()
    local top = headerH + 2          -- below tabs row
    local bot = H - footerH
    return 1, top, W, bot - top + 1
end

local function drawFooter(pageStr, hint)
    local y = H - footerH + 1
    fillRow(1, y, W, THEME.bg)
    fillRow(1, y + 1, W, THEME.faint)
    writeAt(2, y, "<", THEME.dim)
    writeRight(W - 1, y, ">", THEME.dim)
    if pageStr then writeAt(5, y, pageStr, THEME.dim) end
    if hint then writeRight(W - 4, y, hint, THEME.faint) end
    writeAt(2, y + 1, "r=redraw  R=reset  q=quit", THEME.faint)
    writeRight(W - 1, y + 1, clock(), THEME.dim)
end

--===========================================================================
--  VIEWS
--===========================================================================
local function panel(x, y, w, h, title)
    fillBox(x, y, w, h, THEME.bg)
    if title then writeAt(x + 1, y, title, THEME.accent) end
end

local function viewOverview()
    local _, y0, w, h = contentRect()
    if not curSnap then
        writeAt(2, y0 + 2, "No data yet (waiting for first poll).", THEME.warn)
        return
    end
    local s = curSnap
    local row = y0

    -- ENERGY
    panel(2, row, w - 2, 3, "ENERGY")
    local er = s.maxEnergy and s.maxEnergy > 0 and (s.energy / s.maxEnergy) or 0
    gauge(3, row + 2, w - 6, er, ratioColour(er), THEME.faint)
    writeAt(3, row + 1, fmtEnergy(s.energy) .. " / " .. fmtEnergy(s.maxEnergy), THEME.text)
    writeRight(W - 2, row + 1, string.format("%.1f%%", er * 100), ratioColour(er))
    row = row + 4

    -- POWER FLOW
    panel(2, row, w - 2, 3, "POWER (avg / tick)")
    writeAt(3, row + 1, "in ", THEME.dim)
    writeAt(6, row + 1, s.pinj and (fmtNum(s.pinj) .. " AE/t") or "--", THEME.incol)
    local half = math.floor((w - 4) / 2)
    writeAt(3 + half, row + 1, "out", THEME.dim)
    writeAt(3 + half + 4, row + 1, s.puse and (fmtNum(s.puse) .. " AE/t") or "--", THEME.outcol)
    local net = (s.pinj or 0) - (s.puse or 0)
    local netCol = net >= 0 and THEME.good or THEME.bad
    writeAt(3, row + 2, "net", THEME.dim)
    writeAt(7, row + 2, string.format("%s%.2f AE/t", net >= 0 and "+" or "-", math.abs(net)), netCol)
    row = row + 4

    -- STORAGE / COUNTS
    panel(2, row, w - 2, 4, "STORAGE")
    local function stat(cx, label, value, sub)
        writeAt(3, row + 1, label, THEME.dim)
        writeAt(3, row + 2, value, THEME.text)
        if sub then writeAt(3, row + 3, sub, THEME.faint) end
    end
    local colW = math.floor((w - 4) / 3)
    -- items
    stat(2, "ITEM TYPES", fmtNum(s.itemTypes), fmtNum(s.itemCount) .. " items")
    -- item bytes
    if s.usedItem and s.totalItem and s.totalItem > 0 then
        local ur = s.usedItem / s.totalItem
        writeAt(3 + colW, row + 1, "ITEM BYTES", THEME.dim)
        writeAt(3 + colW, row + 2, fmtNum(s.usedItem) .. " / " .. fmtNum(s.totalItem), THEME.text)
        gauge(3 + colW, row + 3, colW - 2, ur, ratioColour(ur), THEME.faint)
    else
        writeAt(3 + colW, row + 1, "ITEM BYTES", THEME.dim)
        writeAt(3 + colW, row + 2, "n/a", THEME.faint)
    end
    -- fluids
    writeAt(3 + colW * 2, row + 1, "FLUID TYPES", THEME.dim)
    writeAt(3 + colW * 2, row + 2, fmtNum(s.fluidTypes), THEME.text)
    if s.usedFluid and s.totalFluid and s.totalFluid > 0 then
        local fr = s.usedFluid / s.totalFluid
        writeAt(3 + colW * 2, row + 3, fmtNum(s.usedFluid) .. " / " .. fmtNum(s.totalFluid), THEME.faint)
        -- ponytail: only the item-bytes gauge drawn; fluids shown numerically
    else
        writeAt(3 + colW * 2, row + 3, fmtNum(s.fluidAmount) .. " mB", THEME.faint)
    end
    row = row + 5

    -- TOP STORED (mini)
    local remaining = (y0 + h - 1) - row + 1
    if remaining >= 4 then
        panel(2, row, w - 2, remaining, "TOP STORED (current)")
        local list = topEntries("items", "cur", 5)
        if #list == 0 then
            writeAt(3, row + 2, "waiting for data...", THEME.faint)
        else
            for i, e in ipairs(list) do
                if row + 1 + i > y0 + h - 1 then break end
                writeAt(3, row + 1 + i, string.format("%2d.", i), THEME.faint)
                local nameMax = w - 22
                local name = e.display
                if #name > nameMax then name = name:sub(1, nameMax - 1) .. "\187" end
                writeAt(7, row + 1 + i, name, THEME.text)
                writeRight(W - 3, row + 1 + i, fmtNum(e.cur), THEME.accent)
            end
        end
    end
end

-- generic leaderboard view for items or fluids
local function viewLeaderboard(kind, valueField)
    local _, y0, w, h = contentRect()
    _ = valueField -- kept for call-site readability
    -- three columns: IN / OUT / STORED
    local titles = { "TOP IN", "TOP OUT", "TOP STORED" }
    local fields = { "inAmt", "outAmt", "cur" }
    local cols = { THEME.incol, THEME.outcol, THEME.accent }
    local unit = (kind == "fluids") and "mB" or "x"

    local listH = h - 1
    local colW = math.floor((w - 4) / 3)
    local xs = { 2, 2 + colW + 1, 2 + (colW + 1) * 2 }

    -- column headers
    for ci = 1, 3 do
        writeAt(xs[ci], y0, titles[ci], cols[ci])
        fillRow(xs[ci], y0 + 1, colW, THEME.faint)
    end

    for ci = 1, 3 do
        local list = topEntries(kind, fields[ci], CONFIG.topN)
        local startIdx = (page - 1) * listH
        for i = 1, listH do
            local idx = startIdx + i
            local e = list[idx]
            local yy = y0 + 1 + i
            if yy > y0 + h then break end
            if e then
                local name = e.display
                local nameMax = colW - 9
                if #name > nameMax then name = name:sub(1, nameMax - 1) .. "\187" end
                writeAt(xs[ci], yy, string.format("%2d.", idx), THEME.faint)
                writeAt(xs[ci] + 4, yy, name, THEME.text)
                local valStr = fmtNum(e.value) .. unit
                writeRight(xs[ci] + colW - 1, yy, valStr, cols[ci])
            end
        end
    end
end

local function viewCrafting()
    local _, y0, w, h = contentRect()
    if not curSnap then writeAt(2, y0, "waiting for data...", THEME.faint) return end
    local craft = curSnap.craftables
    local keys = {}
    for k, v in pairs(craft) do keys[#keys + 1] = { key = k, display = v.display } end
    table.sort(keys, function(a, b) return a.display < b.display end)

    writeAt(2, y0, "CRAFTABLES: ", THEME.dim)
    writeAt(14, y0, fmtNum(#keys), THEME.accent)
    fillRow(2, y0 + 1, w - 2, THEME.faint)

    local listH = h - 2
    local startIdx = (page - 1) * listH
    for i = 1, listH do
        local idx = startIdx + i
        local e = keys[idx]
        local yy = y0 + 1 + i
        if yy > y0 + h then break end
        if e then
            local name = e.display
            local nameMax = w - 6
            if #name > nameMax then name = name:sub(1, nameMax - 1) .. "\187" end
            writeAt(2, yy, name, THEME.text)
            -- crafting state is expensive to query per-item; show sample only
            if idx <= 20 and bridge and bridge.isItemCrafting then
                local crafting = safeCall("isItemCrafting", { name = e.display })
                if crafting then writeRight(W - 2, yy, "crafting", THEME.warn) end
            end
        end
    end
end

--===========================================================================
--  RENDER
--===========================================================================
local function render()
    clearScreen()
    drawHeader()
    drawTabs()
    if view == 1 then viewOverview()
    elseif view == 2 then viewLeaderboard("items", "count")
    elseif view == 3 then viewLeaderboard("fluids", "amount")
    elseif view == 4 then viewCrafting() end

    local totalPages = 1
    if view == 2 or view == 3 then
        -- page count from longest of the three leaderboards
        local _, _, _, h = contentRect()
        local listH = h - 1
        local kind = (view == 2 and "items" or "fluids")
        local total = 0
        for _, f in ipairs({ "inAmt", "outAmt", "cur" }) do
            local n = #topEntries(kind, f, 999)
            if n > total then total = n end
        end
        totalPages = math.max(1, math.ceil(total / listH))
    elseif view == 4 then
        local _, _, _, h = contentRect()
        local listH = h - 2
        local n = curSnap and (function() local c=0; for _ in pairs(curSnap.craftables) do c=c+1 end return c end)() or 0
        totalPages = math.max(1, math.ceil(n / listH))
    end
    if page > totalPages then page = totalPages end
    drawFooter(string.format("p%d/%d", page, totalPages), nil)
end

--===========================================================================
--  INPUT
--===========================================================================
local function handleTouch(x, y)
    -- tabs row = headerH + 1
    if y == headerH + 1 then
        local cx = 2
        for i, name in ipairs(views) do
            local label = " " .. name .. " "
            if x >= cx and x < cx + #label then
                if view ~= i then view = i; page = 1 end
                return
            end
            cx = cx + #label + 1
        end
        return
    end
    -- footer row -> paging
    if y == H - footerH + 1 then
        if x <= 3 then page = math.max(1, page - 1); return end
        if x >= W - 2 then page = page + 1; return end
    end
end

local function handleKey(k)
    if k == keys.r then return "redraw"
    elseif k == string.byte("r") then resetCounters(); return "redraw"
    elseif k == keys.q or k == string.byte("q") then return "quit"
    elseif k == keys.up   or k == string.byte("+") or k == keys.equals then page = page + 1; return "redraw"
    elseif k == keys.down or k == keys.minus then page = math.max(1, page - 1); return "redraw"
    end
end

--===========================================================================
--  MAIN
--===========================================================================
local function attachMonitor()
    local mon
    if CONFIG.monitorSide then
        mon = peripheral.wrap(CONFIG.monitorSide)
    else
        mon = peripheral.find("monitor")
    end
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
        -- ponytail: no auto-retry loop; user fixes hardware and re-runs.
        return
    end

    poll()  -- prime first snapshot so leaderboards seed quickly
    local lastFrame = 0
    while true do
        local now = os.epoch("utc")
        if now - lastPollAt >= CONFIG.poll * 1000 then poll() end
        if now - lastFrame >= CONFIG.refresh * 1000 then
            render(); lastFrame = now
        end

        local ev = { os.pullEvent() }
        local e = ev[1]
        if e == "monitor_touch" or e == "touch" then
            handleTouch(ev[3], ev[4]); render()
        elseif e == "key" then
            local act = handleKey(ev[2])
            if act == "quit" then break end
            if act == "redraw" then render() end
        elseif e == "char" then
            local ch = ev[2]
            if ch == "r" or ch == "R" then
                if ch == "R" then resetCounters() end
                render()
            elseif ch == "q" then break
            end
        elseif e == "monitor_resize" then
            W, H = term.getSize(); render()
        end
        -- ponytail: sleeps via pullEvent + bounded os.sleep; fine for a dashboard.
        local sleepUntil = math.min(lastPollAt + CONFIG.poll * 1000,
                                    lastFrame + CONFIG.refresh * 1000)
        local wait = (sleepUntil - os.epoch("utc")) / 1000
        if wait > 0 then os.sleep(math.min(wait, 0.25)) end
    end
end

main()
term.redirect(term.native())
