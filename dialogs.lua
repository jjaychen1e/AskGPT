local InputDialog = require("ui/widget/inputdialog")
local ChatGPTViewer = require("chatgptviewer")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local _ = require("gettext")

local queryChatGPT = require("gpt_query")

local CONFIGURATION = nil
local buttons, input_dialog

local success, result = pcall(function() return require("configuration") end)
if success then
  CONFIGURATION = result
else
  print("configuration.lua not found, skipping...")
end

local function showCustomPromptResult(ui, highlightedText, buttonConfig, userInput)
  local title, author =
    ui.document:getProps().title or _("Unknown Title"),
    ui.document:getProps().authors or _("Unknown Author")

  -- Check if original prompt contains {text} placeholder
  local hasTextPlaceholder = buttonConfig.prompt:find("{text}")

  -- Replace {text} placeholder with highlighted text
  local prompt = buttonConfig.prompt:gsub("{text}", highlightedText)
  -- Replace {input} placeholder with user input if provided
  if userInput then
    prompt = prompt:gsub("{input}", userInput)
  end

  -- Build context message conditionally to avoid duplicating highlighted text
  local contextMessage
  if hasTextPlaceholder then
    -- Text is already in the prompt, just add book context
    contextMessage = "I'm reading something titled '" .. title .. "' by " .. author .. ".\n\n" .. prompt
  else
    -- Include highlighted text in context
    contextMessage = "I'm reading something titled '" .. title .. "' by " .. author ..
      ". About the following text: " .. highlightedText .. "\n\n" .. prompt
  end

  local message_history = {
    {
      role = "system",
      content = "The following is a conversation with an AI assistant. The assistant is helpful, creative, clever, and very friendly. Answer as concisely as possible. You may use simple markdown formatting like bold, italic, bullet points, and code blocks, but avoid complex formatting such as tables"
    },
    {
      role = "user",
      content = contextMessage
    }
  }

  local options = {}
  if buttonConfig.model then
    options.model = buttonConfig.model
  end

  local function handleNewQuestion(chatgpt_viewer, question)
    table.insert(message_history, {
      role = "user",
      content = question
    })

    local answer = queryChatGPT(message_history, options)

    table.insert(message_history, {
      role = "assistant",
      content = answer
    })

    local result_text = ""
    if not buttonConfig.hide_highlighted_text then
      result_text = _("Highlighted text: ") .. "\"" .. highlightedText .. "\"\n\n"
    end
    -- Start from index 3 if hiding first user prompt, else 2
    local start_idx = buttonConfig.hide_user_prompt and 3 or 2
    for i = start_idx, #message_history do
      if message_history[i].role == "user" then
        result_text = result_text .. _("User: ") .. message_history[i].content .. "\n\n"
      else
        result_text = result_text .. _("ChatGPT: ") .. message_history[i].content .. "\n\n"
      end
    end

    chatgpt_viewer:update(result_text)
  end

  local loading = InfoMessage:new{
    text = _("Loading..."),
    timeout = 0.1
  }
  UIManager:show(loading)

  UIManager:scheduleIn(0.1, function()
    local answer = queryChatGPT(message_history, options)

    table.insert(message_history, {
      role = "assistant",
      content = answer
    })

    local result_text = ""
    if not buttonConfig.hide_highlighted_text then
      result_text = _("Highlighted text: ") .. "\"" .. highlightedText .. "\"\n\n"
    end
    if not buttonConfig.hide_user_prompt then
      result_text = result_text .. _("User: ") .. message_history[2].content .. "\n\n"
    end
    result_text = result_text .. _("ChatGPT: ") .. answer .. "\n\n"

    local chatgpt_viewer = ChatGPTViewer:new {
      title = buttonConfig.label or _("AskGPT"),
      text = result_text,
      onAskQuestion = handleNewQuestion
    }

    UIManager:show(chatgpt_viewer)
  end)
end

-- Wrapper function that handles allow_input option
local function handleCustomButton(ui, highlightedText, buttonConfig)
  if buttonConfig.allow_input then
    -- Show input dialog first
    local custom_input_dialog
    custom_input_dialog = InputDialog:new{
      title = _(buttonConfig.label or "Enter additional details"),
      input_hint = _("Type your input here..."),
      input_type = "text",
      buttons = {{
        {
          text = _("Cancel"),
          callback = function()
            UIManager:close(custom_input_dialog)
          end
        },
        {
          text = _("Submit"),
          callback = function()
            local userInput = custom_input_dialog:getInputText()
            UIManager:close(custom_input_dialog)
            showCustomPromptResult(ui, highlightedText, buttonConfig, userInput)
          end
        }
      }}
    }
    UIManager:show(custom_input_dialog)
  else
    -- Execute immediately without input
    showCustomPromptResult(ui, highlightedText, buttonConfig, nil)
  end
end

local function translateText(text, target_language)
  local translation_message = {
    role = "user",
    content = "Translate the following text to " .. target_language .. ": " .. text
  }
  local translation_history = {
    {
      role = "system",
      content = "You are a helpful translation assistant. Provide direct translations without additional commentary."
    },
    translation_message
  }
  return queryChatGPT(translation_history)
end

local function createResultText(highlightedText, message_history)
  local result_text = _("Highlighted text: ") .. "\"" .. highlightedText .. "\"\n\n"

  for i = 3, #message_history do
    if message_history[i].role == "user" then
      result_text = result_text .. _("User: ") .. message_history[i].content .. "\n\n"
    else
      result_text = result_text .. _("ChatGPT: ") .. message_history[i].content .. "\n\n"
    end
  end

  return result_text
end

local function showLoadingDialog()
  local loading = InfoMessage:new{
    text = _("Loading..."),
    timeout = 0.1
  }
  UIManager:show(loading)
end

local function showChatGPTDialog(ui, highlightedText, message_history)
  local title, author =
    ui.document:getProps().title or _("Unknown Title"),
    ui.document:getProps().authors or _("Unknown Author")
  local message_history = message_history or {{
    role = "system",
    content = "The following is a conversation with an AI assistant. The assistant is helpful, creative, clever, and very friendly. Answer as concisely as possible. You may use simple markdown formatting like bold, italic, bullet points, and code blocks, but avoid complex formatting such as tables."
  }}

  local function handleNewQuestion(chatgpt_viewer, question)
    table.insert(message_history, {
      role = "user",
      content = question
    })

    local answer = queryChatGPT(message_history)

    table.insert(message_history, {
      role = "assistant",
      content = answer
    })

    local result_text = createResultText(highlightedText, message_history)

    chatgpt_viewer:update(result_text)
  end

  buttons = {
    {
      text = _("Cancel"),
      callback = function()
        UIManager:close(input_dialog)
      end
    },
    {
      text = _("Ask"),
      callback = function()
        local question = input_dialog:getInputText()
        UIManager:close(input_dialog)
        showLoadingDialog()

        UIManager:scheduleIn(0.1, function()
          local context_message = {
            role = "user",
            content = "I'm reading something titled '" .. title .. "' by " .. author ..
              ". I have a question about the following highlighted text: " .. highlightedText
          }
          table.insert(message_history, context_message)

          local question_message = {
            role = "user",
            content = question
          }
          table.insert(message_history, question_message)

          local answer = queryChatGPT(message_history)
          local answer_message = {
            role = "assistant",
            content = answer
          }
          table.insert(message_history, answer_message)

          local result_text = createResultText(highlightedText, message_history)

          local chatgpt_viewer = ChatGPTViewer:new {
            title = _("AskGPT"),
            text = result_text,
            onAskQuestion = handleNewQuestion
          }

          UIManager:show(chatgpt_viewer)
        end)
      end
    }
  }

  if CONFIGURATION and CONFIGURATION.features and CONFIGURATION.features.translate_to then
    table.insert(buttons, {
      text = _("Translate"),
      callback = function()
        showLoadingDialog()

        UIManager:scheduleIn(0.1, function()
          local translated_text = translateText(highlightedText, CONFIGURATION.features.translate_to)

          table.insert(message_history, {
            role = "user",
            content = "Translate to " .. CONFIGURATION.features.translate_to .. ": " .. highlightedText
          })

          table.insert(message_history, {
            role = "assistant",
            content = translated_text
          })

          local result_text = createResultText(highlightedText, message_history)
          local chatgpt_viewer = ChatGPTViewer:new {
            title = _("Translation"),
            text = result_text,
            onAskQuestion = handleNewQuestion
          }

          UIManager:show(chatgpt_viewer)
        end)
      end
    })
  end

  input_dialog = InputDialog:new{
    title = _("Ask a question about the highlighted text"),
    input_hint = _("Type your question here..."),
    input_type = "text",
    buttons = {buttons}
  }
  UIManager:show(input_dialog)
end

return {
  showChatGPTDialog = showChatGPTDialog,
  showCustomPromptResult = handleCustomButton
}