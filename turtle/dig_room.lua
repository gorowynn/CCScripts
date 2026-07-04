--[[
  dig_room.lua — carve a rectangular room.
  Turtle starts at the LOWER-LEFT-FRONT corner, facing the LENGTH direction.

    WIDTH  = blocks across  (left/right)
    HEIGHT = blocks up       (1 is fine; 1x1x1 is rejected — nothing to dig)
    LENGTH = blocks forward  (face this way at start)

  Pattern: column-by-column. At each floor cell the turtle sweeps a 1x1
  vertical shaft up through HEIGHT, returns to the floor, then steps to the
  next cell in a boustrophedon (snake) path across the W x L floor.

  Inventory:
    slot 1 = FUEL  (never dropped as loot)
    slot 2 = CHEST (auto-placed; chained into a row when one fills up)

  Extras:
    - Pre-flight fuel check + refuel from slot 1
    - Loot-fuel fallback: when slot 1 empties, burn coal/lava/etc. from any
      loot slot (3-16) before pausing for a manual refuel
    - Inventory-full mid-dig: returns to start, offloads into chests (places/
      chains them, ground-dump fallback if out of chests), then resumes at the
      exact column it left off
    - Resume after restart: progress is saved every column to .dig_room_state;
      re-running with the same <w h l> resumes, a different size starts fresh
    - Ore logging: every block is inspected before digging; ores are tallied
      and reported at the end
    - Gravel/falling-block re-dig, live status display, chat alerts

  Alerts: uses a Plethora/Sc-Peripherals `chatBox` if present, else falls
  back to `rednet.broadcast` if a modem is attached, else just prints.

  Usage:  dig_room <width> <height> <length>
--]]

local args = { ... }
if #args < 3 then
  print("Usage: dig_room <width> <height> <length>")
  print("  width  = blocks across (left/right)")
  print("  height = blocks up (1 ok; 1x1x1 rejected)")
  print("  length = blocks forward (face this way at start)")
  return
end

local WIDTH  = tonumber(args[1])
local HEIGHT = tonumber(args[2])
local LENGTH = tonumber(args[3])
if not (WIDTH and HEIGHT and LENGTH)
   or WIDTH < 1 or HEIGHT < 1 or LENGTH < 1 then
  printError("width, height and length must be positive integers")
  return
end
if WIDTH * HEIGHT * LENGTH < 2 then
  -- only 1x1x1 reaches here: the turtle already occupies the sole cell
  printError("1x1x1 has nothing to dig (the turtle is already in the only cell).")
  printError("Increase at least one dimension.")
  return
end

local FUEL_SLOT   = 1
local CHEST_SLOT  = 2
local STUCK_LIMIT = 15   -- failed move attempts before declaring stuck
local STATE_FILE  = ".dig_room_state"

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
    pcall(function() rednet.broadcast(full, "dig_room") end)
  end
end

-- --- live status display ----------------------------------------------
local totalColumns = WIDTH * LENGTH

local function setStatus(msg, done)
  term.setCursorPos(1, 1); term.clearLine(); term.write(msg or "")
  term.setCursorPos(1, 2); term.clearLine()
  term.write(("Progress: %d / %d columns  (%d%%)"):format(
        done, totalColumns,
        math.floor(done / totalColumns * 100)))
  term.setCursorPos(1, 3); term.clearLine()
  term.write(("Fuel: %s   |   loot slots 3-16   |   chests used: see log")
             :format(tostring(turtle.getFuelLevel())))
end

local function log(msg)
  local _, h = term.getSize()
  term.setCursorPos(1, h); term.scroll(1); term.write(msg or "")
end

-- --- run state (all resumable) ----------------------------------------
local pos         = { x = 0, z = 0 }
local heading     = { x = 0, z = 1 }
local w           = 0          -- current width index  [0..WIDTH-1]
local l           = 0          -- current length index [0..LENGTH-1]
local lengthDir   = 1          -- +1 or -1 (snake direction along z)
local doneColumns = 0
local aborting    = false
local chestsUsed  = 0
local oreLog      = {}         -- ore name (no namespace) -> count

-- --- state persistence ------------------------------------------------
local function saveState()
  local f = fs.open(STATE_FILE, "w")
  if not f then return end
  f.write(textutils.serialize({
    dims         = { WIDTH, HEIGHT, LENGTH },
    pos          = pos,
    heading      = heading,
    w            = w,
    l            = l,
    lengthDir    = lengthDir,
    doneColumns  = doneColumns,
    aborting     = aborting,
    chestsUsed   = chestsUsed,
    oreLog       = oreLog,
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
  local d = data.dims
  if d[1] ~= WIDTH or d[2] ~= HEIGHT or d[3] ~= LENGTH then
    return false   -- different job; caller will start fresh
  end
  pos, heading     = data.pos, data.heading
  w, l, lengthDir  = data.w, data.l, data.lengthDir
  doneColumns      = data.doneColumns or 0
  aborting         = data.aborting or false
  chestsUsed       = data.chestsUsed or 0
  oreLog           = data.oreLog or {}
  notify("RESUME", ("Resuming at W%d L%d (%d/%d columns)")
         :format(w + 1, l + 1, doneColumns, totalColumns))
  return true
end

-- On resume, walk down through already-carved air until solid floor, without
-- digging. At a column boundary detectDown() is immediately true (no move);
-- a mid-column reboot is recovered by descending to the floor.
local function descendToFloor()
  local guard = 0
  while not turtle.detectDown() and guard < HEIGHT do
    if not turtle.down() then break end
    guard = guard + 1
  end
end

-- --- fuel -------------------------------------------------------------
-- Burn fuel from `slot` until level reaches `target` (default: max) or slot
-- is empty. Greedy by default — pre-flight passes no target so all of slot 1
-- is consumed.
local function refuelFrom(slot, target)
  if turtle.getFuelLevel() == "unlimited" then return end
  target = target or math.huge
  turtle.select(slot)
  while turtle.getFuelLevel() < target and turtle.refuel(1) do end
  turtle.select(1)
end

-- Burns slot 1 first, then any fuel in loot slots 3-16. Mid-dig fallback tops
-- up to `target` (default 4000) rather than torching all the loot coal.
local function refuelAll(target)
  target = target or 4000
  refuelFrom(FUEL_SLOT, target)
  if turtle.getFuelLevel() < target then
    for s = 3, 16 do refuelFrom(s, target) end
  end
end

-- --- ore logging ------------------------------------------------------
-- ponytail: substring match catches every *_ore and deepslate variant plus
-- ancient_debris; no curated list to maintain.
local function isOre(name)
  return name and (name:find("_ore", 1, true) ~= nil
                   or name == "minecraft:ancient_debris")
end

local function noteOre(info)
  if not info then return end
  local short = (info.name or ""):gsub("^minecraft:", "")
  if isOre(info.name) then
    oreLog[short] = (oreLog[short] or 0) + 1
    log(("ore: %s"):format(short))
  end
end

-- --- falling-block-safe dig/move helpers -----------------------------
local function digUntilClear(detect, dig, inspectFn)
  local tries = 0
  while detect() and tries < 40 do
    if inspectFn then
      local ok, info = inspectFn()
      if ok then noteOre(info) end
    end
    dig(); sleep(0.3); tries = tries + 1
  end
end

local function safeForward()
  digUntilClear(turtle.detect, turtle.dig, turtle.inspect)
  local tries = 0
  while not turtle.forward() do
    if turtle.getFuelLevel() == 0 then
      refuelAll()
      if turtle.getFuelLevel() == 0 then
        notify("FUEL", "Out of fuel! Add fuel to slot 1, then press any key.")
        setStatus("OUT OF FUEL — waiting for refuel...", doneColumns)
        os.pullEvent("key")
        refuelAll()
      end
    end
    digUntilClear(turtle.detect, turtle.dig, turtle.inspect)
    sleep(0.2); tries = tries + 1
    if tries >= STUCK_LIMIT then
      notify("STUCK", "Can't move forward after " .. STUCK_LIMIT ..
             " tries (unbreakable block?). Aborting dig, returning home.")
      aborting = true
      return false
    end
  end
  return true
end

local function safeUp()
  digUntilClear(turtle.detectUp, turtle.digUp, turtle.inspectUp)
  local tries = 0
  while not turtle.up() do
    if turtle.getFuelLevel() == 0 then refuelAll() end
    digUntilClear(turtle.detectUp, turtle.digUp, turtle.inspectUp)
    sleep(0.2); tries = tries + 1
    if tries >= STUCK_LIMIT then
      notify("STUCK", "Can't move up after " .. STUCK_LIMIT ..
             " tries. Aborting dig, returning home.")
      aborting = true
      return false
    end
  end
  return true
end

local function safeDown()
  digUntilClear(turtle.detectDown, turtle.digDown, turtle.inspectDown)
  local tries = 0
  while not turtle.down() do
    if turtle.getFuelLevel() == 0 then refuelAll() end
    digUntilClear(turtle.detectDown, turtle.digDown, turtle.inspectDown)
    sleep(0.2); tries = tries + 1
    if tries >= STUCK_LIMIT then
      notify("STUCK", "Can't move down after " .. STUCK_LIMIT ..
             " tries. Aborting dig, returning home.")
      aborting = true
      return false
    end
  end
  return true
end

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

-- Navigate to a floor cell (tx, tz). Path is carved air, so no digging
-- expected. Returns false (and sets aborting) if blocked.
local function goTo(tx, tz)
  if pos.x < tx then turnTo({ x = 1, z = 0 })
  elseif pos.x > tx then turnTo({ x = -1, z = 0 }) end
  while pos.x ~= tx do if not step() then return false end end
  if pos.z < tz then turnTo({ x = 0, z = 1 })
  elseif pos.z > tz then turnTo({ x = 0, z = -1 }) end
  while pos.z ~= tz do if not step() then return false end end
  return true
end

-- --- the room ----------------------------------------------------------
local function sweepColumn()
  for _ = 2, HEIGHT do if not safeUp() then return false end end
  for _ = 2, HEIGHT do if not safeDown() then return false end end
  return true
end

local function fuelNeeded()
  local columns   = WIDTH * LENGTH
  local vertical  = columns * 2 * (HEIGHT - 1)
  local lengthFwd = WIDTH * (LENGTH - 1)
  local sideSteps = WIDTH - 1
  local goHome    = (WIDTH - 1) + (LENGTH - 1)
  return vertical + lengthFwd + sideSteps + goHome
end

-- --- loot drop (reused by mid-dig offload and final drop) -------------
-- Assumes turtle is at (0,0). Places/reuses chests along +x at z=-1; chains
-- a new chest when one fills. Falls back to dumping into the room if chests
-- run out. Leaves the turtle back at (0,0) facing +z (into the room).
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

local function dropLootAtHome()
  turnTo({ x = 0, z = -1 })
  ensureChestAhead()
  local groundFallback = false
  for s = 3, 16 do
    if turtle.getItemCount(s) > 0 then
      turtle.select(s)
      if groundFallback then
        turnTo({ x = 0, z = 1 }); turtle.drop(); turnTo({ x = 0, z = -1 })
      else
        while turtle.getItemCount(s) > 0 do
          if turtle.drop() then
            -- slot emptied
          else
            -- chest full (or no chest): chain a new one or fall back
            if turtle.getItemCount(CHEST_SLOT) == 0 then
              notify("WARN", "Ran out of chests! Dumping remaining loot on the ground.")
              groundFallback = true
              break
            end
            turnTo({ x = 1, z = 0 })
            if not step() then break end
            turnTo({ x = 0, z = -1 })
            if not ensureChestAhead() then groundFallback = true; break end
          end
        end
      end
    end
  end
  turtle.select(1)
  -- return to origin so callers know where we are
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

-- --- pre-flight --------------------------------------------------------
refuelFrom(FUEL_SLOT)   -- greedy: burn everything in the fuel slot
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
  log(("Room %dx%dx%d  (need ~%d fuel, have %s)"):format(
        WIDTH, HEIGHT, LENGTH, need, tostring(have)))
end

-- start or resume
if not tryResume() then
  clearState()   -- discard any stale state from a different job
  pos, heading   = { x = 0, z = 0 }, { x = 0, z = 1 }
  w, l, lengthDir = 0, 0, 1
  doneColumns, aborting, chestsUsed, oreLog = 0, false, 0, {}
else
  descendToFloor()
end
saveState()

-- --- main dig loop ----------------------------------------------------
while w < WIDTH do
  if aborting then break end
  turnTo({ x = 0, z = lengthDir })
  while l < LENGTH do
    if aborting then break end

    -- mid-dig offload when every loot slot is occupied
    if inventoryFull() then
      local tx, tz = pos.x, pos.z
      setStatus("Inventory full — returning to drop loot...", doneColumns)
      notify("FULL", "Inventory full; returning to start to offload loot.")
      if goTo(0, 0) then
        dropLootAtHome()
        goTo(tx, tz)
      end
      turnTo({ x = 0, z = lengthDir })
      saveState()
      if aborting then break end
    end

    setStatus(("Digging column W%d L%d"):format(w + 1, l + 1), doneColumns)
    if not sweepColumn() then break end
    doneColumns = doneColumns + 1

    l = l + 1
    if l < LENGTH then
      setStatus(("Moving to L%d"):format(l + 1), doneColumns)
      if not step() then break end
    end
    saveState()   -- invariant: saved (w,l) = next column to dig
  end
  if aborting then break end

  l = 0
  w = w + 1
  if w < WIDTH then
    setStatus(("Stepping to width row %d"):format(w + 1), doneColumns)
    turnTo({ x = 1, z = 0 })
    if not step() then break end
    lengthDir = -lengthDir
    saveState()
  end
end

-- --- return to start ---------------------------------------------------
if aborting then
  setStatus("ABORTED — returning home with loot...", doneColumns)
  notify("ABORT", "Dig aborted. Returning to start to drop what was mined.")
else
  setStatus("Returning to start...", doneColumns)
end
goTo(0, 0)
turnTo({ x = 0, z = -1 })   -- face the entrance (-z) for the final drop

-- --- drop loot ---------------------------------------------------------
setStatus("Dropping loot...", doneColumns)
dropLootAtHome()

-- --- final report ------------------------------------------------------
local oreBits = {}
for name, count in pairs(oreLog) do
  oreBits[#oreBits + 1] = ("%s x%d"):format(name, count)
end
table.sort(oreBits)
local oreSummary = (#oreBits > 0) and (" | ores: " .. table.concat(oreBits, ", ")) or ""

local summary = ("Done. %d/%d columns, %d chest(s) used.%s%s"):format(
  doneColumns, totalColumns, chestsUsed,
  aborting and " (ABORTED early)" or "", oreSummary)
setStatus(summary, doneColumns)
notify("DONE", summary)
clearState()
print("")
