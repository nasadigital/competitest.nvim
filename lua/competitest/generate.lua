local api = vim.api
local luv = vim.loop
local config = require("competitest.config")
local utils = require("competitest.utils")
local M = {}

function M.prepare_generation(passed_args)
	local bufnr = api.nvim_get_current_buf()
	local cfg = config.get_buffer_config(bufnr)
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

	-- Run custom generation command if configured
	if cfg.custom_generation_command and type(cfg.custom_generation_command) == "table" then
		-- Replace $(PROBLEM_DIR) placeholder with actual directory
		local cmd = {}
		for i, arg in ipairs(cfg.custom_generation_command) do
			local replaced_arg = string.gsub(arg, "%$%(PROBLEM_DIR%)", destdir)
			table.insert(cmd, replaced_arg)
		end
		-- Append passed args if any
		if passed_args then
			for _, arg in ipairs(passed_args) do
				table.insert(cmd, arg)
			end
		end

		-- Define callback for when the command finishes
		local on_exit = function(exit_code, signal, stdout_output, stderr_output)
			if exit_code == 0 then
				utils.notify("Custom generation completed successfully.", "INFO")
			else
				local detailed_msg = "Custom generation failed with exit code: " .. tostring(exit_code) .. " in directory: " .. destdir
				if stdout_output and stdout_output ~= "No output" then
					detailed_msg = detailed_msg .. "\nSTDOUT: " .. stdout_output
				end
				if stderr_output and stderr_output ~= "No errors" then
					detailed_msg = detailed_msg .. "\nSTDERR: " .. stderr_output
				end
				utils.notify(detailed_msg, "WARN")
			end
		end

		-- Run the command asynchronously
		utils.run_external_command(cmd, on_exit, destdir)
	end
end

return M
