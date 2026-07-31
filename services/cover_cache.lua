local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")
local bit = require("bit")
local util = require("util")
local Constants = require("models.constants")

local CoverCache = {}

-- getDataDir() is "." on Kindle, which resolves against the working directory rather than the
-- install path; getFullDataDir() answers with the absolute one.
local CACHE_DIR = DataStorage:getFullDataDir() .. "/cache/opds_plus/covers"

local function hashUrl(url)
	local h1 = 5381
	local h2 = 2166136261

	for i = 1, #url do
		local b = string.byte(url, i)
		h1 = bit.tobit(bit.bxor((h1 * 33), b))
		h2 = bit.tobit((h2 * 16777619) + b)
	end

	return bit.tohex(h1) .. bit.tohex(h2)
end

local function cachePath(url)
	return CACHE_DIR .. "/" .. hashUrl(url) .. ".img"
end

local function readFile(path)
	local f = io.open(path, "rb")
	if not f then
		return nil
	end
	local data = f:read("*a")
	f:close()
	return data
end

-- A full disk often reports itself only on the flush, so the close matters as much as the write.
local function writeFile(path, content)
	local f = io.open(path, "wb")
	if not f then
		return false
	end
	local written = f:write(content)
	local closed = f:close()
	if not written or not closed then
		os.remove(path)
		return false
	end
	return true
end

local function listCacheFiles()
	local files = {}
	local total = 0

	if lfs.attributes(CACHE_DIR, "mode") ~= "directory" then
		return files, total
	end

	for name in lfs.dir(CACHE_DIR) do
		if name ~= "." and name ~= ".." and name:sub(-4) == ".img" then
			local path = CACHE_DIR .. "/" .. name
			local attr = lfs.attributes(path)
			if attr and attr.mode == "file" then
				local size = attr.size or 0
				table.insert(files, {
					path = path,
					size = size,
					mtime = attr.modification or 0,
				})
				total = total + size
			end
		end
	end

	return files, total
end

--- Free space at a path, in MB, or nil if it cannot be told.
-- util.diskUsage runs "df -kP", and busybox on legacy Kindles has no -P and prints nothing,
-- so fall back to plain "df -k" and read the last row it prints.
local function freeSpaceMB(dir)
	local usage = util.diskUsage(dir)
	if usage and usage.available then
		return usage.available / 1024 / 1024
	end
	local handle = io.popen("df -k " .. util.shell_escape({ dir }) .. " 2>/dev/null | tail -1")
	if not handle then
		return nil
	end
	local row = handle:read("*l")
	handle:close()
	if not row then
		return nil
	end
	-- Anchor on the use% column: a device name can hold digits of its own (/dev/sda1).
	local available = row:match("%d+%s+%d+%s+(%d+)%s+%d+%%")
	return available and tonumber(available) / 1024 or nil
end

local default_max_bytes

--- Cache ceiling to use when the user has not set one: smaller on a device short on space.
-- @return number Maximum cache size in bytes
function CoverCache.defaultMaxBytes()
	if default_max_bytes then
		return default_max_bytes
	end
	local mb = Constants.COVER_CACHE.DEFAULT_MAX_MB
	local free_mb = freeSpaceMB(DataStorage:getFullDataDir())
	if free_mb and free_mb < Constants.COVER_CACHE.LOW_SPACE_MB then
		mb = Constants.COVER_CACHE.LOW_SPACE_MAX_MB
	end
	default_max_bytes = mb * 1024 * 1024
	return default_max_bytes
end

local function pruneToMaxBytes(max_bytes)
	if not max_bytes or max_bytes <= 0 then
		return
	end

	local files, total = listCacheFiles()
	if total <= max_bytes then
		return
	end

	table.sort(files, function(a, b)
		return a.mtime < b.mtime
	end)

	for _, file in ipairs(files) do
		if total <= max_bytes then
			break
		end

		os.remove(file.path)
		total = total - file.size
	end
end

function CoverCache.get(url, ttl_seconds)
	local path = cachePath(url)
	local attr = lfs.attributes(path)
	if not attr or attr.mode ~= "file" then
		return nil
	end

	local content = readFile(path)
	if not content or content == "" then
		return nil
	end

	local age = os.time() - (attr.modification or 0)
	return {
		content = content,
		stale = ttl_seconds and age > ttl_seconds or false,
		age_seconds = age,
	}
end

function CoverCache.put(url, content, max_bytes)
	if not content or content == "" then
		return false
	end

	if not util.makePath(CACHE_DIR) then
		return false
	end

	-- Rename onto the entry, so a write cut short leaves a scratch file and never half a cover.
	local scratch = cachePath(url) .. ".tmp"
	if not writeFile(scratch, content) then
		return false
	end
	if not os.rename(scratch, cachePath(url)) then
		os.remove(scratch)
		return false
	end
	if max_bytes and max_bytes > 0 then
		pruneToMaxBytes(max_bytes)
	end
	return true
end

function CoverCache.clear()
	if lfs.attributes(CACHE_DIR, "mode") ~= "directory" then
		return
	end

	for name in lfs.dir(CACHE_DIR) do
		if name ~= "." and name ~= ".." and (name:sub(-4) == ".img" or name:sub(-4) == ".tmp") then
			os.remove(CACHE_DIR .. "/" .. name)
		end
	end
end

return CoverCache
