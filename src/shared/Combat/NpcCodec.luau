--!strict
-- Packs NPC snapshots into buffers for unreliable remotes. Pure, unit tested under Lune.
--
-- Unreliable remote events over 1000 bytes are dropped, so snapshots are split into chunks of
-- at most `maxBytes` (keep it at 900 for headroom). Each chunk is self-contained:
--
--   header   f64 server time, u16 entity count                       (10 bytes)
--   entity   u16 id, i16 x, i16 z, u8 yaw, u8 health, u8 state, u8 aux (10 bytes)
--
-- Positions are fixed point (1/16 stud, range about +/-2047 studs); yaw is in 1/256 turns;
-- health is a fraction of max in 1/255 steps; state is an NPC-defined code; aux is an extra
-- 0 to 1 value in 1/255 steps (a monster's stagger bar).

export type Entity = {
	id: number,
	x: number,
	z: number,
	-- Radians.
	yaw: number,
	-- 0 to 1.
	health: number,
	state: number,
	-- 0 to 1; optional, 0 when absent.
	aux: number?,
}

local HEADER_BYTES = 10
local ENTITY_BYTES = 10
local POSITION_SCALE = 16
local TAU = 2 * math.pi

local NpcCodec = {}

NpcCodec.ENTITY_BYTES = ENTITY_BYTES
NpcCodec.HEADER_BYTES = HEADER_BYTES

-- State codes carried in snapshots.
NpcCodec.States = table.freeze({
	idle = 0,
	move = 1,
	attack = 2,
	telegraph = 3,
	recover = 4,
	stagger = 5,
	-- Underground (burrowing monsters): not drawn.
	hidden = 6,
})

local function toFixed(v: number): number
	return math.clamp(math.floor(v * POSITION_SCALE + 0.5), -32768, 32767)
end

-- Splits entities into buffers of at most maxBytes each. Returns no buffers for no entities.
function NpcCodec.pack(time: number, entities: { Entity }, maxBytes: number): { buffer }
	local perChunk = (maxBytes - HEADER_BYTES) // ENTITY_BYTES
	assert(perChunk >= 1, "maxBytes too small for one entity")
	local chunks: { buffer } = {}
	local index = 1
	while index <= #entities do
		local count = math.min(perChunk, #entities - index + 1)
		local b = buffer.create(HEADER_BYTES + count * ENTITY_BYTES)
		buffer.writef64(b, 0, time)
		buffer.writeu16(b, 8, count)
		for i = 0, count - 1 do
			local e = entities[index + i]
			local o = HEADER_BYTES + i * ENTITY_BYTES
			buffer.writeu16(b, o, e.id)
			buffer.writei16(b, o + 2, toFixed(e.x))
			buffer.writei16(b, o + 4, toFixed(e.z))
			buffer.writeu8(b, o + 6, math.floor((e.yaw % TAU) / TAU * 256 + 0.5) % 256)
			buffer.writeu8(b, o + 7, math.clamp(math.floor(e.health * 255 + 0.5), 0, 255))
			buffer.writeu8(b, o + 8, math.clamp(e.state, 0, 255))
			buffer.writeu8(b, o + 9, math.clamp(math.floor((e.aux or 0) * 255 + 0.5), 0, 255))
		end
		table.insert(chunks, b)
		index += count
	end
	return chunks
end

-- Reads one chunk. Returns the server time and the entities, or nil for a malformed buffer.
function NpcCodec.unpack(b: buffer): (number?, { Entity }?)
	local length = buffer.len(b)
	if length < HEADER_BYTES then
		return nil, nil
	end
	local time = buffer.readf64(b, 0)
	local count = buffer.readu16(b, 8)
	if length ~= HEADER_BYTES + count * ENTITY_BYTES then
		return nil, nil
	end
	local entities: { Entity } = table.create(count)
	for i = 0, count - 1 do
		local o = HEADER_BYTES + i * ENTITY_BYTES
		entities[i + 1] = {
			id = buffer.readu16(b, o),
			x = buffer.readi16(b, o + 2) / POSITION_SCALE,
			z = buffer.readi16(b, o + 4) / POSITION_SCALE,
			yaw = buffer.readu8(b, o + 6) / 256 * TAU,
			health = buffer.readu8(b, o + 7) / 255,
			state = buffer.readu8(b, o + 8),
			aux = buffer.readu8(b, o + 9) / 255,
		}
	end
	return time, entities
end

return NpcCodec
