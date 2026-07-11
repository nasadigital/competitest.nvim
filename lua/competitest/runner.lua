local api = vim.api
local luv = vim.loop
local config = require("competitest.config")
local utils = require("competitest.utils")
local ui = require("competitest.runner_ui")

local TCRunner = {}
TCRunner.__index = TCRunner

---Create a new Testcase Runner
---@param bufnr integer: buffer number that specify the buffer to associate the runner with
---@return object: a new TCRunner object, or nil on failure
function TCRunner:new(bufnr, given_filename, given_args)
	if not given_args then
		given_args = {}
	end
	local filetype = api.nvim_buf_get_option(bufnr, "filetype")
	local filedir = api.nvim_buf_call(bufnr, function()
		return vim.fn.expand("%:p:h")
	end) .. "/"

	local function eval_command(command)
		if command == nil then
			return nil
		end
		local exec = utils.buf_eval_string(bufnr, command.exec, nil, given_filename)
		local args = {}
		for index, arg in ipairs(command.args or given_args) do
			args[index] = utils.buf_eval_string(bufnr, arg, nil, given_filename)
		end
		return { exec = exec, args = args }
	end

	local buf_cfg = config.get_buffer_config(bufnr)
	local this = {
		config = buf_cfg,
		bufnr = bufnr,
		cc = eval_command(buf_cfg.compile_command[filetype]), -- compile command
		rc = eval_command(buf_cfg.run_command[filetype]), -- run command
		compile_directory = filedir .. buf_cfg.compile_directory .. "/",
		running_directory = filedir .. buf_cfg.running_directory .. "/",
		testcase_directory = filedir .. buf_cfg.testcases_directory .. "/",
	}
	if this.rc == nil then
		utils.notify("TCRunner:new: run command for filetype '" .. filetype .. "' isn't configured properly.\nCannot proceed.")
		return nil
	end

	setmetatable(this, self)

	-- Auto-detect checker: look for checker.<filetype> in problem directory
	-- Only for the main solution runner (not generators or correct runners)
	if not given_filename then
	local checker_source = filedir .. "checker." .. filetype
	this.checker_bin = this.running_directory .. "checker"
	if utils.does_file_exist(checker_source) then
		local checker_cfg = buf_cfg.compile_command[filetype]
		if checker_cfg then
			this.has_checker_source = true
			local checker_exec = utils.buf_eval_string(bufnr, checker_cfg.exec, nil, checker_source)
			local checker_args = {}
			for i, arg in ipairs(checker_cfg.args or {}) do
				checker_args[i] = utils.buf_eval_string(bufnr, arg, nil, checker_source)
			end
			this.checker_cc = { exec = checker_exec, args = checker_args }
		end
	end
	end

	return this
end

---Run the testcases specified in self.tcdata
---@param tctbl table | nil: table associating testcase numbers to file names
---@param compile boolean | nil: whether to compile or not
function TCRunner:run_testcases(tctbl, compile, generated_testcases)
	if tctbl then -- if tctbl isn't specified use the testcases that were previously loaded
		if self.config.save_all_files then
			api.nvim_command("wa")
		elseif self.config.save_current_file then
			api.nvim_buf_call(self.bufnr, function()
				api.nvim_command("w")
			end)
		end

		self.tcdata = {} -- table containing data about testcases and results
		if compile == nil then -- if not specified compile
			compile = true
		end
		self.compile = compile and self.cc ~= nil
		if self.compile then -- if compilation is needed we add it as a testcase
			table.insert(self.tcdata, { stdin = {}, expout = nil, tcnum = "Comp" })
		end

		if generated_testcases then
			for i = 1, generated_testcases do
				table.insert(self.tcdata, { stdin = {}, expout = nil, tcnum = i })
			end
		end

		for tcnum, tc in pairs(tctbl) do
			table.insert(self.tcdata, {
				stdin = vim.split(tc.input, "\n", { plain = true }),
				-- expout = expected output, can be table or nil
				expout = tc.output and vim.split(tc.output, "\n", { plain = true }),
				tcnum = tcnum,
				timelimit = self.config.maximum_time,
			})
		end
	end

	-- reset running data
	for _, tc in pairs(self.tcdata) do
		tc.status = ""
		tc.hlgroup = "CompetiTestRunning"
		tc.stdout = nil
		tc.stderr = nil
		tc.running = false
		tc.killed = false
		tc.time = nil
	end

	local tc_size = #self.tcdata -- how many testcases
	local mut = self.config.multiple_testing -- multiple testing, how many testcases to run at the same time
	if mut == -1 then -- -1 -> make the most of the amount of available parallelism
		if luv.available_parallelism then
			mut = luv.available_parallelism()
		else -- vim.loop.available_parallelism() isn't available in Neovim < 0.7.2
			local cpu_info = luv.cpu_info()
			mut = cpu_info and #cpu_info or 1
		end
	elseif mut == 0 then -- 0 -> run all testcases together
		mut = tc_size
	end
	mut = math.min(tc_size, mut)
	local next_tc = 1

	function self.run_next_tc(tcnum)
		if tcnum then
			if tcnum == 1 and self.compile then
				self:execute_testcase(tcnum, self.cc.exec, self.cc.args, self.compile_directory)
			else
				local new_args = { unpack(self.rc.args) }
				new_args[#new_args + 1] = tostring(tcnum)
				self:execute_testcase(tcnum, self.rc.exec, new_args, self.running_directory)
			end
			return
		end
		if next_tc > tc_size then
			return
		end
		next_tc = next_tc + 1
		local new_args = { unpack(self.rc.args) }
		new_args[#new_args + 1] = tostring(next_tc - 1)
		self:execute_testcase(next_tc - 1, self.rc.exec, new_args, self.running_directory, self.run_next_tc)
	end

	local function run_first_testcases()
		local starting_tc = next_tc
		next_tc = next_tc + mut
		for tcnum = starting_tc, math.min(tc_size, starting_tc + mut - 1) do
			local new_args = { unpack(self.rc.args) }
			new_args[#new_args + 1] = tostring(tcnum)
			self:execute_testcase(tcnum, self.rc.exec, new_args, self.running_directory, self.run_next_tc)
		end
	end

	if not self.compile then
		run_first_testcases()
	else
		next_tc = 2
		local function run_tests_after_compile()
			run_first_testcases()
		end

		local function checker_compile_callback()
			if self.tcdata[1].exit_code ~= 0 then
				utils.notify("Checker compilation failed, falling back to string comparison.", "WARN")
			end
			run_tests_after_compile()
		end

		local function compilation_callback()
			if self.tcdata[1].exit_code ~= 0 then
				return
			end
			if self.checker_cc then
				-- Compile checker after solution
				self.tcdata[1].status = ""
				self.tcdata[1].hlgroup = "CompetiTestRunning"
				self:execute_testcase(1, self.checker_cc.exec, self.checker_cc.args,
					self.compile_directory, checker_compile_callback)
			else
				run_tests_after_compile()
			end
		end

		self:execute_testcase(1, self.cc.exec, self.cc.args, self.compile_directory, compilation_callback)
	end
end

---Start a testcase process with given parameters
---@param tcindex integer: testcase index, refer to self.tcdata
---@param exec string: name of executable
---@param args table: array of its arguments
---@param dir string: current working directory
---@param callback function | nil: callback function
function TCRunner:execute_testcase(tcindex, exec, args, dir, callback)
	local process = {
		exec = exec,
		args = args,
		stdin = luv.new_pipe(false),
		stdout = luv.new_pipe(false),
		stderr = luv.new_pipe(false),
	}
	local tc = self.tcdata[tcindex]

	-- utils.create_directory(dir)
	process.handle, process.pid = luv.spawn(process.exec, {
		args = process.args,
		cwd = dir,
		stdio = { process.stdin, process.stdout, process.stderr },
	}, function(code, signal)
		tc.running = false
		tc.time = luv.now() - tc.process.starting_time
		tc.exit_code = code
		tc.exit_signal = signal

		-- determine process status to display
		if tc.killed then
			if tc.timelimit and tc.time >= tc.timelimit then
				tc.status = "TIMEOUT"
				tc.hlgroup = "CompetiTestWrong"
			else
				tc.status = "KILLED"
				tc.hlgroup = "CompetiTestWarning"
			end
		else
			if tc.exit_signal ~= 0 then
				tc.status = "SIG " .. tc.exit_signal
				tc.hlgroup = "CompetiTestWarning"
			elseif tc.exit_code ~= 0 then
				tc.status = "RET " .. tc.exit_code
				tc.hlgroup = "CompetiTestWarning"
			end -- correct/wrong/done status is computed when stdout is closed
		end

		tc.process.stdin:close()
		tc.process.handle:close()
		if tc.timer and not tc.timer:is_closing() then
			tc.timer:stop()
			tc.timer:close()
		end

		self:update_ui(true)
		if callback then
			callback()
		end
	end)
	if not process.handle then
		-- utils.notify("TCRunner:execute_testcase: failed to spawn process using '" .. process.exec .. "' (" .. process.pid .. ").")
		tc.status = "FAILED"
		tc.hlgroup = "CompetiTestWarning"
		tc.time = -1
		self:update_ui(true)
		return
	end

	---Update array of lines with data received from stdout or stderr
	---@param lines table
	---@param received string
	local function add_stream_lines(lines, received)
		local received_lines = vim.split(string.gsub(received, "\r\n", "\n"), "\n", { plain = true })
		local n = #lines
		for _, line in ipairs(received_lines) do
			lines[n] = (lines[n] or "") .. line
			n = n + 1
		end
	end

	luv.write(process.stdin, table.concat(tc.stdin, "\n"))
	luv.shutdown(process.stdin)
	tc.stdout = { "" }
	luv.read_start(process.stdout, function(err, data)
		if err or not data then
			tc.process.stdout:read_stop()
			tc.process.stdout:close()
			if not tc.running and tc.status ~= "RUNNING" then
				return
			end
			-- Try custom checker if binary exists (skip for compilation testcase)
			if tc.tcnum ~= "Comp" and self.checker_bin and utils.does_file_exist(self.checker_bin) then
				self:run_checker(tc, function(verdict)
					tc.status = verdict
					tc.hlgroup = verdict == "CORRECT" and "CompetiTestCorrect" or "CompetiTestWrong"
					self:update_ui(true)
				end)
				return
			end

			local correct = require("competitest.compare").compare_output(
				table.concat(tc.stdout, "\n"),
				tc.expout and table.concat(tc.expout, "\n"),
				self.config.output_compare_method
			)
			if correct == true then
				tc.status = "CORRECT"
				tc.hlgroup = "CompetiTestCorrect"
			elseif correct == false then
				tc.status = "WRONG"
				tc.hlgroup = "CompetiTestWrong"
			else
				tc.status = "DONE"
				tc.hlgroup = "CompetiTestDone"
			end
			self:update_ui(true)
		else
			add_stream_lines(tc.stdout, data)
			self:update_ui()
		end
	end)
	tc.stderr = { "" }
	luv.read_start(process.stderr, function(err, data)
		if err or not data then
			tc.process.stderr:read_stop()
			tc.process.stderr:close()
			return
		end
		add_stream_lines(tc.stderr, data)
		self:update_ui()
	end)

	if tc.timelimit then
		tc.timer = luv.new_timer()
		tc.timer:start(tc.timelimit, 0, function()
			tc.timer:stop()
			tc.timer:close()
			self:kill_process(tcindex)
		end)
	end

	-- set running data
	tc.time = nil
	process.starting_time = luv.now()
	tc.process = process
	tc.status = "RUNNING"
	tc.hlgroup = "CompetiTestRunning"
	tc.running = true
	tc.killed = false
	self:update_ui(true)
end

---Run the custom checker to evaluate a testcase
---@param tc table: testcase data table (stdin, stdout, expout)
---@param callback function: called with verdict string ("CORRECT" or "WRONG")
function TCRunner:run_checker(tc, callback)
	local tmpdir = "/tmp/competitest_checker"
	os.execute("mkdir -p " .. tmpdir)

	-- Unique tag per testcase within this runner
	local tag = tostring(self.bufnr) .. "_" .. tostring(tc.tcnum)
	local input_file = tmpdir .. "/in_" .. tag .. ".txt"
	local output_file = tmpdir .. "/out_" .. tag .. ".txt"
	local answer_file = tmpdir .. "/ans_" .. tag .. ".txt"

	local function write_file(path, content)
		local f = io.open(path, "w")
		if f then
			f:write(content)
			f:close()
		end
	end

	write_file(input_file, table.concat(tc.stdin, "\n"))
	write_file(output_file, table.concat(tc.stdout, "\n"))

	local checker_args = { input_file, output_file }
	if tc.expout then
		write_file(answer_file, table.concat(tc.expout, "\n"))
		table.insert(checker_args, answer_file)
	end

	local stdin_pipe = luv.new_pipe(false)
	local stdout_pipe = luv.new_pipe(false)
	local stderr_pipe = luv.new_pipe(false)

	local checker_timeout = 5000
	local checker_timer = luv.new_timer()
	local checker_handle = nil
	local checker_pid = nil
	local exit_code = 0

	local function cleanup_temp_files()
		os.remove(input_file)
		os.remove(output_file)
		if tc.expout then
			os.remove(answer_file)
		end
	end

	checker_timer:start(checker_timeout, 0, function()
		if checker_pid then
			luv.process_kill(checker_pid, "sigkill")
		end
		-- Force-close pipes so read_start close callbacks fire
		if not stdout_pipe:is_closing() then
			stdout_pipe:close()
		end
		if not stderr_pipe:is_closing() then
			stderr_pipe:close()
		end
		checker_timer:stop()
		checker_timer:close()
	end)

	local checker_stdout = { "" }
	local checker_stderr = { "" }
	local stdout_closed = false
	local stderr_closed = false

	local function on_both_pipes_closed()
		-- Stop timer and close handles
		if checker_timer and not checker_timer:is_closing() then
			checker_timer:stop()
			checker_timer:close()
		end
		if checker_handle and not checker_handle:is_closing() then
			checker_handle:close()
		end
		if not stdin_pipe:is_closing() then
			stdin_pipe:close()
		end

		-- Append checker diagnostics to tc.stderr
		tc.stderr[#tc.stderr + 1] = ""
		tc.stderr[#tc.stderr + 1] = "[checker stdout]"
		for _, line in ipairs(checker_stdout) do
			tc.stderr[#tc.stderr + 1] = line
		end
		tc.stderr[#tc.stderr + 1] = ""
		tc.stderr[#tc.stderr + 1] = "[checker stderr]"
		for _, line in ipairs(checker_stderr) do
			tc.stderr[#tc.stderr + 1] = line
		end
		self:update_ui(true)

		cleanup_temp_files()
		callback(exit_code == 0 and "CORRECT" or "WRONG")
	end

	checker_handle, checker_pid = luv.spawn(self.checker_bin, {
		args = checker_args,
		cwd = self.running_directory,
		stdio = { stdin_pipe, stdout_pipe, stderr_pipe },
	}, function(code, signal)
		exit_code = code or 0
		if signal ~= 0 then
			exit_code = 1
		end
	end)

	if not checker_handle then
		cleanup_temp_files()
		callback("WRONG")
		return
	end

	-- Close stdin immediately (checker reads from files, not stdin)
	stdin_pipe:close()

	luv.read_start(stdout_pipe, function(err, data)
		if err or not data then
			if not stdout_pipe:is_closing() then
				stdout_pipe:read_stop()
				stdout_pipe:close()
			end
			stdout_closed = true
			if stderr_closed then
				on_both_pipes_closed()
			end
		else
			local received_lines = vim.split(string.gsub(data, "\r\n", "\n"), "\n", { plain = true })
			local n = #checker_stdout
			for _, line in ipairs(received_lines) do
				checker_stdout[n] = (checker_stdout[n] or "") .. line
				n = n + 1
			end
		end
	end)

	luv.read_start(stderr_pipe, function(err, data)
		if err or not data then
			if not stderr_pipe:is_closing() then
				stderr_pipe:read_stop()
				stderr_pipe:close()
			end
			stderr_closed = true
			if stdout_closed then
				on_both_pipes_closed()
			end
		else
			local received_lines = vim.split(string.gsub(data, "\r\n", "\n"), "\n", { plain = true })
			local n = #checker_stderr
			for _, line in ipairs(received_lines) do
				checker_stderr[n] = (checker_stderr[n] or "") .. line
				n = n + 1
			end
		end
	end)
end

---Kill the process associated with a testcase
---@param tcindex integer: testcase index
function TCRunner:kill_process(tcindex)
	local tc = self.tcdata[tcindex]
	if tc.running ~= true then
		return
	end

	tc.process.stdout:read_stop()
	tc.process.stdout:close()
	tc.process.stderr:read_stop()
	tc.process.stderr:close()
	tc.process.handle:kill("sigkill")
	tc.killed = true
end

---Kill all the running processes associated with testcases
function TCRunner:kill_all_processes()
	if self.tcdata then
		for tcindex, _ in pairs(self.tcdata) do
			self:kill_process(tcindex)
		end
	end
end

---Show Runner UI
function TCRunner:show_ui()
	if not self.tcdata then -- nothing to show
		return
	end
	if not self.ui then
		self.ui = ui:new(self)
	end
	self.ui:show_ui()
	self.ui:update_ui()
end

---Set or update restore_winid
---@param winid integer: bring the cursor to the given window after runner is closed
function TCRunner:set_restore_winid(winid)
	self.restore_winid = winid
	if self.ui then
		self.ui.restore_winid = winid
	end
end

---Update Runner UI content
---@param update_windows boolean | nil: whether to update all the windows or only details windows
function TCRunner:update_ui(update_windows)
	if self.ui then
		if update_windows then -- avoid direct assignment to satisfy unprocessed previous update_windows requests
			self.ui.update_windows = true
		end
		self.ui.update_details = true
		self.ui:update_ui()
	end
end

function TCRunner:resize_ui()
	if self.ui then
		self.ui:resize_ui()
	end
end

function TCRunner:add_testcase(idx)
	local testcases = require("competitest.testcases")
	local tctbl = testcases.buf_get_testcases(self.bufnr)
	local tcnum = 0
	while tctbl[tcnum] do
		tcnum = tcnum + 1
	end
	testcases.io_files.buf_write_pair(self.bufnr, tcnum, table.concat(self.tcdata[idx].stdin, "\n"), table.concat(self.tcdata[idx].expout, "\n"))
	utils.notify("Added testcase " .. (idx - 1), "TRACE")
end

return TCRunner
