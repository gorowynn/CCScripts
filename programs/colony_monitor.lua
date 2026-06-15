--===========================================================================
-- Colony Monitor  ·  a modern SCADA-inspired dashboard for MineColonies
--===========================================================================
-- For CC:Tweaked on Minecraft 1.21.1.
-- Requires:  Advanced Peripherals (colony_integrator peripheral), MineColonies
--            and an Advanced Monitor (golden border) for colour.
--
-- Features:
--   * Auto-detects monitor + colony integrator and adapts layout to size
--   * Touch tabs (+ arrow keys / 1-4 on a computer) to switch views
--   * Dashboard  — colony stats, alerts, active requests, visitors
--   * Buildings  — every building with level gauges, guard/storage/upgrade state
--   * Citizens   — every citizen with job, mood, saturation, health
--   * Research   — the full research tree with status LEDs + progress
--
-- Install:  wget run <url> colony_monitor   (then run `colony_monitor`)
--===========================================================================

-- pull in the standard CC:Tweaked globals we rely on (keeps luacheck happy)
local term, colors, keys, peripheral, os, string, math, table, pairs, ipairs, tostring, tonumber, type, error
    = term, colors, keys, peripheral, os, string, math, table, pairs, ipairs, tostring, tonumber, type, error
local unpack = unpack or table.unpack   -- Lua 5.1 has global unpack; be safe

--===========================================================================
-- CONFIG  ·  tweak to taste
--===========================================================================
local CONFIG = {
    refreshInterval = 5,      -- seconds between colony data polls
    monitorSide     = nil,    -- nil = auto-detect the first monitor found
    colonySide      = nil,    -- nil = auto-detect the colony integrator
    textScale       = 0.5,    -- 0.5 = dense (great for a wall of monitors)
    colonyName      = nil,    -- optional friendly name; defaults to "Colony #ID"
}

--===========================================================================
-- THEME  ·  SCADA-style dark palette built from the 16 CC colours
--===========================================================================
local THEME = {
    bg         = colors.black,
    panel      = colors.black,
    text       = colors.white,
    dim        = colors.lightGray,
    faint      = colors.gray,
    good       = colors.lime,
    warn       = colors.yellow,
    bad        = colors.red,
    info       = colors.cyan,
    accent     = colors.lightBlue,
    -- per-view accent used for the title bar + tab highlight
    viewAccent = { colors.cyan, colors.yellow, colors.lime, colors.purple },
}

-- colour constant -> single hex char used by term.blit
local BLIT = {}
do
    -- keys MUST match the CC:Tweaked `colors` API (American spelling):
    -- gray / lightGray. (British `grey` lives only in the `colours` API.)
    local map = { white=0, orange=1, magenta=2, lightBlue=3, yellow=4, lime=5,
        pink=6, gray=7, lightGray=8, cyan=9, purple=10, blue=11, brown=12,
        green=13, red=14, black=15 }
    for name, idx in pairs(map) do
        BLIT[colors[name]] = string.format("%x", idx)
    end
end
local function B(c) return BLIT[c] or BLIT[colors.white] end  -- blit char for a colour

--===========================================================================
-- DRAWING PRIMITIVES  ·  all draw to the current term redirect (the monitor)
--===========================================================================
local W, H                          -- current canvas size (chars)

local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

local function writeAt(x, y, text, fg, bg)
    if not text or text == "" or y < 1 or y > H or x > W then return end
    if x < 1 then                     -- clip characters that fall off the left
        text = text:sub(2 - x)
        x = 1
        if text == "" then return end
    end
    if x + #text - 1 > W then         -- clip characters that fall off the right
        text = text:sub(1, W - x + 1)
    end
    term.setCursorPos(x, y)
    if bg then
        term.blit(text, string.rep(B(fg or colors.white), #text), string.rep(B(bg), #text))
    else
        term.setTextColor(fg or colors.white)
        term.write(text)
    end
end

-- fill w chars on row y with a solid colour
local function fillRow(x, y, w, col)
    if w <= 0 or y < 1 or y > H then return end
    if x < 1 then w = w + (x - 1); x = 1 end
    if x > W then return end
    if x + w - 1 > W then w = W - x + 1 end
    if w <= 0 then return end
    term.setCursorPos(x, y)
    term.blit(string.rep(" ", w), string.rep(B(col), w), string.rep(B(col), w))
end

-- clear a rectangular region with a colour
local function fillBox(x, y, w, h, col)
    for r = 0, h - 1 do fillRow(x, y + r, w, col) end
end

local function clearScreen()
    term.setBackgroundColor(THEME.bg)
    term.clear()
end

-- right-align text ending at column xRight
local function writeRight(xRight, y, text, fg, bg)
    writeAt(xRight - #text + 1, y, text, fg, bg)
end

-- horizontal gauge bar; ratio clamped 0..1
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

-- a single-cell status LED with a label
local function led(x, y, label, state)
    -- state: "good"|"warn"|"bad"|"off"  OR  research: "done"|"prog"|"avail"
    local map = { good = THEME.good, warn = THEME.warn, bad = THEME.bad, off = THEME.faint,
                  done = THEME.good, prog = THEME.warn, avail = THEME.info }
    term.setCursorPos(x, y)
    term.blit(" ", B(map.off), B(map[state] or map.off))
    if label then writeAt(x + 1, y, label, THEME.text) end
end

-- a titled card: solid accent header strip + black body of bodyH rows
local function card(x, y, w, headerH, bodyH, title, accent, rightLabel)
    fillBox(x, y, w, headerH, accent)
    writeAt(x + 1, y, title, colors.white, accent)
    if rightLabel then writeRight(x + w - 1, y, rightLabel, colors.white, accent) end
    -- body left transparent (black) with a faint underline
    if bodyH > 0 then
        fillBox(x, y + headerH, w, bodyH, THEME.panel)
        fillRow(x, y + headerH + bodyH, w, THEME.faint)
    end
    return x + 1, y + headerH, w - 2, bodyH  -- inner content origin + size
end

--===========================================================================
-- COLOUR HELPERS FOR VALUES
--===========================================================================
local function ratioColour(ratio, invert)
    -- green when high, red when low (unless invert)
    local r = invert and (1 - ratio) or ratio
    if r >= 0.66 then return THEME.good end
    if r >= 0.33 then return THEME.warn end
    return THEME.bad
end

-- forward declarations (assigned in APP STATE) so the table renderer can use them
local app, ui

--===========================================================================
-- TEXT & TABLE LAYOUT  ·  word wrap + dynamic column widths, no truncation
--===========================================================================

-- Turn a raw registry/package name into something readable.
--   "com.minecolonies.buildings.GuardTower" -> "Guard Tower"
--   "minecolonies:guard_tower"              -> "Guard Tower"
-- Already-readable strings (no "." or ":") are returned untouched.
local function humanize(s)
    if s == nil then return "?" end
    s = tostring(s)
    if s == "" then return "?" end
    if not s:find("[.:]") then return s end               -- already human text
    -- strip to the segment after the last "." or ":"
    local pos = 0
    for i = #s, 1, -1 do
        local c = s:sub(i, i)
        if c == "." or c == ":" then pos = i; break end
    end
    s = s:sub(pos + 1)
    s = s:gsub("_", " ")                                  -- snake_case -> spaces
    s = s:gsub("(%l)(%u)", "%1 %2")                       -- lowerUpper -> lower Upper
    s = s:gsub("(%u)(%u%l)", "%1 %2")                      -- acronymWord -> acronym Word
    s = s:gsub("%s+", " ")                                -- collapse runs of spaces
    s = s:gsub("^%s+", "")
    s = s:gsub("(%a)(%w*)", function(a, rest)               -- Title Case each word
        return a:upper() .. rest:lower()
    end)
    return s
end

-- split text into lines each <= maxW chars, on word boundaries; hard-split any
-- single token longer than maxW. Never truncates.
local function wrapText(text, maxW)
    text = text or ""
    if maxW <= 0 then return {} end
    if #text <= maxW then return { text } end
    local lines, line = {}, ""
    for word in text:gmatch("%S+") do
        if line == "" then
            line = word
        elseif #line + 1 + #word <= maxW then
            line = line .. " " .. word
        else
            lines[#lines + 1] = line
            line = word
        end
    end
    if line ~= "" then lines[#lines + 1] = line end
    -- hard-split any over-long single token
    local out = {}
    for _, l in ipairs(lines) do
        if #l <= maxW then
            out[#out + 1] = l
        else
            local i = 1
            while i <= #l do
                out[#out + 1] = l:sub(i, i + maxW - 1)
                i = i + maxW
            end
        end
    end
    return out
end

-- compute column widths to fit available width w. If everything fits naturally,
-- use the max-content widths; otherwise shrink the single "wrap" column and its
-- text wraps onto multiple lines instead of being truncated.
-- returns: widths[], wrapCi (the column index that must wrap, or nil)
local function computeWidths(columns, rows, w)
    local ncol = #columns
    local gutter = 2
    local wrapCi = nil
    for ci, col in ipairs(columns) do if col.wrap then wrapCi = ci end end

    local naturals = {}
    for ci, col in ipairs(columns) do
        local nw = #col.header
        for _, row in ipairs(rows) do
            local c = row[ci] or ""
            if #c > nw then nw = #c end
        end
        naturals[ci] = nw
    end
    local totalNat = gutter * (ncol - 1)
    for ci = 1, ncol do totalNat = totalNat + naturals[ci] end

    if totalNat <= w then return naturals, nil end
    if not wrapCi then return naturals, nil end           -- can't shrink: keep natural

    local widths, used = {}, gutter * (ncol - 1)
    for ci = 1, ncol do
        if ci ~= wrapCi then widths[ci] = naturals[ci]; used = used + naturals[ci] end
    end
    widths[wrapCi] = math.max(6, w - used)
    return widths, wrapCi
end

-- height (in lines) a single data row will occupy once laid out
local function rowHeight(columns, dataRow, widths, wrapCi)
    if not wrapCi then return 1 end
    return #wrapText(dataRow[wrapCi] or "", widths[wrapCi])
end

-- render a dynamic-width table with height-based pagination.
--   columns: { { header=, align="left"|"right", wrap=bool, color=fn(cell,row)->col } }
--   rows:    list of tables with keys 1..ncol (plus any "_" extras for color fns)
-- updates app.page[viewIdx] / ui.pages[viewIdx].
local function drawTable(x, y, w, bodyH, columns, rows, viewIdx)
    local ncol = #columns
    local gutter = 2
    local widths, wrapCi = computeWidths(columns, rows, w)

    -- column left x positions
    local cx = {}
    local acc = x
    for ci = 1, ncol do cx[ci] = acc; acc = acc + widths[ci] + gutter end

    -- header row + underline
    for ci, col in ipairs(columns) do
        if col.align == "right" then
            writeRight(cx[ci] + widths[ci] - 1, y, col.header, THEME.dim)
        else
            writeAt(cx[ci], y, col.header, THEME.dim)
        end
    end
    fillRow(x, y + 1, w, THEME.faint)

    local bodyStart = y + 2
    local budget = bodyH - 2                              -- body lines available
    if budget < 1 then
        app.page[viewIdx] = 1; ui.pages[viewIdx] = 1; return
    end

    -- paginate by accumulated row heights
    local pages, cur, starts = 1, 0, { 1 }
    for i, dataRow in ipairs(rows) do
        local rh = rowHeight(columns, dataRow, widths, wrapCi)
        if cur > 0 and cur + rh > budget then
            pages = pages + 1; starts[pages] = i; cur = rh
        else
            cur = cur + rh
        end
    end
    app.page[viewIdx] = clamp(app.page[viewIdx] or 1, 1, pages)
    ui.pages[viewIdx] = pages

    local page = app.page[viewIdx]
    local startIdx = starts[page]
    local stopIdx  = (page < pages) and (starts[page + 1] - 1) or #rows

    local row = bodyStart
    for i = startIdx, stopIdx do
        if row > y + bodyH - 1 then break end
        local dataRow = rows[i]
        local rh = rowHeight(columns, dataRow, widths, wrapCi)
        for ci = 1, ncol do
            local col = columns[ci]
            local fg = (col.color and col.color(dataRow[ci], dataRow)) or THEME.text
            local lines = (ci == wrapCi)
                and wrapText(dataRow[ci] or "", widths[ci])
                or  { dataRow[ci] or "" }
            for li = 1, #lines do
                local yy = row + li - 1
                if yy > y + bodyH - 1 then break end
                if col.align == "right" then
                    writeRight(cx[ci] + widths[ci] - 1, yy, lines[li], fg)
                else
                    writeAt(cx[ci], yy, lines[li], fg)
                end
            end
        end
        row = row + rh
    end
end

--===========================================================================
-- COLONY DATA LAYER
--===========================================================================
local Colony = { data = nil, ok = true, err = "", integrator = nil, lastPoll = 0 }

-- find the colony integrator peripheral on 1.21.1 (colony_integrator) or older
local function findColony()
    if CONFIG.colonySide then return peripheral.wrap(CONFIG.colonySide) end
    local found = peripheral.find("colony_integrator")
    if found then return found end
    found = peripheral.find("colonyIntegrator")  -- pre-1.21.1 name, just in case
    if found then return found end
    -- last resort: scan everything by type
    for _, name in ipairs(peripheral.getNames()) do
        local ok, ptype = pcall(peripheral.getType, name)
        if ok and (ptype == "colony_integrator" or ptype == "colonyIntegrator") then
            return peripheral.wrap(name)
        end
    end
    return nil
end

-- safe call: returns result or nil on error
local function safe(fn, ...)
    local results = { pcall(fn, ...) }
    if results[1] then return unpack(results, 2) end
    return nil
end

local function asTable(v)  -- never return nil to a range-for
    if type(v) == "table" then return v end
    return {}
end

function Colony.init()
    Colony.integrator = findColony()
    if not Colony.integrator then
        Colony.ok, Colony.err = false, "No colony integrator found"
        return false
    end
    return true
end

-- poll every method; on any hard error, keep the last good data and flag stale
function Colony.refresh()
    if not Colony.integrator then return end
    local it = Colony.integrator
    local d = {}
    local prev = Colony.data

    d.id          = safe(it.getColonyID)
    d.happiness   = safe(it.getHappiness)
    d.citizens    = safe(it.amountOfCitizens)
    d.maxCitizens = safe(it.maxOfCitizens)
    d.underAttack = safe(it.isUnderAttack)
    d.citizenList = asTable(safe(it.getCitizens))
    d.buildings   = asTable(safe(it.getBuildings))
    d.requests    = asTable(safe(it.getRequests))
    d.visitors    = asTable(safe(it.getVisitors))
    d.research    = safe(it.getResearch)

    -- if a critical field failed, keep previous data + mark stale
    if d.id == nil and prev then
        Colony.data, Colony.ok, Colony.err = prev, false, "stale"
        return
    end
    Colony.data, Colony.ok, Colony.err = d, true, ""
    Colony.lastPoll = os.clock()
end

-- derived helpers ---------------------------------------------------------
function Colony.citizenRatio()
    local d = Colony.data
    if not d or not d.maxCitizens or d.maxCitizens == 0 then return 0 end
    return (d.citizens or 0) / d.maxCitizens
end

function Colony.happinessRatio()
    local d = Colony.data
    if not d or not d.happiness then return 0 end
    return clamp(d.happiness / 10, 0, 1)   -- MineColonies happiness ~ 0..10
end

-- idle / hungry / sleeping counts from the citizen list
function Colony.citizenFlags()
    local idle, hungry, asleep, children, adults = 0, 0, 0, 0, 0
    for _, c in ipairs(asTable(Colony.data and Colony.data.citizenList)) do
        if c.isIdle then idle = idle + 1 end
        if c.betterFood then hungry = hungry + 1 end
        if c.isAsleep then asleep = asleep + 1 end
        if c.age == "child" then children = children + 1 else adults = adults + 1 end
    end
    return { idle = idle, hungry = hungry, asleep = asleep,
             children = children, adults = adults }
end

--===========================================================================
-- RESEARCH TREE  ·  flatten into a labelled, depth-tagged list
--===========================================================================
local function researchState(node)
    local p = tonumber(node.progress) or 0
    if p >= 1 then return "done" end
    if p > 0 then return "prog" end
    -- status enum is undocumented/variable; treat anything not started as
    -- "available" (requirements may still gate it in-game)
    return "avail"
end

local function flattenResearch(research)
    local rows, idx = {}, 1
    local function add(branch, node, depth)
        if type(node) ~= "table" or not node.name then return end
        rows[idx] = { branch = branch, depth = depth, node = node }
        idx = idx + 1
        for _, child in ipairs(asTable(node.children)) do
            add(branch, child, depth + 1)
        end
    end
    -- research root = { branchName = { node, node, ... } }
    for branch, nodes in pairs(asTable(research)) do
        if type(nodes) == "table" then
            -- nodes might be an array of nodes, or a single node with children
            if nodes.name then
                add(branch, nodes, 0)
            else
                for _, node in ipairs(nodes) do add(branch, node, 0) end
            end
        end
    end
    table.sort(rows, function(a, b)
        if a.branch ~= b.branch then return a.branch < b.branch end
        return false
    end)
    return rows
end

--===========================================================================
-- APP STATE  ·  view selection + per-view pagination
--===========================================================================
local VIEWS = {
    { key = "dashboard", name = "DASHBOARD" },
    { key = "buildings", name = "BUILDINGS" },
    { key = "citizens",  name = "CITIZENS"  },
    { key = "research",  name = "RESEARCH"  },
}
app = { view = 1, page = { 1, 1, 1, 1 } }  -- current view + page per view

-- hit-test rectangles captured during the last render, for touch handling
ui = { tabs = {}, prev = nil, next = nil, pages = {} }

--===========================================================================
-- SHARED CHROME  ·  title bar, tab bar, footer
--===========================================================================
local function clock()
    local t = os.time()
    local h = math.floor(t) % 24
    local m = math.floor((t - math.floor(t)) * 60)
    return string.format("%02d:%02d", h, m)
end

local function drawTitleBar()
    local accent = THEME.viewAccent[app.view] or THEME.accent
    fillRow(1, 1, W, accent)
    local d = Colony.data
    local name = CONFIG.colonyName or (d and ("Colony #" .. tostring(d.id or "?"))) or "No Colony"
    writeAt(2, 1, "MINECOLONIES  " .. string.upper(name), colors.white, accent)
    -- connection LED + clock on the right
    local right = clock()
    if Colony.ok then
        right = right .. "  ONLINE"
    else
        right = right .. "  OFFLINE"
    end
    writeRight(W - 1, 1, right, colors.white, accent)
end

local function drawTabBar()
    local y = 2
    local n = #VIEWS
    local tabW = math.floor(W / n)
    ui.tabs = {}
    local x = 1
    for i, v in ipairs(VIEWS) do
        local w = (i == n) and (W - x + 1) or tabW   -- last tab absorbs remainder
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

-- footer: refresh ticker + pagination control (returns body top/bottom bounds)
local function drawFooter(pageText)
    local y = H
    fillRow(1, y, W, THEME.faint)
    writeAt(2, y, "refresh " .. CONFIG.refreshInterval .. "s", THEME.dim, THEME.faint)
    if pageText then
        writeAt(math.floor((W - #pageText) / 2) + 1, y, pageText, THEME.dim, THEME.faint)
    end
    writeRight(W - 1, y, "touch tabs / arrows", THEME.dim, THEME.faint)
end

--===========================================================================
-- VIEW 1  ·  DASHBOARD
--===========================================================================
local function viewDashboard(bodyY)
    local d = Colony.data
    if not d then return end

    -- top stat cards row --------------------------------------------------
    local cardGap = 1
    local n = 4
    local cw = math.floor((W - (n + 1) * cardGap) / n)
    local bx = 2
    local by = bodyY

    -- helper to render a stat card
    local function statCard(x, label, big, sub, accent)
        card(x, by, cw, 1, 2, label, accent)
        writeAt(x + 1, by + 1, big, THEME.text)
        if sub then writeAt(x + 1, by + 2, sub, THEME.dim) end
    end

    statCard(bx, "CITIZENS", tostring(d.citizens or 0) .. "/" .. tostring(d.maxCitizens or 0),
        string.format("%.0f%% capacity", Colony.citizenRatio() * 100), colors.lime)
    statCard(bx + (cw + cardGap), "HAPPINESS", string.format("%.1f", d.happiness or 0),
        string.format("%.0f%%", Colony.happinessRatio() * 100), colors.cyan)
    statCard(bx + (cw + cardGap) * 2, "BUILDINGS", tostring(#d.buildings),
        "structures", colors.yellow)
    statCard(bx + (cw + cardGap) * 3, "VISITORS", tostring(#d.visitors),
        "in tavern", colors.purple)

    -- thin gauge strip: citizen capacity + happiness ---------------------
    local gy = by + 3
    local half = math.floor((W - 2) / 2)
    writeAt(2, gy, "CAP", THEME.dim)
    gauge(6, gy, math.max(4, half - 5), Colony.citizenRatio(),
        ratioColour(Colony.citizenRatio()), THEME.faint)
    local hx = 2 + half + 1
    writeAt(hx, gy, "MOOD", THEME.dim)
    gauge(hx + 5, gy, math.max(4, W - (hx + 5) - 1), Colony.happinessRatio(),
        ratioColour(Colony.happinessRatio()), THEME.faint)

    -- alerts + citizen-status row ----------------------------------------
    local midY = by + 4
    local flags = Colony.citizenFlags()
    local leftW = math.floor(W * 0.4) - 2
    local rightX = leftW + 4
    local rightW = W - rightX - 1

    -- ALERTS card
    local _, ay, iw, ih = card(2, midY, leftW, 1, 5, "ALERTS", colors.red)
    local row = ay
    local function alertLine(state, text)
        if row > ay + ih - 1 then return end
        led(3, row, nil, state)               -- LED at the card's inner left (x=3)
        writeAt(5, row, text, THEME.text)
        row = row + 1
    end
    if d.underAttack then
        alertLine("bad", "COLONY UNDER ATTACK!")
    else
        alertLine("good", "No hostiles detected")
    end
    if flags.hungry > 0 then
        alertLine("warn", flags.hungry .. " citizens need better food")
    end
    if flags.idle > 0 then
        alertLine("warn", flags.idle .. " citizens idle")
    else
        alertLine("good", "All citizens working")
    end
    if Colony.happinessRatio() < 0.5 then
        alertLine("bad", "Happiness is critically low")
    end

    -- CITIZEN STATUS card
    local _, cy, cw2, ch2 = card(rightX, midY, rightW, 1, 5, "CITIZEN STATUS", colors.lightBlue)
    row = cy
    local function statusLine(label, val, col)
        writeAt(rightX + 1, row, label, THEME.dim)
        writeRight(rightX + rightW - 2, row, val, col or THEME.text)
        row = row + 1
    end
    statusLine("Adults",     tostring(flags.adults))
    statusLine("Children",   tostring(flags.children))
    statusLine("Asleep",     tostring(flags.asleep))
    statusLine("Idle",       tostring(flags.idle), flags.idle > 0 and THEME.warn)
    statusLine("Need food",  tostring(flags.hungry), flags.hungry > 0 and THEME.bad)

    -- REQUESTS card (fills the bottom) -----------------------------------
    local reqY = midY + 7
    local reqH = H - 1 - reqY
    if reqH < 2 then reqH = 2 end
    local _, ry, rw, rh = card(2, reqY, W - 2, 1, reqH, "ACTIVE REQUESTS", colors.orange,
        #d.requests .. " total")
    row = ry
    if #d.requests == 0 then
        writeAt(3, row, "No outstanding requests", THEME.dim)
    else
        for i = 1, math.min(#d.requests, rh) do
            local r = d.requests[i]
            if not r then break end
            local st = string.lower(r.state or "")
            local stateCol = (st == "completed" or st == "resolved") and THEME.good
                         or (st == "inprogress" or st == "in progress") and THEME.warn
                         or THEME.info
            local nm = humanize(tostring(r.name or r.target or "?"))
            local need = tostring(r.count or "?")
            if r.minCount and r.minCount ~= r.count then
                need = need .. "/" .. tostring(r.minCount)
            end
            -- name fills the space between x=3 and the right-aligned count
            local nameMax = (W - 1) - 3 - #need - 1
            if nameMax > 0 and #nm > nameMax then nm = nm:sub(1, nameMax) end
            writeAt(3, row, nm, THEME.text)
            writeRight(W - 1, row, need, stateCol)
            row = row + 1
        end
    end
end

--===========================================================================
-- VIEW 2  ·  BUILDINGS
--===========================================================================
local function viewBuildings(bodyY)
    local d = Colony.data
    if not d then return end
    local list = d.buildings
    local tableW = W - 2
    local tableH = H - bodyY - 1

    local columns = {
        { header = "BUILDING", align = "left",  wrap = true,
          color = function() return THEME.text end },
        { header = "TYPE",     align = "left",  wrap = false,
          color = function() return THEME.dim end },
        { header = "LEVEL",    align = "right", wrap = false,
          color = function(_, r) return ratioColour(r._ratio) end },
        { header = "STATUS",   align = "right", wrap = false,
          color = function(_, r) return r._stCol end },
    }
    local rows = {}
    for _, b in ipairs(list) do
        local lvl = tonumber(b.level) or 0
        local maxL = tonumber(b.maxLevel) or 1
        if maxL < 1 then maxL = 1 end
        local stTxt, stCol
        if b.isWorkingOn then stTxt, stCol = "BUILDING", THEME.warn
        elseif not b.built then stTxt, stCol = "RUIN", THEME.bad
        else stTxt, stCol = "OK", THEME.good end
        if b.guarded then stTxt = stTxt .. " (G)" end
        table.insert(rows, {
            humanize(b.name),
            humanize(b.type),
            string.format("%d/%d", lvl, maxL),
            stTxt,
            _ratio = lvl / maxL,
            _stCol = stCol,
        })
    end
    drawTable(2, bodyY, tableW, tableH, columns, rows, 2)
    if #list == 0 then
        writeAt(3, bodyY + 2, "No buildings found", THEME.dim)
    end
end

--===========================================================================
-- VIEW 3  ·  CITIZENS
--===========================================================================
local function viewCitizens(bodyY)
    local d = Colony.data
    if not d then return end
    local list = d.citizenList
    local tableW = W - 2
    local tableH = H - bodyY - 1

    local columns = {
        { header = "CITIZEN", align = "left",  wrap = true,
          color = function() return THEME.text end },
        { header = "JOB",     align = "left",  wrap = false,
          color = function() return THEME.dim end },
        { header = "STATE",   align = "left",  wrap = false,
          color = function(_, r) return r._stCol end },
        { header = "MOOD",    align = "right", wrap = false,
          color = function(_, r) return ratioColour((r._mood or 0) / 10) end },
        { header = "FOOD",    align = "right", wrap = false,
          color = function(_, r) return r._foodCol end },
    }
    local rows = {}
    for _, c in ipairs(list) do
        local job = (c.work and c.work.job) or "—"
        local mood = tonumber(c.happiness) or 0
        local food = tonumber(c.saturation) or 0
        local foodCol = food < 3 and THEME.bad or (food < 6 and THEME.warn or THEME.good)
        table.insert(rows, {
            c.name or "?",
            humanize(job),
            humanize(c.state or "—"),
            string.format("%.1f", mood),
            string.format("%.1f", food),
            _stCol = c.isIdle and THEME.warn or THEME.info,
            _mood = mood,
            _foodCol = foodCol,
        })
    end
    drawTable(2, bodyY, tableW, tableH, columns, rows, 3)
    if #list == 0 then
        writeAt(3, bodyY + 2, "No citizens found", THEME.dim)
    end
end

--===========================================================================
-- VIEW 4  ·  RESEARCH
--===========================================================================
local function viewResearch(bodyY)
    local d = Colony.data
    if not d then return end
    local rows = flattenResearch(d.research)
    if #rows == 0 then
        writeAt(3, bodyY, "No research data available", THEME.dim)
        ui.pages[4] = 1
        return
    end

    -- legend
    writeAt(2, bodyY, "STATUS", THEME.dim)
    local lx = 9
    local legend = { { "done", "Done", THEME.good }, { "prog", "In Progress", THEME.warn },
                     { "avail", "Available", THEME.info } }
    for _, g in ipairs(legend) do
        led(lx, bodyY, nil, g[1])
        writeAt(lx + 1, bodyY, g[2], THEME.dim)
        lx = lx + #g[2] + 3
    end
    fillRow(2, bodyY + 1, W - 2, THEME.faint)

    local rowsAvail = H - bodyY - 3
    local perPage = math.max(1, rowsAvail)
    local pages = math.max(1, math.ceil(#rows / perPage))
    app.page[4] = clamp(app.page[4], 1, pages)
    ui.pages[4] = pages

    local start = (app.page[4] - 1) * perPage
    local row = bodyY + 2
    local curBranch = nil
    for i = start + 1, math.min(#rows, start + perPage) do
        if row > H - 1 then break end
        local r = rows[i]
        local node = r.node
        -- branch header when the branch changes
        if r.branch ~= curBranch then
            curBranch = r.branch
            writeAt(2, row, string.upper(humanize(tostring(curBranch))), THEME.accent)
            row = row + 1
            if row > H - 1 then break end
        end
        local indent = 2 + r.depth * 2
        local st = researchState(node)
        led(indent, row, nil, st)
        local nm = humanize(node.name or "?")
        -- leave room for the right-aligned progress column; clean clip, no "~"
        local avail = W - indent - 12
        if avail > 0 and #nm > avail then nm = nm:sub(1, avail) end
        writeAt(indent + 1, row, nm, st == "done" and THEME.dim or THEME.text)
        -- progress %
        local p = tonumber(node.progress) or 0
        local pTxt = string.format("%3d%%", math.floor(p * 100))
        writeRight(W - 1, row, pTxt, st == "done" and THEME.good or THEME.dim)
        row = row + 1
    end
end

--===========================================================================
-- RENDER DISPATCH
--===========================================================================
local function render()
    W, H = term.getSize()
    clearScreen()
    drawTitleBar()
    drawTabBar()
    local bodyY = 4

    local d = Colony.data
    if not Colony.integrator then
        writeAt(3, bodyY, "ERROR: " .. (Colony.err or "no colony integrator"), THEME.bad)
        writeAt(3, bodyY + 2, "Place a Colony Integrator from Advanced Peripherals", THEME.dim)
        writeAt(3, bodyY + 3, "next to a MineColonies Town Hall, then restart.", THEME.dim)
        drawFooter()
        return
    end
    if not d then
        writeAt(3, bodyY, "Connecting to colony...", THEME.dim)
        drawFooter()
        return
    end

    if app.view == 1 then viewDashboard(bodyY)
    elseif app.view == 2 then viewBuildings(bodyY)
    elseif app.view == 3 then viewCitizens(bodyY)
    elseif app.view == 4 then viewResearch(bodyY) end

    -- pagination footer text, computed AFTER the view populated ui.pages[view]
    local pages = ui.pages[app.view] or 1
    local pageText
    if pages > 1 then
        pageText = string.format("[ page %d / %d ]   < > to navigate", app.page[app.view], pages)
    end
    drawFooter(pageText)
end

--===========================================================================
-- INPUT HANDLING
--===========================================================================
local function selectView(i)
    if i >= 1 and i <= #VIEWS then
        app.view = i
    end
end

local function onPage(dir)
    local p = app.page[app.view] + dir
    local maxP = ui.pages[app.view] or 1
    app.page[app.view] = clamp(p, 1, maxP)
end

local function handleTouch(side, x, y)
    -- tab bar hits
    for i, t in ipairs(ui.tabs) do
        if y == t.y and x >= t.x1 and x <= t.x2 then selectView(i); return end
    end
    -- footer pagination (prev/next on the bottom corners)
    if y == H then
        if x <= 3 then onPage(-1)
        elseif x >= W - 3 then onPage(1) end
        return
    end
end

local function handleKey(k)
    if k == keys.right then selectView(app.view % #VIEWS + 1)
    elseif k == keys.left then selectView((app.view - 2) % #VIEWS + 1)
    elseif k == keys.up or k == keys.pageUp then onPage(-1)
    elseif k == keys.down or k == keys.pageDown then onPage(1)
    elseif k == keys.one then selectView(1)
    elseif k == keys.two then selectView(2)
    elseif k == keys.three then selectView(3)
    elseif k == keys.four then selectView(4)
    end
end

--===========================================================================
-- MONITOR / TERMINAL SETUP
--===========================================================================
local function findMonitor()
    if CONFIG.monitorSide then return peripheral.wrap(CONFIG.monitorSide) end
    return peripheral.find("monitor")
end

--===========================================================================
-- MAIN
--===========================================================================
local function main()
    local mon = findMonitor()
    if not mon then
        -- fall back to the computer screen with a helpful message
        print("Colony Monitor: no monitor found.")
        print("Attach an Advanced Monitor (touch-capable) and run again.")
        print("You can also set CONFIG.monitorSide to a side / network name.")
        return
    end
    mon.setTextScale(CONFIG.textScale)
    term.redirect(mon)

    Colony.init()

    -- initial poll + draw
    Colony.refresh()
    render()

    local timer = os.startTimer(CONFIG.refreshInterval)
    while true do
        local event = { os.pullEvent() }
        local e = event[1]
        if e == "timer" and event[2] == timer then
            Colony.refresh()
            render()
            timer = os.startTimer(CONFIG.refreshInterval)
        elseif e == "monitor_touch" then
            handleTouch(event[2], event[3], event[4])
            render()
        elseif e == "key" then
            handleKey(event[2])
            render()
        elseif e == "char" then
            local n = tonumber(event[2])
            if n and n >= 1 and n <= #VIEWS then selectView(n); render() end
        elseif e == "monitor_resize" then
            W, H = term.getSize()
            render()
        elseif e == "terminate" then
            break
        end
    end

    -- tidy up the screen on exit
    term.redirect(term.native())
    term.setTextColor(colors.white)
    term.setBackgroundColor(colors.black)
    term.clear()
    term.setCursorPos(1, 1)
    print("Colony Monitor stopped.")
end

main()
