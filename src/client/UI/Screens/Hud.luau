--!strict
-- HUD v1: health and level, ability buttons with cooldown rings, the team score strip with the
-- round timer, kill feed, minimap, round banner and the respawn screen. Pure view: every value
-- comes from HudState, which UiController keeps up to date.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Fusion = require(ReplicatedStorage.Packages.Fusion)

local Badge = require("../Components/Badge")
local Button = require("../Components/Button")
local CooldownRing = require("../Components/CooldownRing")
local IconButton = require("../Components/IconButton")
local Minimap = require("./Minimap")
local Motion = require("../Motion")
local Panel = require("../Components/Panel")
local ProgressBar = require("../Components/ProgressBar")
local Text = require("../Components/Text")
local Theme = require("../Theme")
local Tooltip = require("../Components/Tooltip")
local UiState = require("../UiState")

local Children, OnEvent = Fusion.Children, Fusion.OnEvent

export type TeamInfo = { name: string, members: number, kills: number, strength: number }
export type KillLine = { id: number, text: string, mine: boolean }

export type HudState = {
	health: Fusion.Value<number>,
	maxHealth: Fusion.Value<number>,
	level: Fusion.Value<number>,
	-- XP into the current class level, and the XP the level needs.
	xp: Fusion.Value<number>,
	xpNext: Fusion.Value<number>,
	-- Big text shown for a moment on level-up ("LEVEL 5"), or "".
	levelUp: Fusion.Value<string>,
	roundText: Fusion.Value<string>,
	banner: Fusion.Value<string>,
	team1: Fusion.Value<TeamInfo>,
	team2: Fusion.Value<TeamInfo>,
	myTeam: Fusion.Value<number>,
	attackCooldown: Fusion.Value<number>,
	dodgeCooldown: Fusion.Value<number>,
	killFeed: Fusion.Value<{ KillLine }>,
	dead: Fusion.Value<boolean>,
	respawnIn: Fusion.Value<number>,
	killedBy: Fusion.Value<string>,
	dots: Fusion.Value<{ Minimap.Dot }>,
	waves: Fusion.Value<{ Minimap.Wave }>,
	-- Every guardian and Titan, in Structures.list order.
	structures: Fusion.Value<{ Minimap.StructureInfo }>,
	-- Jungle camps, in Camps.list order.
	camps: Fusion.Value<{ Minimap.CampInfo }>,
	-- Per team: its Titan is under attack.
	alerts: Fusion.Value<{ boolean }>,
	-- The large monster nearest the player, if any is close.
	boss: Fusion.Value<BossInfo?>,
	-- The egg the player carries ("rare shellback"), or "".
	carrying: Fusion.Value<string>,
	-- Class (Phase 10): its name, the basic attack's name, the three ability slots and their
	-- cooldowns (1 just used, 0 ready), and the status effects on the player.
	className: Fusion.Value<string>,
	attackName: Fusion.Value<string>,
	abilitySlots: Fusion.Value<{ AbilitySlot }>,
	abilityCooldowns: { Fusion.Value<number> },
	statuses: Fusion.Value<{ string }>,
}

export type AbilitySlot = {
	name: string,
	glyph: string,
	key: string,
	unlocked: boolean,
	unlockLevel: number,
}

export type BossInfo = {
	name: string,
	health: number,
	stagger: number,
	staggered: boolean,
	phase: number,
	phases: number,
	locked: boolean,
	hostile: boolean,
}

export type Actions = {
	attack: () -> (),
	dodge: () -> (),
	openSettings: () -> (),
	openPets: () -> (),
	openClasses: () -> (),
	cast: (slot: number) -> (),
}

local TEAM_COLORS = { Theme.color.team1, Theme.color.team2 }
local ABILITY_SIZE = 64

local function teamBlock(scope: UiState.Scope, state: HudState, team: number): Frame
	local info = if team == 1 then state.team1 else state.team2
	local kills = Motion.spring(
		scope,
		scope:Computed(function(use)
			return use(info).kills
		end),
		Theme.motion.numberSpeed
	)
	return scope:New("Frame")({
		Name = `Team{team}`,
		Size = UDim2.fromOffset(190, 52),
		LayoutOrder = if team == 1 then 1 else 3,
		BackgroundColor3 = TEAM_COLORS[team],
		BackgroundTransparency = 0.15,
		[Children] = {
			scope:New("UICorner")({ CornerRadius = Theme.radius.md }),
			scope:New("UIStroke")({
				Color = Color3.new(1, 1, 1),
				Thickness = Theme.stroke.thick,
				Transparency = scope:Computed(function(use)
					return if use(state.myTeam) == team then 0.2 else 1
				end),
			}),
			Text(scope, {
				text = scope:Computed(function(use)
					local i = use(info)
					return `{i.name}  ·  {i.members}`
				end),
				position = UDim2.fromOffset(12, 4),
				size = UDim2.new(1, -60, 0, 22),
				textSize = Theme.text.label,
				font = Theme.font.bold,
			}),
			Text(scope, {
				text = scope:Computed(function(use)
					return string.format("strength %.1f", use(info).strength)
				end),
				position = UDim2.fromOffset(12, 26),
				size = UDim2.new(1, -60, 0, 18),
				textSize = Theme.text.caption,
				color = Color3.new(1, 1, 1),
				transparency = 0.3,
			}),
			-- Kills this round, rolling up on a spring.
			Text(scope, {
				name = "Kills",
				text = scope:Computed(function(use)
					return tostring(math.floor((use(kills) :: number) + 0.5))
				end),
				anchorPoint = Vector2.new(1, 0.5),
				position = UDim2.new(1, -12, 0.5, 0),
				size = UDim2.fromOffset(48, 40),
				textSize = Theme.text.heading,
				font = Theme.font.heavy,
				alignX = Enum.TextXAlignment.Right,
			}),
		},
	}) :: Frame
end

local LANES = { "top", "middle", "bottom" }

local function findStructure(list: { Minimap.StructureInfo }, key: string): Minimap.StructureInfo?
	for _, s in list do
		if s.key == key then
			return s
		end
	end
	return nil
end

-- Under each team block: a pair of pips per lane (outer, inner guardian) and the Titan's health.
-- Pips are bright while alive, faded while locked by lane gating, dark when destroyed.
local function structureRow(scope: UiState.Scope, state: HudState, team: number): Frame
	local children: { Fusion.Child } = {
		scope:New("UIListLayout")({
			FillDirection = Enum.FillDirection.Horizontal,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			Padding = UDim.new(0, 3),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	}
	local order = 0
	for laneIndex, lane in LANES do
		for _, kind in { "outerGuardian", "innerGuardian" } do
			order += 1
			local key = `T{team}_{lane}_{kind}`
			local info = scope:Computed(function(use)
				return findStructure(use(state.structures), key)
			end)
			table.insert(
				children,
				scope:New("Frame")({
					Name = key,
					LayoutOrder = order,
					Size = UDim2.fromOffset(10, 10),
					BackgroundColor3 = scope:Computed(function(use)
						local s = use(info)
						return if s == nil or s.dead then Color3.fromRGB(50, 50, 56) else TEAM_COLORS[team]
					end),
					BackgroundTransparency = scope:Computed(function(use)
						local s = use(info)
						return if s and s.locked then 0.55 else 0
					end),
					BorderSizePixel = 0,
					[Children] = {
						scope:New("UICorner")({ CornerRadius = UDim.new(0, 2) }),
						scope:New("UIStroke")({ Color = Color3.new(1, 1, 1), Transparency = 0.5 }),
					},
				})
			)
		end
		if laneIndex < #LANES then
			order += 1
			table.insert(
				children,
				scope:New("Frame")({ LayoutOrder = order, Size = UDim2.fromOffset(4, 1), BackgroundTransparency = 1 })
			)
		end
	end
	local titanKey = `T{team}_titan`
	local titan = scope:Computed(function(use)
		local s = findStructure(use(state.structures), titanKey)
		return if s then s.health else 1
	end)
	order += 1
	table.insert(
		children,
		scope:New("Frame")({
			Name = "Titan",
			LayoutOrder = order,
			Size = UDim2.fromOffset(84, 10),
			BackgroundColor3 = Theme.color.surface,
			BorderSizePixel = 0,
			[Children] = {
				scope:New("UICorner")({ CornerRadius = UDim.new(0, 3) }),
				scope:New("UIStroke")({
					Color = Theme.color.danger,
					Thickness = Theme.stroke.thick,
					-- Flashes while the Titan is under attack.
					Transparency = scope:Computed(function(use)
						return if use(state.alerts)[team] then 0 else 1
					end),
				}),
				scope:New("Frame")({
					Name = "Fill",
					Size = scope:Computed(function(use)
						return UDim2.fromScale(use(titan), 1)
					end),
					BackgroundColor3 = TEAM_COLORS[team],
					BorderSizePixel = 0,
					[Children] = { scope:New("UICorner")({ CornerRadius = UDim.new(0, 3) }) },
				}),
			},
		})
	)
	return scope:New("Frame")({
		Name = `Structures{team}`,
		LayoutOrder = if team == 1 then 1 else 3,
		Size = UDim2.fromOffset(190, 14),
		BackgroundTransparency = 1,
		[Children] = children,
	}) :: Frame
end

-- Health, stagger and phase of the large monster nearest the player.
local function bossBar(scope: UiState.Scope, state: HudState): Frame
	local function field<T>(get: (BossInfo) -> T, default: T): Fusion.Computed<T>
		return scope:Computed(function(use)
			local b = use(state.boss)
			return if b then get(b) else default
		end)
	end
	return scope:New("Frame")({
		Name = "BossBar",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 92),
		Size = UDim2.fromOffset(440, 46),
		BackgroundColor3 = Theme.color.surface,
		BackgroundTransparency = 0.2,
		Visible = scope:Computed(function(use)
			return use(state.boss) ~= nil
		end),
		[Children] = {
			scope:New("UICorner")({ CornerRadius = Theme.radius.md }),
			scope:New("UIStroke")({
				Color = field(function(b: BossInfo): Color3
					return if b.hostile then Theme.color.danger else Theme.color.info
				end, Theme.color.stroke),
				Thickness = Theme.stroke.thin,
			}),
			Text(scope, {
				name = "Name",
				text = field(function(b: BossInfo): string
					local phase = if b.phases > 1 then `  ·  phase {b.phase}/{b.phases}` else ""
					return b.name .. phase
				end, ""),
				position = UDim2.fromOffset(12, 3),
				size = UDim2.new(1, -24, 0, 18),
				textSize = Theme.text.label,
				font = Theme.font.bold,
			}),
			Text(scope, {
				name = "Status",
				text = field(function(b: BossInfo): string
					return if b.locked then "🔒 LOCKED" elseif b.staggered then "STAGGERED" else ""
				end, ""),
				anchorPoint = Vector2.new(1, 0),
				position = UDim2.new(1, -12, 0, 3),
				size = UDim2.fromOffset(160, 18),
				textSize = Theme.text.caption,
				font = Theme.font.heavy,
				color = field(function(b: BossInfo): Color3
					return if b.locked then Theme.color.textMuted else Theme.color.warning
				end, Theme.color.text),
				alignX = Enum.TextXAlignment.Right,
			}),
			ProgressBar(scope, {
				name = "Health",
				value = field(function(b: BossInfo): number
					return b.health
				end, 0),
				color = field(function(b: BossInfo): Color3
					return if b.locked then Theme.color.textMuted else Theme.color.danger
				end, Theme.color.danger),
				position = UDim2.fromOffset(12, 22),
				size = UDim2.new(1, -24, 0, 12),
			}),
			ProgressBar(scope, {
				name = "Stagger",
				value = field(function(b: BossInfo): number
					return b.stagger
				end, 0),
				color = Theme.color.warning,
				position = UDim2.fromOffset(12, 36),
				size = UDim2.new(1, -24, 0, 5),
			}),
		},
	}) :: Frame
end

local function ability(
	scope: UiState.Scope,
	name: Fusion.UsedAs<string>,
	key: string,
	cooldown: Fusion.Value<number>,
	onClick: () -> (),
	order: number,
	tooltip: Fusion.UsedAs<string>?
): TextButton
	local button = scope:New("TextButton")({
		Name = `Action{order}`,
		Size = UDim2.fromOffset(ABILITY_SIZE, ABILITY_SIZE),
		LayoutOrder = order,
		AutoButtonColor = false,
		Selectable = true,
		BackgroundColor3 = Theme.color.surfaceRaised,
		BackgroundTransparency = 0.1,
		Text = name,
		TextColor3 = Theme.color.text,
		TextSize = Theme.text.caption,
		FontFace = Theme.font.bold,
		[OnEvent("Activated")] = onClick,
		[Children] = {
			scope:New("UICorner")({ CornerRadius = Theme.radius.pill }),
			scope:New("UIStroke")({
				-- Border mode: on a text button the default outlines the text instead.
				ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
				Color = scope:Computed(function(use)
					return if use(cooldown) > 0 then Theme.color.stroke else Theme.color.accent
				end),
				Thickness = Theme.stroke.thick,
			}),
			CooldownRing(scope, { remaining = cooldown, size = ABILITY_SIZE, zIndex = 2 }),
			Badge(scope, {
				text = key,
				color = Theme.color.surface,
				anchorPoint = Vector2.new(0.5, 0.5),
				position = UDim2.fromScale(0.5, 1),
			}),
		},
	}) :: TextButton
	Tooltip(scope, button, tooltip or scope:Computed(function(use)
		return `{use(name)} ({key})`
	end))
	return button
end

-- One class ability slot: its glyph, key and cooldown ring; locked slots show the level that
-- unlocks them.
local function classAbility(scope: UiState.Scope, state: HudState, actions: Actions, slot: number): TextButton
	local info = scope:Computed(function(use): AbilitySlot?
		return use(state.abilitySlots)[slot]
	end)
	local button = ability(
		scope,
		scope:Computed(function(use)
			local s: AbilitySlot? = use(info)
			if s == nil then
				return ""
			end
			return if s.unlocked then s.glyph else `Lv {s.unlockLevel}`
		end),
		tostring(slot),
		state.abilityCooldowns[slot],
		function()
			actions.cast(slot)
		end,
		slot + 1,
		scope:Computed(function(use)
			local s: AbilitySlot? = use(info)
			if s == nil then
				return ""
			end
			return if s.unlocked then `{s.name} ({s.key})` else `{s.name}: unlocks at class level {s.unlockLevel}`
		end)
	)
	button.Name = `Ability{slot}`
	return button
end

local STATUS_STYLE: { [string]: { text: string, color: Color3 } } = {
	slow = { text = "Slowed", color = Theme.color.info },
	stun = { text = "Stunned", color = Theme.color.warning },
	shield = { text = "Shield", color = Theme.color.accent },
	regen = { text = "Healing", color = Theme.color.success },
	taunt = { text = "Taunted", color = Theme.color.danger },
	vulnerable = { text = "Marked", color = Theme.color.danger },
	empower = { text = "Empowered", color = Theme.color.warning },
}

-- Status effects on the player, as small labels above the health bar.
local function statusRow(scope: UiState.Scope, state: HudState): Frame
	local children: { Fusion.Child } = {
		scope:New("UIListLayout")({
			FillDirection = Enum.FillDirection.Horizontal,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			Padding = UDim.new(0, Theme.space.xs),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	}
	-- A fixed label per kind (pooled), shown while it applies.
	local order = 0
	for kind, style in STATUS_STYLE do
		order += 1
		table.insert(
			children,
			Badge(scope, {
				name = kind,
				text = style.text,
				color = style.color,
				layoutOrder = order,
				visible = scope:Computed(function(use)
					return table.find(use(state.statuses), kind) ~= nil
				end),
			})
		)
	end
	return scope:New("Frame")({
		Name = "Statuses",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -64 - ABILITY_SIZE - 20),
		Size = UDim2.fromOffset(420, 22),
		BackgroundTransparency = 1,
		[Children] = children,
	}) :: Frame
end

local function killFeed(scope: UiState.Scope, state: HudState): Frame
	return scope:New("Frame")({
		Name = "KillFeed",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -Theme.space.lg, 0, 150),
		Size = UDim2.fromOffset(420, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		[Children] = {
			scope:New("UIListLayout")({
				Padding = UDim.new(0, Theme.space.xs),
				SortOrder = Enum.SortOrder.LayoutOrder,
				HorizontalAlignment = Enum.HorizontalAlignment.Right,
			}),
			scope:ForValues(state.killFeed :: any, function(_use: any, inner: any, line: KillLine): any
				return inner:New("TextLabel")({
					Name = "Line",
					LayoutOrder = -line.id,
					AutomaticSize = Enum.AutomaticSize.X,
					Size = UDim2.fromOffset(0, 24),
					BackgroundColor3 = if line.mine then Theme.color.accent else Theme.color.surface,
					BackgroundTransparency = 0.25,
					Text = line.text,
					TextColor3 = Theme.color.text,
					TextSize = Theme.text.caption,
					FontFace = Theme.font.bold,
					[Children] = {
						inner:New("UICorner")({ CornerRadius = Theme.radius.sm }),
						inner:New("UIPadding")({ PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8) }),
					},
				})
			end) :: any,
		},
	}) :: Frame
end

local function respawnScreen(scope: UiState.Scope, state: HudState, actions: Actions): Frame
	local alpha = Motion.spring(
		scope,
		scope:Computed(function(use)
			return if use(state.dead) then 1 else 0
		end),
		Theme.motion.moveSpeed
	)
	return scope:New("Frame")({
		Name = "RespawnScreen",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Theme.color.overlay,
		BackgroundTransparency = scope:Computed(function(use)
			return 1 - 0.45 * use(alpha)
		end),
		Visible = scope:Computed(function(use)
			return use(alpha) > 0.01
		end),
		ZIndex = 10,
		[Children] = {
			Text(scope, {
				text = scope:Computed(function(use)
					local by = use(state.killedBy)
					return if by ~= "" then `Defeated by {by}` else "Defeated"
				end),
				anchorPoint = Vector2.new(0.5, 0.5),
				position = UDim2.fromScale(0.5, 0.4),
				size = UDim2.fromOffset(600, 50),
				textSize = Theme.text.heading,
				font = Theme.font.heavy,
				alignX = Enum.TextXAlignment.Center,
				transparency = scope:Computed(function(use)
					return 1 - use(alpha)
				end),
			}),
			Text(scope, {
				text = scope:Computed(function(use)
					return `Respawning in {math.max(0, math.ceil(use(state.respawnIn)))}`
				end),
				anchorPoint = Vector2.new(0.5, 0.5),
				position = UDim2.fromScale(0.5, 0.48),
				size = UDim2.fromOffset(600, 40),
				textSize = Theme.text.title,
				color = Theme.color.textMuted,
				alignX = Enum.TextXAlignment.Center,
				transparency = scope:Computed(function(use)
					return 1 - use(alpha)
				end),
			}),
			-- Switching class is allowed while respawning.
			scope:New("Frame")({
				Name = "ChangeClass",
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.57),
				Size = UDim2.fromOffset(220, 48),
				BackgroundTransparency = 1,
				Visible = state.dead,
				[Children] = {
					Button(scope, {
						text = scope:Computed(function(use)
							return `Change class ({use(state.className)})`
						end),
						variant = "secondary",
						size = UDim2.fromScale(1, 1),
						onClick = actions.openClasses,
					}),
				},
			}) :: any,
		},
	}) :: Frame
end

local function Hud(scope: UiState.Scope, state: HudState, actions: Actions): { Fusion.Child }
	local healthFraction = scope:Computed(function(use)
		local max = use(state.maxHealth)
		return if max > 0 then use(state.health) / max else 0
	end)

	return {
		-- Top centre: team strip with the round timer between the teams.
		scope:New("Frame")({
			Name = "TeamStrip",
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(0.5, 0, 0, Theme.space.sm),
			Size = UDim2.fromOffset(620, 52),
			BackgroundTransparency = 1,
			[Children] = {
				scope:New("UIListLayout")({
					FillDirection = Enum.FillDirection.Horizontal,
					HorizontalAlignment = Enum.HorizontalAlignment.Center,
					Padding = UDim.new(0, Theme.space.sm),
					SortOrder = Enum.SortOrder.LayoutOrder,
				}),
				teamBlock(scope, state, 1),
				Panel(scope, {
					name = "Round",
					size = UDim2.fromOffset(200, 52),
					layoutOrder = 2,
					padding = Theme.space.xs,
					children = {
						Text(scope, {
							text = state.roundText,
							size = UDim2.fromScale(1, 1),
							textSize = Theme.text.label,
							font = Theme.font.bold,
							alignX = Enum.TextXAlignment.Center,
						}),
					},
				}),
				teamBlock(scope, state, 2),
			},
		}),
		-- Guardians and Titans under each team block.
		scope:New("Frame")({
			Name = "StructureStrip",
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(0.5, 0, 0, Theme.space.sm + 56),
			Size = UDim2.fromOffset(620, 14),
			BackgroundTransparency = 1,
			[Children] = {
				scope:New("UIListLayout")({
					FillDirection = Enum.FillDirection.Horizontal,
					HorizontalAlignment = Enum.HorizontalAlignment.Center,
					Padding = UDim.new(0, Theme.space.sm),
					SortOrder = Enum.SortOrder.LayoutOrder,
				}),
				structureRow(scope, state, 1),
				scope:New("Frame")({ LayoutOrder = 2, Size = UDim2.fromOffset(200, 1), BackgroundTransparency = 1 }),
				structureRow(scope, state, 2),
			},
		}),
		bossBar(scope, state),

		-- Round banner (result, new teams).
		Text(scope, {
			name = "Banner",
			text = state.banner,
			anchorPoint = Vector2.new(0.5, 0.5),
			position = UDim2.fromScale(0.5, 0.25),
			size = UDim2.fromOffset(800, 64),
			textSize = Theme.text.display,
			font = Theme.font.heavy,
			alignX = Enum.TextXAlignment.Center,
			stroke = true,
		}),

		-- Top right: minimap, kill feed below it.
		Minimap(scope, {
			dots = state.dots,
			waves = state.waves,
			structures = state.structures,
			camps = state.camps,
			width = 240,
			anchorPoint = Vector2.new(1, 0),
			position = UDim2.new(1, -Theme.space.lg, 0, Theme.space.sm),
			teamColors = TEAM_COLORS,
		}),
		killFeed(scope, state),

		-- Carry indicator above the abilities while carrying an egg.
		scope:New("Frame")({
			Name = "Carrying",
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.new(0.5, 0, 1, -150),
			Size = UDim2.fromOffset(460, 34),
			BackgroundColor3 = Theme.color.warning,
			BackgroundTransparency = 0.15,
			Visible = scope:Computed(function(use)
				return use(state.carrying) ~= ""
			end),
			[Children] = {
				scope:New("UICorner")({ CornerRadius = Theme.radius.pill }),
				Text(scope, {
					text = scope:Computed(function(use)
						return `🥚 {use(state.carrying)} egg  ·  slowed, no dodge  ·  take it to your hatchery`
					end),
					size = UDim2.fromScale(1, 1),
					textSize = Theme.text.label,
					font = Theme.font.bold,
					color = Theme.color.background,
					alignX = Enum.TextXAlignment.Center,
				}),
			},
		}),

		-- Bottom centre: abilities above the health bar with the level badge.
		scope:New("Frame")({
			Name = "Abilities",
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.new(0.5, 0, 1, -64),
			Size = UDim2.fromOffset(520, ABILITY_SIZE + 12),
			BackgroundTransparency = 1,
			[Children] = {
				scope:New("UIListLayout")({
					FillDirection = Enum.FillDirection.Horizontal,
					HorizontalAlignment = Enum.HorizontalAlignment.Center,
					Padding = UDim.new(0, Theme.space.lg),
					SortOrder = Enum.SortOrder.LayoutOrder,
				}),
				ability(scope, state.attackName, "LMB", state.attackCooldown, actions.attack, 1),
				classAbility(scope, state, actions, 1),
				classAbility(scope, state, actions, 2),
				classAbility(scope, state, actions, 3),
				ability(scope, "Dodge", "Q", state.dodgeCooldown, actions.dodge, 5),
			},
		}),
		scope:New("Frame")({
			Name = "Vitals",
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.new(0.5, 0, 1, -Theme.space.lg),
			Size = UDim2.fromOffset(360, 28),
			BackgroundTransparency = 1,
			[Children] = {
				Badge(scope, {
					name = "Level",
					text = scope:Computed(function(use)
						return `Lv {use(state.level)}`
					end),
					anchorPoint = Vector2.new(0, 0.5),
					position = UDim2.fromScale(0, 0.5),
				}),
				ProgressBar(scope, {
					name = "Health",
					value = healthFraction,
					color = scope:Computed(function(use)
						return if use(healthFraction) < 0.3 then Theme.color.healthLow else Theme.color.health
					end),
					label = scope:Computed(function(use)
						return `{math.ceil(use(state.health))} / {math.ceil(use(state.maxHealth))}`
					end),
					anchorPoint = Vector2.new(1, 0.5),
					position = UDim2.fromScale(1, 0.5),
					size = UDim2.new(1, -64, 0, 20),
				}),
			},
		}),

		-- XP towards the next class level, under the health bar.
		ProgressBar(scope, {
			name = "Xp",
			value = scope:Computed(function(use)
				local need = use(state.xpNext)
				return if need > 0 then use(state.xp) / need else 0
			end),
			color = Theme.color.info,
			label = scope:Computed(function(use)
				return `{use(state.className)}  ·  {use(state.xp)} / {use(state.xpNext)} XP`
			end),
			anchorPoint = Vector2.new(0.5, 1),
			position = UDim2.new(0.5, 32, 1, -4),
			size = UDim2.fromOffset(296, 10),
		}),

		-- Level-up moment.
		Text(scope, {
			name = "LevelUp",
			text = state.levelUp,
			anchorPoint = Vector2.new(0.5, 0.5),
			position = UDim2.fromScale(0.5, 0.36),
			size = UDim2.fromOffset(600, 70),
			textSize = Theme.text.display,
			font = Theme.font.heavy,
			color = Theme.color.warning,
			alignX = Enum.TextXAlignment.Center,
			stroke = true,
		}),

		-- Bottom left: settings and pets.
		IconButton(scope, {
			name = "Settings",
			icon = "⚙",
			tooltip = "Settings (P)",
			onClick = actions.openSettings,
			anchorPoint = Vector2.new(0, 1),
			position = UDim2.new(0, Theme.space.lg, 1, -Theme.space.lg),
		}),
		IconButton(scope, {
			name = "Pets",
			icon = "🐾",
			tooltip = "Pet stable (K)",
			onClick = actions.openPets,
			anchorPoint = Vector2.new(0, 1),
			position = UDim2.new(0, Theme.space.lg + 56, 1, -Theme.space.lg),
		}),

		statusRow(scope, state),
		respawnScreen(scope, state, actions),
	}
end

return Hud
