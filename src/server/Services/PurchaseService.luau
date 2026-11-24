--!strict
-- Robux purchases (Phase 12): gold packs are developer products; extra loadouts are a game pass
-- (EconomyService checks ownership). Nothing sold for Robux changes power, XP or any stat.
--
-- The receipt handler is idempotent and only reports PurchaseGranted once the grant is saved:
--   1. The buyer's profile must be loaded on this server (session-locked); otherwise
--      NotProcessedYet, and Roblox retries when they are back.
--   2. Shared.Economy.applyReceipt grants the gold and records the receipt ID in the profile,
--      unless that ID is already recorded (a retry): then it grants nothing.
--   3. The profile is saved now. Only if the save succeeds is the purchase reported granted; if
--      it fails, NotProcessedYet. The retry then finds the receipt already applied in memory (or,
--      after a crash, applies it to the stored profile), so the gold is granted exactly once.

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Economy = require(ReplicatedStorage.Shared.Economy)
local Net = require(ReplicatedStorage.Shared.Net)
local Remotes = require(ReplicatedStorage.Shared.Remotes)

local DataService = require("./DataService")
local EconomyService = require("./EconomyService")

local PurchaseService = {
	name = "PurchaseService",
	dependencies = { "DataService", "EconomyService" },
}

export type Receipt = {
	PlayerId: number,
	ProductId: number,
	PurchaseId: string,
	CurrencySpent: number?,
}

-- Handles one receipt. Returns the decision for Roblox. Exposed for tests and dev tools.
function PurchaseService.process(receipt: Receipt): Enum.ProductPurchaseDecision
	local player = Players:GetPlayerByUserId(receipt.PlayerId)
	local data = if player then DataService.get(player) else nil
	if player == nil or data == nil then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	local result, gold =
		Economy.applyReceipt(data :: any, receipt.PurchaseId, receipt.ProductId, os.time(), Config.get().economy)
	if result == "unknown" then
		warn(`[Purchases] unknown product {receipt.ProductId} (receipt {receipt.PurchaseId})`)
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	if not DataService.save(player) then
		warn(`[Purchases] could not save receipt {receipt.PurchaseId}; Roblox will retry`)
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	if result == "granted" then
		EconomyService.publish(player)
		EconomyService.goldChanged:fire(player, gold, "robux")
		pcall(function()
			game:GetService("AnalyticsService"):LogEconomyEvent(
				player,
				Enum.AnalyticsEconomyFlowType.Source,
				"Gold",
				gold,
				(data :: any).gold,
				Enum.AnalyticsEconomyTransactionType.IAP.Name,
				tostring(receipt.ProductId)
			)
		end)
		Net.fireClient(Remotes.Announce, player, { text = `Thank you! +{gold} gold`, kind = "success" })
	end
	return Enum.ProductPurchaseDecision.PurchaseGranted
end

function PurchaseService.init(_self: typeof(PurchaseService))
	MarketplaceService.ProcessReceipt = function(receipt: any): Enum.ProductPurchaseDecision
		local ok, decision = pcall(PurchaseService.process, receipt)
		if not ok then
			warn(`[Purchases] receipt failed: {decision}`)
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end
		return decision
	end
end

return PurchaseService
