--[[
  dig_room.lua — carve a rectangular room.
  Turtle starts at the LOWER-LEFT-FRONT corner, facing the LENGTH direction.

    WIDTH  = blocks across  (left/right)
    HEIGHT = blocks up
    LENGTH = blocks forward (face this way at start)

  Pattern: column-by-column. At each floor cell the turtle sweeps a 1x1
  vertical shaft up through HEIGHT, returns to the floor, then steps to the
  next cell in a boustrophedon (snake) path across the W x L floor.

  Inventory:
    slot 1 = FUEL  (never dropped as loot)
    slot 2 = CHEST (auto-placed; chained into a row when one fills up)

  Extras: pre-flight fuel check + refuel from slot 1, gravel/falling-block
  re-dig, live status display, multi-chest loot drop, chat alerts on
  out-of-fuel / done / stuck.

  Alerts: uses a Plethora/Sc-Peripherals `chatBox` if present, else falls
  back to `rednet.broadcast` if a modem is attached, else just prints.

  Usage:  dig_room <width> <height> <length>
--]]

local args = { ... }
if #args < 3 then
  print("Usage: dig_room <width> <height> <length>")
  print("  width  = blocks across (left/right)")
  print("  height = blocks up")
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

local FUEL_SLOT  = 1
local CHEST_SLOT = 2
local STUCK_LIMIT = 15   -- failed move attempts before declaring stuck

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
    -- Plethora: say() broadcasts to all players near the turtle
    pcall(function() chatBox.say(full) end)
  elseif modem then
    pcall(function() rednet.broadcast(full, "dig_room") end)
  end
  -- no chatBox/modem: print() above is the only channel
end

-- --- live status display ----------------------------------------------
local totalColumns = WIDTH * LENGTH
local doneColumns  = 0

local function setStatus(msg)
  term.setCursorPos(1, 1); term.clearLine(); term.write(msg or "")
  term.setCursorPos(1, 2); term.clearLine()
  term.write(("Progress: %d / %d columns  (%d%%)"):format(
        doneColumns, totalColumns,
        math.floor(doneColumns / totalColumns * 100)))
  term.setCursorPos(1, 3); term.clearLine()
  term.write(("Fuel: %s   |   loot slots 3-16   |   chests used: see log")
             :format(tostring(turtle.getFuelLevel())))
end

local function log(msg)
  local _, h = term.getSize()
  term.setCursorPos(1, h); term.scroll(1); term.write(msg or "")
end

-- --- falling-block-safe dig/move helpers -----------------------------
local aborting = false   -- set true when stuck; main loops bail out

local function digUntilClear(detect, dig)
  local tries = 0
  while detect() and tries < 40 do
    dig(); sleep(0.3); tries = tries + 1
  end
end

local function refuelFromSlot1(target)
  if turtle.getFuelLevel() == "unlimited" then return true end
  if turtle.getItemCount(FUEL_SLOT) == 0 then return false end
  turtle.select(FUEL_SLOT)
  while turtle.getFuelLevel() < (target or 4000) and turtle.refuel(1) do end
  turtle.select(1)
  return true
end

-- every safe* mover returns false when stuck, true on success
local function safeForward()
  digUntilClear(turtle.detect, turtle.dig)
  local tries = 0
  while not turtle.forward() do
    if turtle.getFuelLevel() == 0 then
      refuelFromSlot1()
      if turtle.getFuelLevel() == 0 then
        notify("FUEL", "Out of fuel! Add fuel to slot 1, then press any key.")
        setStatus("OUT OF FUEL — waiting for refuel...")
        os.pullEvent("key")
        refuelFromSlot1()
      end
    end
    digUntilClear(turtle.detect, turtle.dig)
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
  digUntilClear(turtle.detectUp, turtle.digUp)
  local tries = 0
  while not turtle.up() do
    if turtle.getFuelLevel() == 0 then refuelFromSlot1() end
    digUntilClear(turtle.detectUp, turtle.digUp)
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
  digUntilClear(turtle.detectDown, turtle.digDown)
  local tries = 0
  while not turtle.down() do
    if turtle.getFuelLevel() == 0 then refuelFromSlot1() end
    digUntilClear(turtle.detectDown, turtle.digDown)
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

-- --- position / heading tracking (for the return trip) ----------------
local pos     = { x = 0, z = 0 }
local heading = { x = 0, z = 1 }

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

-- --- the room ----------------------------------------------------------
local function sweepColumn()
  for _ = 2, HEIGHT do if not safeUp() then return false end end
  for _ = 2, HEIGHT do if not safeDown() then return false end end
  doneColumns = doneColumns + 1
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

-- pre-flight fuel check
refuelFromSlot1()
do
  local have  = turtle.getFuelLevel()
  local need  = fuelNeeded()
  local level = (have == "unlimited") and math.huge or have
  if level < need then
    notify("FUEL", ("Need ~%d fuel, have %s. Refuel slot 1 and retry.")
           :format(need, tostring(have)))
    return
  end
  term.clear()
  log(("Room %dx%dx%d  (need ~%d fuel, have %s)"):format(
        WIDTH, HEIGHT, LENGTH, need, tostring(have)))
end

local lengthDir = 1
for w = 0, WIDTH - 1 do
  if aborting then break end
  turnTo({ x = 0, z = lengthDir })
  for l = 0, LENGTH - 1 do
    if aborting then break end
    setStatus(("Digging column W%d L%d"):format(w + 1, l + 1))
    if not sweepColumn() then break end
    if l < LENGTH - 1 then
      setStatus(("Moving to L%d"):format(l + 2))
      if not step() then break end
    end
  end
  if w < WIDTH - 1 and not aborting then
    setStatus(("Stepping to width row %d"):format(w + 2))
    turnTo({ x = 1, z = 0 })
    if not step() then break end
    lengthDir = -lengthDir
  end
end

-- --- return to start ---------------------------------------------------
if aborting then
  setStatus("ABORTED — returning home with loot...")
  notify("ABORT", "Dig aborted. Returning to start to drop what was mined.")
else
  setStatus("Returning to start...")
end
turnTo({ x = -1, z = 0 })
while pos.x > 0 do if not step() then break end end
turnTo({ x = 0, z = -1 })
while pos.z > 0 do if not step() then break end end
turnTo({ x = 0, z = -1 })   -- face the entrance (-z)

-- --- multi-chest loot drop --------------------------------------------
-- Chests are placed in a row along +x at z=-1 (the entrance lip). When a
-- chest fills, the turtle sidesteps +x and places the next one. If slot 2
-- runs out of chests, remaining loot is dropped on the ground into the room.
local chestsUsed = 0

local function ensureChestAhead()
  -- place a chest in front if the cell is empty and we still have one
  if turtle.detect() then
    -- only treat it as reusable if it's actually a chest
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

setStatus("Dropping loot...")
ensureChestAhead()   -- chest #1 directly in front of (0,0)

local groundFallback = false
for s = 3, 16 do
  if turtle.getItemCount(s) > 0 then
    turtle.select(s)
    if groundFallback then
      -- no chests left: face into the room (+z, open air) and dump on ground
      turnTo({ x = 0, z = 1 })
      turtle.drop()
      turnTo({ x = 0, z = -1 })
    else
      while turtle.getItemCount(s) > 0 do
        if turtle.drop() then
          -- slot emptied (into chest or onto ground if no chest)
        else
          -- chest full (drop() false). Need a new chest or fall back.
          if turtle.getItemCount(CHEST_SLOT) == 0 then
            notify("WARN", "Ran out of chests! Dumping remaining loot on the ground.")
            groundFallback = true
            break
          end
          -- sidestep +x to a fresh cell, face -z, place next chest
          turnTo({ x = 1, z = 0 })
          if not step() then break end
          turnTo({ x = 0, z = -1 })
          if not ensureChestAhead() then
            groundFallback = true
            break
          end
        end
      end
    end
  end
end
turtle.select(1)

-- final report
local summary = ("Done. %d/%d columns, %d chest(s) used.%s"):format(
  doneColumns, totalColumns, chestsUsed,
  aborting and " (ABORTED early)" or "")
setStatus(summary)
notify("DONE", summary)
print("")
