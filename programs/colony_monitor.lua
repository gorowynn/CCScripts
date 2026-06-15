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
    colonyName        = nil,    -- optional friendly name; defaults to "Colony #ID"
    buildingBlacklist = { "stash", "postbox" },  -- hide these from the Buildings view (substring match on name/type)
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
-- TOOL / ARMOR TIER DETECTION
-- MineColonies tool/armor requests accept a range of material tiers. The
-- request's `items` list holds each acceptable variant (e.g. iron_pickaxe,
-- diamond_pickaxe). Parse the material from each registry name and return the
-- min-max level range, or nil if this isn't a tool/armor request.
--   Wood/Gold=1  Stone=2  Iron=3  Diamond=4  Netherite=5
local asTable, humanize  -- forward declarations (defined later); tierInfo needs them
local TOOL_TIERS = {
    wood = 1, wooden = 1, golden = 1, gold = 1,
    stone = 2, iron = 3, chain = 3, chainmail = 3,
    diamond = 4, netherite = 5,
}
-- human-readable material name per registry material key (for tier display)
local MAT_NAMES = {
    wood = "Wood", wooden = "Wood", golden = "Gold", gold = "Gold",
    stone = "Stone", iron = "Iron", chain = "Chain", chainmail = "Chain",
    diamond = "Diamond", netherite = "Netherite",
}
local TOOL_TYPES = {
    pickaxe = true, axe = true, shovel = true, hoe = true, sword = true,
    helmet = true, chestplate = true, leggings = true, boots = true,
    shield = true, bow = true, crossbow = true, fishing_rod = true,
    shears = true, flint_and_steel = true,
}
local function tierInfo(items)
    local minT, maxT, minName, maxName, tname
    for _, it in ipairs(asTable(items)) do
        local reg = tostring(it.name or "")
        -- strip namespace:  "minecraft:iron_pickaxe" -> "iron_pickaxe"
        reg = reg:gsub("^[%w_]+:", "")
        local mat, kind = reg:match("^(%a+)_(%a[%w_]*)$")
        if mat and kind and TOOL_TYPES[kind] then
            local tier = TOOL_TIERS[mat]
            if tier then
                tname = tname or kind
                local dname = MAT_NAMES[mat] or humanize(mat)
                if minT == nil or tier < minT then minT, minName = tier, dname end
                if maxT == nil or tier > maxT then maxT, maxName = tier, dname end
            end
        end
    end
    if minT == nil then return nil end
    return { min = minT, max = maxT, minName = minName, maxName = maxName,
             kind = tname or "tool" }
end

--===========================================================================

-- Turn a raw registry/package name into something readable.
--   "com.minecolonies.buildings.GuardTower" -> "Guard Tower"
--   "minecolonies:guard_tower"              -> "Guard Tower"
-- Already-readable strings (no "." or ":") are returned untouched.
function humanize(s)
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
        if col.type == "bar" then
            -- fixed width: bar cells + 1 gap + 4-char percentage (e.g. "100%")
            naturals[ci] = math.max(#col.header, (col.barW or 4) + 5)
        else
            local nw = #col.header
            for _, row in ipairs(rows) do
                local c = row[ci] or ""
                if #c > nw then nw = #c end
            end
            naturals[ci] = nw
        end
    end
    -- base widths start at the natural (max-content) size
    local widths = {}
    for ci = 1, ncol do widths[ci] = naturals[ci] end

    if wrapCi then
        -- the wrap column absorbs ALL slack (and shrinks on overflow), so the
        -- table always fills exactly `w` columns.
        local used = gutter * (ncol - 1)
        for ci = 1, ncol do
            if ci ~= wrapCi then used = used + naturals[ci] end
        end
        widths[wrapCi] = math.max(6, w - used)
        return widths, wrapCi
    end

    -- no wrap column: spread any slack evenly so we still fill the whole width
    local totalNat = gutter * (ncol - 1)
    for ci = 1, ncol do totalNat = totalNat + naturals[ci] end
    if totalNat >= w or ncol == 0 then return widths, nil end
    local slack, per = w - totalNat, math.floor((w - totalNat) / ncol)
    for ci = 1, ncol do widths[ci] = naturals[ci] + per end
    widths[ncol] = widths[ncol] + (slack - per * ncol)   -- remainder to last col
    return widths, nil
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
            if col.type == "bar" then
                -- cell holds a 0..1 ratio; draw a coloured gauge + percentage
                local ratio = clamp(tonumber(dataRow[ci]) or 0, 0, 1)
                local fg = (col.color and col.color(ratio, dataRow)) or THEME.good
                local bw = col.barW or 4
                if row <= y + bodyH - 1 then
                    gauge(cx[ci], row, bw, ratio, fg, THEME.faint)
                    writeAt(cx[ci] + bw + 1, row, string.format("%3d%%", math.floor(ratio * 100)), fg)
                end
            else
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

function asTable(v)  -- never return nil to a range-for
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
app = { view = 1, page = { 1, 1, 1, 1 }, pan = { x = 0, y = 0 } }  -- view, per-view page, research pan

-- hit-test rectangles captured during the last render, for touch handling
ui = { tabs = {}, prev = nil, next = nil, pages = {}, body = nil, research = nil, footer = nil }

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

-- footer: touch-driven < / > nav buttons (left/right halves) + centered info.
-- ctrl = { hasPrev=bool, hasNext=bool, center=function(y) ... end }
local function drawFooter(ctrl)
    local y = H
    fillRow(1, y, W, THEME.faint)
    writeAt(2, y, "<", ctrl.hasPrev and THEME.accent or THEME.faint, THEME.faint)
    writeAt(W - 1, y, ">", ctrl.hasNext and THEME.accent or THEME.faint, THEME.faint)
    if ctrl.center then ctrl.center(y) end
end

--===========================================================================
-- VIEW 1  ·  DASHBOARD
--===========================================================================
local function viewDashboard(bodyY)
    local d = Colony.data
    if not d then return end
    local flags = Colony.citizenFlags()

    -- ===== LAYOUT: left vital rail  |  right (alerts + requests) =====
    local railW  = math.max(14, math.floor(W * 0.35))
    if railW > W - 24 then railW = W - 24 end        -- keep the right side usable
    local railX  = 2
    local rightX = railX + railW + 1                  -- 1-col gutter between rail and right
    local rightW = W - rightX - 1
    local innerX = rightX + 1                         -- inner content origin for the right column
    local innerW = rightW - 2

    -- job map for resolving request sources to "Name (Job)"
    local jobByName = {}
    for _, c in ipairs(asTable(d.citizenList)) do
        local jn = c.work and c.work.job
        if c.name and jn then jobByName[tostring(c.name):lower()] = humanize(jn) end
    end
    local function resolveSource(raw)
        local name = tostring(raw or "Unknown")
        if name == "" then name = "Unknown" end
        local h = humanize(name)
        local job = jobByName[name:lower()]
        if job then return h .. " (" .. job .. ")" end
        return h
    end

    -- ============ LEFT RAIL — stacked vital cards ============
    local function railNext(y, h, b) return y + h + b + 1 end

    -- CITIZENS: count + capacity gauge
    local ry = bodyY
    local _, cy1 = card(railX, ry, railW, 1, 2, "CITIZENS", colors.lime,
        string.format("%.0f%%", Colony.citizenRatio() * 100))
    writeAt(railX + 1, cy1, tostring(d.citizens or 0) .. " / " .. tostring(d.maxCitizens or 0), THEME.text)
    gauge(railX + 1, cy1 + 1, railW - 2, Colony.citizenRatio(),
        ratioColour(Colony.citizenRatio()), THEME.faint)
    ry = railNext(ry, 1, 2)

    -- HAPPINESS: value + mood gauge
    local _, hy1 = card(railX, ry, railW, 1, 2, "HAPPINESS", colors.cyan,
        string.format("%.1f", d.happiness or 0))
    gauge(railX + 1, hy1, railW - 2, Colony.happinessRatio(),
        ratioColour(Colony.happinessRatio()), THEME.faint)
    writeRight(railX + railW - 2, hy1, string.format("%.0f%%", Colony.happinessRatio() * 100), THEME.dim)
    ry = railNext(ry, 1, 2)

    -- CITIZEN STATUS breakdown
    local _, sy1 = card(railX, ry, railW, 1, 4, "CITIZEN STATUS", colors.lightBlue)
    local srow = sy1
    local function sline(label, val, col)
        writeAt(railX + 1, srow, label, THEME.dim)
        writeRight(railX + railW - 2, srow, val, col or THEME.text)
        srow = srow + 1
    end
    sline("Adults",   tostring(flags.adults))
    sline("Children", tostring(flags.children))
    sline("Idle",     tostring(flags.idle),   flags.idle > 0 and THEME.warn)
    sline("Hungry",   tostring(flags.hungry), flags.hungry > 0 and THEME.bad)
    ry = railNext(ry, 1, 4)

    -- VISITORS: recruitment opportunity
    if ry < H - 1 then
        local vList = asTable(d.visitors)
        local vbodyH = (#vList > 0) and 2 or 1
        local _, vy1 = card(railX, ry, railW, 1, vbodyH, "VISITORS", colors.purple)
        if #vList == 0 then
            writeAt(railX + 1, vy1, "None in tavern", THEME.dim)
        else
            writeAt(railX + 1, vy1, #vList .. " available", THEME.text)
            -- first visitor's recruit cost (compact, up to 2 items)
            local costTxt = "free"
            local cost = vList[1].recruitCost
            if type(cost) == "table" then
                local parts = {}
                for i, it in ipairs(cost) do
                    if i > 2 then break end
                    parts[#parts + 1] = tostring(it.count or "?") .. " "
                        .. humanize(it.displayName or it.name or "?")
                end
                if #parts > 0 then costTxt = table.concat(parts, ", ") end
            end
            local cl = "cost: " .. costTxt
            if #cl > railW - 2 then cl = cl:sub(1, railW - 2) end
            writeAt(railX + 1, vy1 + 1, cl, THEME.dim)
        end
    end

    -- ============ RIGHT — ALERTS banner ============
    local alertBodyH = 4
    local _, alY, _, alH = card(rightX, bodyY, rightW, 1, alertBodyH, "ALERTS", colors.red)
    local arow = alY
    local aMax = alY + alH - 1
    local function alertLine(state, text)
        if arow > aMax then return end
        local col = state == "bad" and THEME.bad
                 or state == "warn" and THEME.warn
                 or THEME.good
        fillRow(rightX + 1, arow, rightW - 2, col)            -- full-width coloured bar
        local t = text
        if #t > innerW then t = t:sub(1, innerW) end
        writeAt(innerX, arow, t, colors.black, col)          -- black text on solid bg
        arow = arow + 1
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

    -- ============ RIGHT — ACTIVE REQUESTS (fills the rest) ============
    local reqY = bodyY + 1 + alertBodyH + 1               -- below the alerts card
    local reqH = H - 1 - reqY
    if reqH < 2 then reqH = 2 end

    -- group requests by source
    local order, bySrc = {}, {}
    for _, r in ipairs(d.requests) do
        local src = resolveSource(r.target)
        if src == "" then src = "Unknown" end
        if not bySrc[src] then bySrc[src] = {}; order[#order + 1] = src end
        bySrc[src][#bySrc[src] + 1] = r
    end
    local reqLabel = #d.requests .. " req"
    if #order > 1 then reqLabel = reqLabel .. "  " .. #order .. " src" end

    local _, rqY, _, rqH = card(rightX, reqY, rightW, 1, reqH, "ACTIVE REQUESTS", colors.orange,
        reqLabel)
    local row = rqY
    if #d.requests == 0 then
        writeAt(innerX, row, "No outstanding requests", THEME.dim)
    else
        local maxRow = rqY + rqH - 1
        -- classify a request's state into a tag + colour.
        -- MineColonies' state enum is undocumented, so we do NOT guess buckets:
        -- the tag shows the ACTUAL raw state (humanized), coloured by any stem
        -- we recognise. This means you always see the real status string.
        local function classify(r)
            local raw = tostring(r.state or "")
            local low = raw:lower()
            local stem = low:gsub("[%s_]+", "")        -- "in progress" -> "inprogress"
            local col
            if stem == "completed" or stem == "resolved" or stem == "done" then
                col = THEME.good
            elseif stem:find("deliver") then
                col = THEME.accent
            elseif stem:find("progress") or stem:find("claim") or stem:find("craft") then
                col = THEME.warn
            elseif stem == "" or stem == "open" then
                col = THEME.bad
            else
                col = THEME.info                       -- unknown -> visible, not hidden
            end
            -- humanize the raw state for the tag, e.g. "IN_PROGRESS" -> "In Progress"
            local tag = humanize(low:gsub("_", " "))
            tag = tag:gsub("(%a)(%w*)", function(a, rest)  -- Title Case each word
                return a:upper() .. rest:lower()
            end)
            if #tag > 12 then tag = tag:sub(1, 12) end   -- cap so it can't eat the item
            return tag, col
        end
        for _, src in ipairs(order) do
            -- need room for the source header + at least one item line
            if row > maxRow - 1 then
                if row <= maxRow then writeAt(innerX, row, "...more", THEME.dim) end
                break
            end
            local hdr = src .. "  (" .. #bySrc[src] .. ")"
            if #hdr > innerW then hdr = hdr:sub(1, innerW) end
            writeAt(innerX, row, hdr, THEME.accent)         -- source group header
            row = row + 1
            for _, r in ipairs(bySrc[src]) do
                if row > maxRow then break end
                local tag, tagCol = classify(r)
                local nm = humanize(tostring(r.name or "?"))
                local cnt = tonumber(r.count)
                local minc = tonumber(r.minCount)
                local qty
                if minc and cnt and minc ~= cnt then
                    qty = minc .. "-" .. cnt          -- range, e.g. 1-64
                elseif cnt then
                    qty = tostring(cnt)
                else
                    qty = "?"
                end
                local item = qty .. " " .. nm        -- e.g. "1-64 Pumpkin"
                -- for tool/armor requests, append the min-max tier range
                local ti = tierInfo(r.items)
                if ti then
                    local lv
                    if ti.min == ti.max then
                        lv = " (" .. ti.minName .. ")"
                    else
                        lv = " (" .. ti.minName .. "-" .. ti.maxName .. ")"
                    end
                    item = item .. lv
                end
                -- tag prefix in state colour, item text in default text colour
                local tagStr = "[" .. tag .. "] "
                local itemMax = innerW - #tagStr
                if itemMax > 0 and #item > itemMax then item = item:sub(1, itemMax) end
                writeAt(innerX, row, tagStr, tagCol)
                writeAt(innerX + #tagStr, row, item, THEME.text)
                row = row + 1
            end
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

    -- skip buildings whose name/type contains any blacklisted word
    local function blacklisted(b)
        local bl = CONFIG.buildingBlacklist
        if not bl or #bl == 0 then return false end
        local hay = (humanize(b.name) .. " " .. humanize(b.type) .. " "
                     .. tostring(b.name) .. " " .. tostring(b.type)):lower()
        for _, word in ipairs(bl) do
            word = tostring(word):lower()
            if #word > 0 and hay:find(word, 1, true) then return true end
        end
        return false
    end
    local shown = {}
    for _, b in ipairs(list) do
        if not blacklisted(b) then shown[#shown + 1] = b end
    end

    local columns = {
        { header = "BUILDING", align = "left",  wrap = true,
          color = function() return THEME.text end },
        { header = "COLONIST", align = "left",  wrap = false,
          color = function(_, r) return r._colonistCol end },
        { header = "LEVEL",    align = "right", wrap = false,
          color = function(_, r) return ratioColour(r._ratio) end },
        { header = "STATUS",   align = "right", wrap = false,
          color = function(_, r) return r._stCol end },
        { header = "GUARDED",  align = "right", wrap = false,
          color = function(_, r) return r._guardCol end },
    }
    local rows = {}
    for _, b in ipairs(shown) do
        local lvl = tonumber(b.level) or 0
        local maxL = tonumber(b.maxLevel) or 1
        if maxL < 1 then maxL = 1 end
        local stTxt, stCol
        if b.isWorkingOn then
            -- being worked on: first build, or an upgrade on an existing one
            if b.built then stTxt, stCol = "Upgrading", THEME.warn
            else stTxt, stCol = "Building", THEME.warn end
        elseif not b.built then
            -- not built and not being worked on
            stTxt, stCol = "Planned", THEME.dim
        else
            stTxt, stCol = "OK", THEME.good
        end
        -- building name, falling back to its type when the name is absent
        local bname = b.name
        if bname == nil or bname == "" then bname = b.type end
        -- assigned colonist(s): the API returns a list of {name, id}
        local cList = asTable(b.citizens)
        local colonist, colonistCol
        if #cList == 0 then
            colonist, colonistCol = "", THEME.dim
        else
            local first = cList[1].name or "?"
            if #cList == 1 then
                colonist = tostring(first)
            else
                colonist = tostring(first) .. " +" .. (#cList - 1)
            end
            colonistCol = THEME.text
        end
        table.insert(rows, {
            humanize(bname),
            colonist,
            string.format("%d/%d", lvl, maxL),
            stTxt,
            b.guarded and "Yes" or "",
            _ratio = lvl / maxL,
            _stCol = stCol,
            _colonistCol = colonistCol,
            _guardCol = b.guarded and THEME.good or THEME.dim,
        })
    end
    drawTable(2, bodyY, tableW, tableH, columns, rows, 2)
    if #shown == 0 then
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

    -- value ceilings used to turn raw stats into 0..1 ratios for the bars
    local MOOD_MAX, FOOD_MAX = 10, 20
    local columns = {
        { header = "CITIZEN", align = "left",  wrap = true,
          color = function() return THEME.text end },
        { header = "JOB",     align = "left",  wrap = false,
          color = function() return THEME.dim end },
        { header = "STATUS",  align = "left",  wrap = false,
          color = function(_, r) return r._statusCol end },
        { header = "HEALTH",  type = "bar", barW = 4,
          color = function(v) return ratioColour(v) end },
        { header = "MOOD",    type = "bar", barW = 4,
          color = function(v) return ratioColour(v) end },
        { header = "FOOD",    type = "bar", barW = 4,
          color = function(v) return ratioColour(v) end },
    }
    local rows = {}
    for _, c in ipairs(list) do
        local job = (c.work and c.work.job) or "Unemployed"
        local mood = tonumber(c.happiness) or 0
        local food = tonumber(c.saturation) or 0
        local hp = tonumber(c.health) or 0
        local hpMax = tonumber(c.maxHealth)
        if not hpMax or hpMax < 1 then hpMax = 20 end   -- sane default for citizens
        -- current status: idle / asleep / needs food / the raw state string
        local status, statusCol
        if c.isIdle then status, statusCol = "Idle", THEME.warn
        elseif c.isAsleep then status, statusCol = "Asleep", THEME.dim
        elseif c.betterFood then status, statusCol = "Hungry", THEME.bad
        else status, statusCol = humanize(tostring(c.state or "")), THEME.info end
        table.insert(rows, {
            c.name or "?",
            humanize(job),
            status,
            clamp(hp / hpMax, 0, 1),
            clamp(mood / MOOD_MAX, 0, 1),
            clamp(food / FOOD_MAX, 0, 1),
            _statusCol = statusCol,
        })
    end
    drawTable(2, bodyY, tableW, tableH, columns, rows, 3)
    if #list == 0 then
        writeAt(3, bodyY + 2, "No citizens found", THEME.dim)
    end
end

--===========================================================================
-- RESEARCH TREE  ·  box-drawing junctions + 2D node layout
--===========================================================================
local R_BOX_H, R_PAD, R_HGAP, R_VGAP = 3, 2, 4, 4   -- box height, text pad, h-gap, v-gap

-- map of (up/down/left/right connections) -> junction glyph
local JUNCTION = {}
do
    local function set(u, d, l, r, ch)
        JUNCTION[(u and 1 or 0) .. (d and 1 or 0) .. (l and 1 or 0) .. (r and 1 or 0)] = ch
    end
    set(true,  true,  true,  true,  "┼")
    set(true,  true,  true,  false, "┤")
    set(true,  true,  false, true,  "├")
    set(true,  false, true,  true,  "┴")
    set(false, true,  true,  true,  "┬")
    set(true,  true,  false, false, "│")
    set(false, false, true,  true,  "─")
    set(true,  false, false, true,  "└")
    set(true,  false, true,  false, "┘")
    set(false, true,  false, true,  "┌")
    set(false, true,  true,  false, "┐")
    set(true,  false, false, false, "│")
    set(false, true,  false, false, "│")
    set(false, false, false, true,  "─")
    set(false, false, true,  false, "─")
end
local function junctionChar(u, d, l, r)
    return JUNCTION[(u and 1 or 0) .. (d and 1 or 0) .. (l and 1 or 0) .. (r and 1 or 0)] or " "
end

-- lay out the research forest into positioned nodes within a virtual canvas.
-- returns branches (each: name, headerY, nodes[]) + canvas {w,h}
local function layoutResearch(research)
    local function makeNode(raw, depth)
        local n = {
            label = humanize(raw.name or "?"),
            depth = depth,
            status = researchState(raw),
            progress = tonumber(raw.progress) or 0,
            children = {},
        }
        n.bw = math.max(6, #n.label + R_PAD * 2)
        for _, ch in ipairs(asTable(raw.children)) do
            n.children[#n.children + 1] = makeNode(ch, depth + 1)
        end
        return n
    end
    local function subtreeW(n)
        if #n.children == 0 then n.sw = n.bw; return n.bw end
        local total = 0
        for _, c in ipairs(n.children) do total = total + subtreeW(c) + R_HGAP end
        n.sw = math.max(n.bw, total - R_HGAP)
        return n.sw
    end
    local function assignXY(n, left, top)
        n.x = left + math.floor((n.sw - n.bw) / 2)
        n.y = top
        local cl = left
        for _, c in ipairs(n.children) do
            assignXY(c, cl, top + R_BOX_H + R_VGAP)
            cl = cl + c.sw + R_HGAP
        end
    end
    local function gather(n, list)
        list[#list + 1] = n
        for _, c in ipairs(n.children) do gather(c, list) end
    end

    local names = {}
    for k in pairs(asTable(research)) do names[#names + 1] = k end
    table.sort(names)

    local branches, canvasW, canvasH, curY = {}, 1, 1, 0
    for _, bname in ipairs(names) do
        local rootsRaw = research[bname]
        local rawRoots = {}
        if type(rootsRaw) == "table" then
            if rootsRaw.name then rawRoots = { rootsRaw }
            else for _, r in ipairs(rootsRaw) do rawRoots[#rawRoots + 1] = r end end
        end
        local roots = {}
        for _, r in ipairs(rawRoots) do roots[#roots + 1] = makeNode(r, 0) end
        if #roots > 0 then
            for _, r in ipairs(roots) do subtreeW(r) end
            local forestW = 0
            for _, r in ipairs(roots) do forestW = forestW + r.sw + R_HGAP end
            forestW = math.max(1, forestW - R_HGAP)

            local headerY, treeTopY = curY, curY + 1
            local rl, nodes, maxBottom = 0, {}, treeTopY + R_BOX_H
            for _, r in ipairs(roots) do
                assignXY(r, rl, treeTopY)
                rl = rl + r.sw + R_HGAP
                gather(r, nodes)
            end
            for _, n in ipairs(nodes) do
                local b = n.y + R_BOX_H
                if b > maxBottom then maxBottom = b end
            end
            branches[#branches + 1] = { name = humanize(bname), headerY = headerY, nodes = nodes }
            if forestW > canvasW then canvasW = forestW end
            if maxBottom > canvasH then canvasH = maxBottom end
            curY = maxBottom + 2
        end
    end
    return branches, { w = canvasW, h = canvasH }
end

--===========================================================================
-- VIEW 4  ·  RESEARCH  (real tree with nodes + connectors, touch-panned)
--===========================================================================
local function viewResearch(bodyY)
    local d = Colony.data
    if not d then return end
    local branches, canvas = layoutResearch(d.research)
    if #branches == 0 then
        writeAt(3, bodyY, "No research data available", THEME.dim)
        ui.pages[4] = 1
        return
    end

    local x0, y0 = 2, bodyY
    local x1, y1 = W - 1, H - 1
    local vw, vh = x1 - x0 + 1, y1 - y0 + 1
    local maxX, maxY = math.max(0, canvas.w - vw), math.max(0, canvas.h - vh)
    app.pan.x = clamp(app.pan.x, 0, maxX)
    app.pan.y = clamp(app.pan.y, 0, maxY)
    local panX, panY = app.pan.x, app.pan.y

    local function sx(vx) return x0 + vx - panX end
    local function sy(vy) return y0 + vy - panY end
    local function stCol(st)
        if st == "done" then return THEME.good end
        if st == "prog" then return THEME.warn end
        return THEME.info
    end

    -- connectors (drawn first, so node boxes sit on top) ----------------
    for _, br in ipairs(branches) do
        for _, n in ipairs(br.nodes) do
            if #n.children > 0 then
                local pcx = n.x + math.floor(n.bw / 2)
                local busY = n.y + R_BOX_H + math.floor(R_VGAP / 2) - 1
                local cxs = {}
                for _, c in ipairs(n.children) do
                    cxs[#cxs + 1] = { x = c.x + math.floor(c.bw / 2), top = c.y }
                end
                table.sort(cxs, function(a, b) return a.x < b.x end)
                local leftX, rightX = cxs[1].x, cxs[#cxs].x
                for r = n.y + R_BOX_H, busY - 1 do
                    writeAt(sx(pcx), sy(r), "│", THEME.faint)
                end
                for x = leftX, rightX do
                    local u, dn = (x == pcx), false
                    for _, c in ipairs(cxs) do if c.x == x then dn = true end end
                    writeAt(sx(x), sy(busY),
                        junctionChar(u, dn, x > leftX, x < rightX), THEME.faint)
                end
                for _, c in ipairs(cxs) do
                    for r = busY + 1, c.top - 1 do
                        writeAt(sx(c.x), sy(r), "│", THEME.faint)
                    end
                end
            end
        end
    end

    -- nodes -------------------------------------------------------------
    for _, br in ipairs(branches) do
        writeAt(sx(0), sy(br.headerY), string.upper(br.name), THEME.accent)
        for _, n in ipairs(br.nodes) do
            local bx, by = sx(n.x), sy(n.y)
            local col = stCol(n.status)
            local label = n.label
            local maxLen = n.bw - R_PAD * 2
            if #label > maxLen then label = label:sub(1, maxLen) end
            -- top border
            writeAt(bx, by, "┌" .. string.rep("─", n.bw - 2) .. "┐", col)
            -- name row: solid status-coloured fill, black label
            fillRow(bx, by + 1, n.bw, col)
            local lpad = math.floor((n.bw - #label) / 2)
            writeAt(bx + lpad, by + 1, label, colors.black, col)
            -- bottom border (a ┬ tee where the connector exits to children)
            local ci = math.floor(n.bw / 2)
            local bot
            if #n.children > 0 then
                bot = "└" .. string.rep("─", ci - 1) .. "┬" .. string.rep("─", n.bw - 2 - ci) .. "┘"
            else
                bot = "└" .. string.rep("─", n.bw - 2) .. "┘"
            end
            writeAt(bx, by + 2, bot, col)
        end
    end

    -- pan indicators (touch-scroll hints on the edges) -------------------
    local midX = math.floor((x0 + x1) / 2)
    if panX > 0 then writeAt(x0, y0 + math.floor(vh / 2), "<", THEME.accent, THEME.bg) end
    if panX < maxX then writeAt(x1, y0 + math.floor(vh / 2), ">", THEME.accent, THEME.bg) end
    if panY > 0 then writeAt(midX, y0, "^", THEME.accent, THEME.bg) end
    if panY < maxY then writeAt(midX, y1, "v", THEME.accent, THEME.bg) end

    ui.research = { canvas = canvas, vw = vw, vh = vh, x0 = x0, y0 = y0, x1 = x1, y1 = y1 }
    ui.pages[4] = 1
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

    -- record body region for touch panning
    ui.body = { x0 = 2, y0 = bodyY, x1 = W - 1, y1 = H - 1 }

    if app.view == 1 then viewDashboard(bodyY)
    elseif app.view == 2 then viewBuildings(bodyY)
    elseif app.view == 3 then viewCitizens(bodyY)
    elseif app.view == 4 then viewResearch(bodyY) end

    -- footer controls — fully touch-driven (no keys required)
    local ctrl = { hasPrev = false, hasNext = false }
    if app.view == 4 and ui.research then
        local r = ui.research
        local maxX = math.max(0, r.canvas.w - r.vw)
        ctrl.hasPrev = app.pan.x > 0
        ctrl.hasNext = app.pan.x < maxX
        ctrl.center = function(y)
            local parts = { { THEME.good, "done" }, { THEME.warn, "wip" }, { THEME.info, "open" } }
            local tw = 0
            for _, p in ipairs(parts) do tw = tw + 1 + #p[2] + 1 end
            local x = math.floor((W - tw) / 2) + 1
            for _, p in ipairs(parts) do
                fillRow(x, y, 1, p[1])
                writeAt(x + 1, y, p[2], THEME.dim, THEME.faint)
                x = x + 1 + #p[2] + 1
            end
        end
    else
        local pages = ui.pages[app.view] or 1
        local s
        if pages > 1 then
            ctrl.hasPrev = app.page[app.view] > 1
            ctrl.hasNext = app.page[app.view] < pages
            s = string.format("page %d / %d", app.page[app.view], pages)
        else
            s = "refresh " .. CONFIG.refreshInterval .. "s"
        end
        ctrl.center = function(y)
            writeAt(math.floor((W - #s) / 2) + 1, y, s, THEME.dim, THEME.faint)
        end
    end
    ui.footer = ctrl
    drawFooter(ctrl)
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

-- horizontal nav driven by the footer < / > touch buttons:
-- pages for the list views, horizontal pan for the research tree
local function onLeft()
    if app.view == 4 and ui.research then
        local r = ui.research
        local maxX = math.max(0, r.canvas.w - r.vw)
        local step = math.max(4, math.floor(r.vw / 4))
        app.pan.x = clamp(app.pan.x - step, 0, maxX)
    else
        onPage(-1)
    end
end
local function onRight()
    if app.view == 4 and ui.research then
        local r = ui.research
        local maxX = math.max(0, r.canvas.w - r.vw)
        local step = math.max(4, math.floor(r.vw / 4))
        app.pan.x = clamp(app.pan.x + step, 0, maxX)
    else
        onPage(1)
    end
end

local function handleTouch(side, x, y)
    -- 1. tab bar
    for i, t in ipairs(ui.tabs) do
        if y == t.y and x >= t.x1 and x <= t.x2 then selectView(i); return end
    end
    -- 2. footer: left half = previous / pan-left, right half = next / pan-right
    if y == H then
        if x <= math.floor(W / 2) then onLeft() else onRight() end
        return
    end
    -- 3. research tree: tap the body edges to pan (touch-only)
    if app.view == 4 and ui.body and ui.research then
        local b, r = ui.body, ui.research
        if y >= b.y0 and y <= b.y1 and x >= b.x0 and x <= b.x1 then
            local maxX, maxY = math.max(0, r.canvas.w - r.vw), math.max(0, r.canvas.h - r.vh)
            local stepX, stepY = math.max(4, math.floor(r.vw / 4)), math.max(3, math.floor(r.vh / 3))
            if x <= b.x0 + 3 then
                app.pan.x = clamp(app.pan.x - stepX, 0, maxX)
            elseif x >= b.x1 - 3 then
                app.pan.x = clamp(app.pan.x + stepX, 0, maxX)
            elseif y <= b.y0 + 1 then
                app.pan.y = clamp(app.pan.y - stepY, 0, maxY)
            elseif y >= b.y1 - 1 then
                app.pan.y = clamp(app.pan.y + stepY, 0, maxY)
            end
        end
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
