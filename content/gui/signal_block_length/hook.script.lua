-- Signal Block Length Tooltips: GUI hooks
--
-- Registered through hook.res.lua (react-replacement-config), which runs
-- before the game GUI is built.
--
-- 1. Placing a signal: the construction tool asks `getProposalStringsFn` for
--    extra tooltip lines (the base game uses it for "Reputation: -x%"). It is
--    wrapped for edge object tools (signals) to append the block length.
-- 2. Hovering an existing signal: the game's DefaultEntityToolTip recipe is
--    replaced by one that shows the signal name and its block length; all
--    other entities get the original tooltip.

local block_length = ug_require "block_length.lua"
local builtin = ug_require "::/gui/main/builtin.lua"
local react = ug_require "::/gui/main/react.lua"
local engine_react_util = ug_require "::/gui/main/engine_react_util.tl"
local game_tooltips = ug_require "::/gui/main/game_tooltips.tl"
local construction_react_util = ug_require "::/gui/construction/construction_react_util.tl"

---------------------------------------------------------------------------
-- Hover tooltip for existing signals
---------------------------------------------------------------------------

local SignalBlockLengthEntityToolTip = react.RegisterRecipe("SignalBlockLengthEntityToolTip", function(param)
	react.setMouseTransparent(true)

	-- For signals: the full tooltip text (signal name + block length), else nil.
	local textState = engine_react_util.useStepState(function()
		local entity = param.entityRef:get()
		if entity == nil or (param.filter and not param.filter(entity)) then
			return nil
		end
		local ok, text = pcall(block_length.describeSignal, entity)
		if not ok then
			block_length.warn(text)
			return nil
		end
		if not text then
			return nil
		end
		local name = api.engine.util.getEntityName(entity)
		return name and (name .. "\n" .. text) or text
	end)

	local text = textState:old()
	if not text then
		-- a recipe must return a layout, so wrap the original recipe's node
		return builtin.BoxLayout{
			children = { react.CallOriginalRecipe(game_tooltips.DefaultEntityToolTip, param) },
		}
	end

	-- One text box styled like the game's entity tooltip (see game.css.lua),
	-- so the background covers both the name and the block length.
	return builtin.BoxLayout{
		children = {
			builtin.TextView{
				meta = {
					class = "default-tooltip-configuration, font-scale-tooltip",
					mouseTransparent = true,
				},
				text = text,
			},
		},
	}
end)

---------------------------------------------------------------------------
-- Placement tooltip of the signal tool
---------------------------------------------------------------------------

-- Our wrappers, so action params that are handed out again are not wrapped twice.
local wrappers = setmetatable({}, { __mode = "k" })

local function wrapProposalStrings(actionParams)
	local original = actionParams.getProposalStringsFn
	if original and wrappers[original] then
		return
	end

	local wrapper = function(proposal, proposalData)
		local strings = original and original(proposal, proposalData) or {}
		local ok, line = pcall(block_length.describe, proposal, proposalData)
		if not ok then
			block_length.warn(line)
		elseif line then
			strings[#strings + 1] = line
		end
		return strings
	end
	wrappers[wrapper] = true
	actionParams.getProposalStringsFn = wrapper
end

local function hookConstructionTool()
	local originalGetActionParams = construction_react_util.getActionParams

	construction_react_util.getActionParams = function(...)
		local result = originalGetActionParams(...)
		local actionParams = result and result.constructionActionParams
		if actionParams and actionParams.edgeObjectBuilder ~= nil then
			local ok, err = pcall(wrapProposalStrings, actionParams)
			if not ok then
				block_length.warn(err)
			end
		end
		return result
	end
end

---------------------------------------------------------------------------

local function doReplaceFn(replacementApi)
	hookConstructionTool()
	replacementApi.ReplaceRecipe(game_tooltips.DefaultEntityToolTip, SignalBlockLengthEntityToolTip)
end

-- Script files referenced as "file@function" must expose their functions via data().
function data()
	return {
		doReplaceFn = doReplaceFn,
	}
end
