--!strict
-- The cosmetic format (Phase 12). Every cosmetic is pure looks: nothing here is read by the stat
-- function, damage, XP or any other rule (unit tests check the catalogue has no other fields).

-- "weaponSkin", "armourSkin", "petSkin", "trail", "killEffect", "emote" or "title" (checked by
-- tests; plain strings because literal unions widen in data tables).
export type Kind = string

export type Look = {
	-- Main and secondary colours (RGB 0-255).
	color: { number }?,
	color2: { number }?,
	-- An Enum.Material name ("Neon", "Metal", "Glass", ...).
	material: string?,
	-- Adds a soft light to the piece.
	glow: boolean?,
	-- Particles per second on the piece (counted against the budget).
	particles: number?,
	-- Trails: seconds a point lasts, and width in studs.
	lifetime: number?,
	width: number?,
	-- Kill effects: burst shape ("sparks", "rings", "skulls", "petals").
	burst: string?,
	-- Emotes: the pose ("wave", "cheer", "bow", "spin").
	pose: string?,
	-- Titles: the text shown on the nameplate.
	text: string?,
}

export type Item = {
	id: string,
	name: string,
	kind: Kind,
	-- "common", "rare", "epic" or "legendary".
	rarity: string,
	-- Gold price; 0 means it cannot be bought (given another way).
	price: number,
	-- Weapon skins: the weapon they fit ("sword", "bow", "staff", "wand"), or nil for any.
	weapon: string?,
	description: string,
	look: Look,
}

return nil
