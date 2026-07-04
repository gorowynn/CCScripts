--[[
  dig_shape.lua — turtle dig tool. Two modes:

  === ROOM ===  carve a rectangular room.
  Turtle starts at the LOWER-LEFT-FRONT corner, facing the LENGTH direction.

    WIDTH  = blocks across  (left/right)
    HEIGHT = blocks up       (1 is fine; 1x1x1 is rejected — nothing to dig)
    LENGTH = blocks forward  (face this way at start)

  Pattern: vertical wave (boustrophedon in the vertical plane). The turtle
  mines a 1x1 shaft UP through HEIGHT at the first floor cell, steps sideways
  at the TOP to the next cell, mines DOWN, steps sideways at the FLOOR, mines
  UP, and so on. Every block is mined with exactly one move into it — no
  wasted descent. Across the W x L floor the path also snakes (length
  direction reverses each width row).

  === HILL ===  carve a sloped hillside / ramp (carve only, no placing).
  Turtle starts at the LOW edge, ground level, facing UPHILL (+z).

    WIDTH  = blocks across  (left/right)
    LENGTH = slope length   (face this way at start; rises in this direction)
    HIGH    = total rise    (how many blocks higher the high edge is vs start)

  The ramp surface rises linearly from 0 at the low edge to HIGH at the far
  edge, plus a small per-cell jitter (±1, deterministic) so the result looks
  naturally rough rather than a sterile diagonal. The turtle removes every
  block ABOVE the surface, leaving the ramp. Material at/below the surface
  is untouched. Existing air is skipped.
  ponytail: processed layer-by-layer top-down; each layer is a per-column
  carve length swept in a boustrophedon. Layers shrink as we descend. The
  jitter makes the high edge ragged rather than straight. Repositioning
  between layers goes through carved air via goTo — ~40% extra moves vs a
  perfect variable-height wave, but the wave has off-by-one traps at surface
  steps whereas layers never put the turtle inside material.

  === Inventory (both modes) ===
    slot 1 = FUEL  only (never dropped as loot, never mined into)
    slot 2 = CHEST (auto-placed; chained into a row when one fills up)
    slots 3-16 = loot. Fuel is ONLY slot 1 — add more there when it empties.

  Extras (both modes):
    - Pre-flight fuel check + greedy burn of slot 1
    - Inventory-full mid-dig: returns to start, offloads into chests (places/
      chains them, ground-dump fallback if out of chests), then resumes at the
      exact cell it left off
    - Resume after restart: progress saved to .dig_shape_state each step;
      re-running with the same dims+mode resumes, else starts fresh
    - Block logging: every block is inspected before digging; all blocks are
      tallied and reported at the end, shown live
    - Gravel/falling-block re-dig, live status display with live block
      counts, chat alerts

  Alerts: uses a Plethora/Sc-Peripherals `chatBox` if present, else falls
  back to `rednet.broadcast` if a modem is attached, else just prints.

  Usage:  dig_shape <width> <height> <length>   -- room mode (CLI)
          dig_shape                              -- guided: pick shape + dims
--]]

local args = { ... }

-- --- argument parsing: CLI if given, else interactive guided prompts -----
local WIDTH, HEIGHT, LENGTH, HIGH
local mode = "room"   -- "room" or "hill"; CLI defaults to room

local function readNumber(prompt)
  while true do
    io.write(prompt)
    local s = io.read()
    if not s then return nil end   -- EOF / Ctrl-D
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    if s == "" then
      print("  (enter a number)")
    else
      local n = tonumber(s)
      if n and n == math.floor(n) and n >= 1 then return n end
      print("  must be a positive integer")
    end
  end
end

local function readChoice(prompt, options)
  while true do
    print(prompt)
    for i, opt in ipairs(options) do
      print(("  %d) %s"):format(i, opt.label))
    end
    io.write("Choice [1-" .. #options .. "]: ")
    local s = io.read()
    if not s then return nil end
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    local n = tonumber(s)
    if n and n >= 1 and n <= #options then return options[n].value end
    print("  invalid choice")
  end
end

if #args >= 3 then
  -- CLI: always room mode
  WIDTH  = tonumber(args[1])
  HEIGHT = tonumber(args[2])
  LENGTH = tonumber(args[3])
  if not (WIDTH and HEIGHT and LENGTH)
     or WIDTH < 1 or HEIGHT < 1 or LENGTH < 1 then
    printError("width, height and length must be positive integers")
    return
  end
else
  -- guided mode
  term.clear(); term.setCursorPos(1, 1)
  print("=== dig_shape guided setup ===")
  print("")
  local shape = readChoice("Mine which shape?", {
    { label = "rectangular room",                value = "room" },
    { label = "sloped hillside/ramp (carve only)", value = "hill" },
  })
  if not shape then return end   -- EOF
  mode = shape
  print("")
  WIDTH  = readNumber("Width  (blocks across, left/right):  ")
  LENGTH = readNumber("Length (blocks forward, face this way): ")
  if mode == "hill" then
    HIGH = readNumber("Rise   (height of high edge above start): ")
    if not (WIDTH and LENGTH and HIGH) then return end
    if HIGH < 1 then
      printError("rise must be a positive integer (use 'room' for a flat dig)")
      return
    end
  else
    HEIGHT = readNumber("Height (blocks up, 1 ok):            ")
    if not (WIDTH and HEIGHT and LENGTH) then return end
    if WIDTH * HEIGHT * LENGTH < 2 then
      printError("1x1x1 has nothing to dig (the turtle is already in the only cell).")
      printError("Increase at least one dimension.")
      return
    end
  end
end

local FUEL_SLOT   = 1
local CHEST_SLOT  = 2
local STUCK_LIMIT = 15   -- failed move attempts before declaring stuck
local STATE_FILE  = ".dig_shape_state"

-- --- chat / log alerts -------------------------------------------------
local chatBox = peripheral.find("chatBox")
local modem   = peripheral.find("modem")
if modem and modem.isOpen then
  pcall(function() modem.open(65535) end)  -- ponytail: ignore if already open
end

local function notify(level, msg)
  local full = ("[%s] %s"):format(level or "INFO", msg)
  print(full)
  if chatBox then
    pcall(function() chatBox.say(full) end)   -- Plethora: broadcast nearby
  elseif modem then
    pcall(function() rednet.broadcast(full, "dig_shape") end)
  end
end

-- --- run state (declared early so display/loops close over it) ---------
local totalColumns = WIDTH * LENGTH                  -- room progress total
local doneColumns  = 0                               -- room progress done
local totalLayers  = (mode == "hill") and HIGH or 0  -- hill progress total
local doneLayers   = 0                               -- hill progress done
local startTime    = os.clock()                       -- for ETA (process time)
local pos          = { x = 0, y = 0, z = 0 }
local heading      = { x = 0, z = 1 }
-- room sweep cursors
local w            = 0          -- current width index  [0..WIDTH-1]
local l            = 0          -- current length index [0..LENGTH-1]
local lengthDir    = 1          -- +1 or -1 (snake direction along z)
local goingUp      = true       -- vertical direction of the current column
-- hill sweep cursor
local hillY        = HIGH or 0  -- current layer being carved [HIGH..1]
local aborting     = false
local chestsUsed   = 0
local blockLog     = {}         -- block name (no namespace) -> count

-- --- live status display ----------------------------------------------
-- Format seconds into a short human-ish duration (e.g. "2m 13s", "1h 4m").
local function fmtTime(s)
  s = math.floor(s or 0)
  if s < 60 then return s .. "s" end
  if s < 3600 then return math.floor(s/60) .. "m " .. (s%60) .. "s" end
  return math.floor(s/3600) .. "h " .. math.floor((s%3600)/60) .. "m"
end

local function setStatus(msg)
  term.setCursorPos(1, 1); term.clearLine(); term.write(msg or "")
  term.setCursorPos(1, 2); term.clearLine()
  local done, total
  if mode == "hill" then done, total = doneLayers, totalLayers
  else                  done, total = doneColumns, totalColumns end
  term.write(("Progress: %d / %d  (%d%%)"):format(
        done, total, math.floor(done / total * 100)))
  -- ETA: average process-time per unit so far * remaining.
  -- ponytail: os.clock() is CPU time, excludes sleep/idle (e.g. fuel pause),
  -- so ETA skews low during waits — acceptable on a small terminal where we
  -- can't fit a wall-clock row too.
  term.setCursorPos(1, 3); term.clearLine()
  local elapsed = os.clock() - startTime
  local eta = (done > 0) and (elapsed / done) * (total - done) or nil
  local etaStr = eta and ("  ETA %s"):format(fmtTime(eta)) or ""
  term.write(("Fuel: %s%s"):format(tostring(turtle.getFuelLevel()), etaStr))
end

local function log(msg)
  local _, h = term.getSize()
  term.setCursorPos(1, h); term.scroll(1); term.write(msg or "")
end

-- Live block-count panel: lines 4..(h-1), one block per line, top counts
-- first. Bottom line (h) stays reserved for log() event messages.
local function drawBlockCounts()
  local _, th = term.getSize()
  local last = th - 1
  local names = {}
  for n in pairs(blockLog) do names[#names + 1] = n end
  table.sort(names, function(a, b)
    if blockLog[a] ~= blockLog[b] then return blockLog[a] > blockLog[b] end
    return a < b
  end)
  for y = 4, last do term.setCursorPos(1, y); term.clearLine() end
  local y = 4
  for _, n in ipairs(names) do
    if y > last then break end
    term.setCursorPos(1, y)
    term.write(("%s x%d"):format(n, blockLog[n]))
    y = y + 1
  end
end

-- --- state persistence ------------------------------------------------
local function saveState()
  local f = fs.open(STATE_FILE, "w")
  if not f then return end
  f.write(textutils.serialize({
    mode         = mode,
    dims         = { WIDTH, HIGH or HEIGHT, LENGTH },
    pos          = pos,
    heading      = heading,
    -- room cursors
    w            = w,
    l            = l,
    lengthDir    = lengthDir,
    goingUp      = goingUp,
    doneColumns  = doneColumns,
    -- hill cursor
    hillY        = hillY,
    doneLayers   = doneLayers,
    -- shared
    aborting     = aborting,
    chestsUsed   = chestsUsed,
    blockLog     = blockLog,
  }))
  f.close()
end

local function clearState()
  if fs.exists(STATE_FILE) then fs.delete(STATE_FILE) end
end

-- Returns true if a matching in-progress job was restored.
local function tryResume()
  if not fs.exists(STATE_FILE) then return false end
  local f = fs.open(STATE_FILE, "r")
  if not f then return false end
  local ok, data = pcall(textutils.unserialize, f.readAll())
  f.close()
  if not ok or type(data) ~= "table" or not data.dims then return false end
  if data.mode ~= mode then return false end   -- different mode; start fresh
  local d = data.dims
  if d[1] ~= WIDTH or d[2] ~= (HIGH or HEIGHT) or d[3] ~= LENGTH then
    return false   -- different job; caller will start fresh
  end
  pos, heading     = data.pos, data.heading
  w, l, lengthDir  = data.w, data.l, data.lengthDir
  goingUp          = data.goingUp
  if goingUp == nil then goingUp = true end
  doneColumns      = data.doneColumns or 0
  hillY            = data.hillY or (HIGH or 0)
  doneLayers       = data.doneLayers or 0
  aborting         = data.aborting or false
  chestsUsed       = data.chestsUsed or 0
  blockLog         = data.blockLog or data.oreLog or {}
  if mode == "hill" then
    notify("RESUME", ("Resuming hill at layer y=%d (%d/%d layers)")
           :format(hillY, doneLayers, totalLayers))
  else
    notify("RESUME", ("Resuming at W%d L%d (%d/%d columns)")
           :format(w + 1, l + 1, doneColumns, totalColumns))
  end
  return true
end

-- --- fuel -------------------------------------------------------------
-- Burn from `slot` until level reaches `target` (default: greedy/all) or the
-- slot is empty.
local function refuelFrom(slot, target)
  if turtle.getFuelLevel() == "unlimited" then return end
  target = target or math.huge
  turtle.select(slot)
  while turtle.getFuelLevel() < target and turtle.refuel(1) do end
  turtle.select(1)
end

-- --- block logging ----------------------------------------------------
-- ponytail: CC:T turtle.inspect() has no displayName for blocks, so derive a
-- readable name from the registry id: strip ANY namespace (everything up to
-- and including the last ':'), swap '_' for spaces, Title Case. True
-- localization would need a hardcoded table or the commands API (command
-- computer only) — not worth it here.
local function niceName(id)
  if not id then return "" end
  local short = id:gsub("^.*:", "")      -- strip any namespace
  short = short:gsub("_", " ")          -- snake_case -> spaces
  short = short:gsub("%a", function(c)  -- Title Case each word
    return c:upper()
  end, 1)
  -- capitalize after each space too
  short = short:gsub(" (%a)", function(c) return c:upper() end)
  return short
end

-- Tally every mined block by nice name; the live count panel redraws on
-- every block so counts are always current.
local function noteBlock(info)
  if not info then return end
  local display = niceName(info.name)
  if display == "" then return end
  blockLog[display] = (blockLog[display] or 0) + 1
  drawBlockCounts()
end

-- --- falling-block-safe dig/move helpers ------------------------------
local function digUntilClear(detect, dig, inspectFn)
  local tries = 0
  while detect() and tries < 40 do
    if inspectFn then
      local ok, info = inspectFn()
      if ok then noteBlock(info) end
    end
    dig(); sleep(0.3); tries = tries + 1
  end
end

-- ponytail: one table-driven mover replaces three near-identical functions.
-- All three directions share the same out-of-fuel pause-for-key behaviour.
local MOVERS = {
  forward = { name = "forward", detect = turtle.detect,  dig = turtle.dig,  insp = turtle.inspect,
              move = turtle.forward },
  up      = { name = "up",      detect = turtle.detectUp, dig = turtle.digUp, insp = turtle.inspectUp,
              move = turtle.up },
  down    = { name = "down",    detect = turtle.detectDown, dig = turtle.digDown, insp = turtle.inspectDown,
              move = turtle.down },
}

local function safeMove(m)
  digUntilClear(m.detect, m.dig, m.insp)
  local tries = 0
  while not m.move() do
    if turtle.getFuelLevel() == 0 then
      refuelFrom(FUEL_SLOT)
      if turtle.getFuelLevel() == 0 then
        notify("FUEL", "Out of fuel! Add fuel to slot 1, then press any key.")
        setStatus("OUT OF FUEL — waiting for refuel...")
        os.pullEvent("key")
        refuelFrom(FUEL_SLOT)
      end
    end
    digUntilClear(m.detect, m.dig, m.insp)
    sleep(0.2); tries = tries + 1
    if tries >= STUCK_LIMIT then
      notify("STUCK", ("Can't move %s after %d tries. Aborting dig, returning home.")
             :format(m.name, STUCK_LIMIT))
      aborting = true
      return false
    end
  end
  return true
end

local function safeForward() return safeMove(MOVERS.forward) end
local function safeUp()      return safeMove(MOVERS.up) end
local function safeDown()    return safeMove(MOVERS.down) end

-- --- position / heading tracking --------------------------------------
local function turnRight()
  turtle.turnRight()
  heading = { x = heading.z, z = -heading.x }
end
local function turnTo(target)
  local guard = 0
  while (heading.x ~= target.x or heading.z ~= target.z) and guard < 4 do
    turnRight(); guard = guard + 1
  end
end
local function step()
  if not safeForward() then return false end
  pos.x = pos.x + heading.x
  pos.z = pos.z + heading.z
  return true
end

-- Navigate to a cell (tx, ty, tz) through carved air. Returns false (and
-- sets aborting) if blocked. Vertical legs use safeUp/safeDown.
local function goTo(tx, ty, tz)
  if pos.x < tx then turnTo({ x = 1, z = 0 })
  elseif pos.x > tx then turnTo({ x = -1, z = 0 }) end
  while pos.x ~= tx do if not step() then return false end end
  if pos.z < tz then turnTo({ x = 0, z = 1 })
  elseif pos.z > tz then turnTo({ x = 0, z = -1 }) end
  while pos.z ~= tz do if not step() then return false end end
  while pos.y < ty do if not safeUp() then return false end; pos.y = pos.y + 1 end
  while pos.y > ty do if not safeDown() then return false end; pos.y = pos.y - 1 end
  return true
end

-- --- shared loot drop (mid-dig offload and final drop) ----------------
local function ensureChestAhead()
  if turtle.detect() then
    local ok, info = turtle.inspect()
    if ok and info and info.name == "minecraft:chest" then return true end
    return false   -- non-chest block in the way; can't loot here
  end
  if turtle.getItemCount(CHEST_SLOT) == 0 then return false end
  turtle.select(CHEST_SLOT)
  if turtle.place() then
    chestsUsed = chestsUsed + 1
    log(("Placed chest #%d"):format(chestsUsed))
    turtle.select(1)
    return true
  end
  turtle.select(1)
  return false
end

-- Assumes turtle is at (0,0,0). Tries to place/reuse a chest facing the
-- entrance (-z) first; falls back to the interior (+z), guaranteed carved
-- air with a solid floor. When a chest fills, chains a new one along +x.
-- If no chest can be placed or slot 2 runs out, dumps loot as a last resort.
-- Leaves the turtle back at (0,0,0) facing +z.
local function dropLootAtHome()
  local chestDirs = { { x = 0, z = -1 }, { x = 0, z = 1 } }
  local chestDir  = chestDirs[1]
  local placed    = false
  for _, d in ipairs(chestDirs) do
    turnTo(d)
    if ensureChestAhead() then chestDir = d; placed = true; break end
  end
  local groundFallback = not placed
  if groundFallback then
    notify("WARN", "Could not place a chest (slot 2 empty or blocked both ways). " ..
           "Dumping loot into the room.")
  end

  for s = 3, 16 do
    if turtle.getItemCount(s) > 0 then
      turtle.select(s)
      if groundFallback then
        turnTo({ x = 0, z = 1 }); turtle.drop(); turnTo(chestDir)
      else
        while turtle.getItemCount(s) > 0 do
          if turtle.drop() then
            -- slot emptied into the chest
          else
            -- chest full: chain a new one along +x
            if turtle.getItemCount(CHEST_SLOT) == 0 then
              notify("WARN", "Ran out of chests! Dumping remaining loot on the ground.")
              groundFallback = true
              break
            end
            turnTo({ x = 1, z = 0 })
            if not step() then break end
            turnTo(chestDir)
            if not ensureChestAhead() then groundFallback = true; break end
          end
        end
      end
    end
  end
  turtle.select(1)
  if pos.x ~= 0 then
    turnTo({ x = -1, z = 0 })
    while pos.x ~= 0 do if not step() then break end end
  end
  turnTo({ x = 0, z = 1 })
end

local function inventoryFull()
  for s = 3, 16 do
    if turtle.getItemCount(s) == 0 then return false end
  end
  return true
end

-- Offload now: remember where we are, go home, drop, come back. Returns
-- false if aborted during the trip.
local function offloadIfFull(returnDir)
  if not inventoryFull() then return true end
  local tx, ty, tz = pos.x, pos.y, pos.z
  setStatus("Inventory full — returning to drop loot...")
  notify("FULL", "Inventory full; returning to start to offload loot.")
  if not goTo(0, 0, 0) then return false end
  dropLootAtHome()
  goTo(tx, ty, tz)
  if returnDir then turnTo(returnDir) end
  return not aborting
end

-- === ROOM =============================================================
-- Mine one column in the given vertical direction. Returns false on stuck.
-- For HEIGHT==1 this is a no-op (the cell is already air under the turtle).
local function mineColumn(up)
  if up then
    for _ = 2, HEIGHT do
      if not safeUp() then return false end
      pos.y = pos.y + 1
    end
  else
    for _ = 2, HEIGHT do
      if not safeDown() then return false end
      pos.y = pos.y - 1
    end
  end
  return true
end

local function fuelNeededRoom()
  local columns    = WIDTH * LENGTH
  local vertical   = columns * (HEIGHT - 1)
  local horizontal = columns - 1
  local goHome     = (WIDTH - 1) + (LENGTH - 1) + (HEIGHT - 1)
  return vertical + horizontal + goHome
end

local function digRoom()
  while w < WIDTH do
    if aborting then break end
    turnTo({ x = 0, z = lengthDir })
    while l < LENGTH do
      if aborting then break end
      if not offloadIfFull({ x = 0, z = lengthDir }) then break end

      setStatus(("Digging column W%d L%d (%s)"):format(
            w + 1, l + 1, goingUp and "up" or "down"))
      if not mineColumn(goingUp) then break end
      doneColumns = doneColumns + 1
      goingUp = not goingUp

      l = l + 1
      if l < LENGTH then
        setStatus(("Moving to L%d"):format(l + 1))
        if not step() then break end
      end
      saveState()
    end
    if aborting then break end

    l = 0
    w = w + 1
    if w < WIDTH then
      setStatus(("Stepping to width row %d"):format(w + 1))
      turnTo({ x = 1, z = 0 })
      if not step() then break end
      lengthDir = -lengthDir
      saveState()
    end
  end
end

-- === HILL =============================================================
-- ponytail: cheap deterministic hash -> {-1, 0, +1}; reproducible across
-- resume (no RNG seed to persist). Gives the ramp a natural rough surface
-- instead of a sterile diagonal. No bit ops (Lua 5.1/CC:T safe).
local function surfaceJitter(x, li)
  local h = (x * 73856093 + li * 19349663) % 2147483647
  h = math.floor(h / 715827883) % 3
  return h - 1   -- -1, 0, or +1
end

-- Ramp surface height at cell (x, l). Linear rise 0 -> HIGH, jittered ±1,
-- clamped to [0, HIGH].
local function hillSurface(x, li)
  if LENGTH <= 1 then return HIGH end
  local base = math.floor(HIGH * li / (LENGTH - 1) + 0.5)
  local s = base + surfaceJitter(x, li)
  if s < 0 then s = 0 end
  if s > HIGH then s = HIGH end
  return s
end

-- Largest length-index (inclusive) whose surface at column x is below layer y.
-- Cells [0..lMax] at column x, layer y need carving; beyond is surface/soil.
local function hillLMax(x, y)
  local lMax = -1
  for li = 0, LENGTH - 1 do
    if hillSurface(x, li) < y then lMax = li end
  end
  return lMax
end

-- Carve column x from z=0..lMax at the current height (pos.y). Returns false
-- on stuck/abort. The per-column lMax is what gives the high edge its ragged,
-- natural variation across the width.
local function sweepColumn(x, lMax, sdir)
  local target = (sdir == 1) and lMax or 0
  -- if we're resuming mid-column, the turtle may already be past/short of
  -- target; the while loop below handles both by walking to target.
  turnTo({ x = 0, z = sdir })
  while pos.z ~= target do
    if not offloadIfFull({ x = 0, z = sdir }) then return false end
    if not step() then return false end
  end
  return true
end

local function fuelNeededHill()
  local cells = 0
  for y = 1, HIGH do
    for x = 0, WIDTH - 1 do
      cells = cells + (hillLMax(x, y) + 1)
    end
  end
  local ascend = HIGH
  local goHome = WIDTH + LENGTH + HIGH   -- worst-case reposition/return
  return cells + ascend + goHome
end

local function digHill()
  -- ascend to the top layer at the low-edge corner (digs through any material)
  for _ = 1, HIGH do
    if not safeUp() then return end
    pos.y = pos.y + 1
  end
  while hillY >= 1 do
    if aborting then break end
    if not goTo(0, hillY, 0) then break end
    setStatus(("Carving layer y=%d"):format(hillY))
    local sdir = 1
    for col = 0, WIDTH - 1 do
      if aborting then break end
      local lMax = hillLMax(col, hillY)
      if lMax >= 0 then
        if not sweepColumn(col, lMax, sdir) then break end
      end
      if col < WIDTH - 1 then
        turnTo({ x = 1, z = 0 })
        if not step() then break end
        sdir = -sdir
      end
    end
    doneLayers = doneLayers + 1
    hillY = hillY - 1
    saveState()
  end
end

-- --- pre-flight --------------------------------------------------------
local function fuelNeeded()
  return (mode == "hill") and fuelNeededHill() or fuelNeededRoom()
end

refuelFrom(FUEL_SLOT)   -- greedy: burn everything in the dedicated fuel slot
do
  local have  = turtle.getFuelLevel()
  local need  = fuelNeeded()
  local level = (have == "unlimited") and math.huge or have
  if level < need then
    -- warn but proceed; the turtle will pause for fuel mid-dig when it runs out
    notify("FUEL", ("Need ~%d fuel, have %s. Starting anyway; will pause for refuel.")
           :format(need, tostring(have)))
  end
  term.clear()
  if mode == "hill" then
    log(("Hill %dx%d rise %d  (need ~%d fuel, have %s)"):format(
          WIDTH, LENGTH, HIGH, need, tostring(have)))
  else
    log(("Room %dx%dx%d  (need ~%d fuel, have %s)"):format(
          WIDTH, HEIGHT, LENGTH, need, tostring(have)))
  end
end

-- start or resume
if not tryResume() then
  clearState()   -- discard any stale state from a different job
  pos, heading   = { x = 0, y = 0, z = 0 }, { x = 0, z = 1 }
  w, l, lengthDir, goingUp = 0, 0, 1, true
  hillY, doneLayers = HIGH or 0, 0
  doneColumns, aborting, chestsUsed, blockLog = 0, false, 0, {}
end
saveState()

-- --- main dig dispatch ------------------------------------------------
if mode == "hill" then
  digHill()
else
  digRoom()
end

-- --- return to start ---------------------------------------------------
if aborting then
  setStatus("ABORTED — returning home with loot...")
  notify("ABORT", "Dig aborted. Returning to start to drop what was mined.")
else
  setStatus("Returning to start...")
end
goTo(0, 0, 0)
turnTo({ x = 0, z = -1 })   -- face the entrance (-z) for the final drop

-- --- drop loot ---------------------------------------------------------
setStatus("Dropping loot...")
dropLootAtHome()

-- --- final report ------------------------------------------------------
local blockBits = {}
for name, count in pairs(blockLog) do
  blockBits[#blockBits + 1] = ("%s x%d"):format(name, count)
end
table.sort(blockBits)
local blockSummary = (#blockBits > 0)
  and (" | mined: " .. table.concat(blockBits, ", ")) or ""

local progressWord = (mode == "hill") and "layers" or "columns"
local doneCount    = (mode == "hill") and doneLayers or doneColumns
local totalCount   = (mode == "hill") and totalLayers or totalColumns
local summary = ("Done. %d/%d %s, %d chest(s) used.%s%s"):format(
  doneCount, totalCount, progressWord, chestsUsed,
  aborting and " (ABORTED early)" or "", blockSummary)
setStatus(summary)
notify("DONE", summary)
clearState()
print("")
