local Blitbuffer = require("ffi/blitbuffer")
local Dispatcher = require("dispatcher")  -- luacheck:ignore
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local SpinWidget = require("ui/widget/spinwidget")
local DataStorage = require("datastorage")
local FrameContainer = require("ui/widget/container/framecontainer")
local Device = require("device")
local Screen = Device.screen
local Font = require("ui/font")
local Geom = require("ui/geometry")
local InputContainer = require("ui/widget/container/inputcontainer")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local OverlapGroup = require("ui/widget/overlapgroup")
local CenterContainer = require("ui/widget/container/centercontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local RightContainer = require("ui/widget/container/rightcontainer")
local TextWidget = require("ui/widget/textwidget")
local Button = require("ui/widget/button")
local LineWidget = require("ui/widget/linewidget")
local GestureRange = require("ui/gesturerange")
local Size = require("ui/size")
local _ = require("gettext")
local ZoteroAPI = require("zoteroapi")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local lfs = require("libs/libkoreader-lfs")


local DEFAULT_LINES_PER_PAGE = 14

local table_empty = function(table)
    -- see https://stackoverflow.com/a/1252776
    local next = next
    return (next(table) == nil)
end

local ZoteroItemRow = InputContainer:extend{
    width = nil, -- set by the browser, used for layout
    title = "",
    sub = nil, -- smaller second line: author and year
    is_dim = false,
    tappable = true,
    callback = nil,
}

function ZoteroItemRow:init()
    self.title_face = Font:getFace("smallinfofont")
    self.sub_face = Font:getFace("infont")

    local pad_h = Size.padding.large
    local pad_v = Size.padding.small
    local gap = Size.span.vertical_default
    local content_w = self.width - 2 * pad_h

    local title_widget = TextWidget:new{
        text = self.title,
        face = self.title_face,
        max_width = content_w,
        fgcolor = self.is_dim and Blitbuffer.COLOR_DARK_GRAY or nil,
    }
    local title_h = title_widget:getSize().h

    local sub_widget
    local sub_h = 0
    if self.sub ~= nil then
        sub_widget = TextWidget:new{
            text = self.sub,
            face = self.sub_face,
            max_width = content_w,
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        }
        sub_h = sub_widget:getSize().h
    end

    local row_h = pad_v + title_h + (self.sub ~= nil and (gap + sub_h) or 0) + pad_v
    self.dimen = Geom:new{
        w = self.width,
        h = row_h,
    }

    if self.tappable then
        self.ges_events = {
            TapSelect = {
                GestureRange:new{
                    ges = "tap",
                    range = self.dimen,
                },
            },
        }
    end

    local content = {
        VerticalSpan:new{ width = pad_v },
        title_widget,
    }
    if sub_widget ~= nil then
        table.insert(content, VerticalSpan:new{ width = gap })
        table.insert(content, sub_widget)
    end
    table.insert(content, VerticalSpan:new{ width = pad_v })

    self.content_top_pad = pad_v
    self.content_bottom_pad = pad_v

    self[1] = HorizontalGroup:new{
        align = "top",
        HorizontalSpan:new{ width = pad_h },
        VerticalGroup:new{
            align = "left",
            unpack(content),
        },
        HorizontalSpan:new{ width = pad_h },
    }
end

function ZoteroItemRow:onTapSelect()
    if self.callback ~= nil then
        self.callback()
    end
    return true
end

local ZoteroBrowser = InputContainer:extend{
    no_title = false,
    is_borderless = true,
    is_popout = false,
    parent = nil,
    covers_full_screen = true,
    current_items = {},
}


function ZoteroBrowser:init()
    self.paths = {}
    self.current_items = {}
    if Device:hasKeys() then
        self.key_events.Back = { { Device.input.group.Back } }
    end
end

function ZoteroBrowser:onBack()
    return self:onReturn()
end

-- Show search input
function ZoteroBrowser:onLeftButtonTap()
    table.insert(self.paths, "search")
    local search_query_dialog
    search_query_dialog = InputDialog:new{
        title = _("Search Zotero titles"),
        input = "",
        input_hint = "search query",
        description = _("This will search title, first author and DOI of all entries."),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(search_query_dialog)
                    end,
                },
                {
                    text = _("Search"),
                    is_enter_default = true,
                    callback = function()
                        UIManager:close(search_query_dialog)
                        self:displaySearchResults(search_query_dialog:getInputText())
                    end,
                },
            }
        }
    }
    UIManager:show(search_query_dialog)
    search_query_dialog:onShowKeyboard()
end


function ZoteroBrowser:onReturn()
    table.remove(self.paths, #self.paths)
    if #self.paths == 0 then
        self:displayCollection(nil)
    else
        self:displayCollection(self.paths[#self.paths])
    end
    return true
end


function ZoteroBrowser:onMenuSelect(item)
    if item.collection ~= nil then
        table.insert(self.paths, item.key)
        self:displayCollection(item.key)
    elseif item.wildcard_collection ~= nil then
        table.insert(self.paths, "root")
        self:displaySearchResults("")
    elseif item.is_label ~= nil then
        -- nop
    else
        self.download_dialog = InfoMessage:new{
            text = _("Downloading file"),
            timeout = 5,
            icon = "notice-info",
        }
        UIManager:scheduleIn(0.05, function()
            local full_path, e = ZoteroAPI.downloadAndGetPath(item.key)
            if e ~= nil then
                local b = InfoMessage:new{
                    text = _("Could not open file.") .. e,
                    timeout = 5,
                    icon = "notice-warning"
                }
                UIManager:show(b)
            else
                UIManager:close(self.download_dialog)
                local ReaderUI = require("apps/reader/readerui")
                self.close_callback()
                ReaderUI:showReader(full_path)
            end
        end)
        UIManager:show(self.download_dialog)
    end
end

function ZoteroBrowser:displaySearchResults(query)
    local items = ZoteroAPI.displaySearchResults(query)
    if table_empty(items) then
        table.insert(items, 1, {
            ["text"] = _("No Results"),
            ["is_label"] = true,
        })
    end
    self:setItems(items)
end

function ZoteroBrowser:displayCollection(collection_id)
    local items = ZoteroAPI.displayCollection(collection_id)

    if collection_id == nil then
        table.insert(items, 1, {
            ["text"] = _("All Items"),
            ["wildcard_collection"] = true
        })
    end

    if table_empty(items) then
        table.insert(items, 1, {
            ["text"] = _("No Items"),
            ["is_label"] = true,
        })
    end

    self:setItems(items)
end

function ZoteroBrowser:_button(text, callback)
    return Button:new{
        text = text,
        bordersize = 0,
        callback = callback,
        show_parent = self,
    }
end

function ZoteroBrowser:updateHeader()
    local screen_w = Screen:getWidth()

    local left_parts = {}
    if #self.paths > 0 then
        table.insert(left_parts, self:_button(_("Back"), function()
            self:onReturn()
        end))
    end
    local title_widget = TextWidget:new{
        text = "Zotero",
        face = Font:getFace("tfont"),
    }
    table.insert(left_parts, HorizontalSpan:new{ width = Size.span.horizontal_default })
    table.insert(left_parts, title_widget)
    local left_group = HorizontalGroup:new{ align = "center", unpack(left_parts) }

    local search_button = self:_button(_("Search"), function()
        self:onLeftButtonTap()
    end)

    local header_h = title_widget:getSize().h
    if #self.paths > 0 then
        header_h = math.max(header_h, left_parts[1]:getSize().h)
    end
    header_h = math.max(header_h, search_button:getSize().h) + 2 * Size.padding.small
    self.header_h = header_h

    self.header = FrameContainer:new{
        padding = 0,
        bordersize = 0,
        margin = 0,
        HorizontalGroup:new{
            align = "center",
            OverlapGroup:new{
                dimen = Geom:new{ w = screen_w, h = header_h },
                LeftContainer:new{
                    dimen = Geom:new{ w = screen_w, h = header_h },
                    left_group,
                },
                RightContainer:new{
                    dimen = Geom:new{ w = screen_w, h = header_h },
                    search_button,
                },
            },
        },
    }
end

function ZoteroBrowser:updateList()
    self:updateHeader()

    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()
    local inner_w = screen_w - ScrollableContainer:getScrollbarWidth()
    local list_h = screen_h - self.header_h - Size.line.medium

    local rows = {}
    local content_h = 0
    local top_bound = 0
    local pad_v = Size.padding.small
    local step_scroll_grid = {}
    for i, item in ipairs(self.current_items) do
        local row = ZoteroItemRow:new{
            width = inner_w,
            title = item.title or item.text or "",
            sub = item.sub,
            is_dim = item.is_label == true,
            tappable = item.is_label ~= true,
            callback = function()
                self:onMenuSelect(item)
            end,
        }
        table.insert(rows, row)
        content_h = content_h + row.dimen.h
        local bottom_bound = top_bound + row.dimen.h - 1
        step_scroll_grid[i] = {
            top = top_bound,
            bottom = bottom_bound,
            content_top = top_bound + pad_v,
            content_bottom = bottom_bound - pad_v,
            row_num = i,
        }
        top_bound = top_bound + row.dimen.h
    end
    local content_group = VerticalGroup:new{ align = "left", unpack(rows) }

    self.scroll_container = ScrollableContainer:new{
        dimen = Geom:new{ w = screen_w, h = list_h },
        show_parent = self.show_parent or self,
        step_scroll_grid = step_scroll_grid,
        hide_truncated_grid_items = true,
        CenterContainer:new{
            dimen = Geom:new{ w = inner_w, h = content_h },
            content_group,
        },
    }
    self.scroll_container:initState()
    print("Z: rows=" .. #rows
        .. " content_h=" .. content_h
        .. " list_h=" .. list_h
        .. " scrollable=" .. tostring(self.scroll_container._is_scrollable))
    self.cropping_widget = self.scroll_container
    if self.show_parent ~= nil then
        self.show_parent.cropping_widget = self.scroll_container
    end

    self.body = VerticalGroup:new{
        align = "center",
        self.header,
        LineWidget:new{
            dimen = Geom:new{ w = screen_w, h = Size.line.medium },
        },
        self.scroll_container,
    }
    self.dimen = Geom:new{ w = screen_w, h = screen_h }
    self[1] = self.body
end

function ZoteroBrowser:setItems(items)
    self.current_items = items
    self:updateList()
    if self.refresh_callback ~= nil then
        self.refresh_callback()
    end
end

local Plugin = WidgetContainer:new{
    name = "zotero",
    is_doc_only = false
}

function Plugin:onDispatcherRegisterActions()
    Dispatcher:registerAction("zotero_open_action", {
        category="none",
        event="ZoteroOpenAction",
        title=_("Zotero Open"),
        general=true,
    })
    Dispatcher:registerAction("zotero_sync_action", {
        category="none",
        event="ZoteroSyncAction",
        title=_("Zotero Sync"),
        general=true
    })
end

function Plugin:init()
    self.initialized = false
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    xpcall(self.initAPIAndBrowser, self.initError, self)
    self.initialized = true
    print("Z: successfully initialized!")
end

function Plugin:initError(e)
    print("Could not initialize Zotero: " .. e)
end

function Plugin:checkInitialized()
    if not self.initialized  or self.browser == nil then
        UIManager:show(InfoMessage:new{
            text = _("Zotero not initialized. Please set the plugin directory first."),
            timeout = 3,
            icon = "notice-warning"
        })
    end

    return self.initialized
end

function Plugin:initAPIAndBrowser()
    self.zotero_dir_path = DataStorage:getDataDir() .. "/zotero"
    lfs.mkdir(self.zotero_dir_path)
    ZoteroAPI.init(self.zotero_dir_path)
    self.small_font_face = Font:getFace("smallffont")
    self.browser = ZoteroBrowser:new{
        refresh_callback = function()
            local need_full = self.browser.scroll_container
                and self.browser.scroll_container._is_scrollable == false
            UIManager:setDirty(self.zotero_dialog, need_full and "full" or "ui")
            self.ui:onRefresh()
        end,
        close_callback = function()
            UIManager:close(self.zotero_dialog, "full")
        end,
		items_per_page = self:getItemsPerPage()
    }
    self.zotero_dialog = FrameContainer:new{
        padding = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        self.browser
    }
    self.browser.show_parent = self.zotero_dialog
    print("Z: Browser initialized")
end

function Plugin:addToMainMenu(menu_items)
    menu_items.zotero = {
        text = _("Zotero"),
        sorting_hint = "search",
        sub_item_table = {
            {
                text = _("Browse"),
                callback = function()
                    self:onZoteroOpenAction()
                end,
            },
            {
                text = _("Synchronize"),
                callback = function()
                    self:onZoteroSyncAction()
                end,

            },
            {
                text = _("Maintenance"),
                callback = function()
                    return nil
                end,
                sub_item_table = {
                    {
                        text = _("Resync entire collection"),
                        callback = function()
                            ZoteroAPI.resetSyncState()
                            self:onZoteroSyncAction()
                        end,
                    },
                },
            },
            {
                text = _("Settings"),
                callback = function()
                    return nil
                end,
                sub_item_table = {
                    {
                        text = _("Configure Zotero account"),
                        callback = function()
                            self:setAccount()
                        end,
                    },
                    {
                        text = _("Enable WebDAV storage"),
                        checked_func = function()
                            return ZoteroAPI.getWebDAVEnabled()
                        end,
                        callback = function()
                            ZoteroAPI.toggleWebDAVEnabled()
                        end,
                    },
                    {
                        text = _("Configure WebDAV account"),
                        callback = function()
                            self:setWebdavAccount()
                        end,
                    },
                    {
                        text = _("Check WebDAV connection"),
                        callback = function()
                            local msg = nil
                            local result = ZoteroAPI.checkWebDAV()
                            if result == nil then
                                msg = _("Success, WebDAV works!")
                            else
                                msg = _("WebDAV could not connect: ") .. result
                            end
                            UIManager:show(InfoMessage:new{
                                text = msg,
                                timeout = 3,
                                icon = "notice-info"
                            })
                        end,
                    },
                    {
                        text = _("Items per page"),
                        callback = function()
                            self:setItemsPerPage()
                        end,

                    },
                }
            }
        },
    }
end

function Plugin:setAccount()
    self.account_dialog = MultiInputDialog:new{
        title = _("Edit User Info"),
        fields = {
            {
                text = ZoteroAPI.getUserID(),
                hint = _("User ID (integer)"),
            },
            {
                text = ZoteroAPI.getAPIKey(),
                hint = _("API Key"),
            },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        self.account_dialog:onClose()
                        UIManager:close(self.account_dialog)
                    end
                },
                {
                    text = _("Update"),
                    callback = function()
                        local fields = self.account_dialog:getFields()
                        if not string.match(fields[1], "[0-9]+") then
                            UIManager:show(InfoMessage:new{
                                text = _("The User ID must be an integer number."),
                                timeout = 3,
                                icon = "notice-warning"
                            })
                            return
                        end

                        ZoteroAPI.setUserID(fields[1])
                        ZoteroAPI.setAPIKey(fields[2])
                        ZoteroAPI.saveModifiedItems()
                        self.account_dialog:onClose()
                        UIManager:close(self.account_dialog)
                    end
                },
            },
        },
    }
    UIManager:show(self.account_dialog)
    self.account_dialog:onShowKeyboard()
end

function Plugin:setWebdavAccount()
    self.webdav_account_dialog = MultiInputDialog:new{
        title = _("Edit WebDAV credentials"),
        fields = {
            {
                text = ZoteroAPI.getWebDAVUrl(),
                hint = _("URL")
            },
            {
                text = ZoteroAPI.getWebDAVUser(),
                hint = _("Username"),
            },
            {
                text = ZoteroAPI.getWebDAVPassword(),
                hint = _("Password"),
            },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        self.webdav_account_dialog:onClose()
                        UIManager:close(self.webdav_account_dialog)
                    end
                },
                {
                    text = _("Update"),
                    callback = function()
                        local fields = self.webdav_account_dialog:getFields()

                        ZoteroAPI.setWebDAVUrl(fields[1])
                        ZoteroAPI.setWebDAVUser(fields[2])
                        ZoteroAPI.setWebDAVPassword(fields[3])
                        ZoteroAPI.saveModifiedItems()
                        self.webdav_account_dialog:onClose()
                        UIManager:close(self.webdav_account_dialog)
                    end
                },
            },
        },
    }
    UIManager:show(self.webdav_account_dialog)
    self.webdav_account_dialog:onShowKeyboard()
end

function Plugin:setItemsPerPage()
    assert(ZoteroAPI.getSettings ~= nil)
	print("setting to " .. self:getItemsPerPage())
    self.items_per_page_dialog = SpinWidget:new {
        title_text = _("Set items per page"),
        value = self:getItemsPerPage(),
		value_min = 1,
		value_max = 1000,
        callback = function(d)
						ZoteroAPI.getSettings():saveSetting("items_per_page", d.value)
						ZoteroAPI.getSettings():flush()
                        UIManager:show(InfoMessage:new{
                            text = _("This change requires a restart of KOReader to take effect."),
                            timeout = 3,
                            icon = "notice"
                        })
                    end,
    }
	UIManager:show(self.items_per_page_dialog)
end

function Plugin:getItemsPerPage()
    return ZoteroAPI.getSettings():readSetting("items_per_page", DEFAULT_LINES_PER_PAGE)
end

function Plugin:onZoteroOpenAction()
    if not self:checkInitialized() then
        return
    end

    self.browser:init()
    UIManager:show(self.zotero_dialog, "full", Geom:new{
        w = Screen:getWidth(),
        h = Screen:getHeight()
    })
    self.browser:displayCollection(nil)
end

function Plugin:onZoteroSyncAction()
    if not self:checkInitialized() then
        return
    end
    UIManager:scheduleIn(1, function()
        local e = ZoteroAPI.syncAllItems()

        if e == nil then
            UIManager:show(InfoMessage:new{
                text = _("Success."),
                timeout = 3,
                icon = "check"
            })
        else
            UIManager:show(InfoMessage:new{
                text = e,
                timeout = 3,
                icon = "notice-warning"
            })
        end
    end)

    UIManager:show(InfoMessage:new{
        text = _("Synchronizing Zotero library. This might take some time."),
        timeout = 3,
        icon = "notice-info"
    })

end

return Plugin
