--!strict
-- Packs minion snapshots for unreliable remotes. Pure, unit tested under Lune.
--
-- Like NpcCodec, but each entity also carries its kind and team, so a client can draw a minion
-- the moment it enters its interest area without a separate spawn event:
--
--   header   f64 server time, u16 entity count                               (10 bytes)
--   entity   u16 id, i16 x, i16 z, u8 yaw, u8 health, u8 state, u8 kindTeam   (10 bytes)
--
-- kindTeam = kind * 4 + team (team 1 or 2). Chunks stay under `maxBytes` (use 900; the engine
-- drops unreliable payloads over 1000 bytes).

export type Entity = {
	id: number,
	x: number,
	z: number,
	yaw: number,
	health: number,
	state: number,
	kind: number,
	team: number,
}

local HEADER_BYTES = 10
local ENTITY_BYTES = 10
local POSITION_SCALE = 16
local TAU = 2 * math.pi

local MinionCodec = {}

MinionCodec.ENTITY_BYTES = ENTITY_BYTES
MinionCodec.HEADER_BYTES = HEADER_BYTES

MinionCodec.States = table.freeze({
	walk = 0,
	fight = 1,
	dead = 2,
})

-- Quantises a value the way the codec stores it, so the server can tell whether a minion
-- changed visibly since it was last sent.
function MinionCodec.quantize(entity: Entity): (number, number, number, number, number)
	local x = math.clamp(math.floor(entity.x * POSITION_SCALE + 0.5), -32768, 32767)
	local z = math.clamp(math.floor(entity.z * POSITION_SCALE + 0.5), -32768, 32767)
	local yaw = math.floor((entity.yaw % TAU) / TAU * 256 + 0.5) % 256
	local health = math.clamp(math.floor(entity.health * 255 + 0.5), 0, 255)
	return x, z, yaw, health, math.clamp(entity.state, 0, 255)
end

-- Packs entities into chunks of at most maxBytes.
function MinionCodec.pack(time: number, entities: { Entity }, maxBytes: number): { buffer }
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
			local x, z, yaw, health, state = MinionCodec.quantize(e)
			buffer.writeu16(b, o, e.id)
			buffer.writei16(b, o + 2, x)
			buffer.writei16(b, o + 4, z)
			buffer.writeu8(b, o + 6, yaw)
			buffer.writeu8(b, o + 7, health)
			buffer.writeu8(b, o + 8, state)
			buffer.writeu8(b, o + 9, math.clamp(e.kind, 0, 63) * 4 + math.clamp(e.team, 0, 3))
		end
		table.insert(chunks, b)
		index += count
	end
	return chunks
end

-- Reads one chunk; nil for a malformed buffer.
function MinionCodec.unpack(b: buffer): (number?, { Entity }?)
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
		local kindTeam = buffer.readu8(b, o + 9)
		entities[i + 1] = {
			id = buffer.readu16(b, o),
			x = buffer.readi16(b, o + 2) / POSITION_SCALE,
			z = buffer.readi16(b, o + 4) / POSITION_SCALE,
			yaw = buffer.readu8(b, o + 6) / 256 * TAU,
			health = buffer.readu8(b, o + 7) / 255,
			state = buffer.readu8(b, o + 8),
			kind = kindTeam // 4,
			team = kindTeam % 4,
		}
	end
	return time, entities
end

return MinionCodec
