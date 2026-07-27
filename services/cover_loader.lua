-- Cover Loader Service for OPDS Menus
-- Handles asynchronous loading, rendering, and cleanup of cover images
-- Shared between list_menu.lua and grid_menu.lua to eliminate duplication

local RenderImage = require("ui/renderimage")

local ImageLoader = require("services.image_loader")
local Debug = require("utils.debug")

local CoverLoader = {}

-- Entries hold their covers until the catalog is left, so a long browse would keep every page
-- ever drawn; the device has no swap. Dropping the oldest costs a re-render from the disk cache.
-- Well over two pages in either view: a cover still on screen is painted from its widget.
local MAX_RENDERED_COVERS = 40
local rendered = {} -- oldest first, {entry, key}

local function sizeKey(cover_width, cover_height)
	return cover_width .. "x" .. cover_height
end

local function freeRendering(entry, key)
	local cover_bb = entry.cover_bbs and entry.cover_bbs[key]
	if cover_bb then
		cover_bb:free()
		entry.cover_bbs[key] = nil
	end
	if entry.cover_bb_key == key then
		entry.cover_bb = nil
		entry.cover_bb_key = nil
		entry.lazy_load_cover = true
	end
end

-- Move a rendering to the young end, so that what the page shows is never the first to go:
-- a cover taken from cover_bbs is drawn without being rendered again, and would otherwise keep
-- ageing while on screen until it is freed under the widget still painting it.
local function touchRendering(entry, key)
	for i = #rendered, 1, -1 do
		local held = rendered[i]
		if held.entry == entry and held.key == key then
			table.remove(rendered, i)
			table.insert(rendered, held)
			return true
		end
	end
	return false
end

local function rememberRendering(entry, key)
	if touchRendering(entry, key) then
		return
	end
	table.insert(rendered, { entry = entry, key = key })
	while #rendered > MAX_RENDERED_COVERS do
		local oldest = table.remove(rendered, 1)
		freeRendering(oldest.entry, oldest.key)
	end
end

--- Free every cover rendered for these entries, e.g. before their catalog is replaced.
-- @param item_table table Catalog entries
function CoverLoader.freeCovers(item_table)
	if not item_table then
		return
	end
	local freed = {}
	for _, entry in ipairs(item_table) do
		for _, cover_bb in pairs(entry.cover_bbs or {}) do
			cover_bb:free()
		end
		entry.cover_bbs = nil
		entry.cover_bb = nil
		entry.cover_bb_key = nil
		freed[entry] = true
	end
	for i = #rendered, 1, -1 do
		if freed[rendered[i].entry] then
			table.remove(rendered, i)
		end
	end
end

--- Extract unique URLs from items pending cover load
-- @param items_to_update table Array of {entry, widget} items
-- @return table urls Array of unique URLs
-- @return table items_by_url Map of URL -> array of item_data
function CoverLoader.extractUniqueUrls(items_to_update)
	local urls = {}
	local items_by_url = {}

	for _, item_data in ipairs(items_to_update) do
		local url = item_data.entry.cover_url
		if url and not items_by_url[url] then
			table.insert(urls, url)
			items_by_url[url] = { item_data }
		elseif url then
			table.insert(items_by_url[url], item_data)
		end
	end

	return urls, items_by_url
end

--- Create a cover render callback for image loading
-- @param items_by_url table Map of URL -> array of item_data
-- @param cover_width number Target cover width
-- @param cover_height number Target cover height
-- @param debug_log function|nil Optional debug logging function
-- @return function Callback for ImageLoader
function CoverLoader.createRenderCallback(items_by_url, cover_width, cover_height)
	return function(url, content)
		local items = items_by_url[url]
		if not items then
			Debug.error("CoverLoader:", "No items for URL:", url)
			return
		end

		for _, item_data in ipairs(items) do
			local entry = item_data.entry
			local widget = item_data.widget

			entry.lazy_load_cover = false

			-- No content means the download failed; mark it either way, or it is queued again.
			local cover_bb
			if content then
				local ok, result = pcall(function()
					return RenderImage:renderImageData(
						content,
						#content,
						false,
						cover_width,
						cover_height
					)
				end)
				if ok then
					cover_bb = result
				else
					Debug.error("CoverLoader:", "Failed to render cover:", tostring(result))
				end
			end

			entry.cover_bb = cover_bb
			entry.cover_failed = cover_bb == nil
			entry.cover_bb_key = cover_bb and sizeKey(cover_width, cover_height) or nil
			if cover_bb then
				entry.cover_bbs = entry.cover_bbs or {}
				entry.cover_bbs[entry.cover_bb_key] = cover_bb
				rememberRendering(entry, entry.cover_bb_key)
			end

			-- Update the widget to show the new cover (or error state)
			widget.entry = entry
			widget:update()
		end
	end
end

--- Schedule the pending covers, replacing whatever the previous page left running.
-- One lasting closure per menu: a fresh one each page would leave the old one queued with
-- nothing to unschedule it by.
-- @param menu table Menu instance
-- @param delay number Seconds before loading starts
function CoverLoader.scheduleLoad(menu, delay)
	local UIManager = require("ui/uimanager")

	CoverLoader.stopLoading(menu)

	if not menu._scheduled_cover_load then
		menu._scheduled_cover_load = function()
			if menu._loadVisibleCovers then
				menu:_loadVisibleCovers()
			end
		end
	end
	UIManager:scheduleIn(delay, menu._scheduled_cover_load)
end

--- Stop cover loading while a dialog covers the menu; CoverLoader.defer resumes it.
-- @param menu table Menu instance
function CoverLoader.stopLoading(menu)
	local UIManager = require("ui/uimanager")

	if menu.halt_image_loading then
		menu.halt_image_loading()
		menu.halt_image_loading = nil
	end
	if menu._scheduled_cover_load then
		UIManager:unschedule(menu._scheduled_cover_load)
	end
end

--- Point the entry at its cover for this view's size, keeping the other view's rendering.
-- Re-rendering costs a decode, or a download once the cached image has expired.
-- @param entry table Catalog entry
-- @param cover_width number Cover width this view draws with
-- @param cover_height number Cover height this view draws with
function CoverLoader.useCoverForSize(entry, cover_width, cover_height)
	local key = sizeKey(cover_width, cover_height)
	if entry.cover_bb_key == key then
		touchRendering(entry, key)
		return
	end

	if entry.cover_bb and entry.cover_bb_key then
		entry.cover_bbs = entry.cover_bbs or {}
		entry.cover_bbs[entry.cover_bb_key] = entry.cover_bb
	end

	local kept = entry.cover_bbs and entry.cover_bbs[key]
	entry.cover_bb = kept
	entry.cover_bb_key = kept and key or nil
	if kept then
		touchRendering(entry, key)
	else
		-- A cover that failed to download or decode fails at any size, and a failed entry never
		-- matches the size key above, so clearing the flag here would re-fetch it on every page.
		entry.lazy_load_cover = not entry.cover_failed
	end
end

--- Load covers for menu items
-- @param menu table Menu instance with _items_to_update, cover_width, cover_height
-- @param debug_log function|nil Optional debug logging function
-- @return function|nil Halt function to cancel loading, or nil if nothing to load
function CoverLoader.loadVisibleCovers(menu, debug_log)
	if not menu._items_to_update or #menu._items_to_update == 0 then
		return nil
	end

	-- The caller is about to overwrite the only handle that could stop the running batch.
	if menu.halt_image_loading then
		menu.halt_image_loading()
		menu.halt_image_loading = nil
	end

	-- Extract unique cover URLs
	local urls, items_by_url = CoverLoader.extractUniqueUrls(menu._items_to_update)

	if #urls == 0 then
		return nil
	end

	Debug.log("CoverLoader:", "Loading", #urls, "unique cover URLs")

	-- Get credentials from the menu
	local username = menu.root_catalog_username
	local password = menu.root_catalog_password
	local cache_enabled = true
	local cache_max_mb = nil
	local cache_ttl_minutes = nil
	if menu.settings and menu.settings.cover_cache_enabled ~= nil then
		cache_enabled = menu.settings.cover_cache_enabled ~= false
		cache_max_mb = menu.settings.cover_cache_max_mb
		cache_ttl_minutes = menu.settings.cover_cache_ttl_minutes
	end

	-- Create render callback
	local render_callback = CoverLoader.createRenderCallback(
		items_by_url,
		menu.cover_width,
		menu.cover_height
	)

	-- Load covers asynchronously
	local _, halt = ImageLoader:loadImages(
		urls,
		render_callback,
		username,
		password,
		cache_enabled,
		cache_max_mb,
		cache_ttl_minutes
	)

	-- Clear the pending items
	menu._items_to_update = {}

	return halt
end

--- Clean up cover loading and free resources
-- @param menu table Menu instance with halt_image_loading and item_table
function CoverLoader.cleanup(menu)
	-- Cancel any in-progress image loading
	if menu.halt_image_loading then
		menu.halt_image_loading()
		menu.halt_image_loading = nil
	end

	CoverLoader.freeCovers(menu.item_table)
end

--- Initialize cover loading state on a menu
-- Sets up required fields for cover loading
-- @param menu table Menu instance to initialize
function CoverLoader.initMenu(menu)
	menu._items_to_update = menu._items_to_update or {}
	menu.halt_image_loading = nil
end

--- Queue an item for cover loading
-- @param menu table Menu instance
-- @param entry table Entry with cover_url
-- @param widget table Widget to update when cover loads
function CoverLoader.queueItem(menu, entry, widget)
	if not menu._items_to_update then
		menu._items_to_update = {}
	end
	table.insert(menu._items_to_update, { entry = entry, widget = widget })
end

--- Check if there are items pending cover load
-- @param menu table Menu instance
-- @return boolean True if there are pending items
function CoverLoader.hasPendingItems(menu)
	return menu._items_to_update and #menu._items_to_update > 0
end

--- Stop loading covers and try again once the user has stopped navigating.
-- Fetching a cover blocks the UI thread for as long as the server takes, so a batch left running
-- makes every keypress wait for it.
-- @param menu table Menu instance
-- @param delay number|nil Seconds of quiet before loading resumes (default 1)
function CoverLoader.defer(menu, delay)
	CoverLoader.stopLoading(menu)

	menu._items_to_update = {}
	for _, item in ipairs(menu._cover_queue or {}) do
		if item.entry and not item.entry.cover_bb and not item.entry.cover_failed then
			table.insert(menu._items_to_update, item)
		end
	end
	if #menu._items_to_update > 0 then
		CoverLoader.scheduleLoad(menu, delay or 1)
	end
end

return CoverLoader
