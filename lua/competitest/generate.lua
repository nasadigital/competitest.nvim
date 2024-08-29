local api = vim.api
local luv = vim.loop
local config = require("competitest.config")
local utils = require("competitest.utils")
local M = {}

function M.prepare_generation()
	local bufnr = api.nvim_get_current_buf()
	local cfg = config.load_buffer_config(bufnr)
	if type(cfg.generation_template_directory) ~= "string" then
		utils.notify("prepare_generation: generation_template_directory not set, nothing to prepare.", "WARN")
		return
	end

	local expanded_dir = string.gsub(cfg.generation_template_directory, "^%~", vim.loop.os_homedir()) -- expand tilde into home directory
	local dir = luv.fs_opendir(expanded_dir)
	if not dir then
		utils.notify("prepare_generation: Couldn't open directory " .. cfg.generation_template_directory, "WARN")
		return {}
	end

	local destdir = api.nvim_buf_call(bufnr, function()
		return vim.fn.expand("%:p:h")
	end) .. "/"

	while true do -- read all the files in directory
		local entry = luv.fs_readdir(dir)
		if entry == nil then
			break
		end
		if entry[1].type == "file" then
			luv.fs_copyfile(expanded_dir .. "/" .. entry[1].name, destdir .. entry[1].name)
		end
	end
	assert(luv.fs_closedir(dir), "CompetiTest.nvim: io_files.load: unable to close '" .. expanded_dir .. "'")
end

return M
