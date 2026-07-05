--===========================================================================
-- warehouse_hub.lua  ·  SCADA warehouse overview
-- Central computer. Hosts on rednet, receives warehouse snapshots from one or
-- more warehouse_node computers, and renders a live, touch-driven SCADA view
-- on an Advanced Monitor.
--
-- Hardware: Computer + Wireless/Ender Modem + Advanced Monitor (touch).
-- Run:  warehouse_hub
--
-- Controls:
--   * tap a GROUP header  -> expand / collapse that item group
--   * tap footer  < / >   -> page the list (or left/right half of footer)
--   * keys:  r=redraw  q=quit  up/down=page  (+/- also toggle paging)
--===========================================================================

local CONFIG = {
    PROT        = "colony_warehouse", -- must match warehouse_node.lua
    HOST_NAME   = "colony_hub",
    STALE_SEC   = 30,                 -- node goes red if no report in this window
    textScale   = 0.5,                -- CC minimum; densest possible
    monitorSide = nil,                -- nil = auto-detect; or "left"/"top"/"network_3"
    refresh     = 2,                  -- seconds between automatic re-renders (clock/stale)
}

--===========================================================================
--  GLOBALS  (local-captured for speed + lint)
--===========================================================================
local term, colors, keys, peripheral, rednet, os, string, math, table, pairs,
      ipairs, tostring, printError =
      term, colors, keys, peripheral, rednet, os, string, math, table, pairs,
      ipairs, tostring, printError

--===========================================================================
--  THEME  ·  SCADA dark palette (matches colony_monitor.lua)
--===========================================================================
local THEME = {
    bg     = colors.black, panel = colors.black,
    text   = colors.white, dim   = colors.lightGray, faint = colors.gray,
    good   = colors.lime,  warn  = colors.yellow,    bad   = colors.red,
    info   = colors.cyan,  accent = colors.cyan,
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
-- "minecraft:oak_log" -> "Oak Log" ; already-pretty text passes through
local function humanize(s)
    s = tostring(s or "?")
    if s:find(":") then s = s:gsub("^[%w_]+:", "") end
    if s:find("_") then s = s:gsub("_", " ") end
    return s:sub(1, 1):upper() .. s:sub(2)
end
-- "minecraft:oak_log" -> "minecraft"
-- path part of a registry id: "minecraft:raw_iron" -> "raw_iron"
local function pathOf(id)
    return (tostring(id):gsub("^[%w_]+:", ""))
end

-- ponytail: heuristic classifier on the registry path. Forge/NeoForge tags
-- (c:ores, c:foods, ...) are NOT reachable via CC's inventory API — getItemDetail
-- returns a registry id, no tag membership. So we bucket by id pattern. First
-- matching rule wins; extend RULES in order. "Misc" catches the rest.
local RULES = {
    { "Tools",   { "_pickaxe$", "_axe$", "_shovel$", "_hoe$", "_sword$", "_bow$",
                   "crossbow$", "fishing_rod$", "shears$", "flint_and_steel$", "shield$" } },
    { "Armor",   { "_helmet$", "_chestplate$", "_leggings$", "_boots$" } },
    { "Ores",    { "_ore$", "^raw_" } },
    { "Metals",  { "_ingot$", "_nugget$", "_dust$", "_gear$", "_plate$", "_rod$",
                   "_wire$", "_gem$", "_crystal$", "^coal$", "^charcoal$", "^diamond$",
                   "^emerald$", "^quartz$", "^lapis_lazuli$", "^redstone$", "^netherite_" } },
    { "Wood",    { "_log$", "_planks$", "_leaves$", "_sapling$", "^stick$" } },
    { "Stone",   { "cobblestone", "^stone$", "_stone$", "^dirt$", "^sand$", "^gravel$",
                   "^sandstone", "^netherrack", "^end_stone", "^obsidian", "^deepslate",
                   "^granite", "^diorite", "^andesite", "^clay", "^terracotta", "^brick",
                   "glass", "^ice", "^snow$", "^cactus$" } },
    { "Redstone",{ "redstone", "repeater", "comparator", "piston", "dispenser", "dropper",
                   "observer", "hopper", "lever", "_button$", "_pressure_plate$", "_rail$",
                   "^tnt", "^note_block$", "^daylight_detector", "^tripwire" } },
    { "Food",    { "bread", "apple", "^beef", "porkchop", "^cooked_", "mutton", "^chicken",
                   "^rabbit", "^cod", "^salmon", "^fish", "cookie", "melon_slice",
                   "sweet_berries", "glow_berries", "^carrot", "^potato", "^beetroot",
                   "^cake", "pumpkin_pie", "stew", "^honey_bottle", "^milk_bucket",
                   "^dried_kelp", "^sugar$", "^wheat$", "^egg$", "kelp", "seeds$" } },
}

local function categoryOf(id)
    local p = pathOf(id)
    for _, rule in ipairs(RULES) do
        for _, pat in ipairs(rule[2]) do
            if p:find(pat) then return rule[1] end
        end
    end
    return "Misc"
end

--===========================================================================
--  STATE
--===========================================================================
-- nodes[name] = { time, day, total, types, items = { {id,name,count}, ... }}
local nodes = {}
local app = { page = 1, expanded = {} }      -- expanded key = node.."\\"..group
local ui  = { touch = {}, prev = false, next = false }  -- captured touch rects

-- ordered node names (stable iteration)
local function nodeNames()
    local t = {}
    for name in pairs(nodes) do t[#t + 1] = name end
    table.sort(t)
    return t
end

-- group a node's items by category (heuristic; see categoryOf)
-- returns ordered list: { name=mod, items={...}, total=N, types=N, max=count-of-largest }
local function groupsOf(n)
    local g = {}
    for _, it in ipairs(n.items or {}) do
        local m = categoryOf(it.id)
        local e = g[m]
        if not e then e = { name = m, items = {}, total = 0, types = 0, max = 0 }; g[m] = e end
        e.items[#e.items + 1] = it
        e.total = e.total + (it.count or 0)
        e.types = e.types + 1
        if (it.count or 0) > e.max then e.max = it.count end
    end
    local list = {}
    for _, e in pairs(g) do list[#list + 1] = e end
    table.sort(list, function(a, b)
        -- Misc always sinks to the bottom; everything else by total desc
        if a.name == "Misc" then return false end
        if b.name == "Misc" then return true end
        return a.total > b.total
    end)
    for _, e in ipairs(list) do
        table.sort(e.items, function(a, b) return (a.count or 0) > (b.count or 0) end)
    end
    return list
end

-- is a node's data stale?
local function isStale(n)
    local ageSec = (os.day() == n.day) and math.max(0, os.time() - n.time) * 50 or 9999
    return ageSec > CONFIG.STALE_SEC
end

--===========================================================================
--  ROW MODEL  ·  flatten nodes -> groups -> items into a pageable row list
--===========================================================================
-- row shapes:
--   { kind="node",  name, n }
--   { kind="group", key, gname, total, types, expanded }
--   { kind="item",  text, count, max }
local function buildRows()
    local rows = {}
    for _, name in ipairs(nodeNames()) do
        local n = nodes[name]
        rows[#rows + 1] = { kind = "node", name = name, n = n }
        for _, g in ipairs(groupsOf(n)) do
            local key = name .. "\\" .. g.name
            local open = app.expanded[key]
            rows[#rows + 1] = { kind = "group", key = key, gname = g.name,
                                total = g.total, types = g.types, open = open }
            if open then
                for _, it in ipairs(g.items) do
                    rows[#rows + 1] = { kind = "item",
                        text = humanize(it.name or it.id),
                        count = it.count or 0, max = g.max }
                end
            end
        end
    end
    return rows
end

--===========================================================================
--  RENDER
--===========================================================================
local bodyTop, bodyBot          -- body region rows (set in render)

local function drawTitleBar()
    fillRow(1, 1, W, THEME.accent)
    local nn = #nodes
    local who = nn == 0 and "NO NODE" or (nn == 1 and nodeNames()[1] or nn .. " NODES")
    writeAt(2, 1, "WAREHOUSE  " .. string.upper(who), colors.white, THEME.accent)
    -- status: any node stale -> OFFLINE/STALE else ONLINE
    local anyStale = false
    for _, n in pairs(nodes) do if isStale(n) then anyStale = true; break end end
    local right = clock() .. (anyStale and "  STALE" or (nn > 0 and "  ONLINE" or "  WAIT"))
    writeRight(W - 1, 1, right, colors.white, THEME.accent)
end

local function drawSummary()
    local y = 2
    local totItems, totTypes, staleN = 0, 0, 0
    for _, n in pairs(nodes) do
        totItems, totTypes = totItems + (n.total or 0), totTypes + (n.types or 0)
        if isStale(n) then staleN = staleN + 1 end
    end
    fillRow(1, y, W, THEME.faint)
    local left = string.format(" ITEMS %-5d  TYPES %-4d  NODES %d%s",
        totItems, totTypes, #nodes, staleN > 0 and ("  !" .. staleN .. " STALE") or "")
    writeAt(2, y, left, THEME.dim, THEME.faint)
end

local function drawFooter(rows, startIdx)
    local y = H
    fillRow(1, y, W, THEME.faint)
    local bodyH = bodyBot - bodyTop + 1
    local maxPage = math.max(1, math.ceil(#rows / bodyH))
    app.page = clamp(app.page, 1, maxPage)
    ui.prev = app.page > 1
    ui.next = app.page < maxPage
    writeAt(2, y, "<", ui.prev and THEME.accent or THEME.faint, THEME.faint)
    writeAt(W - 1, y, ">", ui.next and THEME.accent or THEME.faint, THEME.faint)
    local mid = string.format("PAGE %d/%d   tap group to fold", app.page, maxPage)
    writeAt(math.floor((W - #mid) / 2) + 1, y, mid, THEME.dim, THEME.faint)
end

local function render()
    local rows = buildRows()
    bodyTop, bodyBot = 3, H - 1
    local bodyH = bodyBot - bodyTop + 1
    local maxPage = math.max(1, math.ceil(#rows / bodyH))
    app.page = clamp(app.page, 1, maxPage)
    local startIdx = (app.page - 1) * bodyH + 1

    clearScreen()
    drawTitleBar()
    drawSummary()
    ui.touch = {}   -- reset hit-rects for this frame

    local y = bodyTop
    for i = startIdx, math.min(#rows, startIdx + bodyH - 1) do
        local r = rows[i]
        if r.kind == "node" then
            -- node divider: thin rule + name + online/stale tag
            fillRow(1, y, W, THEME.panel)
            local tag = isStale(r.n) and "STALE" or "OK"
            local tcol = isStale(r.n) and THEME.bad or THEME.good
            writeAt(2, y, ">", THEME.accent)
            writeAt(4, y, string.upper(r.name), THEME.text)
            writeRight(W - 6, y, string.format("%-4s %4d", tag, r.n.total or 0), tcol)
        elseif r.kind == "group" then
            -- group header: touch target. full-width faint underline accent.
            local mark = r.open and "-" or "+"
            writeAt(2, y, mark, r.open and THEME.warn or THEME.good)
            writeAt(4, y, string.lower(r.gname), THEME.text)
            local right = string.format("%d items / %d types", r.total, r.types)
            writeRight(W - 2, y, right, THEME.dim)
            fillRow(1, y, 1, THEME.faint)  -- left rail tick
            ui.touch[#ui.touch + 1] = { y = y, key = r.key }
        else -- item
            local cnt = tostring(r.count)
            local col = r.max > 0 and ratioColour(r.count / r.max) or THEME.text
            writeAt(2, y, r.text, THEME.dim)
            local dotStart = 2 + #r.text + 1
            local dotEnd   = (W - 2) - #cnt - 1
            if dotEnd >= dotStart then
                writeAt(dotStart, y, string.rep(".", dotEnd - dotStart + 1), THEME.faint)
            end
            writeRight(W - 2, y, cnt, col)
        end
        y = y + 1
    end

    drawFooter(rows, startIdx)
end

--===========================================================================
--  INPUT
--===========================================================================
local function toggleGroup(key)
    app.expanded[key] = not app.expanded[key]
    app.page = 1
end
local function onPage(d)
    app.page = clamp(app.page + d, 1, 999)
end

local function handleTouch(x, y)
    -- footer: left half prev, right half next
    if y == H then
        if x <= math.floor(W / 2) then onPage(-1) else onPage(1) end
        return
    end
    -- group headers
    for _, t in ipairs(ui.touch) do
        if y == t.y then toggleGroup(t.key); return end
    end
end
local function handleKey(k)
    if     k == keys.r then                       -- redraw
    elseif k == keys.q then return "quit"
    elseif k == keys.up   or k == keys.pageUp   then onPage(-1)
    elseif k == keys.down or k == keys.pageDown then onPage(1)
    end
end

--===========================================================================
--  HARDWARE
--===========================================================================
local function findMonitor()
    if CONFIG.monitorSide then return peripheral.wrap(CONFIG.monitorSide) end
    return peripheral.find("monitor")
end
local function findModemSide()
    for _, side in ipairs(rs.getSides()) do
        if peripheral.isPresent(side) and peripheral.getType(side) == "modem" then
            return side
        end
    end
end

--===========================================================================
--  MAIN
--===========================================================================
local monitor = findMonitor()
if not monitor then
    print("warehouse_hub: no monitor found. Attach an Advanced Monitor or set CONFIG.monitorSide.")
    return
end
monitor.setTextScale(CONFIG.textScale)
term.redirect(monitor)
W, H = term.getSize()
W, H = W or 51, H or 19   -- ponytail: sane fallback if getSize ever returns nil

local modemSide = findModemSide()
if not modemSide then
    print("warehouse_hub: no modem found. Attach a wireless/ender modem.")
    return
end
rednet.open(modemSide)
rednet.host(CONFIG.PROT, CONFIG.HOST_NAME)

print(string.format("warehouse_hub: hosting '%s' on '%s'.", CONFIG.HOST_NAME, CONFIG.PROT))
render()

local timer = os.startTimer(CONFIG.refresh)
while true do
    local event = { os.pullEvent() }
    local e = event[1]
    if e == "rednet_message" then
        local _, msg, prot = unpack(event, 2)
        if prot == CONFIG.PROT and type(msg) == "table" and msg.node and msg.items then
            nodes[msg.node] = msg
            render()
        end
    elseif e == "monitor_touch" then
        handleTouch(event[3], event[4])
        render()
    elseif e == "key" then
        if handleKey(event[2]) == "quit" then break end
        render()
    elseif e == "timer" and event[2] == timer then
        render()                      -- refresh clock + staleness colours
        timer = os.startTimer(CONFIG.refresh)
    end
end

if term.restore then term.restore() end
rednet.unhost(CONFIG.PROT, CONFIG.HOST_NAME)
