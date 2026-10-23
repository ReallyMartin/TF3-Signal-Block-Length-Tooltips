-- Computes signal block lengths: the distance from a signal back along the
-- track (against the direction the signal applies to) to the previous signal
-- applying to the same direction, or to the end of the track.
--
-- At switches every branch a train could come from is followed, so the result
-- may be a range (shortest - longest route). Crossings without a switch are
-- passed straight through only (see isCrossingTrack).
--
-- Two entry points:
--   describe(proposal, proposalData)  signal being placed (construction proposal)
--   describeSignal(entity)            existing signal
--
-- A proposal replaces the edge the signal is placed on by new edges, so all
-- track lookups go through a small overlay of the proposal on top of the
-- current world state.
--
-- The tooltips are recomputed every frame, so world data and walk results are
-- cached across calls (see worldCache and walk).

local block_length = {}

-- Set to true to print diagnostic output to the game log.
local DEBUG = false

local MAX_SEARCH_DISTANCE = 50000  -- metres; stop walking beyond this
local MAX_WALK_STEPS = 2000        -- edges visited per computation (switch-heavy yards)
local MIN_CONTINUE_COS = 0.5       -- a train can only pass a node if the tracks deviate < 60°
local CURVE_SAMPLES = 32           -- polyline samples per edge for arc length
local TN_SAMPLES = 16              -- samples to locate a signal on its transport network edge
local EPS = 0.05                   -- metres
local EXISTING_CACHE_SECONDS = 0.5 -- hover tooltip is evaluated every frame
local WORLD_CACHE_SECONDS = 30     -- lifetime of cached world track/signal data

local EDGE_OBJECT_SIGNAL = api.type.enum.EdgeObjectType.SIGNAL or 2
local PROPOSAL_CATEGORY_SIGNAL = 2 -- Proposal.EdgeObject.category (0 = stop, 1 = waypoint, 2 = signal)
local SEGMENT_TYPE_TRACK = 1       -- Proposal.SegmentAndEntity.type (0 = street, 1 = track)

local LOG_PREFIX = "[signal_block_length] "

---------------------------------------------------------------------------
-- Logging
---------------------------------------------------------------------------

-- Tooltips are recomputed on every mouse move / frame, so identical
-- consecutive lines are only printed once.
local lastLogLine = nil

local function printOnce(line)
	if line ~= lastLogLine then
		lastLogLine = line
		print(line)
	end
end

local function log(fmt, ...)
	if DEBUG then
		printOnce(LOG_PREFIX .. string.format(fmt, ...))
	end
end

-- Errors are always reported (once per distinct message).
function block_length.warn(message)
	printOnce(LOG_PREFIX .. "error: " .. tostring(message))
end

---------------------------------------------------------------------------
-- Engine access
---------------------------------------------------------------------------

-- Entities created by a proposal (negative ids) do not exist in the world yet;
-- api.engine.getComponent raises "Invalid entity" for them.
local function isWorldEntity(entity)
	return type(entity) == "number" and entity >= 0 and api.engine.entityExists(entity)
end

-- Cheap check for nodes reached through edges: proposal nodes have negative
-- ids, and world edges only reference existing nodes.
local function isWorldNode(node)
	return type(node) == "number" and node >= 0
end

local function getComponent(entity, componentType)
	if not isWorldEntity(entity) then
		return nil
	end
	return api.engine.getComponent(entity, componentType)
end

---------------------------------------------------------------------------
-- Vector helpers (plain tables, so we do not depend on userdata operators)
---------------------------------------------------------------------------

local function vec(v)
	local x = v.x
	if x == nil then
		return { x = v[1], y = v[2], z = v[3] or 0 }
	end
	return { x = x, y = v.y, z = v.z or 0 }
end

local function sub(a, b) return { x = a.x - b.x, y = a.y - b.y, z = a.z - b.z } end
local function neg(a) return { x = -a.x, y = -a.y, z = -a.z } end
local function dist(a, b)
	local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- Directions are compared in the ground plane.
local function norm2(a)
	local l = math.sqrt(a.x * a.x + a.y * a.y)
	if l < 1e-9 then
		return { x = 0, y = 0, z = 0 }
	end
	return { x = a.x / l, y = a.y / l, z = 0 }
end
local function dot2(a, b) return a.x * b.x + a.y * b.y end

-- Translation of a Mat4f (16 elements, column-major). Indexing is expected to
-- be 1-based like the rest of the Lua API; fall back to 0-based if element 16
-- is not the homogeneous 1.
local function matTransl(m)
	local ok, w = pcall(function() return m[16] end)
	if ok and w ~= nil and math.abs(w - 1) < 1e-4 then
		return { x = m[13], y = m[14], z = m[15] }
	end
	return { x = m[12], y = m[13], z = m[14] }
end

---------------------------------------------------------------------------
-- Base edge geometry (cubic Hermite curve, as used by the game)
---------------------------------------------------------------------------

local function hermite(p0, t0, p1, t1, t)
	local t2, t3 = t * t, t * t * t
	local h00 = 2 * t3 - 3 * t2 + 1
	local h10 = t3 - 2 * t2 + t
	local h01 = -2 * t3 + 3 * t2
	local h11 = t3 - t2
	return {
		x = h00 * p0.x + h10 * t0.x + h01 * p1.x + h11 * t1.x,
		y = h00 * p0.y + h10 * t0.y + h01 * p1.y + h11 * t1.y,
		z = h00 * p0.z + h10 * t0.z + h01 * p1.z + h11 * t1.z,
	}
end

local function buildCurve(comp)
	local p0, t0 = vec(comp.position0), vec(comp.tangent0)
	local p1, t1 = vec(comp.position1), vec(comp.tangent1)
	local pts, cum = {}, { 0 }
	for i = 0, CURVE_SAMPLES do
		pts[i + 1] = hermite(p0, t0, p1, t1, i / CURVE_SAMPLES)
	end
	for i = 2, #pts do
		cum[i] = cum[i - 1] + dist(pts[i - 1], pts[i])
	end
	-- Plain copy of the edge objects: curves of world edges are cached across
	-- calls, so they must not keep engine data alive.
	local objects = {}
	for _, object in ipairs(comp.objects or {}) do
		objects[#objects + 1] = { object[1], object[2] }
	end
	return {
		objects = objects,
		node0 = comp.node0,
		node1 = comp.node1,
		pts = pts,
		cum = cum,
		length = cum[#cum],
		-- direction of travel when leaving node0 / arriving at node1
		dir0 = norm2(t0),
		dir1 = norm2(t1),
	}
end

-- Projects a world position onto the curve (in the ground plane).
-- Returns the arc length from node0, the track direction there
-- (node0 -> node1) and the (2D) distance to the track.
local function project(curve, pos)
	local bestD, bestS, bestDir = math.huge, 0, curve.dir0
	for i = 1, #curve.pts - 1 do
		local a, b = curve.pts[i], curve.pts[i + 1]
		local ab = sub(b, a)
		local len2 = ab.x * ab.x + ab.y * ab.y
		local u = 0
		if len2 > 1e-12 then
			u = ((pos.x - a.x) * ab.x + (pos.y - a.y) * ab.y) / len2
			u = math.max(0, math.min(1, u))
		end
		local d = (pos.x - a.x - ab.x * u) ^ 2 + (pos.y - a.y - ab.y * u) ^ 2
		if d < bestD then
			bestD = d
			bestS = curve.cum[i] + (curve.cum[i + 1] - curve.cum[i]) * u
			bestDir = norm2(ab)
		end
	end
	return bestS, bestDir, math.sqrt(bestD)
end

---------------------------------------------------------------------------
-- Existing signals
---------------------------------------------------------------------------

local waypointType = nil
do
	local ok, t = pcall(function() return api.type.Signal.Type.WAYPOINT end)
	if ok then
		waypointType = t
	end
end

local function isWaypoint(sig, edgeObject)
	if waypointType ~= nil and sig.type == waypointType then
		return true
	end
	local res = edgeObject.edgeObjectConstruction
	return type(res) == "string" and res:lower():find("waypoint", 1, true) ~= nil
end

-- Returns the (ground plane) travel direction the signal applies to.
-- The signal applies to trains travelling along its transport network edge if
-- the `edgePr` direction flag is set, and against it otherwise (verified in
-- game against the base signal model signal_path_a.mdl: mast on the -y side,
-- light shining towards -x, i.e. it applies to trains moving +x).
local function signalFacing(sig, pos)
	local edgeId, along = sig.edgePr[1], sig.edgePr[2]
	local tn = getComponent(edgeId.entity, api.type.ComponentType.TRANSPORT_NETWORK)
	local edge = tn and tn.edges and tn.edges[edgeId.index + 1]
	if not edge then
		return nil
	end
	local calcPosition = api.engine.util.transport.calcPosition
	local samples = {}
	for i = 0, TN_SAMPLES do
		samples[i + 1] = vec(calcPosition(edge.geometry, i / TN_SAMPLES))
	end
	local bestI, bestD = 1, math.huge
	for i = 1, #samples do
		local d = (samples[i].x - pos.x) ^ 2 + (samples[i].y - pos.y) ^ 2
		if d < bestD then
			bestI, bestD = i, d
		end
	end
	local a = samples[math.max(1, bestI - 1)]
	local b = samples[math.min(#samples, bestI + 1)]
	local facing = norm2(sub(b, a))
	if not along then
		facing = neg(facing)
	end
	return facing
end

-- Returns { pos, facing } for an existing signal entity, or false for anything
-- else (including waypoints and signals whose direction cannot be determined).
local function signalInfo(ctx, entity)
	local cached = ctx.signalInfos[entity]
	if cached ~= nil then
		return cached
	end
	local info = false
	local edgeObject = getComponent(entity, api.type.ComponentType.EDGE_OBJECT)
	local signalList = getComponent(entity, api.type.ComponentType.SIGNAL_LIST)
	local sig = signalList and signalList.signals and signalList.signals[1]
	if edgeObject and sig and not isWaypoint(sig, edgeObject) then
		local pos = matTransl(edgeObject.transf)
		local ok, facing = pcall(signalFacing, sig, pos)
		if ok and facing then
			info = { pos = pos, facing = facing }
		else
			log("could not determine direction of signal %s: %s", tostring(entity), tostring(facing))
		end
	end
	ctx.signalInfos[entity] = info
	return info
end

---------------------------------------------------------------------------
-- World cache and proposal overlay
---------------------------------------------------------------------------

-- Track and signal data of the world, kept across calls: the tooltip is
-- recomputed on every mouse move, and on big maps rebuilding up to
-- MAX_WALK_STEPS edges from the engine each time causes stutter.
--
-- Changing an edge (geometry or edge objects) replaces it by new edge
-- entities, and node track segments are always read live, so cached edges
-- stay valid while they are reachable. The cache is still dropped
-- periodically, and an edge whose nodes no longer match is rebuilt (see
-- getCurveAt) in case an entity id gets reused.
local world = nil

local function worldCache()
	local now = os.clock()
	if world == nil or now - world.time > WORLD_CACHE_SECONDS then
		world = { time = now, curves = {}, signalInfos = {} }
	end
	return world
end

-- `proposal` may be nil to work on the current world state only.
local function makeContext(proposal)
	local sp = proposal and proposal.proposal or {}
	local cache = worldCache()
	local ctx = {
		removed = {},
		added = {},
		addedList = {},
		addedByNode = {},
		new2old = sp.new2oldEdgeObjects or {},
		curves = {},                     -- edges added by the proposal
		worldCurves = cache.curves,      -- world edges (persistent)
		signalInfos = cache.signalInfos, -- signals are always world entities (persistent)
		ownSignal = nil, -- the signal being measured from; ignored during the walk
		steps = 0,
		memo = nil,      -- walk results beyond the proposal (see walk)
		inMemo = false,
		touched = false,
	}
	for _, seg in ipairs(sp.removedSegments or {}) do
		ctx.removed[seg.entity] = true
	end
	for _, seg in ipairs(sp.addedSegments or {}) do
		if seg.type == SEGMENT_TYPE_TRACK then
			ctx.added[seg.entity] = seg.comp
			ctx.addedList[#ctx.addedList + 1] = seg.entity
			for _, node in ipairs({ seg.comp.node0, seg.comp.node1 }) do
				ctx.addedByNode[node] = ctx.addedByNode[node] or {}
				table.insert(ctx.addedByNode[node], seg.entity)
			end
		end
	end
	return ctx
end

local function getCurve(ctx, edge)
	local added = ctx.added[edge]
	if added then
		local curve = ctx.curves[edge]
		if curve == nil then
			curve = buildCurve(added)
			ctx.curves[edge] = curve
		end
		return curve
	end
	local curve = ctx.worldCurves[edge]
	if curve == nil then
		local comp = getComponent(edge, api.type.ComponentType.BASE_EDGE)
		if not comp then
			return nil -- not cached: the id may belong to a new edge later
		end
		curve = buildCurve(comp)
		ctx.worldCurves[edge] = curve
	end
	return curve
end

-- Like getCurve, for an edge reached through `node`. A cached world edge that
-- no longer touches `node` is stale (reused entity id) and is rebuilt.
local function getCurveAt(ctx, edge, node)
	local curve = getCurve(ctx, edge)
	if curve and curve.node0 ~= node and curve.node1 ~= node and not ctx.added[edge] then
		ctx.worldCurves[edge] = nil
		curve = getCurve(ctx, edge)
		if curve and curve.node0 ~= node and curve.node1 ~= node then
			return nil
		end
	end
	return curve
end

local function trackSegmentsAt(ctx, node)
	local result = {}
	if isWorldNode(node) then
		for _, edge in ipairs(api.engine.system.streetSystem.getNodeTrackSegments(node) or {}) do
			if not ctx.removed[edge] then
				result[#result + 1] = edge
			end
		end
	end
	for _, edge in ipairs(ctx.addedByNode[node] or {}) do
		result[#result + 1] = edge
	end
	return result
end

---------------------------------------------------------------------------
-- Junctions
---------------------------------------------------------------------------

-- Direction in which `curve` leaves `node` (which must be one of its nodes).
local function leaveDir(curve, node)
	if curve.node0 == node then
		return curve.dir0
	end
	return neg(curve.dir1)
end

-- Tracks joined at a node continue each other smoothly: a straight
-- continuation and both legs of a switch leave the node exactly opposite to
-- the track they continue. At a crossing, each of the two lines has such a
-- partner on the far side. So a track that smoothly continues a different
-- track on our side (and not ours) belongs to the crossing line, even if the
-- crossing angle is shallow enough to pass the angle limit.
local SMOOTH_COS = -0.996   -- leave directions within ~5° of opposite
local CROSSING_COS = -0.966 -- crossing lines meet at more than ~15°; below that,
                            -- treat it as a (slightly kinked) switch

-- `tracks`: { edge, out = leave direction } for all tracks at the node;
-- `from`: our entry, `target`: the candidate entry.
local function isCrossingTrack(tracks, from, target)
	if dot2(from.out, target.out) < CROSSING_COS then
		return false -- continues our track (or nearly)
	end
	for _, other in ipairs(tracks) do
		if other ~= from and other ~= target and dot2(other.out, target.out) < SMOOTH_COS then
			return true
		end
	end
	return false
end

---------------------------------------------------------------------------
-- Signals on edges
---------------------------------------------------------------------------

-- Edge objects on edges added by the proposal are new entities; their data
-- lives on the old entity they replace.
local function sourceEntity(ctx, entity)
	local old = ctx.new2old[entity]
	if old and old[1] then
		return old[1]
	end
	return entity
end

-- Signals on an edge: { entity, s = arc length from node0, dir = +1|-1 },
-- where dir = +1 means the signal applies to trains travelling node0 -> node1.
-- Stored on the curve, so world edges compute this only once.
local function signalsOnEdge(ctx, curve)
	if curve.signals then
		return curve.signals
	end
	local result = {}
	for _, object in ipairs(curve.objects) do
		local entity = object[1]
		if object[2] == EDGE_OBJECT_SIGNAL then
			local info = signalInfo(ctx, sourceEntity(ctx, entity))
			if info then
				local s, trackDir = project(curve, info.pos)
				result[#result + 1] = {
					entity = entity,
					s = s,
					dir = dot2(info.facing, trackDir) >= 0 and 1 or -1,
				}
			end
		end
	end
	curve.signals = result
	return result
end

-- signalsOnEdge for the walk: a cached world edge whose signals no longer all
-- exist (e.g. one was bulldozed) is rebuilt from the engine.
local function liveSignalsOnEdge(ctx, edge, curve)
	local signals = signalsOnEdge(ctx, curve)
	if ctx.added[edge] then
		return signals, curve
	end
	for _, sig in ipairs(signals) do
		if not api.engine.entityExists(sig.entity) then
			ctx.worldCurves[edge] = nil
			curve = getCurve(ctx, edge)
			if not curve then
				return {}, nil
			end
			return signalsOnEdge(ctx, curve), curve
		end
	end
	return signals, curve
end

---------------------------------------------------------------------------
-- Walk
---------------------------------------------------------------------------

local continueAt -- defined below; walk and continueAt call each other

-- Walks backwards on `edge`, starting at arc length `s`, against trains that
-- travel in direction `dir` (+1: node0 -> node1). `acc` is the distance so far.
-- Appends { length, kind = "signal"|"end"|"loop"|"limit" } per route to `results`.
local function walk(ctx, edge, s, dir, acc, onPath, results)
	if ctx.added[edge] then
		ctx.touched = true -- see the memo below
	end
	ctx.steps = ctx.steps + 1
	if ctx.steps > MAX_WALK_STEPS or acc > MAX_SEARCH_DISTANCE then
		results[#results + 1] = { length = acc, kind = "limit" }
		return
	end
	local key = tostring(edge) .. ":" .. dir
	if onPath[key] then
		results[#results + 1] = { length = acc, kind = "loop" }
		return
	end

	local curve = getCurve(ctx, edge)
	local signals
	if curve then
		signals, curve = liveSignalsOnEdge(ctx, edge, curve)
	end
	if not curve then
		results[#results + 1] = { length = acc, kind = "end" }
		return
	end

	-- Nearest signal behind us applying to the same direction.
	local best
	for _, sig in ipairs(signals) do
		if sig.dir == dir and sig.entity ~= ctx.ownSignal then
			if dir == 1 and sig.s < s - EPS and (best == nil or sig.s > best) then
				best = sig.s
			elseif dir == -1 and sig.s > s + EPS and (best == nil or sig.s < best) then
				best = sig.s
			end
		end
	end
	if best then
		results[#results + 1] = { length = acc + math.abs(s - best), kind = "signal" }
		return
	end

	acc = acc + (dir == 1 and s or (curve.length - s))
	local node = dir == 1 and curve.node0 or curve.node1
	-- direction in which we leave this edge through `node`
	local back = dir == 1 and neg(curve.dir0) or curve.dir1

	-- Leaving the proposal into the world: everything from here on is the
	-- same for every frame while the signal is dragged along the same edge,
	-- so it is computed once (relative to `node`) and reused.
	local memo = ctx.memo
	if memo and not ctx.inMemo and ctx.added[edge] and isWorldNode(node) then
		local hit = memo[node]
		if not hit then
			hit = {}
			ctx.inMemo, ctx.touched = true, false
			continueAt(ctx, edge, key, node, back, 0, onPath, hit)
			-- Routes that lead back into the proposal depend on where the
			-- signal is; those are not reused.
			if not ctx.touched then
				memo[node] = hit
			end
			ctx.inMemo = false
		end
		for _, r in ipairs(hit) do
			results[#results + 1] = { length = acc + r.length, kind = r.kind }
		end
		return
	end
	continueAt(ctx, edge, key, node, back, acc, onPath, results)
end

-- Continues the walk at `node`, which `edge` (walk key `key`) leaves in
-- direction `back`, into every track a train could have come from.
function continueAt(ctx, edge, key, node, back, acc, onPath, results)
	-- All tracks at the node with the direction they leave it in.
	local from = { edge = edge, out = neg(back) }
	local tracks = { from }
	for _, other in ipairs(trackSegmentsAt(ctx, node)) do
		if other ~= edge then
			local oc = getCurveAt(ctx, other, node)
			if oc and oc.node0 ~= oc.node1 then
				tracks[#tracks + 1] = { edge = other, curve = oc, out = leaveDir(oc, node) }
			end
		end
	end

	onPath[key] = true
	local continued = false
	for i = 2, #tracks do
		local target = tracks[i]
		if dot2(target.out, back) > MIN_CONTINUE_COS and not isCrossingTrack(tracks, from, target) then
			local nc = target.curve
			local nextDir, nextS
			if nc.node0 == node then
				nextDir, nextS = -1, 0
			else
				nextDir, nextS = 1, nc.length
			end
			continued = true
			walk(ctx, target.edge, nextS, nextDir, acc, onPath, results)
		end
	end
	onPath[key] = nil

	if not continued then
		results[#results + 1] = { length = acc, kind = "end" }
	end
end

---------------------------------------------------------------------------
-- Tooltip text
---------------------------------------------------------------------------

-- Uses the game's formatter (locale decimal separator, metric/imperial) and
-- falls back to plain metric output.
local function formatLength(m)
	local ok, text
	if m >= 10000 then
		ok, text = pcall(api.util.formatLength, m, 1)
	else
		ok, text = pcall(api.util.formatLength, m, 0, true)
	end
	if ok and type(text) == "string" then
		return text
	end
	if m >= 10000 then
		return string.format("%.1f km", m / 1000)
	end
	return string.format("%d m", math.floor(m + 0.5))
end

-- Walks back from arc length `s` on `edge` for a signal applying to travel
-- direction `dir` and returns the tooltip line.
local function measure(ctx, edge, s, dir)
	local results = {}
	walk(ctx, edge, s, dir, 0, {}, results)

	local minLen, maxLen = math.huge, 0
	local hasSignal, hasLimit = false, false
	for _, r in ipairs(results) do
		minLen = math.min(minLen, r.length)
		maxLen = math.max(maxLen, r.length)
		hasSignal = hasSignal or r.kind == "signal"
		hasLimit = hasLimit or r.kind == "limit"
	end
	log("edge=%s s=%.1f dir=%d routes=%d steps=%d min=%.1f max=%.1f",
		tostring(edge), s, dir, #results, ctx.steps, minLen, maxLen)

	-- Translated strings are format templates (see strings.json), so each
	-- language controls its own punctuation and word order.
	local text
	if maxLen - minLen < 1 then
		text = formatLength(maxLen)
	else
		text = string.format(_("%s - %s"), formatLength(minLen), formatLength(maxLen))
	end
	if hasLimit then
		text = "> " .. text
	end
	if not hasSignal then
		text = string.format(_("%s (no signal behind)"), text)
	end
	return string.format(_("Block length: %s"), text)
end

---------------------------------------------------------------------------
-- Signal being placed
---------------------------------------------------------------------------

-- The proposal's new signal: a signal edge object that does not replace an
-- existing one.
local function findNewSignal(ctx, proposal)
	for _, edgeObject in ipairs(proposal.proposal.edgeObjectsToAdd or {}) do
		if tonumber(tostring(edgeObject.category)) == PROPOSAL_CATEGORY_SIGNAL then
			local old = ctx.new2old[edgeObject.resultEntity]
			if not (old and old[1]) then
				return edgeObject
			end
		end
	end
	return nil
end

local function findEdgeOfNewSignal(ctx, entity, pos)
	for _, edge in ipairs(ctx.addedList) do
		for _, object in ipairs(ctx.added[edge].objects or {}) do
			if object[1] == entity then
				return edge
			end
		end
	end
	-- Fallback: the closest added track edge
	local bestEdge, bestD = nil, math.huge
	for _, edge in ipairs(ctx.addedList) do
		local _, _, d = project(getCurve(ctx, edge), pos)
		if d < bestD then
			bestEdge, bestD = edge, d
		end
	end
	return bestEdge
end

-- Position of the new signal: its model transform if the proposal carries one
-- (the base game's preview does not), otherwise the cursor, next to which the
-- tool snaps the signal.
local function newSignalPosition(edgeObject)
	local ok, transf = pcall(function() return edgeObject.modelInstance.transf end)
	if ok and transf ~= nil then
		local okPos, pos = pcall(matTransl, transf)
		if okPos and pos.x ~= nil then
			return pos
		end
	end
	if api.gui.mouse.hasTerrainPosition() then
		return vec(api.gui.mouse.getTerrainPosition())
	end
	return nil
end

local lastProposal = { key = nil, text = nil }
local proposalMemo = { key = nil, entries = nil }

-- Returns the tooltip line for a construction proposal, or nil if the
-- proposal does not place a signal.
function block_length.describe(proposal, proposalData)
	if not (proposal and proposal.proposal) then
		return nil
	end
	if proposalData and proposalData.errorState and proposalData.errorState.critical then
		return nil
	end

	local ctx = makeContext(proposal)
	local edgeObject = findNewSignal(ctx, proposal)
	if not edgeObject then
		return nil
	end
	ctx.ownSignal = edgeObject.resultEntity

	local pos = newSignalPosition(edgeObject)
	local edge = pos and findEdgeOfNewSignal(ctx, ctx.ownSignal, pos)
	local curve = edge and getCurve(ctx, edge)
	if not curve then
		log("no track edge found for new signal")
		return nil
	end

	-- Signals stand on the right of the travel direction they apply to, so a
	-- signal on the right side of the edge (left == false) applies to trains
	-- travelling node0 -> node1.
	local dir = edgeObject.left and -1 or 1

	-- The edge(s) the proposal replaces, i.e. where the signal is placed.
	local removed = { tostring(world.time) }
	for _, seg in ipairs(proposal.proposal.removedSegments or {}) do
		removed[#removed + 1] = tostring(seg.entity)
	end
	removed = table.concat(removed, ",")

	-- The tooltip is requested repeatedly while the signal does not move, so
	-- reuse the last result for the same replaced edge, position and side.
	local key = string.format("%.1f:%.1f:%d:", pos.x, pos.y, dir) .. removed
	if key == lastProposal.key then
		return lastProposal.text
	end

	-- Walk results beyond the replaced edge, reused while the signal is
	-- dragged along it (see walk). Placing the signal replaces that edge, and
	-- building anything else first moves the proposal off it, so the stored
	-- results never outlive a change made by the player.
	if proposalMemo.key ~= removed then
		proposalMemo.key, proposalMemo.entries = removed, {}
	end
	ctx.memo = proposalMemo.entries

	local s = project(curve, pos)
	local text = measure(ctx, edge, s, dir)
	lastProposal.key, lastProposal.text = key, text
	return text
end

local existingCache = { entity = nil, time = -math.huge, text = nil }

-- Returns the tooltip line for an existing signal entity, or nil for anything
-- else (including waypoints). The result is cached briefly because the hover
-- tooltip asks every frame.
function block_length.describeSignal(entity)
	if not isWorldEntity(entity) then
		return nil
	end
	local now = os.clock()
	if existingCache.entity == entity and now - existingCache.time < EXISTING_CACHE_SECONDS then
		return existingCache.text
	end

	local text = nil
	if getComponent(entity, api.type.ComponentType.SIGNAL_LIST) then
		local ctx = makeContext(nil)
		ctx.ownSignal = entity
		local info = signalInfo(ctx, entity)
		local edge = info and api.engine.system.streetSystem.getEdgeForEdgeObject(entity)
		local curve = edge and getCurve(ctx, edge)
		if curve then
			local s, trackDir = project(curve, info.pos)
			local dir = dot2(info.facing, trackDir) >= 0 and 1 or -1
			text = measure(ctx, edge, s, dir)
		end
	end

	existingCache.entity, existingCache.time, existingCache.text = entity, now, text
	return text
end

return block_length
