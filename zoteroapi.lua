local BaseUtil = require("ffi/util")
local Util = require("ffi/util")  -- luacheck:ignore
local LuaSettings = require("luasettings")
local http = require("socket.http")
local ltn12 = require("ltn12")
local https = require("ssl.https")
local JSON = require("json")
local lfs = require("libs/libkoreader-lfs")
local DocSettings = require("docsettings")
local sha2 = require("ffi/sha2")
local Archiver = require("ffi/archiver")

-- Functions expect config parameter, a lua table with the following keys:
-- zotero_dir: Path to a directory where cache files will be stored
-- api_key: self-explanatory
--
-- Directory layout of zoteroapi
-- /items.json: Contains all items
-- /storage/<KEY>/filename.pdf: Actual PDF files
-- /storage/<KEY>/version: Version number of downloaded attachment
-- /meta.lua: Metadata containing library version, items etc.

local API = {}

local SUPPORTED_MEDIA_TYPES = {
    [1] = "application/pdf",
    [2] = "application/epub+zip"
}

local function joinTables(target, source)
    return table.move(source, 1, #source, #target + 1, target)
end

local function file_exists(path)
    if path == nil then return nil end
    return lfs.attributes(path) ~= nil
end

local function table_contains(t, search_value)
    for k, v in pairs(t) do
        if v == search_value then
            return true
        end
    end

    return false
end

local function file_slurp(path)
    if not file_exists(path) then
        return nil
    end
    local f = io.open(path, "r")

    if f == nil then
        return nil
    end

    local content = f:read("*all")
    f:close()
    return content
end

-- Extract the publication year from a Zotero date string, which can look like
-- "2021", "2021-04", "2021-04-12" or even fuzzier.
local function extractYear(date_string)
    if date_string == nil then
        return nil
    end

    return string.match(date_string, "(%d%d%d%d)")
end

-- A single author is shortened to "Last, Initial." (e.g. "Flash Gordon" ->
-- "Gordon, F."). Multi-author summaries ("A and B") are left untouched.
local function formatAuthor(summary)
    if summary == nil then
        return nil
    end
    -- Zotero joins multiple creators with " and ", e.g. "Shakura and Sunyaev".
    if string.match(summary, " and ") then
        return summary
    end
    local last, first
    last, first = string.match(summary, "^%s*(.-)%s*,%s*(.-)%s*$")
    if last == nil then
        first, last = string.match(summary, "^%s*(%S+)%s+(%S+)%s*$")
    end
    if last ~= nil and first ~= nil then
        local initial = string.match(first, "^%S")
        if initial ~= nil then
            return last .. ", " .. initial .. "."
        end
    end
    return summary
end

-- Values used for comparison. Returned so that nil values sort last.
local function sortValue(item, field)
    local v = item[field]
    if v == nil or v == "" then
        return nil
    end
    if field == "year" then
        -- keep as numeric year when possible
        local y = tonumber(v)
        return y or v
    end
    return string.lower(v)
end

-- Natural string comparison that splits digit runs so that "10" > "2".
-- Case-insensitive via sortValue (or the passed-in values).
local function naturalCompare(a, b)
    local a_len, b_len = #a, #b
    local i, j = 1, 1
    while i <= a_len and j <= b_len do
        local ca, cb = a:sub(i, i), b:sub(j, j)
        local na, nb = ca:match("%d"), cb:match("%d")
        if na and nb then
            local as = a:match("^%d+", i)
            local bs = b:match("^%d+", j)
            local la, lb = tonumber(as), tonumber(bs)
            if la ~= lb then
                return la < lb
            end
            -- Equal numeric values: fewer leading zeros sorts first.
            if #as ~= #bs then
                return #as < #bs
            end
            i, j = i + #as, j + #bs
        else
            if ca ~= cb then
                return ca < cb
            end
            i, j = i + 1, j + 1
        end
    end
    -- One string is a prefix of the other (or they are equal).
    return a_len - i < b_len - j
end

-- Sort a list of items by the given order.
-- Orders: author, title, year, date_added, date_modified.
-- Default: Author/Title/Year sort ascending; date orders sort newest first.
-- `desc` (true/false/nil) overrides the direction.
function API.sortItems(items, sort_order, desc)
    local field = sort_order
    if not (field == "author" or field == "year"
        or field == "date_added" or field == "date_modified") then
        field = "title"
    end
    if desc == nil then
        desc = field == "date_added" or field == "date_modified"
    end
    table.sort(items, function(a, b)
        local av, bv
        if field == "author" then
            -- Fall back to title when no author (collections, labels, "No results").
            av, bv = a.author or a.title, b.author or b.title
        else
            av, bv = sortValue(a, field), sortValue(b, field)
        end
        if av == nil and bv == nil then
            return string.lower(a.title or "") < string.lower(b.title or "")
        end
        if av == nil then return false end
        if bv == nil then return true end
        if type(av) == "number" and type(bv) == "number" then
            if av == bv then
                return string.lower(a.title or "") < string.lower(b.title or "")
            end
            if desc then
                return av > bv
            end
            return av < bv
        end
        av = string.lower(tostring(av))
        bv = string.lower(tostring(bv))
        if av == bv then
            return string.lower(a.title or "") < string.lower(b.title or "")
        end
        if desc then
            return naturalCompare(bv, av)
        end
        return naturalCompare(av, bv)
    end)
    return items
end

function API.cutDecimalPlaces(x, num_places)
    local fac = 10^num_places
    return math.floor(x * fac) / fac
end

function API.init(zotero_dir)
    print("Z: initializing API")
    API.zotero_dir = zotero_dir
    local settings_path = BaseUtil.joinPath(API.zotero_dir, "meta.lua")
    print(settings_path)
    API.settings = LuaSettings:open(settings_path)
    print("Z: settings opened")

    API.storage_dir = BaseUtil.joinPath(API.zotero_dir, "storage")
    if not file_exists(API.storage_dir) then
        lfs.mkdir(API.storage_dir)
    end

    print("Z: storage dir" .. API.storage_dir)
end

function API.getAPIKey()
    return API.settings:readSetting("api_key")
end
function API.setAPIKey(api_key)
    API.settings:saveSetting("api_key", api_key)
end

function API.getUserID()
    return API.settings:readSetting("user_id")
end

function API.setUserID(user_id)
    API.settings:saveSetting("user_id", user_id)
end

function API.getWebDAVEnabled()
    return API.settings:isTrue("webdav_enabled")
end
function API.getWebDAVUser()
    return API.settings:readSetting("webdav_user")
end

function API.getWebDAVPassword()
    return API.settings:readSetting("webdav_password")
end

function API.getWebDAVUrl()
    return API.settings:readSetting("webdav_url")
end

function API.toggleWebDAVEnabled()
    API.settings:toggle("webdav_enabled")
end

function API.setWebDAVUser(user)
    API.settings:saveSetting("webdav_user", user)
end

function API.setWebDAVPassword(password)
    API.settings:saveSetting("webdav_password", password)
end

function API.setWebDAVUrl(url)
    API.settings:saveSetting("webdav_url", url)
end

function API.getLibraryVersion()
    return API.settings:readSetting("library_version_nr", "0")
end

function API.setLibraryVersion(version)
    return API.settings:saveSetting("library_version_nr", version)
end

-- Retrieve underlying settings object to make changes from the outside
function API.getSettings()
    return API.settings
end


-- Check that a webdav connection works by performing a PROPFIND operation on the
-- URL with the associated credentials.
-- returns nil if no problems where found, otherwise error string
function API.checkWebDAV()
    local url = API.getWebDAVUrl()
    if url == nil then
        return "No WebDAV URL provided"
    end

    local user = API.getWebDAVUser()
    local pass = API.getWebDAVPassword()
    local headers = API.getWebDAVHeaders()

    local b, c, h = http.request {
        url = url,
        method = "PROPFIND",
        headers = headers
    }

    if c == 200 or c == 207 then
        return nil
    elseif c == 400 or c == 401 then
        return "Reached server, but access forbidden. Check username and password."
    end


end

-- List of zotero items that need to be synced to the server.  Items that are
-- modified will have a "key" property, new items will not carry this property.
function API.getModifiedItems()
    if API.modified_items == nil then
        API.modified_items = API.settings:readSetting("modified_items", {})
    end

    return API.modified_items
end


-- This just syncs them to disk, it will not modify the Zotero collection!
function API.saveModifiedItems()
    API.settings:flush()
end

function API.getFilterTag()
    return API.settings:readSetting("filter_tag", "")
end

function API.setFilterTag(tag)
    return API.settings:saveSetting("filter_tag", tag)
end

function API.setItems(items)
    API.items = items
    local f = assert(io.open(BaseUtil.joinPath(API.zotero_dir, "items.json"), "w"))
    local content = JSON.encode(API.items)
    f:write(content)
    f:close()
end

function API.getItems()
    if API.items == nil then
        local path = BaseUtil.joinPath(API.zotero_dir, "items.json")
        local file_exists = lfs.attributes(path)

        if not file_exists then
            API.items = {}
        else
            API.items = JSON.decode(file_slurp(path))
        end
    end

    return API.items
end

function API.getCollections()
    if API.collections == nil then
        local path = BaseUtil.joinPath(API.zotero_dir, "collections.json")
        local file_exists = lfs.attributes(path)

        if not file_exists then
            API.collections = {}
        else
            API.collections = JSON.decode(file_slurp(path))
        end
    end

    return API.collections
end

function API.setCollections(collections)
    API.collections = collections
    local f = assert(io.open(BaseUtil.joinPath(API.zotero_dir, "collections.json"), "w"))
    local content = JSON.encode(API.collections)
    f:write(content)
    f:close()
end

function API.verifyResponse(r, c)
    if r ~= 1 then
        return ("Error: no network connection available. Please check your connection and try again. (" .. c .. ")")
    elseif c ~= 200 then
        return ("Error: API responded with status code " .. c)
    end

    return nil
end

function API.fetchCollectionSize(collection_url, headers)
    print("Determining size of '" .. collection_url .. "'")
    local r, c, h = http.request {
        method = "HEAD",
        url = collection_url,
        headers = headers
    }

    local e = API.verifyResponse(r, c)
    if e ~= nil then return nil, e end

    local total_results = tonumber(h["total-results"])
    if total_results == nil or total_results < 0 then
        return nil, "Error: could not determine number of items in library"
    end

    return tonumber(total_results)
end

-- Fetches a paginated URL collection.
--
-- If no callback is given, it returns an array containing all entries of the collection.
--
-- If a callback is given, it will be called with the entries on each page as they are fetched
-- and the function will return the version number.
--
-- If an error occurs, the function will return nil and the error message as second parameter.
function API.fetchCollectionPaginated(collection_url, headers, callback)
    -- Try to determine the size
    local collection_size, e = API.fetchCollectionSize(collection_url, headers)
    if e ~= nil then return nil, e end

    print(("Fetching %s items."):format(collection_size))
    -- The API returns the results in pages with 100 entries each, loop accordingly.
    local items = {}
    local library_version = 0
    local step_size = 100
    for item_nr = 0, collection_size, step_size do
        local page_url = ("%s&limit=%i&start=%i"):format(collection_url, step_size, item_nr)
        print("Fetching page ", item_nr, page_url)

        local page_data = {}
        local r, c, h = http.request {
            method = "GET",
            url = page_url,
            headers = headers,
            sink = ltn12.sink.table(page_data)
        }

        library_version = h["last-modified-version"]

        local e = API.verifyResponse(r, c)
        if e ~= nil then return nil, e end

        local content = table.concat(page_data, "")
        local ok, result = pcall(JSON.decode, content)
        if not ok then
            return nil, "Error: failed to parse JSON in response"
        end

        if callback then
            callback(result)
        else
            -- add items to the list we return in the end
            table.move(result, 1, #result, #items + 1, items)
        end
    end

    if callback then
        return library_version, nil
    else
        return items, nil
    end

end

function API.ensureKeyAndID()
    local user_id = API.settings:readSetting("user_id", "")
    local api_key = API.settings:readSetting("api_key", "")

    if user_id == "" then
        return "Error: must set User ID"
    elseif api_key == "" then
        return "Error: must set API Key"
    end

    return nil, api_key, user_id
end

function API.getHeaders(api_key)
    return {
        ["zotero-api-key"] = api_key,
        ["zotero-api-version"] = "3"
    }
end

function API.syncAllItems()
    local since = API.getLibraryVersion()

    local e, api_key, user_id = API.ensureKeyAndID()
    if e ~= nil then return e end
    print(e, api_key, user_id)

    local headers = API.getHeaders(api_key)
    local items_url = ("https://api.zotero.org/users/%s/items?since=%s&includeTrashed=true"):format(user_id, since)
    local collections_url = ("https://api.zotero.org/users/%s/collections?since=%s&includeTrashed=true"):format(user_id, since)

    -- Sync library items
    local items = API.getItems()
    print("loaded items: " .. #items)
    local r, e = API.fetchCollectionPaginated(items_url, headers, function(partial_entries)
        print("Received callback, processing entries: " .. #partial_entries)
        for i = 1, #partial_entries do
            -- Ruthlessly update our local items
            local item = partial_entries[i]
            local key = item.key

            -- Check if item was deleted.
            -- Server either sets deleted to true or 1, so we need to check for both
            if item.data ~= nil and (item.data.deleted == 1 or item.data.deleted == true) then
                items[key] = nil
            else
                items[key] = item
            end
        end
    end)
    if e ~= nil then return e end
    API.setItems(items)

    -- Sync library collections
    local collections = API.getCollections()
    local r, e = API.fetchCollectionPaginated(collections_url, headers, function(partial_entries)
        print("Received callback, processing entries: " .. #partial_entries)
        for i = 1, #partial_entries do
            -- Ruthlessly update our local items
            local collection = partial_entries[i]
            local key = collection.key
            if collection.data ~= nil and (collection.data.deleted == 1 or collection.data.deleted == true) then
                collections[key] = nil
            else
                collections[key] = collection
            end
        end
    end)
    if e ~= nil then return e end
    API.setCollections(collections)

    API.setLibraryVersion(r)
    API.settings:flush()

    return nil
end

-- If a tag is set, ensure all entries actually have that tag and it has not been removed
-- If no tag is set, just remove all deleted entries from the library
function API.purgeEntries()

end

function API.getDirAndPath(attachmentKey)
    local items = API.getItems()
    local attachment = items[attachmentKey]

    if attachment == nil or attachment.data.filename == nil then
        return nil, nil
    end

    local targetDir = API.storage_dir .. "/"
    if attachment.data.parentItem ~= nil then
        targetDir = targetDir .. attachment.data.parentItem
    else
        targetDir = targetDir .. attachmentKey
    end
    local targetPath = targetDir .. "/" .. attachment.data.filename

    return targetDir, targetPath
end

-- Returns true if the attachment file is present locally and up to date
-- (same check as downloadAndGetPath's cache shortcut).
function API.isDownloaded(attachmentKey)
    local items = API.getItems()
    local attachment = items[attachmentKey]
    if attachment == nil or attachment.data.itemType ~= "attachment" then
        return false
    end

    local targetDir, targetPath = API.getDirAndPath(attachmentKey)
    if targetPath == nil then
        return false
    end

    local local_version = tonumber(file_slurp(targetDir .. "/version"))
    local version_ok = attachment.version == nil
        or (local_version ~= nil and local_version >= attachment.version)
    return version_ok and file_exists(targetPath)
end

-- Downloads an attachment file to the correct directory and returns the path.
-- If the local version is up to date, no network request is made.
-- Before the download, the download_callback is called.
-- Returns tuple with path and error, if path is correct then error is nil.
function API.downloadAndGetPath(key, download_callback)
    local e, api_key, user_id = API.ensureKeyAndID()
    if e ~= nil then return nil, e end

    local items = API.getItems()
    if items[key] == nil then
        return nil, "Error: the requested file can not be found in the database"
    end
    local item = items[key]

    if item.data.itemType ~= "attachment" then
        return nil, "Error: this item is not an attachment"
    end

    if item.data.linkMode == "linked_file" then
        return nil, "Error: this item is a linked attachment. Linked attachments are currently unsupported."
    end

    if item.data.linkMode ~= "imported_file" and item.data.linkMode ~= "imported_url"then
        return nil, "Error: unsupported link mode '" .. tostring(item.data.linkMode) .. "'."
    end

    local attachment = item

    local targetDir, targetPath = API.getDirAndPath(key)
    if targetDir == nil then
        return nil, "Error: attachment has no filename"
    end
    lfs.mkdir(targetDir)

    local local_version = tonumber(file_slurp(targetDir .. "/version"))

    if local_version ~= nil and local_version >= attachment.version and file_exists(targetPath) then
        return targetPath, nil -- all done, local file is up to date
    end

    if download_callback ~= nil then download_callback() end

    if API.settings:isTrue("webdav_enabled") then
        local result, errormsg = API.downloadWebDAV(key, targetDir, targetPath)
        if result == nil then
            return nil, errormsg
        end
    else
        local url = "https://api.zotero.org/users/" .. API.getUserID() .. "/items/" .. key .. "/file"
        print("Fetching " .. url)

        local r, c, h = http.request {
            url = url,
            headers = API.getHeaders(api_key),
            redirect = true,
            sink = ltn12.sink.file(io.open(targetPath, "wb"))
        }

        local e = API.verifyResponse(r, c)
        if e ~= nil then return nil, e end
    end

    local versionFile = io.open(targetDir .. "/version", "w")
    if versionFile == nil then
        return nil, "Could not write version file"
    end
    versionFile:write(tostring(attachment.version))
    versionFile:close()

    return targetPath, nil
end

function API.downloadWebDAV(key, targetDir, targetPath)
    if API.getWebDAVUrl() == nil then
        return nil, "WebDAV url not set"
    end
    local url = API.getWebDAVUrl() .. "/" .. key .. ".zip"
    local headers = API.getWebDAVHeaders()
    local zipPath = targetDir .. "/" .. key .. ".zip"
    print("Fetching URL " .. url)
    local r, c, h = http.request {
        method = "GET",
        url = url,
        headers = headers,
        redirect = true,
        sink = ltn12.sink.file(io.open(zipPath, "wb"))
    }

    if r ~= 1 then
        return nil, "Error: no network connection available. Please check your connection and try again. (" .. c .. ")"
    elseif c ~= 200 then
        return nil, "Download failed with status code " .. c
    end

    -- Zotero WebDAV storage packs documents inside a zipfile.
    -- Use KOReader's bundled libarchive instead of a system `unzip` binary
    -- (some devices, e.g. Android/Tolino, do not ship one).
    local reader = Archiver.Reader:new()
    if not reader:open(zipPath) then
        return nil, "Unzipping failed: could not open archive"
    end
    local ok = true
    for entry in reader:iterate() do
        if entry.mode == "file" and not reader:extractToPath(entry.path, targetDir .. "/" .. entry.path) then
            ok = false
            break
        end
    end
    local err = reader.err
    reader:close()
    os.remove(zipPath)
    if not ok then
        return nil, "Unzipping failed: " .. tostring(err)
    end

    return targetPath
end

function API.getWebDAVHeaders()
    local user = API.getWebDAVUser() or ""
    local pass = API.getWebDAVPassword() or ""

    return {
        ["Authorization"] = "Basic " .. sha2.bin_to_base64(user .. ":" .. pass)
    }
end

-- Return a table of entries of a collection.
--
-- If key is nil, entries of the root collection will be given.
-- Each entry is a table with at least two values, the key and name.
-- Collections will have a display name that ends with a slash and contain true
-- under the key "collection" in their table.
function API.displayCollection(key, sort_order, sort_desc)
    local result = {}

    -- Get list of collections
    local collections = API.getCollections()
    for k, collection in pairs(collections) do
        if (key == nil and collection.data.parentCollection == false) or
            (key ~= nil and collection.data.parentCollection == key) then
            table.insert(result, {
                ["key"] = k,
                ["text"] = collection.data.name .. "/",
                ["collection"] = true,
                ["title"] = collection.data.name,
            })
        end
    end
    -- Sort collections by name
    table.sort(result, function(a, b)
        return (a.title or a.text) < (b.title or b.text)
    end)

    -- Get list of items
    -- Careful: linear search. Can be optimized quite a bit!
    local items = API.getItems()
    local collectionItems = {}

    for k, item in pairs(items) do
        if item.data.itemType == "attachment"
            and table_contains(SUPPORTED_MEDIA_TYPES, item.data.contentType ) then

            if item.data.parentItem ~= nil then
                -- if we have a parent item, check whether it belongs to the collection
                -- we search for
                local parentItem = items[item.data.parentItem]
                if parentItem ~= nil and table_contains(parentItem.data.collections, key) then
                    local author = formatAuthor(parentItem.meta.creatorSummary) or "Unknown"
                    local title = parentItem.data.title or item.data.title or "Unknown Title"
                    local year = extractYear(parentItem.data.date)
                    local sub = author
                    if year ~= nil then
                        sub = sub .. " (" .. year .. ")"
                    end

                    table.insert(collectionItems, {
                        ["key"] = k,
                        ["text"] = title,
                        ["title"] = title,
                        ["sub"] = sub,
                        ["author"] = author,
                        ["year"] = year,
                        ["date_added"] = parentItem.data.dateAdded,
                        ["date_modified"] = parentItem.data.dateModified,
                    })
                end
            else
                -- item does not have metadata header
                if item.data.title ~= nil
                    and item.data.collections ~= nil
                    and table_contains(item.data.collections, key) then
                    local title = item.data.title
                    local year = extractYear(item.data.date)
                    local sub = year ~= nil and ("(" .. year .. ")") or nil

                    table.insert(collectionItems, {
                        ["key"] = k,
                        ["text"] = title,
                        ["title"] = title,
                        ["sub"] = sub,
                        ["author"] = formatAuthor(item.data.creatorSummary),
                        ["year"] = year,
                        ["date_added"] = item.data.dateAdded,
                        ["date_modified"] = item.data.dateModified,
                    })
                end
            end
        end
    end
    API.sortItems(collectionItems, sort_order, sort_desc)

    -- Join collections and items together and return it
    return joinTables(result, collectionItems)
end

function API.displaySearchResults(query, sort_order, sort_desc)
    print("displaySearchResults for " .. query)
    local queryRegex = ".*" .. string.gsub(string.lower(query), " ", ".*") .. ".*"
    print("Searching for " .. queryRegex)
    -- Careful: linear search. Can be optimized quite a bit!
    local items = API.getItems()
    local results = {}

    for k, item in pairs(items) do
        if item.data.itemType == "attachment"
            and table_contains(SUPPORTED_MEDIA_TYPES, item.data.contentType ) then
            if item.data.parentItem ~= nil and items[item.data.parentItem] ~= nil then
                local parentItem = items[item.data.parentItem]
                if parentItem ~= nil then
                    local author = formatAuthor(parentItem.meta.creatorSummary) or "Unknown"
                    local title = parentItem.data.title or item.data.title or "Unknown Title"
                    local year = extractYear(parentItem.data.date)
                    local sub = author
                    if year ~= nil then
                        sub = sub .. " (" .. year .. ")"
                    end
                    -- Used for matching only: title, first author, year and DOI.
                    local match_text = title .. " " .. author .. " "
                        .. (year or "") .. " " .. (parentItem.data.DOI or "")

                    if string.match(string.lower(match_text), queryRegex) then
                        table.insert(results, {
                            ["key"] = k,
                            ["text"] = title,
                            ["title"] = title,
                            ["sub"] = sub,
                            ["author"] = author,
                            ["year"] = year,
                            ["date_added"] = parentItem.data.dateAdded,
                            ["date_modified"] = parentItem.data.dateModified,
                        })
                    end
                end
            elseif item.data ~= nil and item.data.title ~= nil then
                -- item does not have metadata header, match against title directly
                local title = item.data.title
                if string.match(string.lower(title), queryRegex) then
                        table.insert(results, {
                            ["key"] = k,
                            ["text"] = title,
                            ["title"] = title,
                            ["author"] = formatAuthor(item.data.creatorSummary),
                            ["year"] = extractYear(item.data.date),
                            ["date_added"] = item.data.dateAdded,
                            ["date_modified"] = item.data.dateModified,
                        })
                end
            end
        end
    end

    API.sortItems(results, sort_order, sort_desc)

    return results
end


-- Output the timezone-agnostic timestamp, since KOReader uses timestamps with
-- local time.
function API.addTimezone(timestamp)
    local year, month, day, hour, minute, second = string.match(timestamp,
        "(%d%d%d%d)-(%d%d)-(%d%d) (%d%d):(%d%d):(%d%d)")
    local time = {
        ["year"] = year,
        ["month"] = month,
        ["day"] = day,
        ["hour"] = hour,
        ["min"] = minute,
        ["sec"] = second
    }

    return os.date("!%Y-%m-%dT%H:%M:%SZ", os.time(time))
end

function API.localTimezone(timestamp)
end

function API.compareTimestamps(zoteroTimestamp, koreaderTimestamp)
    local a,b = zoteroTimestamp, API.addTimezone(koreaderTimestamp)

    if a == b then
       return 0
    elseif a < b then
        return -1
    else
        return 1
    end
end

function API.syncModifiedItems()
    local modItems = API.getModifiedItems()
end

function API.resetSyncState()
    API.setItems({})
    API.setCollections({})
    API.setLibraryVersion(0)
end

return API
