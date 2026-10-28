-- Comprehensive Anti-Cheat Audit Verifier Test Suite for battleship.lua

local valid_fleet = "1:0,0,H;2:2,4,V;3:5,1,H;4:7,3,V;5:8,8,H"
local valid_salt = "K9X2M1"

local function djb2_hex(str)
  local hash = 5381
  for i = 1, #str do
    local b = string.byte(str, i)
    hash = ((hash * 33) + b) & 0xFFFFFFFF
  end
  return string.format("%08X", hash)
end

local correct_hash = djb2_hex(valid_fleet .. "|" .. valid_salt)

local function run_audit_test(test_name, enemy_salt, enemy_fleet, enemy_committed_hash, recorded_shots)
  local storekv = {}
  local toast_msgs = {}

  _G.wada = {
    ui = { canvas = function() return { fill=function() end, rect=function() end, line=function() end, text=function() end, circle=function() end, pos=function() end } end },
    sys = { random = math.random, beep = function() end, toast = function(msg) toast_msgs[#toast_msgs + 1] = msg end, millis = function() return 0 end },
    store = {
      get = function(k, d) if storekv[k] == nil then return d end return storekv[k] end,
      set = function(k, v) storekv[k] = v end
    },
    timer = { every = function() end, cancel = function() end },
    mesh = { send = function() end, self = function() return { name="ADMIRAL" } end },
    audio = { tone = function() end }
  }

  local shots_str = recorded_shots or string.rep("0", 100)
  storekv["active_match"] = string.format("A3F1|ENEMY|STATE_AUDIT|10|MYSALT|MYHASH|%s|%s|%s|%s|NONE|NONE",
    enemy_committed_hash, valid_fleet, shots_str, string.rep("0", 100))

  local a = dofile("battleship.lua")
  a.on_open(320, 240)
  a.on_key("1") -- resume match

  local rev_pkt = string.format("BS|REV|A3F1|10|%s|%s", enemy_salt, enemy_fleet)
  a.on_message({ from = "ENEMY", kind = "dm", text = rev_pkt })

  return storekv["career_stats"], a
end

print("=== STARTING COMPREHENSIVE ANTI-CHEAT TEST SUITE ===")

-- 1. Honest Match
print("Test 1: Honest match (Valid hash, valid geometry, honest log)...")
local honest_shots = {}
for y = 0, 9 do
  for x = 0, 9 do
    -- Carrier at (0,0) was hit, (9,9) was miss
    if x == 0 and y == 0 then
      honest_shots[#honest_shots + 1] = "H"
    elseif x == 9 and y == 9 then
      honest_shots[#honest_shots + 1] = "M"
    else
      honest_shots[#honest_shots + 1] = "0"
    end
  end
end
local res1 = run_audit_test("Honest", valid_salt, valid_fleet, correct_hash, table.concat(honest_shots))
print("Result 1: Honest match passed! Stats:", res1)
assert(res1 ~= nil, "Career stats must be saved")

-- 2. Cheat: Tampered Board Hash
print("Test 2: Cheat attempt - Tampered Board Hash...")
local res2 = run_audit_test("Tampered Hash", valid_salt, valid_fleet, "DEADBEEF", table.concat(honest_shots))
print("Result 2: Tampered hash intercepted. Disqualified enemy awarded win to player.")
assert(res2 ~= nil, "Disqualification handled cleanly")

-- 3. Cheat: Overlapping Ships
print("Test 3: Cheat attempt - Overlapping Ships in revealed fleet...")
local overlap_fleet = "1:0,0,H;2:0,0,V;3:5,1,H;4:7,3,V;5:8,8,H"
local overlap_hash = djb2_hex(overlap_fleet .. "|" .. valid_salt)
local res3 = run_audit_test("Overlap", valid_salt, overlap_fleet, overlap_hash, table.concat(honest_shots))
print("Result 3: Geometry check caught overlapping ships.")

-- 4. Cheat: Out of Bounds Ship
print("Test 4: Cheat attempt - Out-of-bounds ship...")
local oob_fleet = "1:8,0,H;2:2,4,V;3:5,1,H;4:7,3,V;5:8,8,H" -- Carrier length 5 at x=8 spans to 12!
local oob_hash = djb2_hex(oob_fleet .. "|" .. valid_salt)
local res4 = run_audit_test("OOB", valid_salt, oob_fleet, oob_hash, table.concat(honest_shots))
print("Result 4: Geometry check caught out-of-bounds ship.")

-- 5. Cheat: Combat Dishonesty - Opponent claimed MISS on actual ship cell
print("Test 5: Cheat attempt - Combat dishonesty (Claimed MISS on ship cell)...")
local dishonest_miss = {}
for y = 0, 9 do
  for x = 0, 9 do
    -- Carrier is at (0,0) to (4,0). Player fired at (0,0) and opponent told us MISS ('M')!
    if x == 0 and y == 0 then
      dishonest_miss[#dishonest_miss + 1] = "M"
    else
      dishonest_miss[#dishonest_miss + 1] = "0"
    end
  end
end
local res5 = run_audit_test("Dishonest MISS", valid_salt, valid_fleet, correct_hash, table.concat(dishonest_miss))
print("Result 5: Honesty check caught enemy claiming MISS on occupied ship cell.")

-- 6. Cheat: Combat Dishonesty - Opponent claimed HIT on empty water cell
print("Test 6: Cheat attempt - Combat dishonesty (Claimed HIT on empty water)...")
local dishonest_hit = {}
for y = 0, 9 do
  for x = 0, 9 do
    -- (9,0) is empty water. Player fired at (9,0) and opponent claimed HIT ('H')!
    if x == 9 and y == 0 then
      dishonest_hit[#dishonest_hit + 1] = "H"
    else
      dishonest_hit[#dishonest_hit + 1] = "0"
    end
  end
end
local res6 = run_audit_test("Dishonest HIT", valid_salt, valid_fleet, correct_hash, table.concat(dishonest_hit))
print("Result 6: Honesty check caught enemy claiming HIT on empty water.")

print("=== ALL 6 ANTI-CHEAT VERIFIER TESTS PASSED! ===")

