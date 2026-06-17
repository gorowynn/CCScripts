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

local CLI = { ... }   -- program args; "test" runs the self-check instead of main

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
    -- control-room extras -------------------------------------------------
    stuckPolls     = 12,    -- refreshes a request stays unresolved before flagged STUCK (x refreshInterval s)
    historyMax     = 60,    -- how many refresh samples the trend sparklines keep
    -- building types (substring, case-insensitive) that employ citizens.
    -- Used by the Action Board / Workforce view to spot empty worker buildings.
    -- ponytail: maintained by hand; unknown worker types just won't be flagged.
    workerBuildings = {
        "builder", "lumberjack", "miner", "farmer", "fisher", "fisherman",
        "baker", "cook", "smelter", "blacksmith", "crusher", "sawmill",
        "carpenter", "stonemason", "stonysmeltery", "mechanic", "glassblower",
        "dyer", "plantation", "warehouse", "deliveryman", "courier",
        "guard", "barracks", "library", "university", "hospital", "mystic",
        "enchanter", "archery", "combatacademy", "sifter", "florist", "gardener",
        "composter", "graveyard", "cowboy", "swineherder", "shepherd",
    },
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
    -- per-view accent used for the title bar + tab highlight (one per view)
    viewAccent = { colors.red, colors.cyan, colors.yellow, colors.lime, colors.purple, colors.blue },
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

-- pure sparkline builder: returns an ASCII string (<= w chars) whose shading
-- tracks the value series. ASCII-only so it renders on any CC:T font.
-- ponytail: auto-ranges to the visible window, so a flat line still prints full width.
local SPARK = { ' ', '.', ':', '-', '=', '#' }   -- 6 levels, low -> high
local function sparkString(w, values)
    if w <= 0 then return "" end
    local n = #values
    if n == 0 then return string.rep(' ', w) end
    local mn, mx = math.huge, -math.huge
    for _, v in ipairs(values) do
        v = tonumber(v) or 0
        if v < mn then mn = v end
        if v > mx then mx = v end
    end
    if mx <= mn then                                       -- flat series: visible steady line, not blank
        return string.rep(SPARK[math.floor(#SPARK / 2) + 1], w)
    end
    local start = (n > w) and (n - w + 1) or 1      -- show the most recent w samples
    local cols  = n - start + 1
    local out = string.rep(' ', w - cols)           -- left-pad so newest sits at the right
    for i = 1, cols do
        local v = tonumber(values[start + i - 1]) or 0
        local idx = math.floor(((v - mn) / (mx - mn)) * (#SPARK - 1) + 0.5) + 1
        idx = clamp(idx, 1, #SPARK)
        out = out .. SPARK[idx]
    end
    assert(#out == w, "sparkline width drift")    -- ponytail: shape invariant
    return out
end

-- sparkline renderer wrapper
local function sparkline(x, y, w, values, fg)
    writeAt(x, y, sparkString(w, values), fg)
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
    Colony.buildJobMap()   -- refresh the name->job map used by resolveSource()
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

-- build a name(lower) -> humanized-job map from the current citizen list.
-- Powers resolveSource() for request attribution (dashboard + stuck tracker).
function Colony.buildJobMap()
    local m = {}
    for _, c in ipairs(asTable(Colony.data and Colony.data.citizenList)) do
        local jn = c.work and c.work.job
        if c.name and jn then m[tostring(c.name):lower()] = humanize(jn) end
    end
    Colony._jobMap = m
end

-- humanize a request target, appending its job when the target is a citizen.
function Colony.resolveSource(raw)
    local name = tostring(raw or "Unknown")
    if name == "" then name = "Unknown" end
    local h = humanize(name)
    local job = Colony._jobMap and Colony._jobMap[name:lower()]
    if job then return h .. " (" .. job .. ")" end
    return h
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

local function buildBranches(research)
    -- returns a list of { name, nodes, counts } where nodes is a depth-tagged
    -- flattened list and counts = { total, done, prog, avail }
    local function flatten(raw, depth, list)
        if type(raw) ~= "table" or not raw.name then return end
        local st = researchState(raw)
        list[#list + 1] = {
            label = humanize(raw.name or "?"),
            depth = depth,
            status = st,
            progress = tonumber(raw.progress) or 0,
        }
        for _, ch in ipairs(asTable(raw.children)) do
            flatten(ch, depth + 1, list)
        end
    end

    local names = {}
    for k in pairs(asTable(research)) do names[#names + 1] = k end
    table.sort(names)

    local branches = {}
    for _, bname in ipairs(names) do
        local rootsRaw = research[bname]
        if type(rootsRaw) == "table" then
            local nodes = {}
            if rootsRaw.name then
                flatten(rootsRaw, 0, nodes)
            else
                for _, r in ipairs(rootsRaw) do flatten(r, 0, nodes) end
            end
            if #nodes > 0 then
                local counts = { total = #nodes, done = 0, prog = 0, avail = 0 }
                for _, n in ipairs(nodes) do
                    counts[n.status] = (counts[n.status] or 0) + 1
                end
                branches[#branches + 1] =
                    { name = humanize(bname), nodes = nodes, counts = counts }
            end
        end
    end
    return branches
end

--===========================================================================
-- TREND HISTORY  ·  rolling buffer powering the dashboard sparklines
--===========================================================================
local History = { samples = {}, max = CONFIG.historyMax }

function History.push(d)
    if not d then return end
    local flags = Colony.citizenFlags()
    local popRatio = (d.maxCitizens and d.maxCitizens > 0)
        and (d.citizens or 0) / d.maxCitizens or 0
    local s = History.samples
    s[#s + 1] = {
        happiness = tonumber(d.happiness) or 0,
        requests  = #asTable(d.requests),
        popRatio  = popRatio,
        idle      = flags.idle,
        hungry    = flags.hungry,
    }
    while #s > History.max do table.remove(s, 1) end
end

-- return a plain numeric series for one metric ("happiness"/"requests"/"popRatio")
function History.series(name)
    local out = {}
    for _, e in ipairs(History.samples) do out[#out + 1] = e[name] or 0 end
    return out
end

--===========================================================================
-- STUCK-REQUEST TRACKER  ·  flags requests that never resolve
-- Keys each non-complete request by (source|item|state) and ages it across
-- polls; anything present for >= CONFIG.stuckPolls refreshes is "stuck".
-- ponytail: poll-counter based (deterministic), not wall-clock.
--===========================================================================
local Stuck = { sigs = {}, poll = 0 }

function Stuck.refresh(requests)
    Stuck.poll = Stuck.poll + 1
    local seen = {}
    for _, r in ipairs(asTable(requests)) do
        local raw  = tostring(r.state or "")
        local stem = raw:lower():gsub("[%s_]+", "")
        -- only track live (non-complete) requests
        if stem ~= "completed" and stem ~= "resolved" and stem ~= "done" then
            local src  = Colony.resolveSource(r.target)
            local item = humanize(tostring(r.name or "?"))
            local sig  = src .. "\31" .. tostring(r.name) .. "\31" .. raw
            seen[sig] = true
            if not Stuck.sigs[sig] then
                Stuck.sigs[sig] = { first = Stuck.poll, src = src, item = item }
            end
        end
    end
    for sig in pairs(Stuck.sigs) do
        if not seen[sig] then Stuck.sigs[sig] = nil end
    end
end

-- list of { age=refreshes, src=, item= } aged past the threshold, oldest first
function Stuck.staleList()
    local out, thr = {}, CONFIG.stuckPolls or 12
    for _, info in pairs(Stuck.sigs) do
        local seen = Stuck.poll - info.first + 1       -- consecutive refreshes present
        assert(seen >= 1, "stuck seen nonpositive")      -- ponytail: invariant
        if seen >= thr then out[#out + 1] = { age = seen, src = info.src, item = info.item } end
    end
    table.sort(out, function(a, b) return a.age > b.age end)
    return out
end

--===========================================================================
-- APP STATE  ·  view selection + per-view pagination
--===========================================================================
local VIEWS = {
    { key = "action",    name = "ACTION"    },
    { key = "dashboard", name = "DASHBOARD" },
    { key = "buildings", name = "BUILDINGS" },
    { key = "citizens",  name = "CITIZENS"  },
    { key = "workforce", name = "WORKFORCE" },
    { key = "research",  name = "RESEARCH"  },
}
-- named view indices — no magic numbers in dispatch / input handling
local VI = { ACTION = 1, DASH = 2, BUILD = 3, CITZ = 4, WORK = 5, RESEARCH = 6 }
app = { view = 1, page = { 1, 1, 1, 1, 1, 1 }, expanded = {} }  -- view, per-view page, expanded research branches

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

    -- request source -> "Name (Job)" via the shared colony job map
    local resolveSource = Colony.resolveSource

    -- ============ LEFT RAIL — dense, muted village stats ============
    local RH = colors.gray          -- muted header colour for the whole rail (no rainbow)
    local function railNext(y, h, b) return y + h + b + 1 end

    -- building-derived stats (built / under construction)
    local bWorking = 0
    for _, b in ipairs(asTable(d.buildings)) do
        if b.isWorkingOn then bWorking = bWorking + 1 end
    end

    local ry = bodyY

    -- OVERVIEW: all key counts, dense label:value rows
    local _, oy1 = card(railX, ry, railW, 1, 5, "OVERVIEW", RH)
    local orow = oy1
    local function oline(label, val, col)
        writeAt(railX + 1, orow, label, THEME.dim)
        writeRight(railX + railW - 2, orow, val, col or THEME.text)
        orow = orow + 1
    end
    oline("Citizens",  tostring(d.citizens or 0) .. "/" .. tostring(d.maxCitizens or 0))
    oline("Happiness", string.format("%.1f", d.happiness or 0))
    oline("Buildings", tostring(#d.buildings))
    oline("Construct", tostring(bWorking), bWorking > 0 and THEME.warn)
    oline("Requests",  tostring(#d.requests))
    ry = railNext(ry, 1, 5)

    -- GAUGES: capacity + mood (the only colour in the rail — it encodes ratio)
    local _, gy1 = card(railX, ry, railW, 1, 2, "GAUGES", RH)
    writeAt(railX + 1, gy1,     "CAP",  THEME.dim)
    gauge(railX + 6, gy1, railW - 7, Colony.citizenRatio(),
        ratioColour(Colony.citizenRatio()), THEME.faint)
    writeAt(railX + 1, gy1 + 1, "MOOD", THEME.dim)
    gauge(railX + 6, gy1 + 1, railW - 7, Colony.happinessRatio(),
        ratioColour(Colony.happinessRatio()), THEME.faint)
    ry = railNext(ry, 1, 2)

    -- WORKFORCE: citizen breakdown (idle/hungry warn when nonzero)
    local _, wy1 = card(railX, ry, railW, 1, 4, "WORKFORCE", RH)
    local wrow = wy1
    local function wline(label, val, col)
        writeAt(railX + 1, wrow, label, THEME.dim)
        writeRight(railX + railW - 2, wrow, val, col or THEME.text)
        wrow = wrow + 1
    end
    wline("Adults",   tostring(flags.adults))
    wline("Children", tostring(flags.children))
    wline("Idle",     tostring(flags.idle),   flags.idle > 0 and THEME.warn)
    wline("Hungry",   tostring(flags.hungry), flags.hungry > 0 and THEME.bad)
    ry = railNext(ry, 1, 4)

    -- TRENDS: sparkline strip of recent history (happiness / requests / pop)
    if ry < H - 3 then
        local _, ty1 = card(railX, ry, railW, 1, 3, "TRENDS", RH)
        local spX = railX + 6
        local spW = railW - 12          -- leave room for label + trailing value
        if spW < 4 then spW = 4 end
        local function trendRow(yy, label, series, curTxt, col)
            writeAt(railX + 1, yy, label, THEME.dim)
            sparkline(spX, yy, spW, series, col)
            writeRight(railX + railW - 2, yy, curTxt, THEME.text)
        end
        trendRow(ty1,     "MOOD", History.series("happiness"),
            string.format("%.1f", d.happiness or 0), ratioColour(Colony.happinessRatio()))
        trendRow(ty1 + 1, "REQ",  History.series("requests"),
            tostring(#(d.requests or {})), THEME.warn)
        trendRow(ty1 + 2, "POP",  History.series("popRatio"),
            tostring(d.citizens or 0), THEME.accent)
        ry = railNext(ry, 1, 3)
    end

    -- VISITORS: recruitment opportunity + recruit cost
    if ry < H - 1 then
        local vList = asTable(d.visitors)
        local vbodyH = (#vList > 0) and 2 or 1
        local _, vy1 = card(railX, ry, railW, 1, vbodyH, "VISITORS", RH)
        if #vList == 0 then
            writeAt(railX + 1, vy1, "none in tavern", THEME.dim)
        else
            writeAt(railX + 1, vy1, #vList .. " available", THEME.text)
            -- robust recruit-cost parsing: the field may be a single item,
            -- a list, or a keyed table. Handle all three; never claim "free".
            local cost = vList[1].recruitCost
            local function itemStr(it)
                if type(it) ~= "table" then return nil end
                local n = it.displayName or it.name
                if not n then return nil end
                local cnt = it.count
                if cnt then return tostring(cnt) .. " " .. humanize(n) end
                return humanize(n)
            end
            local costTxt
            if type(cost) == "table" then
                if cost.name or cost.displayName then
                    costTxt = itemStr(cost)                       -- single item
                else
                    for _, it in ipairs(cost) do costTxt = costTxt or itemStr(it) end  -- list
                    if not costTxt then                          -- keyed table?
                        for _, it in pairs(cost) do costTxt = costTxt or itemStr(it) end
                    end
                end
            end
            local cl = costTxt or "no cost data"
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
-- VIEW 4  ·  RESEARCH  (collapsible branches, ASCII-only, touch to expand)
--===========================================================================
local function viewResearch(bodyY)
    local d = Colony.data
    if not d then return end
    local branches = buildBranches(d.research)
    if #branches == 0 then
        writeAt(3, bodyY, "No research data available", THEME.dim)
        ui.pages[VI.RESEARCH] = 1
        return
    end

    local x0, x1 = 2, W - 1
    local innerW = x1 - x0
    local function stCol(st)
        if st == "done" then return THEME.good end
        if st == "prog" then return THEME.warn end
        return THEME.info
    end
    local function stTag(st)
        if st == "done" then return "DONE" end
        if st == "prog" then return "WIP" end
        return "OPEN"
    end

    -- build display lines: collapsed branch summaries + expanded branch nodes
    local lines = {}
    for _, br in ipairs(branches) do
        local isExp = app.expanded[br.name]
        local marker = isExp and "v" or ">"
        local c = br.counts
        local nm = string.upper(br.name)
        if #nm > 12 then nm = nm:sub(1, 12) end
        local summary = string.format("%s %-12s  %2d nodes  %2d done  %2d wip  %2d open",
            marker, nm, c.total, c.done, c.prog, c.avail)
        lines[#lines + 1] = { text = summary, fg = THEME.accent,
                              kind = "branch", name = br.name }
        if isExp then
            for _, n in ipairs(br.nodes) do
                local indent = string.rep("  ", n.depth + 1)
                local rightTxt = stTag(n.status) .. " " ..
                    string.format("%3d%%", math.floor(n.progress * 100))
                lines[#lines + 1] = {
                    text = indent .. n.label,
                    fg = stCol(n.status),
                    rightText = rightTxt,
                    rightFg = stCol(n.status),
                }
            end
        end
    end

    -- paginate by line count
    local rowsAvail = H - bodyY - 1
    local perPage = math.max(1, rowsAvail)
    local pages = math.max(1, math.ceil(#lines / perPage))
    app.page[VI.RESEARCH] = clamp(app.page[VI.RESEARCH], 1, pages)
    ui.pages[VI.RESEARCH] = pages

    -- render + capture branch hit-test rects for touch toggling
    ui.research = { branches = {} }
    local start = (app.page[VI.RESEARCH] - 1) * perPage
    local row = bodyY
    for i = start + 1, math.min(#lines, start + perPage) do
        if row > H - 1 then break end
        local ln = lines[i]
        if ln.rightText then
            -- node line: name left, status right-aligned
            local rightW = #ln.rightText + 1
            local maxLeft = innerW - rightW
            local left = ln.text
            if maxLeft > 0 and #left > maxLeft then left = left:sub(1, maxLeft) end
            writeAt(x0, row, left, ln.fg)
            writeRight(x1, row, ln.rightText, ln.rightFg or ln.fg)
        else
            local t = ln.text
            if #t > innerW then t = t:sub(1, innerW) end
            writeAt(x0, row, t, ln.fg)
        end
        if ln.kind == "branch" then
            ui.research.branches[#ui.research.branches + 1] =
                { y = row, name = ln.name }
        end
        row = row + 1
    end
end

--===========================================================================
-- VIEW 0  ·  ACTION BOARD  (derived, prioritized to-do list)
-- The headline control-room feature: turns raw colony state into a ranked set
-- of concrete things to go fix in-game. sev: 1 bad / 2 warn / 3 info.
--===========================================================================
local function isWorkerBuilding(b)
    local hay = (tostring(b.type) .. " " .. tostring(b.name)):lower()
    for _, w in ipairs(CONFIG.workerBuildings or {}) do
        w = tostring(w):lower()
        if #w > 0 and hay:find(w, 1, true) then return true end
    end
    return false
end

local function viewAction(bodyY)
    local d = Colony.data
    if not d then return end
    local flags = Colony.citizenFlags()
    local items = {}   -- { sev=, text= }

    if d.underAttack then
        items[#items + 1] = { sev = 1, text = "UNDER ATTACK - raise guards / rally defenders" }
    end
    if flags.hungry > 0 then
        items[#items + 1] = { sev = 1,
            text = "FOOD: " .. flags.hungry .. " citizens need better food (add variety / restaurant)" }
    end
    if Colony.happinessRatio() < 0.5 then
        items[#items + 1] = { sev = 1,
            text = "HAPPINESS LOW (" .. string.format("%.1f", d.happiness or 0) .. ") - check food / housing / safety" }
    end
    -- stuck requests: the #1 real colony problem (unfulfillable request chain)
    for _, s in ipairs(Stuck.staleList()) do
        local total = s.age * CONFIG.refreshInterval
        local mins = math.floor(total / 60)
        local secs = total % 60
        local ageTxt = (mins > 0 and (mins .. "m ") or "") .. secs .. "s"
        items[#items + 1] = { sev = 2,
            text = "STUCK: " .. s.item .. " for " .. s.src .. " (" .. ageTxt .. ") - missing chain / material?" }
    end
    -- housing near capacity
    if (d.maxCitizens or 0) > 0 and Colony.citizenRatio() >= 0.9 then
        items[#items + 1] = { sev = 2,
            text = "HOUSING: colony " .. (d.citizens or 0) .. "/" .. (d.maxCitizens or 0) .. " nearly full - build / upgrade housing" }
    end
    -- built worker buildings with nobody assigned
    local unstaffed = {}
    for _, b in ipairs(asTable(d.buildings)) do
        if b.built and not b.isWorkingOn and isWorkerBuilding(b) and #asTable(b.citizens) == 0 then
            unstaffed[#unstaffed + 1] = humanize(b.name or b.type)
        end
    end
    for i = 1, math.min(5, #unstaffed) do
        items[#items + 1] = { sev = 2, text = "STAFF: " .. unstaffed[i] .. " has no worker - assign a citizen" }
    end
    if #unstaffed > 5 then
        items[#items + 1] = { sev = 2, text = "STAFF: " .. (#unstaffed - 5) .. " more unstaffed (see WORKFORCE)" }
    end
    if flags.idle > 0 then
        items[#items + 1] = { sev = 2, text = "IDLE: " .. flags.idle .. " citizens with no job - assign work" }
    end
    -- unguarded buildings
    local unguarded = 0
    for _, b in ipairs(asTable(d.buildings)) do
        if b.built and b.guarded == false then unguarded = unguarded + 1 end
    end
    if unguarded > 0 then
        items[#items + 1] = { sev = 3, text = "DEFENSE: " .. unguarded .. " buildings unguarded" }
    end
    -- recruitment opportunity
    local vList = asTable(d.visitors)
    if #vList > 0 then
        items[#items + 1] = { sev = 3, text = "RECRUIT: " .. #vList .. " visitor(s) available at the tavern" }
    end
    -- research nearest completion
    local bestProg, bestName = 0, nil
    for _, br in ipairs(buildBranches(d.research)) do
        for _, n in ipairs(br.nodes) do
            if n.status == "prog" and n.progress > bestProg then bestProg, bestName = n.progress, n.label end
        end
    end
    if bestName then
        items[#items + 1] = { sev = 3,
            text = "RESEARCH: " .. bestName .. " almost done (" .. math.floor(bestProg * 100) .. "%)" }
    end
    if #items == 0 then
        items[#items + 1] = { sev = 3, text = "All systems nominal - nothing needs attention" }
    end

    table.sort(items, function(a, b) return a.sev < b.sev end)

    local sevCol = { [1] = THEME.bad, [2] = THEME.warn, [3] = THEME.info }
    local sevTag = { [1] = "!!", [2] = "!", [3] = " " }
    local nBad, nWarn, nInfo = 0, 0, 0
    for _, it in ipairs(items) do
        if it.sev == 1 then nBad = nBad + 1
        elseif it.sev == 2 then nWarn = nWarn + 1
        else nInfo = nInfo + 1 end
    end

    -- summary strip
    local sum = string.format("  URGENT %d   WARN %d   INFO %d  ", nBad, nWarn, nInfo)
    local sumCol = (nBad > 0 and THEME.bad) or (nWarn > 0 and THEME.warn) or THEME.good
    fillRow(2, bodyY, W - 2, THEME.faint)
    writeAt(3, bodyY, sum, sumCol, THEME.faint)

    local columns = {
        { header = "!",     align = "right", color = function(_, r) return sevCol[r._sev] end },
        { header = "ACTION", wrap = true,    color = function(_, r) return sevCol[r._sev] end },
    }
    local rows = {}
    for _, it in ipairs(items) do
        rows[#rows + 1] = { sevTag[it._sev] or " ", it.text, _sev = it.sev }
    end
    drawTable(2, bodyY + 2, W - 2, H - bodyY - 3, columns, rows, VI.ACTION)
end

--===========================================================================
-- VIEW 5  ·  WORKFORCE  (labor distribution + unstaffed buildings)
--===========================================================================
local function viewWorkforce(bodyY)
    local d = Colony.data
    if not d then return end
    local tableW = W - 2
    local tableH = H - bodyY - 1

    -- labor by job
    local jobCount, order, employed = {}, {}, 0
    for _, c in ipairs(asTable(d.citizenList)) do
        local j = (c.work and c.work.job) or nil
        local label = j and humanize(j) or "Unemployed"
        jobCount[label] = (jobCount[label] or 0) + 1
        if j then employed = employed + 1 end
    end
    for k in pairs(jobCount) do order[#order + 1] = k end
    table.sort(order, function(a, b)
        return jobCount[a] ~= jobCount[b] and jobCount[a] > jobCount[b] or a < b
    end)

    -- worker-building slots + unstaffed list
    local slots, unstaffed = 0, {}
    for _, b in ipairs(asTable(d.buildings)) do
        if b.built and isWorkerBuilding(b) then
            slots = slots + 1
            if #asTable(b.citizens) == 0 then
                unstaffed[#unstaffed + 1] = humanize(b.name or b.type)
            end
        end
    end
    local fill = (slots > 0) and (employed / slots) or 0

    -- summary strip
    fillRow(2, bodyY, tableW, THEME.faint)
    local sum = string.format("  WORKERS %d   SLOTS %d   FILL %d%%",
        employed, slots, math.floor(fill * 100))
    writeAt(3, bodyY, sum, ratioColour(fill), THEME.faint)

    -- top half: labor matrix (paginated)
    local topH = math.max(4, math.floor(tableH * 0.55) - 1)
    local laborCols = {
        { header = "JOB",   align = "left",  wrap = true,
          color = function(_, r) return r._sev end },
        { header = "N",     align = "right",
          color = function() return THEME.text end },
        { header = "SHARE", type = "bar", barW = 5,
          color = function(v) return ratioColour(v) end },
    }
    local laborRows = {}
    for _, j in ipairs(order) do
        local n = jobCount[j]
        laborRows[#laborRows + 1] = {
            j, tostring(n), clamp(n / math.max(1, employed), 0, 1),
            _sev = (j == "Unemployed" and n > 0) and THEME.warn or THEME.text,
        }
    end
    drawTable(2, bodyY + 2, tableW, topH, laborCols, laborRows, VI.WORK)

    -- bottom: unstaffed buildings (manual, capped, no pagination)
    local uY = bodyY + 2 + topH
    if uY >= H - 1 then return end
    writeAt(3, uY, "UNSTAFFED BUILDINGS", THEME.dim)
    fillRow(2, uY + 1, tableW, THEME.faint)
    if #unstaffed == 0 then
        writeAt(3, uY + 2, "none - all worker buildings staffed", THEME.good)
        return
    end
    local row = uY + 2
    local maxRow = H - 1
    for i, nm in ipairs(unstaffed) do
        if row > maxRow then
            writeRight(W - 2, maxRow, "+" .. (#unstaffed - i + 1) .. " more", THEME.dim)
            break
        end
        writeAt(3, row, "! " .. nm, THEME.warn)
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

    -- record body region for touch panning
    ui.body = { x0 = 2, y0 = bodyY, x1 = W - 1, y1 = H - 1 }

    if app.view == VI.ACTION then viewAction(bodyY)
    elseif app.view == VI.DASH then viewDashboard(bodyY)
    elseif app.view == VI.BUILD then viewBuildings(bodyY)
    elseif app.view == VI.CITZ then viewCitizens(bodyY)
    elseif app.view == VI.WORK then viewWorkforce(bodyY)
    elseif app.view == VI.RESEARCH then viewResearch(bodyY) end

    -- footer controls — fully touch-driven (no keys required)
    local ctrl = { hasPrev = false, hasNext = false }
    local pages = ui.pages[app.view] or 1
    if app.view == VI.RESEARCH then
        -- research: legend in center, < > page when expanded branches overflow
        ctrl.hasPrev = app.page[VI.RESEARCH] > 1
        ctrl.hasNext = app.page[VI.RESEARCH] < pages
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

local function onLeft() onPage(-1) end
local function onRight() onPage(1) end

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
    -- 3. research: tap a branch summary line to expand/collapse it
    if app.view == VI.RESEARCH and ui.research and ui.research.branches then
        for _, b in ipairs(ui.research.branches) do
            if y == b.y then
                app.expanded[b.name] = not app.expanded[b.name]
                app.page[VI.RESEARCH] = 1          -- expanding changes line count; reset page
                return
            end
        end
    end
end

local function handleKey(k)
    if k == keys.right then selectView(app.view % #VIEWS + 1)
    elseif k == keys.left then selectView((app.view - 2) % #VIEWS + 1)
    elseif k == keys.up or k == keys.pageUp then onPage(-1)
    elseif k == keys.down or k == keys.pageDown then onPage(1)
    elseif k == keys.one then selectView(VI.ACTION)
    elseif k == keys.two then selectView(VI.DASH)
    elseif k == keys.three then selectView(VI.BUILD)
    elseif k == keys.four then selectView(VI.CITZ)
    elseif k == keys.five then selectView(VI.WORK)
    elseif k == keys.six then selectView(VI.RESEARCH)
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

    -- initial poll + draw + seed history
    Colony.refresh()
    History.push(Colony.data)
    Stuck.refresh(Colony.data and Colony.data.requests or {})
    render()

    local timer = os.startTimer(CONFIG.refreshInterval)
    while true do
        local event = { os.pullEvent() }
        local e = event[1]
        if e == "timer" and event[2] == timer then
            Colony.refresh()
            History.push(Colony.data)
            Stuck.refresh(Colony.data and Colony.data.requests or {})
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

--===========================================================================
-- SELF-CHECK  ·  `colony_monitor test` validates the pure-logic extras
-- (sparkline shaping + stuck-request aging) without a colony or monitor.
--===========================================================================
local function _selftest()
    local fail = 0
    local function check(name, cond)
        if cond then print("ok   " .. name) else print("FAIL " .. name); fail = fail + 1 end
    end

    -- sparkline: rising series should peak at the newest (rightmost) sample
    local rising = sparkString(6, { 1, 2, 3, 4, 5, 6 })
    check("spark rising peaks at right", rising:sub(-1) == "#")
    check("spark width is exact", #rising == 6)
    -- flat series fills width with a visible (non-blank) steady line
    local flat = sparkString(5, { 7, 7, 7, 7, 7 })
    check("spark flat fills width", #flat == 5)
    check("spark flat is visible", flat:sub(1, 1) ~= " ")
    -- empty series returns a blank strip of the requested width
    check("spark empty is blank", sparkString(4, {}) == "    ")
    -- stuck tracker: 11 polls under threshold, 12th trips, then clears
    Stuck.sigs, Stuck.poll = {}, 0
    Colony.resolveSource = function(raw) return tostring(raw or "?") end
    local req = { { target = "Baker", name = "minecraft:wheat", state = "IN_PROGRESS" } }
    for _ = 1, (CONFIG.stuckPolls - 1) do Stuck.refresh(req) end
    check("not stuck below threshold", #Stuck.staleList() == 0)
    Stuck.refresh(req)
    check("stuck at threshold", #Stuck.staleList() == 1)
    check("stuck item humanized", Stuck.staleList()[1].item == "Wheat")
    Stuck.refresh({})   -- request resolved -> dropped
    check("cleared after resolve", #Stuck.staleList() == 0)

    print(fail == 0 and "ALL OK" or (fail .. " FAILED"))
    return fail == 0
end

if CLI[1] == "test" then os.exit(_selftest() and 0 or 1) else main() end
