local FFIUtil = require("ffi/util")
local HttpClient = require("services.http_client")
local UIManager = require("ui/uimanager")
local Constants = require("models.constants")
local Debug = require("utils.debug")
local CoverCache = require("services.cover_cache")

local ImageLoader = {}

-- The check is a waitpid, so it costs nothing to ask often.
local FETCH_POLL_SECONDS = 0.25
local FETCH_GRACE_SECONDS = 2

-- A killed child takes a moment to die and still has to be collected, or it stays a zombie for
-- as long as KOReader runs.
local uncollected_pids = {}
local collector_running = false

local function collectFetches()
    for i = #uncollected_pids, 1, -1 do
        if FFIUtil.isSubProcessDone(uncollected_pids[i]) then
            table.remove(uncollected_pids, i)
        end
    end
    if #uncollected_pids > 0 then
        UIManager:scheduleIn(FETCH_POLL_SECONDS, collectFetches)
        return
    end
    collector_running = false
end

local function collectLater(pid)
    table.insert(uncollected_pids, pid)
    if not collector_running then
        collector_running = true
        UIManager:scheduleIn(FETCH_POLL_SECONDS, collectFetches)
    end
end

--- The image a fetch sent back, or nil when it sent none.
-- A fetch answers "OK <bytes>\n" and then the image, or "ERR". The length is what tells a whole
-- image from what a child killed mid-write left behind.
local function parseFetched(payload)
    if not payload then
        return nil
    end
    local length, body_at = payload:match("^OK (%d+)\n()")
    if not length then
        return nil
    end
    local content = payload:sub(body_at)
    return #content == tonumber(length) and content or nil
end

local Batch = {
    loading = false,
    url_map = {},
    callback = nil,
    username = nil,
    password = nil,
}
Batch.__index = Batch

function Batch:new(o)
    return setmetatable(o or {}, self)
end

function Batch:loadImages(urls)
    if self.loading then
        error("batch already in progress")
    end

    self.loading = true
    local stop_loading = false
    local pending_urls = { table.unpack(urls) }
    local ttl_seconds = (self.cache_ttl_minutes or Constants.COVER_CACHE.DEFAULT_TTL_MINUTES) * 60
    local max_bytes = self.cache_max_mb and (self.cache_max_mb * 1024 * 1024)
        or CoverCache.defaultMaxBytes()

    local fetch_pid, fetch_read_fd, fetch_poll
    local cache_write_failed = false

    local function fetchInSubProcess(url)
        local username, password = self.username, self.password
        return FFIUtil.runInSubProcess(function(_, child_write_fd)
            local ok, content = HttpClient.getUrlContent(
                url,
                Constants.TIMEOUTS.IMAGE_LOAD,
                Constants.TIMEOUTS.IMAGE_MAX_TIME,
                username,
                password
            )
            local payload = ok and content and content ~= ""
                and ("OK " .. #content .. "\n" .. content)
                or "ERR\n"
            FFIUtil.writeToFD(child_write_fd, payload, true)
        end, true)
    end

    -- Whoever stops caring about a fetch has to let its child go: kill it, drain the pipe so
    -- a blocked write can finish, and leave the pid to the collector.
    local function abandonFetch()
        if not fetch_pid then
            return
        end
        FFIUtil.terminateSubProcess(fetch_pid)
        collectLater(fetch_pid)
        if fetch_read_fd then
            FFIUtil.readAllFromFD(fetch_read_fd) -- reads to the end, and closes it
            fetch_read_fd = nil
        end
        UIManager:allowStandby()
        fetch_pid = nil
    end

    local run_image
    run_image = function()
        if stop_loading then
            self.loading = false
            return
        end

        local url = table.remove(pending_urls, 1)
        if not url then
            self.loading = false
            return
        end

        local stale_content = nil
        if self.cover_cache_enabled ~= false then
            local cached = CoverCache.get(url, ttl_seconds)
            if cached and not cached.stale then
                Debug.log("ImageLoader:", "Cover cache hit:", url)
                if self.callback then
                    self.callback(url, cached.content)
                end

                -- Schedule rather than recurse: a page of cached covers would otherwise decode,
                -- render and repaint in one go, with no chance for a keypress to be read. The
                -- delay has to outlast that repaint, or the task is due again before the loop
                -- reaches the input poll.
                if #pending_urls > 0 then
                    UIManager:scheduleIn(Constants.UI_TIMING.IMAGE_BATCH_DELAY, run_image)
                    return
                end
                self.loading = false
                return
            end

            Debug.log("ImageLoader:", "Cover cache miss:", url)
            if cached and cached.content then
                stale_content = cached.content
            end
        end

        local function deliver(content)
            if stop_loading then
                self.loading = false
                return
            end
            if self.callback then
                self.callback(url, content)
            end
            if #pending_urls > 0 then
                UIManager:scheduleIn(Constants.UI_TIMING.IMAGE_BATCH_DELAY, run_image)
                return
            end
            self.loading = false
        end

        -- The fetch itself blocks for as long as the server takes, which on a slow link is
        -- seconds per cover. Hand it to a subprocess: it sends the bytes back through a pipe,
        -- and this thread only asks now and then whether there is anything to read.
        Debug.log("ImageLoader:", "Fetching cover with auth:", self.username and "yes" or "no")
        fetch_pid, fetch_read_fd = fetchInSubProcess(url)

        if not fetch_pid then
            fetch_read_fd = nil -- a failed fork answers with an error message, not a pipe
            -- Out of processes or memory: fetching here still beats showing nothing.
            Debug.error("ImageLoader:", "Fork failed, fetching on the UI thread:", url)
            local ok, content = HttpClient.getUrlContent(
                url,
                Constants.TIMEOUTS.IMAGE_LOAD,
                Constants.TIMEOUTS.IMAGE_MAX_TIME,
                self.username,
                self.password
            )
            if ok then
                if self.cover_cache_enabled ~= false then
                    CoverCache.put(url, content, max_bytes)
                end
                deliver(content)
            else
                Debug.error("ImageLoader:", "Failed to download cover:", content or "unknown error")
                deliver(stale_content)
            end
            return
        end

        UIManager:preventStandby()
        local deadline = os.time() + Constants.TIMEOUTS.IMAGE_MAX_TIME + FETCH_GRACE_SECONDS

        fetch_poll = function()
            if stop_loading then
                abandonFetch()
                return
            end

            local done = FFIUtil.isSubProcessDone(fetch_pid)
            -- A cover outgrows the pipe buffer, and the child then blocks in its write until
            -- someone reads: waiting for it to exit first would wait forever.
            local readable = FFIUtil.getNonBlockingReadSize(fetch_read_fd) ~= 0
            if not done and not readable then
                if os.time() < deadline then
                    UIManager:scheduleIn(FETCH_POLL_SECONDS, fetch_poll)
                    return
                end
                Debug.error("ImageLoader:", "Cover fetch outlived its timeout:", url)
                abandonFetch()
                deliver(stale_content)
                return
            end

            local payload = FFIUtil.readAllFromFD(fetch_read_fd)
            fetch_read_fd = nil
            if not done then
                collectLater(fetch_pid) -- it exits now that its write went through
            end
            UIManager:allowStandby()
            fetch_pid = nil

            local content = parseFetched(payload)
            if not content then
                Debug.error("ImageLoader:", "Failed to download cover:", url)
            elseif self.cover_cache_enabled ~= false and not cache_write_failed then
                -- The cover is in hand either way; keeping it is what may fail here, and a
                -- page of them would otherwise say so thirty times over.
                cache_write_failed = not CoverCache.put(url, content, max_bytes)
                if cache_write_failed then
                    Debug.error("ImageLoader:", "Cover cache is not writable, covers are not kept")
                end
            end
            deliver(content or stale_content)
        end

        UIManager:scheduleIn(FETCH_POLL_SECONDS, fetch_poll)
    end

    if #urls == 0 then
        self.loading = false
    end

    UIManager:nextTick(run_image)

    local halt = function()
        stop_loading = true
        self.loading = false
        self.callback = nil
        UIManager:unschedule(run_image)
        if fetch_poll then
            UIManager:unschedule(fetch_poll)
        end
        abandonFetch()
    end

    return halt
end

--- Load images from URLs asynchronously
-- @param urls table Array of URLs to load
-- @param callback function Callback(url, content) called for each loaded image
-- @param username string|nil HTTP auth username
-- @param password string|nil HTTP auth password
-- @param cover_cache_enabled boolean|nil Whether to use in-memory cover cache (default: true)
-- @param cache_max_mb number|nil Maximum cache size in MB
-- @param cache_ttl_minutes number|nil Cache TTL in minutes
-- @return table, function Batch instance and halt function
function ImageLoader:loadImages(urls, callback, username, password, cover_cache_enabled, cache_max_mb, cache_ttl_minutes)
    local batch = Batch:new {
        username = username,
        password = password,
        cover_cache_enabled = cover_cache_enabled ~= false,
        cache_max_mb = cache_max_mb,
        cache_ttl_minutes = cache_ttl_minutes,
    }
    batch.callback = callback
    local halt = batch:loadImages(urls)
    return batch, halt
end

--- Clear disk cover cache.
function ImageLoader.clearCache()
    CoverCache.clear()
end

return ImageLoader
