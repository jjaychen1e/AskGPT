local Device = require("device")
local InputContainer = require("ui/widget/container/inputcontainer")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local Menu = require("ui/widget/menu")
local CenterContainer = require("ui/widget/container/centercontainer")
local Screen = Device.screen
local _ = require("gettext")

local Dialogs = require("dialogs")
local showChatGPTDialog = Dialogs.showChatGPTDialog
local showCustomPromptResult = Dialogs.showCustomPromptResult
local ChatHistory = require("chat_history")
local UpdateChecker = require("update_checker")

-- Load configuration
local CONFIGURATION = nil
local success, result = pcall(function() return require("configuration") end)
if success then
  CONFIGURATION = result
end

local AskGPT = InputContainer:new {
  name = "askgpt",
  is_doc_only = true,
}

-- Flag to ensure the update message is shown only once per session
local updateMessageShown = false

function AskGPT:init()
  -- Register the default "Ask ChatGPT" button
  self.ui.highlight:addToHighlightDialog("askgpt_ChatGPT", function(_reader_highlight_instance)
    return {
      text = _("Ask ChatGPT"),
      enabled = Device:hasClipboard(),
      callback = function()
        NetworkMgr:runWhenOnline(function()
          if not updateMessageShown then
            UpdateChecker.checkForUpdates()
            updateMessageShown = true -- Set flag to true so it won't show again
          end
          showChatGPTDialog(self.ui, _reader_highlight_instance.selected_text.text)
        end)
      end,
    }
  end)

  -- Register custom buttons from configuration
  if CONFIGURATION and CONFIGURATION.custom_buttons then
    for i, buttonConfig in ipairs(CONFIGURATION.custom_buttons) do
      local buttonKey = "askgpt_custom_" .. i
      self.ui.highlight:addToHighlightDialog(buttonKey, function(_reader_highlight_instance)
        return {
          text = _(buttonConfig.label or ("Custom " .. i)),
          enabled = Device:hasClipboard(),
          callback = function()
            NetworkMgr:runWhenOnline(function()
              if not updateMessageShown then
                UpdateChecker.checkForUpdates()
                updateMessageShown = true
              end
              showCustomPromptResult(self.ui, _reader_highlight_instance.selected_text.text, buttonConfig)
            end)
          end,
        }
      end)
    end
  end

  self.ui.menu:registerToMainMenu(self)
end

function AskGPT:addToMainMenu(menu_items)
  menu_items.askgpt_history = {
    text = _("AskGPT Chat History"),
    sorting_hint = "tools",
    callback = function()
      self:showHistoryBrowser()
    end,
  }
end

function AskGPT:showHistoryBrowser()
  local doc_file = self.ui.document.file
  local sessions = ChatHistory.list(doc_file)

  if #sessions == 0 then
    UIManager:show(InfoMessage:new{
      text = _("No saved chat history for this book."),
    })
    return
  end

  local menu_items = {}
  for _, s in ipairs(sessions) do
    local date_str = os.date("%Y-%m-%d %H:%M", s.updated_at)
    table.insert(menu_items, {
      text = s.title,
      mandatory = date_str,
      id = s.id,
    })
  end

  local history_menu
  local history_container
  history_menu = Menu:new {
    title = _("Chat History"),
    item_table = menu_items,
    width = Screen:getWidth() - Screen:scaleBySize(30),
    height = Screen:getHeight() - Screen:scaleBySize(30),
    onMenuSelect = function(self_menu, item)
      UIManager:close(history_container)
      self:resumeChat(item.id)
    end,
    onMenuHold = function(self_menu, item)
      self:showSessionOptions(item.id, item.text, function()
        UIManager:close(history_container)
        self:showHistoryBrowser()
      end)
    end,
    close_callback = function()
      UIManager:close(history_container)
    end,
  }
  history_container = CenterContainer:new {
    dimen = Screen:getSize(),
    history_menu,
  }
  UIManager:show(history_container)
end

function AskGPT:resumeChat(session_id)
  local session_data = ChatHistory.load(session_id)
  if not session_data then
    UIManager:show(InfoMessage:new{
      text = _("Failed to load chat session."),
    })
    return
  end
  NetworkMgr:runWhenOnline(function()
    Dialogs.resumeSession(self.ui, session_data)
  end)
end

function AskGPT:showSessionOptions(session_id, title, refresh_callback)
  local ButtonDialogTitle = require("ui/widget/buttondialogtitle")
  local options_dialog
  options_dialog = ButtonDialogTitle:new {
    title = title,
    buttons = {
      {
        {
          text = _("Delete"),
          callback = function()
            ChatHistory.delete(session_id)
            UIManager:close(options_dialog)
            if refresh_callback then
              refresh_callback()
            end
          end,
        },
      },
      {
        {
          text = _("Cancel"),
          callback = function()
            UIManager:close(options_dialog)
          end,
        },
      },
    },
  }
  UIManager:show(options_dialog)
end

return AskGPT
