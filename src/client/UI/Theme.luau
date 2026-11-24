--!strict
-- Design tokens: every UI colour, size and motion value comes from here so the look can change
-- in one place (Phase 13 HUD v2 restyles through these tokens).
--
-- Sizes are in points at the 1600 x 900 reference resolution; Layout scales them to the screen.

local Theme = {}

Theme.color = table.freeze({
	-- Neutral dark surfaces, from the page background up to raised controls.
	background = Color3.fromRGB(14, 16, 22),
	surface = Color3.fromRGB(24, 27, 36),
	surfaceRaised = Color3.fromRGB(34, 38, 50),
	surfaceHover = Color3.fromRGB(44, 49, 64),
	stroke = Color3.fromRGB(70, 76, 96),
	overlay = Color3.fromRGB(0, 0, 0),

	text = Color3.fromRGB(240, 242, 248),
	textMuted = Color3.fromRGB(160, 166, 184),
	textOnAccent = Color3.fromRGB(255, 255, 255),

	accent = Color3.fromRGB(98, 132, 255),
	-- One accent per team (match Config.teams brick colours).
	team1 = Color3.fromRGB(13, 105, 172),
	team2 = Color3.fromRGB(196, 40, 28),

	-- Semantic colours.
	health = Color3.fromRGB(88, 214, 110),
	healthLow = Color3.fromRGB(240, 170, 60),
	danger = Color3.fromRGB(240, 80, 80),
	success = Color3.fromRGB(90, 210, 130),
	warning = Color3.fromRGB(250, 200, 80),
	info = Color3.fromRGB(110, 180, 255),

	-- Rarity (eggs, pets, cosmetics).
	common = Color3.fromRGB(190, 195, 205),
	rare = Color3.fromRGB(80, 160, 255),
	epic = Color3.fromRGB(180, 100, 255),
	legendary = Color3.fromRGB(255, 180, 50),
})

-- Type scale (text sizes in points).
Theme.text = table.freeze({
	caption = 12,
	body = 15,
	label = 14,
	title = 20,
	heading = 28,
	display = 44,
})

Theme.font = table.freeze({
	regular = Font.fromEnum(Enum.Font.Gotham),
	medium = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Medium),
	bold = Font.fromEnum(Enum.Font.GothamBold),
	heavy = Font.fromEnum(Enum.Font.GothamBlack),
	mono = Font.fromEnum(Enum.Font.RobotoMono),
})

-- Spacing scale (points).
Theme.space = table.freeze({
	xs = 4,
	sm = 8,
	md = 12,
	lg = 16,
	xl = 24,
	xxl = 32,
})

Theme.radius = table.freeze({
	sm = UDim.new(0, 6),
	md = UDim.new(0, 10),
	lg = UDim.new(0, 14),
	pill = UDim.new(1, 0),
})

Theme.stroke = table.freeze({
	thin = 1,
	thick = 2,
})

-- Elevation as background transparency of the shadow under raised panels.
Theme.elevation = table.freeze({
	flat = 1,
	raised = 0.6,
	modal = 0.35,
})

-- Motion: spring speed and damping per kind of movement, and tween durations.
Theme.motion = table.freeze({
	pressSpeed = 40,
	pressDamping = 0.8,
	moveSpeed = 22,
	moveDamping = 1,
	numberSpeed = 12,
	fade = 0.18,
	toastSeconds = 3.5,
})

-- Minimum interactive size in points.
Theme.minTouch = 44

return Theme
