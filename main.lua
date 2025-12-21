local Device = require("device")
local InputContainer = require("ui/widget/container/inputcontainer")
local NetworkMgr = require("ui/network/manager")
local _ = require("gettext")

local Dialogs = require("dialogs")
local showChatGPTDialog = Dialogs.showChatGPTDialog
local showCustomPromptResult = Dialogs.showCustomPromptResult
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
end

return AskGPT