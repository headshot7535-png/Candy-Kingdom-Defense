-- Candy Kingdom Defense battle simulator (runs inside the match place, uses the running Smart Farm's helpers)
-- SIM.run(stageId, team, {hp = k, cash = c}) plays a stage with the farm's own economy and returns
-- {won, lives, leaks, wave, t}. SIM.margin finds the largest enemy-HP multiplier the team still wins at.
local SF = _G.CKD_SF
local C, MT = SF.C, SF.MT
local Cat = C.Catalog
local RS = game:GetService("ReplicatedStorage")
local CTD = RS:WaitForChild("CandyTD")
local Enemies = require(CTD.Enemies)
local W = require(CTD.ToonKit).WORLD
local MatchPath = require(CTD.MatchPath)

local SIM = { layouts = {} }
local PATHS = { candy = "MatchPath", ice = "IcePath", fire = "FirePath", mo = "MoPath", lemon = "LemonPath",
    nightosphere = "NightPath", crystal = "CrystalPath", haunt = "HauntPath", lich = "LichPath" }

function SIM.layout(stageId)
    local world = Cat.worldOf(stageId)
    local key = world and world.id or "candy"
    if SIM.layouts[key] then return SIM.layouts[key] end
    local mod = require(CTD:WaitForChild(PATHS[key] or "MatchPath"))
    local L = mod.layout(nil)
    local path = L.designPath
    -- legal spots near the road (the game's own canPlace), and road samples
    local spots, b = {}, L.bounds or mod.BOUNDS or MatchPath.BOUNDS
    local n = 0
    for x = b.minX + 4, b.maxX - 4, 3 do
        for z = b.minZ + 4, b.maxZ - 4, 3 do
            local p = Vector3.new(x, 0.25, z)
            if path:distanceTo(p) <= 46 and MatchPath.canPlace(L, p * W, {}) then table.insert(spots, { x = x, z = z }) end
            n = n + 1
            if n % 2000 == 0 then task.wait() end
        end
    end
    local entry = { L = L, path = path, pts = path.pts, step = path.step, length = path.length, spots = spots, cov = {} }
    SIM.layouts[key] = entry
    return entry
end

-- placement strategies: weight of a road sample by how far down the road it is (f = 0 entrance … 1 exit)
SIM.STRATS = {
    even = function(f) return 1 end,                              -- most road covered
    front = function(f) return 1.35 - 0.6 * f end,                -- the farm's current weighting
    entrance = function(f) return f < 0.35 and 1.5 or 0.25 end,   -- stack the first third
    middle = function(f) return (f > 0.25 and f < 0.65) and 1.5 or 0.4 end,
    exit = function(f) return 0.4 + 1.2 * f end,                  -- last line of defense
}
local function coverage(E, x, z, r, wf)
    local r2, s, n = r * r, 0, #E.pts
    for i, p in ipairs(E.pts) do
        if (p.X - x) ^ 2 + (p.Z - z) ^ 2 <= r2 then s = s + (wf and wf(i / n) or 1) end
    end
    return s
end
local function covOrder(E, r, strat)
    strat = strat or "even"
    local key = math.floor(r + 0.5) .. ":" .. strat
    if E.cov[key] then return E.cov[key] end
    local wf = SIM.STRATS[strat]
    local t = {}
    for i, s in ipairs(E.spots) do t[i] = coverage(E, s.x, s.z, math.floor(r + 0.5), wf); if i % 500 == 0 then task.wait() end end
    local order = {}
    for i = 1, #t do order[i] = i end
    table.sort(order, function(a, b) return t[a] > t[b] end)
    t.order = order
    E.cov[key] = t
    return t
end

-- team entry: {kind, level, trait, g}
-- The game rewrites LEVELS tables in place: your heroes for their real level/trait/grade (Jake 41 → 355),
-- heroes you don't own at the default ×2.6 (Candy Elemental 135 → 351). Rescale from whatever the table
-- holds now (row 1 vs the base row) to what this team entry should have.
local function mults(u, opts)
    local tm = Cat.traitMults(u.trait)
    local gm = C.M.gradeMults(u.g)
    local want = { dmg = Cat.damageMult(u.level or 1) * tm.dmg * gm.dmg, range = tm.range * gm.range, speed = tm.speed * gm.speed }
    local L, base = MT.levels(u.kind), SF.B.rows and SF.B.rows[u.kind]
    local have = { dmg = 1, range = 1, speed = 1 }
    if L and L[1] and base and base.dmg and base.dmg > 0 then
        have.dmg = L[1].dmg / base.dmg
        have.range = (base.range and base.range > 0) and L[1].range / base.range or 1
        have.speed = (L[1].cd and L[1].cd > 0 and base.cd) and base.cd / L[1].cd or 1
    end
    return { dmg = want.dmg / have.dmg * (opts.dmg or 1), range = want.range / have.range, speed = want.speed / have.speed, cost = tm.cost }
end

function SIM.run(stageId, team, opts)
    opts = opts or {}
    -- kills pay reward × STAGE_CASH (measured live: Candy Zombie 5 → 8), plus each wave's clear bonus
    opts.cash = opts.cash or Cat.STAGE_CASH or 1.5
    local stage = Cat.stage(stageId)
    local E = SIM.layout(stageId)
    local waves = Cat.stageWaves(stage)
    local nW = #waves
    local clock = (stage.minutes or Cat.WAVE_CLOCK.minutes or 5) * 60 / nW
    local money, lives = stage.money or 1000, stage.lives or 10
    local units = {}
    for _, u in ipairs(team) do
        local L = MT.levels(u.kind)
        if L then units[u.kind] = { u = u, L = L, m = mults(u, opts), cap = Cat.placeCap(u.kind), n = 0 } end
    end
    local towers, enemies, spawns = {}, {}, {}
    -- spawn schedule from the stage's own wave list
    for w, groups in ipairs(waves) do
        local t0 = 3 + (w - 1) * clock
        local hpW = Cat.stageWaveHp(stage, w) * (opts.hp or 1)
        for _, g in ipairs(groups) do
            local T = Enemies.TYPES[g[1]]
            if T then
                local delay, interval = tonumber(g[4]) or 0, tonumber(g[3]) or 1
                for i = 1, tonumber(g[2]) or 1 do
                    table.insert(spawns, { t = t0 + delay + (i - 1) * interval, type = T, hp = T.hp * hpW * (tonumber(g[5]) or 1), w = w })
                end
            end
        end
    end
    table.sort(spawns, function(a, b) return a.t < b.t end)
    local si, t, dt = 1, 0, 0.25
    local leaks, lastWave = 0, 1
    local bonusPaid = {}
    local killDist, kills = 0, 0
    local lastSpawnT = spawns[#spawns] and spawns[#spawns].t or 0
    local function kindsNear(x, z, skip)
        local k, r = {}, Cat.PASSIVE_RADIUS or 16
        for _, tw in ipairs(towers) do if tw ~= skip and (tw.x - x) ^ 2 + (tw.z - z) ^ 2 <= r * r then k[tw.kind] = true end end
        return k
    end
    local function rowOf(tw) return units[tw.kind].L[tw.level] end
    local function stats(tw)
        local U, row = units[tw.kind], rowOf(tw)
        local pm = C.M.passiveMult(tw.kind, kindsNear(tw.x, tw.z, tw))
        return row, (row.range or 20) * U.m.range, (row.dmg or 0) * U.m.dmg * pm * ((row.lemon or row.summon or row.guards) and 1.3 or 1),
            math.max(0.1, (row.cd or 1) / U.m.speed), MT.targets(row)
    end
    local function freeSpot(r)
        local tab = covOrder(E, r, opts.strat)
        local list = {}
        for _, tw in ipairs(towers) do table.insert(list, { pos = Vector3.new(tw.x, 0.25, tw.z) * W }) end
        for k = 1, math.min(#tab.order, 500) do
            local s = E.spots[tab.order[k]]
            if MatchPath.canPlace(E.L, Vector3.new(s.x, 0.25, s.z) * W, list) then return s, tab[tab.order[k]] end
        end
    end
    local function economy()
        for _ = 1, 4 do
            local best
            for kind, U in pairs(units) do
                if U.n < U.cap then
                    local row = U.L[1]
                    local r = (row.range or 20) * U.m.range
                    local s, cov = freeSpot(r)
                    if s then
                        local cost = math.floor((row.cost or 0) * U.m.cost + 0.5)
                        local norm = cov / math.max(1, 2 * r / E.step)
                        local g = MT.rowDps(row, U.m) * norm
                        -- same lookahead as the farm: placing + up to 2 upgrades per total coin (Magic Man's L1 is weak, L2/L3 aren't)
                        local ratio, spent = g / cost, cost
                        for lv = 2, 3 do
                            local rw = U.L[lv]
                            if not rw then break end
                            spent = spent + math.floor((rw.cost or 0) * U.m.cost + 0.5)
                            ratio = math.max(ratio, MT.rowDps(rw, U.m) * norm / spent)
                        end
                        if not best or ratio > best.ratio then best = { place = true, kind = kind, s = s, cost = cost, ratio = ratio } end
                    end
                end
            end
            for _, tw in ipairs(towers) do
                local U = units[tw.kind]
                local nxt = U.L[tw.level + 1]
                if nxt then
                    local cost = math.floor((nxt.cost or 0) * U.m.cost + 0.5)
                    local now = MT.rowDps(U.L[tw.level], U.m)
                    local g = math.max(0, MT.rowDps(nxt, U.m) - now)
                    local nxt2 = U.L[tw.level + 2]
                    local ratio = g / cost
                    if nxt2 then ratio = math.max(ratio, math.max(0, MT.rowDps(nxt2, U.m) - now) / (cost + (nxt2.cost or 0) * U.m.cost)) end
                    if not best or ratio > best.ratio then best = { tw = tw, cost = cost, ratio = ratio } end
                end
            end
            if not best or best.cost > money then return end
            money = money - best.cost
            if best.place then
                table.insert(towers, { kind = best.kind, level = 1, x = best.s.x, z = best.s.z, cool = 0 })
                units[best.kind].n = units[best.kind].n + 1
            else
                best.tw.level = best.tw.level + 1
            end
        end
    end
    local steps = 0
    while true do
        t = t + dt
        steps = steps + 1
        -- wave clear bonus (paid around when the next wave is due)
        local due = math.floor((t - 3) / clock)
        for w = 1, math.min(due, nW) do
            if not bonusPaid[w] then bonusPaid[w] = true; money = money + (Cat.stageBonus(stage, w) or 0) end
        end
        economy()
        while spawns[si] and spawns[si].t <= t do
            local s = spawns[si]
            table.insert(enemies, { hp = s.hp, max = s.hp, speed = s.type.speed, dist = 0, leak = s.type.leak or 1, reward = s.type.reward or 0, w = s.w, boss = s.type.boss })
            lastWave = math.max(lastWave, s.w)
            si = si + 1
        end
        -- move + positions
        for i = #enemies, 1, -1 do
            local e = enemies[i]
            if (e.stunT or 0) > 0 then e.stunT = e.stunT - dt
            else
                local slow = (e.slowT or 0) > 0 and 0.5 or 1
                if slow < 1 then e.slowT = e.slowT - dt end
                e.dist = e.dist + e.speed * slow * dt
            end
            if e.dist >= E.length then
                lives = lives - e.leak
                leaks = leaks + e.leak
                table.remove(enemies, i)
            else
                local p = E.path:at(e.dist)
                e.x, e.z = p.X, p.Z
            end
        end
        if lives <= 0 then return { won = false, lives = lives, leaks = leaks, wave = lastWave, t = t } end
        -- towers fire
        for _, tw in ipairs(towers) do
            tw.cool = tw.cool - dt
            if tw.cool <= 0 and #enemies > 0 then
                local row, r, dmg, cd, tg = stats(tw)
                local r2 = r * r
                local target, inRange
                for _, e in ipairs(enemies) do
                    if (e.x - tw.x) ^ 2 + (e.z - tw.z) ^ 2 <= r2 then
                        inRange = inRange or {}
                        table.insert(inRange, e)
                        if not target or e.dist > target.dist then target = e end
                    end
                end
                if target then
                    tw.cool = cd
                    local burn = row.burn and row.burn * units[tw.kind].m.dmg * (row.burnT or 1) or 0
                    -- who gets hit, from the row's own fields:
                    --   zone="range" → every enemy in range · aoe → everyone within aoe of the target (splash share
                    --   for the others if set) · line → a strip along the road · hits+splash → nearest few
                    local hit = { { e = target, f = 1 } }
                    local others = row.splash or 1
                    if row.zone == "range" then
                        for _, e in ipairs(inRange) do if e ~= target then table.insert(hit, { e = e, f = 1 }) end end
                    elseif row.aoe or row.line then
                        local rad = row.aoe or (row.line / 2)
                        for _, e in ipairs(enemies) do
                            if e ~= target and (e.x - target.x) ^ 2 + (e.z - target.z) ^ 2 <= rad * rad then table.insert(hit, { e = e, f = others }) end
                        end
                        if row.hits then while #hit > row.hits do table.remove(hit) end end
                    elseif row.hits and row.splash then
                        table.sort(inRange, function(a, b) return ((a.x - target.x) ^ 2 + (a.z - target.z) ^ 2) < ((b.x - target.x) ^ 2 + (b.z - target.z) ^ 2) end)
                        for k = 2, math.min(#inRange, row.hits) do table.insert(hit, { e = inRange[k], f = row.splash }) end
                    end
                    for _, h in ipairs(hit) do
                        local e = h.e
                        e.hp = e.hp - dmg * h.f - (h.f >= 1 and burn or 0)
                        -- crowd control (raid bosses shrug off stuns: stage.antiStun)
                        local stun = (row.stun or 0) + ((row.statues and 1.5) or 0)
                        if stun > 0 and not (e.boss and stage.antiStun) then e.stunT = math.max(e.stunT or 0, stun) end
                        if row.slow then e.slowT = math.max(e.slowT or 0, row.slow) end
                    end
                end
            end
        end
        for i = #enemies, 1, -1 do
            if enemies[i].hp <= 0 then
                money = money + enemies[i].reward * (opts.cash or 1)
                -- how far down the road kills happen (for placement analysis)
                killDist = killDist + enemies[i].dist / E.length; kills = kills + 1
                table.remove(enemies, i)
            end
        end
        if not spawns[si] and #enemies == 0 then
            -- tail = seconds from the last spawn to the last kill (the only part of a run placement can shorten)
            return { won = true, lives = lives, leaks = leaks, wave = nW, t = t, tail = t - lastSpawnT, killAt = kills > 0 and killDist / kills or 0 }
        end
        if t > 3600 then return { won = false, lives = lives, leaks = leaks, wave = lastWave, t = t, timeout = true } end
        if steps % 40 == 0 then task.wait() end
    end
end

-- largest enemy-HP multiplier the team still wins at (bisection)
function SIM.margin(stageId, team, opts)
    opts = opts or {}
    local lo, hi = 0.05, 8
    local base = SIM.run(stageId, team, { hp = 1, cash = opts.cash, dmg = opts.dmg, strat = opts.strat })
    if not base.won then hi = 1 else lo = 1 end
    for _ = 1, (opts.steps or 7) do
        local mid = math.sqrt(lo * hi)
        local r = SIM.run(stageId, team, { hp = mid, cash = opts.cash, dmg = opts.dmg, strat = opts.strat })
        if r.won then lo = mid else hi = mid end
    end
    return lo, base
end

-- teams from the cached profile: the current slots, optionally with evolutions applied (kind swapped, same level/trait/grade)
function SIM.team(evolve)
    local p = SF.B.prof
    local team = {}
    for _, id in ipairs(p.slots or {}) do
        local u = p.units and p.units[id]
        if u then
            local kind = (evolve and evolve[u.kind]) or u.kind
            table.insert(team, { kind = kind, level = u.level or 1, trait = u.trait, g = u.g })
        end
    end
    return team
end

_G.CKD_SIM = SIM
return SIM
