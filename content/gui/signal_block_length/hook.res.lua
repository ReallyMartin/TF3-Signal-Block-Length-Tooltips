-- Registers a GUI hook that runs before the React GUI is built. The hook adds
-- the block length to the signal placement tooltip and to the hover tooltip
-- of existing signals (see hook.script.lua).
function data()
	return {
		type = "react-replacement-config",
		data = {
			filePath = "signal_block_length::/gui/signal_block_length/hook.script",
			doReplaceFn = "doReplaceFn",
			order = 0,
		}
	}
end
