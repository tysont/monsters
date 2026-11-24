--!strict
-- The cosmetic catalogue (Phase 12): weapon skins, armour skins, pet skins, trails, kill effects,
-- emotes and titles, each with a rarity and a gold price. To add a cosmetic, add an entry here
-- (format in Types.luau); renderers read the look data, so no code changes are needed.
--
-- Prices by rarity: common 250, rare 600, epic 1200, legendary 2500 gold.

local Types = require("@self/Types")

export type Item = Types.Item
export type Look = Types.Look

local PRICE: { [string]: number } = { common = 250, rare = 600, epic = 1200, legendary = 2500 }

local list: { Types.Item } = {}

local function add(
	id: string,
	name: string,
	kind: string,
	rarity: string,
	description: string,
	look: Types.Look,
	weapon: string?
)
	table.insert(list, {
		id = id,
		name = name,
		kind = kind,
		rarity = rarity,
		price = PRICE[rarity],
		weapon = weapon,
		description = description,
		look = look,
	})
end

-- Weapon skins: three fit any weapon, one more per weapon.
add("ember", "Ember", "weaponSkin", "rare", "Glowing coals along the weapon.", {
	color = { 255, 120, 40 },
	material = "Neon",
	particles = 6,
})
add("frostbite", "Frostbite", "weaponSkin", "rare", "Cold blue ice.", { color = { 150, 220, 255 }, material = "Glass" })
add("royal", "Royal", "weaponSkin", "epic", "Gold and deep purple.", {
	color = { 255, 205, 70 },
	color2 = { 90, 40, 140 },
	material = "Metal",
	glow = true,
})
add("obsidian", "Obsidian Blade", "weaponSkin", "epic", "A black glass blade.", {
	color = { 30, 25, 40 },
	color2 = { 180, 60, 255 },
	material = "Glass",
}, "sword")
add("greenwood", "Greenwood Bow", "weaponSkin", "rare", "A living branch.", {
	color = { 80, 160, 70 },
	color2 = { 220, 240, 150 },
	material = "Grass",
}, "bow")
add("starstaff", "Star Staff", "weaponSkin", "legendary", "A staff that holds a small star.", {
	color = { 40, 40, 90 },
	color2 = { 255, 255, 200 },
	material = "Neon",
	glow = true,
	particles = 10,
}, "staff")
add("sunwand", "Sun Wand", "weaponSkin", "epic", "Warm light at the tip.", {
	color = { 255, 240, 200 },
	color2 = { 255, 170, 40 },
	material = "Neon",
	glow = true,
}, "wand")

-- Armour skins: shoulder plates.
add("ironplate", "Iron Plates", "armourSkin", "common", "Plain iron shoulder plates.", {
	color = { 150, 155, 165 },
	material = "Metal",
})
add("mossplate", "Moss Plates", "armourSkin", "rare", "Plates grown over with moss.", {
	color = { 70, 110, 60 },
	material = "Grass",
})
add("crystalplate", "Crystal Plates", "armourSkin", "epic", "Clear crystal plates.", {
	color = { 200, 230, 255 },
	material = "Glass",
	glow = true,
})
add("dragonplate", "Dragon Plates", "armourSkin", "legendary", "Scaled plates that smoulder.", {
	color = { 160, 30, 30 },
	color2 = { 255, 140, 40 },
	material = "Slate",
	particles = 5,
})

-- Pet skins: a tint for any pet.
add("goldpet", "Golden Coat", "petSkin", "epic", "Your pet in gold.", { color = { 255, 205, 70 }, material = "Metal" })
add("shadowpet", "Shadow Coat", "petSkin", "rare", "Your pet in shadow.", { color = { 40, 35, 55 } })
add("frostpet", "Frost Coat", "petSkin", "rare", "Your pet in ice.", { color = { 170, 220, 255 }, material = "Glass" })
add("candypet", "Candy Coat", "petSkin", "common", "Your pet in pink.", { color = { 255, 150, 200 } })

-- Trails: behind you as you move.
add("sparktrail", "Spark Trail", "trail", "common", "A short white streak.", {
	color = { 255, 255, 255 },
	lifetime = 0.3,
	width = 1,
})
add("flametrail", "Flame Trail", "trail", "rare", "Fire at your heels.", {
	color = { 255, 160, 40 },
	color2 = { 255, 40, 20 },
	lifetime = 0.4,
	width = 1.4,
})
add("rainbowtrail", "Rainbow Trail", "trail", "epic", "Every colour.", {
	color = { 255, 80, 80 },
	color2 = { 80, 120, 255 },
	lifetime = 0.5,
	width = 1.6,
})
add("voidtrail", "Void Trail", "trail", "legendary", "A tear in the air behind you.", {
	color = { 60, 0, 100 },
	color2 = { 0, 0, 0 },
	lifetime = 0.6,
	width = 2,
})

-- Kill effects: a burst where your victim falls.
add("sparks", "Sparks", "killEffect", "common", "A spray of sparks.", { color = { 255, 230, 120 }, burst = "sparks" })
add(
	"rings",
	"Shockwave",
	"killEffect",
	"rare",
	"Rings that spread out.",
	{ color = { 120, 200, 255 }, burst = "rings" }
)
add("petals", "Petals", "killEffect", "epic", "A cloud of petals.", { color = { 255, 150, 200 }, burst = "petals" })
add("skulls", "Spooky", "killEffect", "legendary", "Little skulls float up.", {
	color = { 230, 230, 230 },
	burst = "skulls",
})

-- Emotes (key G).
add("wave", "Wave", "emote", "common", "Say hello.", { pose = "wave" })
add("cheer", "Cheer", "emote", "rare", "Both arms up.", { pose = "cheer" })
add("bow", "Bow", "emote", "rare", "A polite bow.", { pose = "bow" })
add("spin", "Spin", "emote", "epic", "A victory spin.", { pose = "spin" })

-- Titles (bought; account-level titles from Phase 9 are free and still shown).
add("titleslayer", "Monster Slayer", "title", "rare", "A title for your nameplate.", { text = "Monster Slayer" })
add("titlewarden", "Wardenbane", "title", "epic", "A title for your nameplate.", { text = "Wardenbane" })
add("titlelegend", "Living Legend", "title", "legendary", "A title for your nameplate.", { text = "Living Legend" })

local byId: { [string]: Types.Item } = {}
for _, item in list do
	assert(byId[item.id] == nil, `duplicate cosmetic {item.id}`)
	byId[item.id] = item
end

local Cosmetics = {
	list = list,
	byId = byId,
	-- Loadout slots, one per kind except pet skins (those live on each pet).
	SLOTS = { "weaponSkin", "armourSkin", "trail", "killEffect", "emote", "title" },
	KINDS = { "weaponSkin", "armourSkin", "petSkin", "trail", "killEffect", "emote", "title" },
	RARITIES = { "common", "rare", "epic", "legendary" },
	PRICE = PRICE,
}

function Cosmetics.get(id: string): Types.Item?
	return byId[id]
end

return Cosmetics
