local M = {}

-- Default highlight colors (only used if not already defined)
local default_highlights = {
	OilGitAdded = { fg = "#a6e3a1" },
	OilGitModified = { fg = "#f9e2af" },
	OilGitRenamed = { fg = "#cba6f7" },
	OilGitUntracked = { fg = "#89b4fa" },
	OilGitIgnored = { fg = "#6c7086" },
}

-- Cache for git status results
local cache = {}
local active_jobs = {}
local debounce_timer = nil
-- Git repository timer management
local git_repo_timers = {} -- [git_root] = { timer, buffer_count }
local active_oil_buffers = {} -- [bufnr] = git_root

-- Configuration
local config = {
	debounce_ms = 500,
	max_cache_age = 30000, -- 30 seconds
	git_refresh_interval = 2000, -- 2 seconds
}

local function setup_highlights()
	-- Only set highlight if it doesn't already exist (respects colorscheme)
	for name, opts in pairs(default_highlights) do
		if vim.fn.hlexists(name) == 0 then
			vim.api.nvim_set_hl(0, name, opts)
		end
	end
end

local function get_git_root(path)
	local git_dir = vim.fn.finddir(".git", path .. ";")
	if git_dir == "" then
		return nil
	end
	-- Get the parent directory of .git, not .git itself
	return vim.fn.fnamemodify(git_dir, ":p:h:h")
end

local function parse_git_output(output, git_root)
	local status = {}
	for line in output:gmatch("[^\r\n]+") do
		if #line >= 3 then
			local status_code = line:sub(1, 2)
			local filepath = line:sub(4)

			-- Handle renames (format: "old-name -> new-name")
			if status_code:sub(1, 1) == "R" then
				local arrow_pos = filepath:find(" %-> ")
				if arrow_pos then
					filepath = filepath:sub(arrow_pos + 4)
				end
			end

			-- Remove leading "./" if present
			if filepath:sub(1, 2) == "./" then
				filepath = filepath:sub(3)
			end

			-- Convert to absolute path
			local abs_path = git_root .. "/" .. filepath

			status[abs_path] = status_code
		end
	end
	return status
end

local function get_cache_key(git_root)
	-- Get git HEAD hash for cache invalidation
	local head_file = git_root .. "/.git/HEAD"
	local head_stat = vim.uv.fs_stat(head_file)
	if not head_stat then
		return nil
	end

	local head_content = ""
	local fd = vim.uv.fs_open(head_file, "r", 438)
	if fd then
		local data = vim.uv.fs_read(fd, 1000, 0)
		if data then
			head_content = data
		end
		vim.uv.fs_close(fd)
	end

	return git_root .. ":" .. head_content .. ":" .. head_stat.mtime.sec
end

local function is_cache_valid(git_root)
	local cache_key = get_cache_key(git_root)
	if not cache_key then
		return false
	end

	local cached = cache[git_root]
	if not cached then
		return false
	end

	-- Check if cache key matches (git state unchanged)
	if cached.key ~= cache_key then
		return false
	end

	-- Check if cache is not too old
	local age = vim.uv.hrtime() / 1000000 - cached.timestamp
	return age < config.max_cache_age
end

local function get_git_status_async(dir, callback)
	local git_root = get_git_root(dir)
	if not git_root then
		callback({})
		return
	end

	-- Check cache first
	if is_cache_valid(git_root) then
		local cached = cache[git_root]
		callback(cached.data)
		return
	end

	-- Prevent multiple concurrent jobs for same repo
	if active_jobs[git_root] then
		return
	end

	active_jobs[git_root] = true

	-- Use vim.system for async execution
	vim.system({ "git", "status", "--porcelain", "--ignored" }, { cwd = git_root, text = true }, function(result)
		active_jobs[git_root] = nil

		if result.code ~= 0 then
			callback({})
			return
		end

		local raw_output = result.stdout or ""
		local status = parse_git_output(raw_output, git_root)

		-- Update cache
		local cache_key = get_cache_key(git_root)
		if cache_key then
			cache[git_root] = {
				key = cache_key,
				data = status,
				raw_output = raw_output,
				timestamp = vim.uv.hrtime() / 1000000,
			}
		end

		callback(status)
	end)
end

-- Git repository timer management functions
local function start_repo_timer(git_root)
	if git_repo_timers[git_root] then
		return -- Timer already exists
	end

	local timer = vim.uv.new_timer()
	if timer then
		timer:start(config.git_refresh_interval, config.git_refresh_interval, function()
			vim.schedule(function()
				-- Update git status cache for this repository
				-- Use git_root as the directory (get_git_status_async will find the git root again)
				get_git_status_async(git_root, function()
					-- Cache is updated inside get_git_status_async
					-- No need to trigger highlight re-application here
				end)
			end)
		end)
		git_repo_timers[git_root] = { timer = timer, buffer_count = 0 }
	end
end

local function stop_repo_timer(git_root)
	local repo_data = git_repo_timers[git_root]
	if repo_data and repo_data.timer then
		if not repo_data.timer:is_closing() then
			repo_data.timer:stop()
			repo_data.timer:close()
		end
		git_repo_timers[git_root] = nil
	end
end

local function register_oil_buffer(bufnr, git_root)
	if not git_root then
		return
	end

	-- Start timer if this is the first buffer for this repo
	if not git_repo_timers[git_root] then
		start_repo_timer(git_root)
	end

	-- Increment buffer count and track buffer
	local repo_data = git_repo_timers[git_root]
	if repo_data then
		repo_data.buffer_count = repo_data.buffer_count + 1
		active_oil_buffers[bufnr] = git_root
	end
end

local function unregister_oil_buffer(bufnr)
	local git_root = active_oil_buffers[bufnr]
	if not git_root then
		return
	end

	-- Decrement buffer count
	local repo_data = git_repo_timers[git_root]
	if repo_data then
		repo_data.buffer_count = repo_data.buffer_count - 1

		-- Stop timer if this was the last buffer for this repo
		if repo_data.buffer_count <= 0 then
			stop_repo_timer(git_root)
		end
	end

	-- Remove buffer tracking
	active_oil_buffers[bufnr] = nil
end

local function get_highlight_group(status_code)
	if not status_code then
		return nil, nil
	end

	local first_char = status_code:sub(1, 1)
	local second_char = status_code:sub(2, 2)

	-- Check staged changes first (prioritize staged over unstaged)
	if first_char == "A" then
		return "OilGitAdded", "+"
	elseif first_char == "M" then
		return "OilGitModified", "~"
	elseif first_char == "R" then
		return "OilGitRenamed", "→"
	end

	-- Check unstaged changes
	if second_char == "M" then
		return "OilGitModified", "~"
	end

	-- Untracked files
	if status_code == "??" then
		return "OilGitUntracked", "?"
	end

	-- Ignored files
	if status_code == "!!" then
		return "OilGitIgnored", "!"
	end

	return nil, nil
end

local function clear_highlights(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()

	-- Only clear if buffer is still valid
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	-- Clear matches more efficiently
	vim.fn.clearmatches()

	-- Clear existing virtual text
	local ns_id = vim.api.nvim_create_namespace("oil_git_status")
	vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)
end

local function apply_highlights_to_buffer(bufnr, git_status)
	local oil = require("oil")
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local current_dir = oil.get_current_dir(bufnr)

	if not current_dir then
		return
	end

	clear_highlights(bufnr)

	-- Batch highlight operations
	local highlights = {}
	local extmarks = {}
	local ns_id = vim.api.nvim_create_namespace("oil_git_status")

	for i, line in ipairs(lines) do
		local entry = oil.get_entry_on_line(bufnr, i)
		if entry and entry.type == "file" then
			-- Build filepath, ensuring no double slashes
			local filepath = current_dir
			if not filepath:match("/$") then
				filepath = filepath .. "/"
			end
			filepath = filepath .. entry.name
			local status_code = git_status[filepath]
			local hl_group, symbol = get_highlight_group(status_code)

			if hl_group and symbol then
				local name_start = line:find(entry.name, 1, true)
				if name_start then
					table.insert(highlights, { hl_group, { { i, name_start, #entry.name } } })
					table.insert(
						extmarks,
						{ i - 1, { virt_text = { { " " .. symbol, hl_group } }, virt_text_pos = "eol" } }
					)
				end
			end
		end
	end

	-- Apply all highlights at once
	for _, hl in ipairs(highlights) do
		vim.fn.matchaddpos(hl[1], hl[2])
	end

	-- Apply all extmarks at once
	for _, mark in ipairs(extmarks) do
		vim.api.nvim_buf_set_extmark(bufnr, ns_id, mark[1], 0, mark[2])
	end
end

local function apply_git_highlights_debounced()
	-- Cancel existing timer
	if debounce_timer then
		if not debounce_timer:is_closing() then
			debounce_timer:stop()
			debounce_timer:close()
		end
		debounce_timer = nil
	end

	-- Create new timer
	debounce_timer = vim.uv.new_timer()
	if debounce_timer then
		debounce_timer:start(
			config.debounce_ms,
			0,
			vim.schedule_wrap(function()
				-- Forward call to main function defined below
				M._apply_git_highlights_impl()
			end)
		)
	end
end

-- Apply highlights immediately using cached data (for BufEnter)
local function apply_git_highlights_fresh()
	local oil = require("oil")
	local bufnr = vim.api.nvim_get_current_buf()
	local current_dir = oil.get_current_dir()

	if not current_dir or vim.bo[bufnr].filetype ~= "oil" then
		return
	end

	local git_root = get_git_root(current_dir)
	if not git_root then
		return
	end

	-- Register this buffer for timer management
	register_oil_buffer(bufnr, git_root)

	-- Apply highlights immediately using cached data (if available)
	if cache[git_root] and cache[git_root].data then
		-- Use cached data immediately - no lag!
		local cached_data = cache[git_root]
		-- Apply highlights immediately with content validation
		vim.schedule(function()
			if vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].filetype == "oil" then
				-- Verify content exists before applying highlights
				local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
				if #lines > 1 then -- Content loaded
					if next(cached_data.data) == nil then
						clear_highlights(bufnr)
					else
						apply_highlights_to_buffer(bufnr, cached_data.data)
					end
				end
			end
		end)
	else
		-- No cached data - fallback to async fetch (first time)
		M._apply_git_highlights_impl()
	end
end

-- Expose internal function for debounced calls
M._apply_git_highlights_impl = function()
	local oil = require("oil")
	local bufnr = vim.api.nvim_get_current_buf()
	local current_dir = oil.get_current_dir(bufnr)

	if not current_dir or vim.bo[bufnr].filetype ~= "oil" then
		clear_highlights(bufnr)
		return
	end

	-- Use async git status
	get_git_status_async(current_dir, function(git_status)
		vim.schedule(function()
			-- Double-check buffer is still valid and is oil
			if not vim.api.nvim_buf_is_valid(bufnr) or vim.bo[bufnr].filetype ~= "oil" then
				return
			end

			-- Always apply highlights from async callback (first time visit)
			-- Don't check previous state here since this is fresh data
			-- If we reach here: either directory changed OR git status changed - always re-apply

			-- Update buffer state with both git status and directory

			if next(git_status) == nil then
				clear_highlights(bufnr)
			else
				apply_highlights_to_buffer(bufnr, git_status)
			end
		end)
	end)
end

local function setup_autocmds()
	local group = vim.api.nvim_create_augroup("OilGitStatus", { clear = true })

	-- Primary trigger: entering oil buffers (force fresh check)
	vim.api.nvim_create_autocmd("BufEnter", {
		group = group,
		pattern = "oil://*",
		callback = function()
			apply_git_highlights_fresh()
		end,
	})

	-- Secondary trigger: after buffer content is loaded
	vim.api.nvim_create_autocmd("BufReadPost", {
		group = group,
		pattern = "oil://*",
		callback = function()
			-- Small delay to ensure oil has processed the content
			vim.defer_fn(function()
				apply_git_highlights_fresh()
			end, 10) -- 10ms delay, much faster than 50ms
		end,
	})

	-- Clean up buffer state, highlights, and timers when buffers are deleted
	vim.api.nvim_create_autocmd("BufDelete", {
		group = group,
		pattern = "oil://*",
		callback = function(args)
			clear_highlights(args.buf)
			unregister_oil_buffer(args.buf)
		end,
	})

	-- Debounced refresh on focus regain (e.g., after git operations)
	vim.api.nvim_create_autocmd("FocusGained", {
		group = group,
		callback = function()
			if vim.bo.filetype == "oil" then
				apply_git_highlights_debounced()
			end
		end,
	})

	-- Terminal close events (for LazyGit, fugitive, etc.)
	vim.api.nvim_create_autocmd("TermClose", {
		group = group,
		callback = function()
			-- Small delay to allow git operations to complete
			vim.defer_fn(function()
				for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
					if vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].filetype == "oil" then
						local oil = require("oil")
						local current_dir = oil.get_current_dir(bufnr)
						if current_dir then
							-- Invalidate cache for this git repo
							local git_root = get_git_root(current_dir)
							if git_root then
								cache[git_root] = nil
							end
							apply_git_highlights_debounced()
						end
					end
				end
			end, 100)
		end,
	})

	-- Git-related user events (with debouncing)
	vim.api.nvim_create_autocmd("User", {
		group = group,
		pattern = { "FugitiveChanged", "GitSignsUpdate" },
		callback = function()
			if vim.bo.filetype == "oil" then
				-- Invalidate all caches on git events
				cache = {}
				apply_git_highlights_debounced()
			end
		end,
	})
end

-- Track if plugin has been initialized
local initialized = false

local function initialize()
	if initialized then
		return
	end

	setup_highlights()
	setup_autocmds()

	initialized = true
end

function M.setup(opts)
	opts = opts or {}

	-- Merge user highlights with defaults (only affects fallbacks)
	if opts.highlights then
		default_highlights = vim.tbl_extend("force", default_highlights, opts.highlights)
	end

	initialize()
end

-- Manual refresh function
function M.refresh()
	-- Clear all caches and buffer states to force fresh data
	cache = {}

	-- Force immediate refresh for current buffer
	local oil = require("oil")
	local bufnr = vim.api.nvim_get_current_buf()
	local current_dir = oil.get_current_dir(bufnr)
	if current_dir then
		local git_root = get_git_root(current_dir)
		if git_root then
			-- Trigger fresh git fetch for this repo
			get_git_status_async(current_dir, function(git_status)
				-- Cache updated, now apply highlights
				vim.schedule(function()
					if vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].filetype == "oil" then
						if next(git_status) == nil then
							clear_highlights(bufnr)
						else
							apply_highlights_to_buffer(bufnr, git_status)
						end
					end
				end)
			end)
		end
	end
end

-- Function to clear cache for specific git root (useful for external tools)
function M.invalidate_cache(git_root)
	if git_root and cache[git_root] then
		cache[git_root] = nil
	end
end

-- Auto-initialize when oil buffer is entered (only set up once)
if not _G._oil_git_autocmd_setup then
	vim.api.nvim_create_autocmd("FileType", {
		pattern = "oil",
		callback = function()
			initialize()
		end,
		group = vim.api.nvim_create_augroup("OilGitAutoInit", { clear = true }),
	})
	_G._oil_git_autocmd_setup = true
end

return M
