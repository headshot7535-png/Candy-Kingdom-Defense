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
-- "crowd": weight each stretch of road by how much enemy HP sat there in an earlier run (occ = 0..1 per
-- road bin, SIM.run's result.occ), so heroes go where the waves really pile up
SIM.OCC_BINS = 40
-- game seconds from a wave's last spawn to the next wave (measured with WaveNextAt: 9.8 real s at x1.1 game
-- speed in Infinite = INFINITE.clock 10). The sim runs at x1: real seconds = sim seconds / the map's pace
SIM.COUNTDOWN = 10
-- normal maps (WaveNextAt on Frosty Fudge Pass, Oct 2026): the next wave is due ~6 s after a wave's last
-- spawn, ~19 s after a boss wave's; a cleared road starts it 1.5 s later (the game's Auto skip, on by default)
SIM.GAP = 6
SIM.BOSS_GAP = 19
SIM.CLEAR_SKIP = 1.5
function SIM.crowdWeight(occ)
    return function(f)
        local i = math.clamp(math.floor(f * #occ) + 1, 1, #occ)
        return 0.2 + 1.3 * (occ[i] or 0)
    end
end
local function covOrder(E, r, strat, occ)
    strat = strat or "even"
    local key = math.floor(r + 0.5) .. ":" .. strat .. (strat == "crowd" and occ and (":" .. tostring(occ)) or "")
    if E.cov[key] then return E.cov[key] end
    local wf = strat == "crowd" and occ and SIM.crowdWeight(occ) or SIM.STRATS[strat] or SIM.STRATS.even
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
    -- tournament week: the buffed element hits x2, the debuffed x0.5 (applied live, not in the LEVELS tables)
    local elem = opts.tourney and (Cat.tourneyMult(opts.tourney, u.kind) or 1) or 1
    return { dmg = want.dmg / have.dmg * (opts.dmg or 1) * elem, range = want.range / have.range, speed = want.speed / have.speed, cost = tm.cost }
end

-- tournament schedule: a wave every TOURNEY.every seconds after the build phase, whatever is still alive.
-- A wave's whole HP is week.hp × growth^(wave-1), shared out by each enemy type's own HP
local function tourneySpawns(week, hpMult)
    local T = Cat.TOURNEY
    local spawns = {}
    local nW = math.max(1, T.length // T.every)
    for w = 1, nW do
        local groups = Cat.tourneyWave(week.world, w)
        local weight = 0
        for _, g in ipairs(groups) do
            local ET = Enemies.TYPES[g[1]]
            if ET then weight = weight + (tonumber(g[2]) or 1) * (ET.hp or 1) end
        end
        local per = (week.hp or T.hp) * (week.growth or T.growth) ^ (w - 1) / math.max(weight, 1) * (hpMult or 1)
        local t0 = T.build + (w - 1) * T.every
        for _, g in ipairs(groups) do
            local ET = Enemies.TYPES[g[1]]
            if ET then
                for i = 1, tonumber(g[2]) or 1 do
                    table.insert(spawns, { t = t0 + (tonumber(g[4]) or 0) + (i - 1) * (tonumber(g[3]) or 1), type = ET, hp = (ET.hp or 1) * per, w = w })
                end
            end
        end
    end
    return spawns, nW
end

function SIM.run(stageId, team, opts)
    opts = opts or {}
    -- kills pay reward × STAGE_CASH (measured live: Candy Zombie 5 → 8), plus each wave's clear bonus
    opts.cash = opts.cash or Cat.STAGE_CASH or 1.5
    -- challenge modifiers (Catalog.challengeMods: hp, speed, count, lives, dmg)
    local M = opts.mods or {}
    if M.dmg and not opts.modsApplied then opts.dmg = (opts.dmg or 1) * M.dmg; opts.modsApplied = true end
    local stage = Cat.stage(stageId)
    local E = SIM.layout(stageId)
    local TR = opts.tourney and Cat.TOURNEY
    -- Infinite (opts.infinite): the world's endless waves (Catalog.infiniteWave: its last two stages' waves
    -- in turn, the finale every 10th) with HP ×INFINITE.growth a wave (Catalog.infiniteHp), up to maxWaves
    local INF = opts.infinite and Cat.worldOf(stageId)
    local waves = TR and {} or Cat.stageWaves(stage)
    if INF then
        waves = {}
        for w = 1, opts.maxWaves or 150 do waves[w] = Cat.infiniteWave(INF.id, w) end
    end
    local nW = #waves
    local clock = TR and TR.every or (stage.minutes or Cat.WAVE_CLOCK.minutes or 5) * 60 / nW
    local money, lives = TR and TR.money or stage.money or 1000, TR and TR.lives or math.floor((stage.lives or 10) * (M.lives or 1))
    local dealt = 0 -- tournament score: damage that landed (no overkill)
    local units = {}
    for _, u in ipairs(team) do
        local L = MT.levels(u.kind)
        if L then units[u.kind] = { u = u, L = L, m = mults(u, opts), cap = Cat.placeCap(u.kind), n = 0, ab = Cat.abilityOf and Cat.abilityOf(u.kind) } end
    end
    local towers, enemies, spawns = {}, {}, {}
    if TR then spawns, nW = tourneySpawns(opts.tourney, opts.hp) end
    -- spawn schedule from the stage's own wave list
    -- waves after the first start when the game says so (see advance() below): placeholder starts far apart
    local FAR = 1e5
    for w, groups in ipairs(waves) do
        local t0 = 3 + (w - 1) * FAR
        local hpW = (INF and Cat.infiniteHp(INF.id, w) or Cat.stageWaveHp(stage, w)) * (opts.hp or 1) * (M.hp or 1)
        for _, g in ipairs(groups) do
            local T = Enemies.TYPES[g[1]]
            if T then
                local delay, interval = tonumber(g[4]) or 0, tonumber(g[3]) or 1
                local count = math.max(1, math.floor((tonumber(g[2]) or 1) * (M.count or 1) + 0.5))
                for i = 1, count do
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
    -- wave pacing, measured live (WaveNextAt, Oct 2026): once a wave has finished spawning a countdown of
    -- SIM.COUNTDOWN s starts, and the next wave comes when it ends, or at once if the road is empty. An early
    -- call (opts.calls = {alive, reach}: the farm's MT.callWave limits × boldness) sends it right away too
    local waveStart, waveTotal, waveSpawned, doneAt, waveBoss = {}, {}, {}, {}, {}
    local emptyAt
    if not TR then
        for w = 1, nW do waveStart[w] = 3 + (w - 1) * FAR; waveTotal[w] = 0; waveSpawned[w] = 0 end
        for _, s in ipairs(spawns) do waveTotal[s.w] = waveTotal[s.w] + 1; if s.type.boss then waveBoss[s.w] = true end end
    end
    local calls, lastCallT, spawnedT = 0, -99, 0
    local function advance()
        local cur = 0
        for w = 1, nW do if waveStart[w] <= t then cur = w end end
        local nw = cur + 1
        if cur < 1 or nw > nW then return end
        local spawnedAll = waveSpawned[cur] >= waveTotal[cur]
        if spawnedAll and not doneAt[cur] then doneAt[cur] = t end
        if spawnedAll and #enemies == 0 then emptyAt = emptyAt or t else emptyAt = nil end
        local gap = INF and SIM.COUNTDOWN or (waveBoss[cur] and SIM.BOSS_GAP or SIM.GAP)
        local natural = spawnedAll and ((emptyAt and t >= emptyAt + (INF and 0 or SIM.CLEAR_SKIP)) or t >= doneAt[cur] + gap)
        if not natural then
            -- early call: the farm's own conditions
            if not opts.calls or leaks > 0 or t - waveStart[cur] < 4 or t - lastCallT < 4 then return end
            if waveSpawned[cur] < waveTotal[cur] * 0.9 or #enemies > opts.calls.alive then return end
            local front = 0
            for _, e in ipairs(enemies) do front = math.max(front, e.dist / E.length) end
            if front > opts.calls.reach then return end
        end
        local shift = waveStart[nw] - t
        if shift <= 0 then return end
        for w = nw, nW do waveStart[w] = waveStart[w] - shift end
        for k = si, #spawns do if spawns[k].w >= nw then spawns[k].t = spawns[k].t - shift end end
        local rest = {}
        for k = si, #spawns do rest[#rest + 1] = spawns[k] end
        table.sort(rest, function(a, b) return a.t < b.t end)
        for k = 1, #rest do spawns[si + k - 1] = rest[k] end
        if not natural then calls, lastCallT = calls + 1, t end
    end
    local function kindsNear(x, z, skip)
        local k, r = {}, Cat.PASSIVE_RADIUS or 16
        for _, tw in ipairs(towers) do if tw ~= skip and (tw.x - x) ^ 2 + (tw.z - z) ^ 2 <= r * r then k[tw.kind] = true end end
        return k
    end
    local function rowOf(tw) return units[tw.kind].L[tw.level] end
    local function rangeOf(tw) return (rowOf(tw).range or 20) * units[tw.kind].m.range end
    local function abilityOn(tw, id) local ab = units[tw.kind].ab; return ab and ab.id == id and (tw.abUntil or 0) > t end
    -- Encore: heroes inside an active Marshall Lee's range attack ×haste faster
    local function hasteAt(tw)
        for _, o in ipairs(towers) do
            if abilityOn(o, "mlEncore") then
                local r = rangeOf(o)
                if (o.x - tw.x) ^ 2 + (o.z - tw.z) ^ 2 <= r * r then return units[o.kind].ab.haste or 1.25 end
            end
        end
        return 1
    end
    local function stats(tw)
        local U, row = units[tw.kind], rowOf(tw)
        local pm = C.M.passiveMult(tw.kind, kindsNear(tw.x, tw.z, tw))
        return row, (row.range or 20) * U.m.range, (row.dmg or 0) * U.m.dmg * pm * ((row.lemon or row.summon or row.guards) and 1.3 or 1),
            math.max(0.1, (row.cd or 1) / U.m.speed / hasteAt(tw)), MT.targets(row)
    end
    -- abilities, on the farm's own timing (MT.abilities): a crowd or a boss in range, else after holding it
    -- CFG.abilityHold seconds with anything in range. Soul Tax / Rent Day pay money, Encore hastes (above).
    -- (Decorpsinator's zombies aren't modelled: their bite lives on the server)
    local CROWD = MT.ABILITY_CROWD or {}
    local holdFor = (SF.CFG and SF.CFG.abilityHold) or 8
    local function abilities()
        for _, tw in ipairs(towers) do
            local ab = units[tw.kind].ab
            if ab and tw.level >= (ab.unlock or 3) and t >= (tw.abAt or 0) then
                local r2 = rangeOf(tw) ^ 2
                local cnt, bosses = 0, 0
                for _, e in ipairs(enemies) do
                    if e.x and (e.x - tw.x) ^ 2 + (e.z - tw.z) ^ 2 <= r2 then cnt = cnt + 1; if e.boss then bosses = bosses + 1 end end
                end
                tw.abReady = tw.abReady or t
                if bosses > 0 or cnt >= (CROWD[ab.id] or 4) or (cnt > 0 and t - tw.abReady >= holdFor) then
                    tw.abReady = nil
                    tw.abUntil = t + (ab.duration or 0)
                    tw.abAt = t + (ab.cooldown or 60)
                    if ab.id == "rentday" then
                        money = money + math.min(ab.cap or 500, (cnt - bosses) * (ab.rent or 25)) + bosses * (ab.bossRent or 250)
                    end
                end
            end
        end
    end
    local function killPay(e)
        local mult = 1
        for _, tw in ipairs(towers) do
            if abilityOn(tw, "soultax") and (e.x - tw.x) ^ 2 + (e.z - tw.z) ^ 2 <= rangeOf(tw) ^ 2 then mult = units[tw.kind].ab.mult or 2; break end
        end
        return e.reward * (opts.cash or 1) * mult
    end
    -- where enemy HP sits along the road (enemy-HP-seconds per bin): the "crowd" placement style
    local occ = {}
    for i = 1, SIM.OCC_BINS do occ[i] = 0 end
    local function freeSpot(r)
        local tab = covOrder(E, r, opts.strat, opts.occ)
        local list = {}
        for _, tw in ipairs(towers) do table.insert(list, { pos = Vector3.new(tw.x, 0.25, tw.z) * W }) end
        for k = 1, math.min(#tab.order, 500) do
            local s = E.spots[tab.order[k]]
            if MatchPath.canPlace(E.L, Vector3.new(s.x, 0.25, s.z) * W, list) then return s, tab[tab.order[k]] end
        end
    end
    local function economy()
        for _ = 1, 4 do
            local opts = {}
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
                        table.insert(opts, { place = true, kind = kind, s = s, cost = cost, ratio = ratio })
                    end
                end
            end
            local placedKinds = {}
            for _, tw in ipairs(towers) do placedKinds[tw.kind] = true end
            local nPlaced, nTeam = 0, 0
            for _ in pairs(placedKinds) do nPlaced = nPlaced + 1 end
            for _ in pairs(units) do nTeam = nTeam + 1 end
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
                    -- same "spread first" rule as the farm: deep upgrades count half until 4 kinds are placed
                    if tw.level + 1 >= 3 and nPlaced < math.min(4, nTeam) then ratio = ratio * 0.5 end
                    table.insert(opts, { tw = tw, cost = cost, ratio = ratio })
                end
            end
            for _, o in ipairs(opts) do if not best or o.ratio > best.ratio then best = o end end
            if not best then return end
            -- same saving rule as the farm: while saving for the best, still buy a cheap option that's
            -- reasonably good (≤20% of the cost, ≥40% of the value per coin)
            if best.cost > money then
                local cheap
                for _, o in ipairs(opts) do
                    if o.cost <= money and o.cost <= best.cost * 0.2 and o.ratio >= best.ratio * 0.4 and (not cheap or o.ratio > cheap.ratio) then cheap = o end
                end
                if not cheap then return end
                best = cheap
            end
            money = money - best.cost
            if best.place then
                local ab = units[best.kind].ab
                table.insert(towers, { kind = best.kind, level = 1, x = best.s.x, z = best.s.z, cool = 0, abAt = t + (ab and ab.firstDelay or 20) })
                units[best.kind].n = units[best.kind].n + 1
            else
                best.tw.level = best.tw.level + 1
            end
        end
    end
    local function occOut()
        local top = 0
        for _, v in ipairs(occ) do top = math.max(top, v) end
        local o = {}
        for i, v in ipairs(occ) do o[i] = top > 0 and math.floor(v / top * 100 + 0.5) / 100 or 0 end
        return o
    end
    local steps = 0
    while true do
        t = t + dt
        steps = steps + 1
        -- wave clear bonus (paid around when the next wave is due)
        local due = math.floor((t - (TR and TR.build or 3)) / clock)
        for w = 1, nW do
            -- a wave's bonus comes when the next one is due (or called)
            local paidNow = TR and w <= due or (not TR and waveStart[w + 1] ~= nil and waveStart[w + 1] <= t)
            if paidNow and not bonusPaid[w] then
                bonusPaid[w] = true
                -- tournament: TOURNEY.cash = {base, per wave}
                -- Infinite: the stage's bonus list in turn (assumed, like its waves)
                local bw = INF and stage.bonus and #stage.bonus > 0 and ((w - 1) % #stage.bonus + 1) or w
                money = money + (TR and ((TR.cash and TR.cash[1] or 0) + (TR.cash and TR.cash[2] or 0) * (w - 1)) or (Cat.stageBonus(stage, bw) or 0))
            end
        end
        economy()
        while spawns[si] and spawns[si].t <= t do
            local s = spawns[si]
            table.insert(enemies, { hp = s.hp, max = s.hp, speed = (s.type.speed or 0) * (M.speed or 1), dist = 0, leak = s.type.leak or 1, reward = s.type.reward or 0, w = s.w, boss = s.type.boss })
            lastWave = math.max(lastWave, s.w)
            if waveSpawned[s.w] then waveSpawned[s.w] = waveSpawned[s.w] + 1 end
            spawnedT = s.t
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
                local leak = TR and math.min(e.leak, TR.leakMax or 5) or e.leak
                lives = lives - leak
                leaks = leaks + leak
                table.remove(enemies, i)
            else
                local p = E.path:at(e.dist)
                e.x, e.z = p.X, p.Z
                local bin = math.clamp(math.floor(e.dist / E.length * SIM.OCC_BINS) + 1, 1, SIM.OCC_BINS)
                occ[bin] = occ[bin] + math.max(0, e.hp) * dt
            end
        end
        abilities()
        if not TR then advance() end
        if lives <= 0 then return { won = false, lives = lives, leaks = leaks, wave = lastWave, t = t, score = dealt, occ = occOut() } end
        if TR and t >= TR.build + TR.length then
            return { won = true, survived = true, lives = lives, leaks = leaks, wave = lastWave, t = t, score = dealt, left = #enemies, occ = occOut() }
        end
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
                        local amt = dmg * h.f + (h.f >= 1 and burn or 0)
                        if e.hp > 0 then dealt = dealt + math.min(amt, e.hp) end
                        e.hp = e.hp - amt
                        -- crowd control (raid bosses shrug off stuns: stage.antiStun)
                        local stun = (row.stun or 0) + ((row.statues and 1.5) or 0)
                        if stun > 0 and not (e.boss and stage.antiStun) then e.stunT = math.max(e.stunT or 0, stun) end
                        if row.slow then e.slowT = math.max(e.slowT or 0, row.slow) end
                        -- knockback: pushed back up the road (bosses that shrug off stuns shrug this off too)
                        if row.back and not (e.boss and stage.antiStun) then e.dist = math.max(0, e.dist - row.back * h.f) end
                    end
                end
            end
        end
        for i = #enemies, 1, -1 do
            if enemies[i].hp <= 0 then
                money = money + killPay(enemies[i])
                -- how far down the road kills happen (for placement analysis)
                killDist = killDist + enemies[i].dist / E.length; kills = kills + 1
                table.remove(enemies, i)
            end
        end
        if not spawns[si] and #enemies == 0 then
            -- tail = seconds from the last spawn to the last kill (the only part of a run placement can shorten)
            return { won = true, survived = TR and true or nil, lives = lives, leaks = leaks, wave = nW, t = t, tail = t - (TR and lastSpawnT or spawnedT), calls = calls, killAt = kills > 0 and killDist / kills or 0, score = dealt, occ = occOut() }
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

-- a normal map played the farm's way, early wave calls included: {won, t, calls, leaks, lives}.
-- opts: strat, occ, mods (challenge), calls = {alive, reach} (default: the farm's CFG × boldness 1)
function SIM.clear(stageId, team, opts)
    opts = opts or {}
    local CFG = SF.CFG or {}
    local calls = opts.calls
    if calls == nil and CFG.earlyCall then
        local a = opts.aggr or 1
        calls = { alive = (CFG.callAlive or 8) * a, reach = (CFG.callReach or 0.5) * a }
    end
    return SIM.run(stageId, team, { strat = opts.strat, occ = opts.occ, mods = opts.mods, calls = calls or nil, hp = opts.hp, dmg = opts.dmg })
end

-- Infinite for a team: plays until the lives run out; {wave, t, won (= reached maxWaves)}. No early calls
-- (the farm never calls in Infinite). stageId = the world's infinite stage
function SIM.infinite(stageId, team, opts)
    opts = opts or {}
    return SIM.run(stageId, team, { infinite = true, maxWaves = opts.maxWaves or 150, strat = opts.strat, occ = opts.occ, hp = opts.hp })
end

-- tournament run for a team: {score, survived, wave, leaks}. week = Catalog.tourneyAt(now); the layout is the
-- week's world (its infinite stage)
function SIM.tourney(week, team, opts)
    opts = opts or {}
    local stageId = type(week.stage) == "table" and week.stage.id or week.stage
    return SIM.run(stageId, team, { tourney = week, strat = opts.strat, occ = opts.occ, hp = opts.hp, cash = opts.cash, dmg = opts.dmg })
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
