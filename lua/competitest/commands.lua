local api = vim.api
local config = require("competitest.config")
local testcases = require("competitest.testcases")
local utils = require("competitest.utils")
local widgets = require("competitest.widgets")

-- Timeout constants (in milliseconds)
local INPUT_GENERATION_TIMEOUT = 30000 -- 30 seconds for input generation
local OUTPUT_GENERATION_TIMEOUT = 30000 -- 30 seconds for output generation
local POLL_INTERVAL = 100 -- Poll every 100ms

local M = {}

---Handle CompetiTest subcommands
---@param args string: command line arguments
function M.command(args)
	args = vim.split(args, " ", { plain = true, trimempty = true })
	if not args[1] then
		utils.notify("command: at least one argument required.")
		return
	end

	---Check if current subcommand has the correct number of arguments
	---@param min_args integer
	---@param max_args integer
	---@return boolean
	local function check_subargs(min_args, max_args)
		local count = #args - 1
		if min_args <= count and count <= max_args then
			return true
		end
		if min_args == max_args then
			utils.notify(string.format("command: %s: exactly %d sub-arguments required.", args[1], min_args))
		else
			utils.notify(string.format("command: %s: from %d to %d sub-arguments required.", args[1], min_args, max_args))
		end
		return false
	end

	local subcommands = {
		add_testcase = function()
			if check_subargs(0, 0) then
				M.edit_testcase(true)
			end
		end,
		edit_testcase = function()
			if check_subargs(0, 1) then
				M.edit_testcase(false, tonumber(args[2]))
			end
		end,
		delete_testcase = function()
			if check_subargs(0, 1) then
				M.delete_testcase(tonumber(args[2]))
			end
		end,
		convert = function()
			if check_subargs(1, 1) then
				M.convert_testcases(args[2])
			end
		end,
		run = function()
			local testcases_list = nil
			if args[2] then
				testcases_list = { unpack(args, 2) }
			end
			M.run_testcases(testcases_list, true, false)
		end,
		run_no_compile = function()
			local testcases_list = nil
			if args[2] then
				testcases_list = { unpack(args, 2) }
			end
			M.run_testcases(testcases_list, false, false)
		end,
		show_ui = function()
			if check_subargs(0, 0) then
				M.run_testcases(nil, false, true)
			end
		end,
		receive = function()
			if check_subargs(1, 1) then
				M.receive(args[2])
			end
		end,
		prepare_generation = function()
			local passed_args = nil
			if args[2] then
				passed_args = { unpack(args, 2) }
			end
			M.prepare_generation(passed_args)
		end,
		generate_input = function()
			local n = 1
			if args[2] then
				n = tonumber(args[2])
			end
			local passed_args = nil
			if args[3] then
				passed_args = { unpack(args, 3) }
			end
			M.generate_input(n, passed_args)
		end,
		generate_output = function()
			local n = 1
			if args[2] then
				n = tonumber(args[2])
			end
			local passed_args = nil
			if args[3] then
				passed_args = { unpack(args, 3) }
			end
			M.generate_output(n, passed_args)
		end,
	}

	local sub = subcommands[args[1]]
	if not sub then
		utils.notify("command: subcommand '" .. args[1] .. "' doesn't exist!")
	else
		sub()
	end
end

---Start testcase editor to add a new testcase or to edit a testcase that already exists
---@param add_testcase boolean: if true a new testcases will be added, otherwise edit a testcase that already exists
---@param tcnum integer | nil: testcase number
function M.edit_testcase(add_testcase, tcnum, bufnr_passed, input_val)
	local bufnr = api.nvim_get_current_buf()
	if bufnr_passed then
		bufnr = bufnr_passed
	end
	config.load_buffer_config(bufnr) -- reload buffer configuration since it may have been updated in the meantime
	local tctbl = testcases.buf_get_testcases(bufnr)
	if add_testcase then
		tcnum = 0
		while tctbl[tcnum] do
			tcnum = tcnum + 1
		end
		tctbl[tcnum] = { input = "", output = "" }
		if input_val then
			tctbl[tcnum].input = input_val
		end
	end

	local function start_editor(item) -- item.id is testcase number
		if not tctbl[item.id] then
			utils.notify("edit_testcase: testcase " .. tostring(item.id or tcnum) .. " doesn't exist!")
			return
		end
		tcnum = item.id

		local function save_data(tc)
			if config.get_buffer_config(bufnr).testcases_use_single_file then
				tctbl[tcnum] = tc
				testcases.single_file.buf_write(bufnr, tctbl)
			else
				testcases.io_files.buf_write_pair(bufnr, tcnum, tc.input, tc.output)
			end
		end

		widgets.editor(bufnr, tcnum, tctbl[tcnum].input, tctbl[tcnum].output, save_data, api.nvim_get_current_win())
	end

	if not tcnum then
		widgets.picker(bufnr, tctbl, "Edit a Testcase", start_editor, api.nvim_get_current_win())
	else
		start_editor({ id = tcnum })
	end
end

---Delete a testcase
---@param tcnum integer | nil: testcase number
function M.delete_testcase(tcnum)
	local bufnr = api.nvim_get_current_buf()
	config.load_buffer_config(bufnr) -- reload buffer configuration since it may have been updated in the meantime
	local tctbl = testcases.buf_get_testcases(bufnr)

	local function delete_testcase(item) -- item.id is testcase number
		if not tctbl[item.id] then
			utils.notify("delete_testcase: testcase " .. tostring(item.id or tcnum) .. " doesn't exist!")
			return
		end
		tcnum = item.id

		local choice = vim.fn.confirm("Are you sure you want to delete Testcase " .. tcnum .. "?", "Yes\nNo")
		if choice == 0 or choice == 2 then
			return
		end -- user pressed <esc> or chose "No"

		if config.get_buffer_config(bufnr).testcases_use_single_file then
			tctbl[tcnum] = nil
			testcases.single_file.buf_write(bufnr, tctbl)
		else
			testcases.io_files.buf_write_pair(bufnr, tcnum, nil, nil)
		end
	end

	if not tcnum then
		widgets.picker(bufnr, tctbl, "Delete a Testcase", delete_testcase, api.nvim_get_current_win())
	else
		delete_testcase({ id = tcnum })
	end
end

---Convert testcases from single file to multiple files and vice versa
---@param mode string: can be "singlefile_to_files", "files_to_singlefile" or "auto"
function M.convert_testcases(mode)
	local bufnr = api.nvim_get_current_buf()
	local singlefile_tctbl = testcases.single_file.buf_load(bufnr)
	local no_singlefile = next(singlefile_tctbl) == nil
	local files_tctbl = testcases.io_files.buf_load(bufnr)
	local no_files = next(files_tctbl) == nil

	local function convert_singlefile_to_files()
		if no_singlefile then
			utils.notify("convert_testcases: there's no single file containing testcases.")
			return
		end
		if not no_files then
			local choice = vim.fn.confirm("Testcases files already exist, by proceeding they will be replaced.", "Proceed\nCancel")
			if choice == 0 or choice == 2 then
				return
			end -- user pressed <esc> or chose "Cancel"
		end

		for tcnum, _ in pairs(files_tctbl) do -- delete already existing files
			testcases.io_files.buf_write_pair(bufnr, tcnum, nil, nil)
		end
		testcases.single_file.buf_write(bufnr, {}) -- delete single file
		testcases.io_files.buf_write(bufnr, singlefile_tctbl) -- create new files
	end

	local function convert_files_to_singlefile()
		if no_files then
			utils.notify("convert_testcases: there are no files containing testcases.")
			return
		end
		if not no_singlefile then
			local choice = vim.fn.confirm("Testcases single file already exists, by proceeding it will be replaced.", "Proceed\nCancel")
			if choice == 0 or choice == 2 then
				return
			end -- user pressed <esc> or chose "Cancel"
		end

		for tcnum, _ in pairs(files_tctbl) do -- delete already existing files
			testcases.io_files.buf_write_pair(bufnr, tcnum, nil, nil)
		end
		testcases.single_file.buf_write(bufnr, files_tctbl) -- create new single file
	end

	if mode == "singlefile_to_files" then
		convert_singlefile_to_files()
	elseif mode == "files_to_singlefile" then
		convert_files_to_singlefile()
	elseif mode == "auto" then
		if no_singlefile and no_files then
			utils.notify("convert_testcases: there's nothing to convert.")
		elseif not no_singlefile and not no_files then
			utils.notify("convert_testcases: single file and testcases files exist, please specifify what's to be converted.")
		elseif no_singlefile then
			convert_files_to_singlefile()
		else
			convert_singlefile_to_files()
		end
	else
		utils.notify("convert_testcases: unrecognized mode '" .. tostring(mode) .. "'.")
	end
end

function M.add_testcase_from_input(bufnr, input, output)
	config.load_buffer_config(bufnr) -- reload buffer configuration since it may have been updated in the meantime
	local tctbl = testcases.buf_get_testcases(bufnr)

	local tcnum = 0
	while tctbl[tcnum] do
		tcnum = tcnum + 1
	end

	tctbl[tcnum] = { input = input, output = output or "" }

	testcases.buf_write_testcases(bufnr, tctbl, config.get_buffer_config(bufnr).testcases_use_single_file)
	utils.notify("Added new testcase " .. tcnum, "INFO")
end

M.runners = {} -- runners associated with a buffer
M.generators = {} -- generator runners associated with a buffer
M.correct_runners = {}

---Unload a runner (called on BufUnload)
function M.remove_runner(bufnr)
	M.runners[bufnr] = nil
	M.generators[bufnr] = nil
	M.correct_runners[bufnr] = nil
end

---Start testcases runner
---@param testcases_list table | nil: list with integers representing testcases to run, or nil to run all the testcases
---@param compile boolean: whether to compile or not
---@param only_show boolean: if true show previously closed CompetiTest windows without executing testcases
function M.run_testcases(testcases_list, compile, only_show)
	local bufnr = api.nvim_get_current_buf()
	config.load_buffer_config(bufnr)
	local tctbl = testcases.buf_get_testcases(bufnr)

	if testcases_list then
		local new_tctbl = {}
		for _, tcnum in ipairs(testcases_list) do
			local num = tonumber(tcnum)
			if not num or not tctbl[num] then -- invalid testcase
				utils.notify("run_testcases: testcase " .. tcnum .. " doesn't exist!")
			else
				new_tctbl[num] = tctbl[num]
			end
		end
		tctbl = new_tctbl
	end

	if not M.runners[bufnr] then -- no runner is associated to buffer
		M.runners[bufnr] = require("competitest.runner"):new(api.nvim_get_current_buf())
		if not M.runners[bufnr] then -- an error occurred
			return
		end
		-- remove runner data when buffer is unloaded
		api.nvim_command("autocmd BufUnload <buffer=" .. bufnr .. "> lua require('competitest.commands').remove_runner(vim.fn.expand('<abuf>'))")
	end
	local r = M.runners[bufnr] -- current runner
	if not only_show then
		r:kill_all_processes()
		r:run_testcases(tctbl, compile)
	end
	r:set_restore_winid(api.nvim_get_current_win())
	r:show_ui()
end

local function get_runner(runner_table, bufnr, ...)
	if not runner_table[bufnr] then -- no runner is associated to buffer
		runner_table[bufnr] = require("competitest.runner"):new(bufnr, ...)
		if not runner_table[bufnr] then -- an error occurred
			return nil
		end
		-- remove runner data when buffer is unloaded
		api.nvim_command("autocmd BufUnload <buffer=" .. bufnr .. "> lua require('competitest.commands').remove_runner(vim.fn.expand('<abuf>'))")
	end
	return runner_table[bufnr]
end

local function get_path_in_buf_dir(bufnr, filename)
	return api.nvim_buf_call(bufnr, function()
		return vim.fn.expand("%:p:h")
	end) .. "/" .. filename
end

---Shared function for generating inputs with a generator program
---@param n number: number of test cases to generate
---@param command_line_args table | nil: command line arguments for the generator
---@param genfilename string: path to the generator file
---@param bufnr number: buffer number
---@param on_success function: callback function to execute when generation is successful
---@param timeout number: timeout value in milliseconds
function M.generate_with_runner(n, command_line_args, genfilename, bufnr, on_success, timeout)
	local r = get_runner(M.generators, bufnr, genfilename, command_line_args)
	if not r then
		return
	end

	utils.notify("Generating inputs...", "TRACE")
	r:kill_all_processes()
	r:run_testcases({}, true, n)

	-- Use a non-blocking polling approach with timeout and early termination
	local start_time = vim.loop.now()

	local function poll_generation()
		local all_done = true
		local has_errors = false
		local occ = {}

		-- First, check compilation status (always tcdata[1])
		local comp_tc = r.tcdata[1]
		if comp_tc then
			local comp_status = comp_tc.status
			-- Check for early termination: if compilation failed, stop immediately
			if comp_status ~= "DONE" and comp_status ~= "" and comp_status ~= "RUNNING" then
				utils.notify("Compilation failed: " .. comp_status, "WARN")
				r:set_restore_winid(api.nvim_get_current_win())
				r:show_ui()
				return
			end
			-- If compilation is still running, not all done yet
			if comp_status == "RUNNING" or comp_status == "" then
				all_done = false
			end
		else
			-- Compilation data missing, treat as error
			utils.notify("Compilation data missing", "WARN")
			r:set_restore_winid(api.nvim_get_current_win())
			r:show_ui()
			return
		end

		-- Then check generated test cases (tcdata[2] to tcdata[n+1])
		for i = 1, n do
			local tc = r.tcdata[i + 1]
			if not tc then
				-- If test case data is missing, treat as failure
				has_errors = true
				occ["FAILED"] = (occ["FAILED"] or 0) + 1
			else
				local status = tc.status
				-- For test cases, check if finished but not in successful state
				if
					status ~= "DONE"
					and status ~= "TIMEOUT"
					and status ~= "FAILED"
					and status ~= "KILLED"
					and not string.find(status, "RET ")
					and not string.find(status, "SIG ")
					and status ~= ""
					and status ~= "RUNNING"
				then
					has_errors = true
				end

				-- Check if the test case is still running or not yet started
				if status ~= "" and status ~= "RUNNING" then -- Test case is finished
					-- If it's not DONE, count as error for generator
					if status ~= "DONE" then
						has_errors = true
					end
					occ[status] = (occ[status] or 0) + 1
				else
					all_done = false
				end
			end
		end

		local elapsed = vim.loop.now() - start_time
		if all_done or elapsed > timeout or has_errors then
			-- Generation completed or timed out
			utils.notify("Done generating inputs! Generated " .. (occ["DONE"] or 0) .. " cases.", "TRACE")

			if (occ["DONE"] or 0) ~= n then
				r:set_restore_winid(api.nvim_get_current_win())
				r:show_ui()

				-- Notify user about failures if any
				local failed_count = n - (occ["DONE"] or 0)
				utils.notify("Warning: " .. failed_count .. " out of " .. n .. " test case(s) failed to generate.", "WARN")
				return
			end

			-- Execute the success callback
			on_success(r, n)

		else
			-- Schedule next poll
			vim.schedule(function()
				vim.defer_fn(poll_generation, POLL_INTERVAL)
			end)
		end
	end

	-- Start the polling
	poll_generation()
end

function M.prepare_generation(passed_args)
	local generation = require("competitest.generate")
	generation.prepare_generation(passed_args)
end

function M.generate_output(n, command_line_args)
	local bufnr = api.nvim_get_current_buf()
	local genfilename = get_path_in_buf_dir(bufnr, "gen.cpp")
	local naivefilename = get_path_in_buf_dir(bufnr, "b.cpp")

	-- Define the success callback for output generation
	local function on_output_success(r, n)
		-- Continue to generate outputs using the correct runner
		local c = get_runner(M.correct_runners, bufnr, naivefilename)
		if not c then
			utils.notify("NO Correct runner...", "WARN")
			return
		end

		-- Process the generated inputs to prepare for output generation
		local new_tbl = {}
		for idx, value in ipairs(r.tcdata) do
			if type(value.tcnum) == "number" then
				new_tbl[idx - 1] = value
				new_tbl[idx - 1].input = table.concat(new_tbl[idx - 1].stdout, "\n")
				new_tbl[idx - 1].output = nil
			end
		end

		M.generators[bufnr] = nil

		utils.notify("Generating outputs...", "TRACE")
		c:kill_all_processes()
		-- Run the naive solution on the generated inputs to produce expected outputs
		c:run_testcases(new_tbl, true)

		-- Poll for compilation and output generation
		local output_start_time = vim.loop.now()

		local function poll_output_generation()
			-- First check compilation status of naive solution (always tcdata[1])
			local comp_tc = c.tcdata[1]
			if comp_tc then
				local comp_status = comp_tc.status
				-- Check for early termination: if compilation failed, stop immediately
				if comp_status ~= "DONE" and comp_status ~= "" and comp_status ~= "RUNNING" then
					utils.notify("Naive solution compilation failed: " .. comp_status, "WARN")
					c:set_restore_winid(api.nvim_get_current_win())
					c:show_ui()
					return
				end
			else
				-- Compilation data missing, treat as error
				utils.notify("Naive solution compilation data missing", "WARN")
				c:set_restore_winid(api.nvim_get_current_win())
				c:show_ui()
				return
			end

			-- Check status of output generation
			local all_outputs_done = true
			local output_occ = {}
			local has_errors = false

			for i = 1, n do
				if i + 1 <= #c.tcdata then
					local tc = c.tcdata[i + 1]
					if not tc then
						-- Test case data missing
						has_errors = true
						output_occ["FAILED"] = (output_occ["FAILED"] or 0) + 1
					else
						local status = tc.status
						-- For output generation, check if finished but not in successful state
						if
							status ~= "DONE"
							and status ~= "TIMEOUT"
							and status ~= "FAILED"
							and status ~= "KILLED"
							and not string.find(status, "RET ")
							and not string.find(status, "SIG ")
							and status ~= ""
							and status ~= "RUNNING"
						then
							has_errors = true
						end

						if tc.running == true or status == "RUNNING" or status == "" then
							all_outputs_done = false
						else
							-- If it's not DONE, count as error for generator
							if status ~= "DONE" then
								has_errors = true
							end
							output_occ[status] = (output_occ[status] or 0) + 1
						end
					end
				end
			end

			local output_elapsed = vim.loop.now() - output_start_time
			if all_outputs_done or output_elapsed > OUTPUT_GENERATION_TIMEOUT or has_errors then
				utils.notify("Done generating outputs! Successful testcases: " .. (output_occ["DONE"] or 0), "TRACE")

				if (output_occ["DONE"] or 0) ~= n then
					c:set_restore_winid(api.nvim_get_current_win())
					c:show_ui()

					-- Notify user about failures if any
					local failed_count = n - (output_occ["DONE"] or 0)
					utils.notify("Warning: " .. failed_count .. " out of " .. n .. " output(s) failed to generate.", "WARN")
					return
				end

				-- Process the generated testcases (inputs with expected outputs)
				local generated_testcases = {}
				for idx, value in ipairs(c.tcdata) do
					if type(value.tcnum) == "number" then
						generated_testcases[idx - 1] = value
						generated_testcases[idx - 1].input = table.concat(generated_testcases[idx - 1].stdin, "\n")
						generated_testcases[idx - 1].output = table.concat(generated_testcases[idx - 1].stdout, "\n")
					end
				end

				local my_runner = get_runner(M.runners, bufnr)
				if not my_runner then
					return
				end
				my_runner:kill_all_processes()
				-- Run the actual solution against the generated testcases (with expected outputs)
				my_runner:run_testcases(generated_testcases, true)
				my_runner:set_restore_winid(api.nvim_get_current_win())
				my_runner:show_ui()
			else
				-- Schedule next poll for output generation
				vim.schedule(function()
					vim.defer_fn(poll_output_generation, POLL_INTERVAL)
				end)
			end
		end

		-- Start polling for output generation
		poll_output_generation()
	end

	-- Use the shared function to generate inputs (the first part of the process)
	M.generate_with_runner(n, command_line_args, genfilename, bufnr, on_output_success, INPUT_GENERATION_TIMEOUT)
end

function M.generate_input(n, command_line_args)
	local bufnr = api.nvim_get_current_buf()
	local genfilename = get_path_in_buf_dir(bufnr, "gen.cpp")

	-- Define the success callback for input generation
	local function on_input_success(r, n)
		-- Process the generated testcases
		local generated_testcases = {}
		for i = 1, n do
			generated_testcases["TC " .. i] = {
				input = table.concat(r.tcdata[i + 1].stdout, "\n"),
				output = nil,
			}
		end

		M.generators[bufnr] = nil

		local my_runner = get_runner(M.runners, bufnr)
		if not my_runner then
			return
		end
		my_runner:kill_all_processes()
		my_runner:run_testcases(generated_testcases, true)
		my_runner:set_restore_winid(api.nvim_get_current_win())
		my_runner:show_ui()
	end

	-- Use the shared function to generate inputs
	M.generate_with_runner(n, command_line_args, genfilename, bufnr, on_input_success, INPUT_GENERATION_TIMEOUT)
end

---Receive testcases, problems or contests from Competitive Companion
---@param mode string: can be "testcases", "problem" or "contest"
function M.receive(mode)
	local receive = require("competitest.receive")

	---Get path for received problems or contests
	---@param path string | function: see received_problems_path, received_contests_directory and received_contests_problems_path
	---@param task table: table with received task data
	---@param file_extension string
	---@return string
	local function eval_path(path, task, file_extension)
		local init_dir
		if type(path) == "string" then
			init_dir = receive.storage_utils.eval_path(path, task, file_extension)
		elseif type(path) == "function" then
			init_dir = path(task, file_extension)
		end
		return init_dir or ""
	end

	if mode == "stop" then
		receive.stop_receiving()
	elseif mode == "status" then
		receive.show_status()
	elseif mode == "testcases" then
		local bufnr = api.nvim_get_current_buf()
		config.load_buffer_config(bufnr)
		local bufcfg = config.get_buffer_config(bufnr)
		local notify = bufcfg.receive_print_message
		local error = receive.start_receiving("testcases", bufcfg.companion_port, notify, notify, bufnr, bufcfg)
		if error then
			utils.notify("receive: " .. error .. ".")
		end
	elseif mode == "problem" or mode == "contest" or mode == "persistently" then
		local cfg = config.load_local_config_and_extend(vim.fn.getcwd())
		local notify = cfg.receive_print_message
		local error = receive.start_receiving(mode, cfg.companion_port, notify, notify, nil, cfg)
		if error then
			utils.notify("receive: " .. error .. ".")
		end
	else
		utils.notify("receive: unrecognized mode '" .. tostring(mode) .. "'.")
	end
end

return M
