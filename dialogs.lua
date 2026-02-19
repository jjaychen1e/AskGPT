local InputDialog = require("ui/widget/inputdialog")
local ChatGPTViewer = require("chatgptviewer")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local _ = require("gettext")

local GPT = require("gpt_query")
local queryChatGPT = GPT.query
local queryChatGPTStreamAsync = GPT.streamAsync
local isStreamingEnabled = GPT.isStreamingEnabled
local ChatHistory = require("chat_history")

local CONFIGURATION = nil
local buttons, input_dialog

local success, result = pcall(function() return require("configuration") end)
if success then
  CONFIGURATION = result
else
  print("configuration.lua not found, skipping...")
end

local function getBookInfo(ui)
  local props = ui.document:getProps()
  local title = props.title
  if not title or title == "" then
    local filepath = ui.document.file or ""
    title = filepath:match("([^/]+)%.[^%.]+$") or _("Unknown Title")
  end
  local author = props.authors
  if not author or author == "" then
    author = _("Unknown Author")
  end
  return title, author, ui.document.file
end

local function showCustomPromptResult(ui, highlightedText, buttonConfig, userInput)
  local title, author, doc_file = getBookInfo(ui)

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

  local session = {
    message_history = message_history,
    highlighted_text = highlightedText,
    book_title = title,
    book_authors = author,
    doc_file = doc_file,
    button_label = buttonConfig.label or "Custom",
  }

  local options = {}
  if buttonConfig.model then
    options.model = buttonConfig.model
  end

  -- Helper to build full conversation result text
  local function buildFullResultText()
    local result_text = ""
    if not buttonConfig.hide_highlighted_text then
      result_text = _("Highlighted text: ") .. "\"" .. highlightedText .. "\"\n\n"
    end
    local start_idx = buttonConfig.hide_user_prompt and 3 or 2
    for i = start_idx, #message_history do
      if message_history[i].role == "user" then
        result_text = result_text .. _("User: ") .. message_history[i].content .. "\n\n"
      else
        result_text = result_text .. _("ChatGPT: ") .. message_history[i].content .. "\n\n"
      end
    end
    return result_text
  end

  -- Helper to build result text with streaming partial content
  local function buildStreamingResultText(partial_content)
    local result_text = ""
    if not buttonConfig.hide_highlighted_text then
      result_text = _("Highlighted text: ") .. "\"" .. highlightedText .. "\"\n\n"
    end
    local start_idx = buttonConfig.hide_user_prompt and 3 or 2
    for i = start_idx, #message_history do
      if message_history[i].role == "user" then
        result_text = result_text .. _("User: ") .. message_history[i].content .. "\n\n"
      else
        result_text = result_text .. _("ChatGPT: ") .. message_history[i].content .. "\n\n"
      end
    end
    result_text = result_text .. _("ChatGPT: ") .. partial_content .. "\n\n"
    return result_text
  end

  local function handleNewQuestion(chatgpt_viewer, question)
    table.insert(message_history, {
      role = "user",
      content = question
    })

    if isStreamingEnabled() then
      -- Show generating indicator
      chatgpt_viewer:update(buildStreamingResultText(_("Generating...") .. " ▌"))

      local streamState = queryChatGPTStreamAsync(message_history, options,
        -- onChunk callback
        function(partial_content)
          chatgpt_viewer:update(buildStreamingResultText(partial_content .. " ▌"))
        end,
        -- onComplete callback
        function(final_content, err)
          if err then
            chatgpt_viewer:update(buildStreamingResultText(_("Error: ") .. tostring(err)))
            return
          end
          table.insert(message_history, {
            role = "assistant",
            content = final_content
          })
          session.title = session.title or ChatHistory.deriveTitle(message_history, highlightedText)
          ChatHistory.save(session)
          chatgpt_viewer:update(buildFullResultText())
        end
      )

      if streamState then
        local function doPoll()
          if streamState.poll() then
            UIManager:scheduleIn(0.1, doPoll)
          end
        end
        UIManager:scheduleIn(0.1, doPoll)
      end
    else
      -- Non-streaming fallback
      local answer = queryChatGPT(message_history, options)

      table.insert(message_history, {
        role = "assistant",
        content = answer
      })

      session.title = session.title or ChatHistory.deriveTitle(message_history, highlightedText)
      ChatHistory.save(session)
      chatgpt_viewer:update(buildFullResultText())
    end
  end

  -- Helper to build result text for custom prompts
  local function buildResultText(answer)
    local result_text = ""
    if not buttonConfig.hide_highlighted_text then
      result_text = _("Highlighted text: ") .. "\"" .. highlightedText .. "\"\n\n"
    end
    if not buttonConfig.hide_user_prompt then
      result_text = result_text .. _("User: ") .. message_history[2].content .. "\n\n"
    end
    result_text = result_text .. _("ChatGPT: ") .. answer .. "\n\n"
    return result_text
  end

  -- Check if streaming is enabled
  if isStreamingEnabled() then
    -- Show viewer immediately with generating message
    local chatgpt_viewer = ChatGPTViewer:new {
      title = buttonConfig.label or _("AskGPT"),
      text = _("Generating response..."),
      onAskQuestion = handleNewQuestion
    }
    UIManager:show(chatgpt_viewer)

    -- Start async streaming request with polling
    UIManager:scheduleIn(0.1, function()
      local streamState = queryChatGPTStreamAsync(message_history, options,
        -- onChunk callback
        function(partial_content)
          local result_text = buildResultText(partial_content .. " ▌")
          chatgpt_viewer:update(result_text)
        end,
        -- onComplete callback
        function(final_content, err)
          if err then
            chatgpt_viewer:update(_("Error: ") .. tostring(err))
            return
          end
          table.insert(message_history, {
            role = "assistant",
            content = final_content
          })
          session.title = session.title or ChatHistory.deriveTitle(message_history, highlightedText)
          ChatHistory.save(session)
          local result_text = buildResultText(final_content)
          chatgpt_viewer:update(result_text)
        end
      )

      if streamState then
        -- Set up polling loop
        local function doPoll()
          local shouldContinue = streamState.poll()
          if shouldContinue then
            UIManager:scheduleIn(0.1, doPoll)
          end
        end
        UIManager:scheduleIn(0.1, doPoll)
      end
    end)
  else
    -- Non-streaming fallback
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

      session.title = session.title or ChatHistory.deriveTitle(message_history, highlightedText)
      ChatHistory.save(session)

      local result_text = buildResultText(answer)

      local chatgpt_viewer = ChatGPTViewer:new {
        title = buttonConfig.label or _("AskGPT"),
        text = result_text,
        onAskQuestion = handleNewQuestion
      }

      UIManager:show(chatgpt_viewer)
    end)
  end
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
  local title, author, doc_file = getBookInfo(ui)
  local message_history = message_history or {{
    role = "system",
    content = "The following is a conversation with an AI assistant. The assistant is helpful, creative, clever, and very friendly. Answer as concisely as possible. You may use simple markdown formatting like bold, italic, bullet points, and code blocks, but avoid complex formatting such as tables."
  }}

  local session = {
    message_history = message_history,
    highlighted_text = highlightedText,
    book_title = title,
    book_authors = author,
    doc_file = doc_file,
    button_label = "Ask ChatGPT",
  }

  -- Helper to build streaming result text with partial content
  local function buildStreamingResultTextForDialog(partial_content)
    local result_text = _("Highlighted text: ") .. "\"" .. highlightedText .. "\"\n\n"
    for i = 3, #message_history do
      if message_history[i].role == "user" then
        result_text = result_text .. _("User: ") .. message_history[i].content .. "\n\n"
      else
        result_text = result_text .. _("ChatGPT: ") .. message_history[i].content .. "\n\n"
      end
    end
    result_text = result_text .. _("ChatGPT: ") .. partial_content .. "\n\n"
    return result_text
  end

  local function handleNewQuestion(chatgpt_viewer, question)
    table.insert(message_history, {
      role = "user",
      content = question
    })

    if isStreamingEnabled() then
      -- Show generating indicator
      chatgpt_viewer:update(buildStreamingResultTextForDialog(_("Generating...") .. " ▌"))

      local streamState = queryChatGPTStreamAsync(message_history, {},
        -- onChunk callback
        function(partial_content)
          chatgpt_viewer:update(buildStreamingResultTextForDialog(partial_content .. " ▌"))
        end,
        -- onComplete callback
        function(final_content, err)
          if err then
            chatgpt_viewer:update(buildStreamingResultTextForDialog(_("Error: ") .. tostring(err)))
            return
          end
          table.insert(message_history, {
            role = "assistant",
            content = final_content
          })
          session.title = session.title or ChatHistory.deriveTitle(message_history, highlightedText)
          ChatHistory.save(session)
          chatgpt_viewer:update(createResultText(highlightedText, message_history))
        end
      )

      if streamState then
        local function doPoll()
          if streamState.poll() then
            UIManager:scheduleIn(0.1, doPoll)
          end
        end
        UIManager:scheduleIn(0.1, doPoll)
      end
    else
      -- Non-streaming fallback
      local answer = queryChatGPT(message_history)

      table.insert(message_history, {
        role = "assistant",
        content = answer
      })

      session.title = session.title or ChatHistory.deriveTitle(message_history, highlightedText)
      ChatHistory.save(session)
      chatgpt_viewer:update(createResultText(highlightedText, message_history))
    end
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

        if isStreamingEnabled() then
          -- Show viewer immediately with generating message
          local chatgpt_viewer = ChatGPTViewer:new {
            title = _("AskGPT"),
            text = _("Generating response..."),
            onAskQuestion = handleNewQuestion
          }
          UIManager:show(chatgpt_viewer)

          UIManager:scheduleIn(0.1, function()
            local streamState = queryChatGPTStreamAsync(message_history, {},
              -- onChunk callback
              function(partial_content)
                -- Build partial result text
                local result_text = _("Highlighted text: ") .. "\"" .. highlightedText .. "\"\n\n"
                for i = 3, #message_history do
                  if message_history[i].role == "user" then
                    result_text = result_text .. _("User: ") .. message_history[i].content .. "\n\n"
                  else
                    result_text = result_text .. _("ChatGPT: ") .. message_history[i].content .. "\n\n"
                  end
                end
                result_text = result_text .. _("ChatGPT: ") .. partial_content .. " ▌\n\n"
                chatgpt_viewer:update(result_text)
              end,
              -- onComplete callback
              function(final_content, err)
                if err then
                  chatgpt_viewer:update(_("Error: ") .. tostring(err))
                  return
                end
                local answer_message = {
                  role = "assistant",
                  content = final_content
                }
                table.insert(message_history, answer_message)
                session.title = session.title or ChatHistory.deriveTitle(message_history, highlightedText)
                ChatHistory.save(session)
                local result_text = createResultText(highlightedText, message_history)
                chatgpt_viewer:update(result_text)
              end
            )

            if streamState then
              local function doPoll()
                local shouldContinue = streamState.poll()
                if shouldContinue then
                  UIManager:scheduleIn(0.1, doPoll)
                end
              end
              UIManager:scheduleIn(0.1, doPoll)
            end
          end)
        else
          -- Non-streaming fallback
          showLoadingDialog()

          UIManager:scheduleIn(0.1, function()
            local answer = queryChatGPT(message_history)
            local answer_message = {
              role = "assistant",
              content = answer
            }
            table.insert(message_history, answer_message)

            session.title = session.title or ChatHistory.deriveTitle(message_history, highlightedText)
            ChatHistory.save(session)

            local result_text = createResultText(highlightedText, message_history)

            local chatgpt_viewer = ChatGPTViewer:new {
              title = _("AskGPT"),
              text = result_text,
              onAskQuestion = handleNewQuestion
            }

            UIManager:show(chatgpt_viewer)
          end)
        end
      end
    }
  }

  if CONFIGURATION and CONFIGURATION.features and CONFIGURATION.features.translate_to then
    table.insert(buttons, {
      text = _("Translate"),
      callback = function()
        local target_language = CONFIGURATION.features.translate_to

        table.insert(message_history, {
          role = "user",
          content = "Translate to " .. target_language .. ": " .. highlightedText
        })

        local translation_history = {
          {
            role = "system",
            content = "You are a helpful translation assistant. Provide direct translations without additional commentary."
          },
          {
            role = "user",
            content = "Translate the following text to " .. target_language .. ": " .. highlightedText
          }
        }

        if isStreamingEnabled() then
          local chatgpt_viewer = ChatGPTViewer:new {
            title = _("Translation"),
            text = _("Translating..."),
            onAskQuestion = handleNewQuestion
          }
          UIManager:show(chatgpt_viewer)

          UIManager:scheduleIn(0.1, function()
            local streamState = queryChatGPTStreamAsync(translation_history, {},
              -- onChunk callback
              function(partial_content)
                local result_text = _("Highlighted text: ") .. "\"" .. highlightedText .. "\"\n\n"
                result_text = result_text .. _("ChatGPT: ") .. partial_content .. " ▌\n\n"
                chatgpt_viewer:update(result_text)
              end,
              -- onComplete callback
              function(final_content, err)
                if err then
                  chatgpt_viewer:update(_("Error: ") .. tostring(err))
                  return
                end
                table.insert(message_history, {
                  role = "assistant",
                  content = final_content
                })
                session.title = session.title or ChatHistory.deriveTitle(message_history, highlightedText)
                ChatHistory.save(session)
                local result_text = createResultText(highlightedText, message_history)
                chatgpt_viewer:update(result_text)
              end
            )

            if streamState then
              local function doPoll()
                local shouldContinue = streamState.poll()
                if shouldContinue then
                  UIManager:scheduleIn(0.1, doPoll)
                end
              end
              UIManager:scheduleIn(0.1, doPoll)
            end
          end)
        else
          showLoadingDialog()

          UIManager:scheduleIn(0.1, function()
            local translated_text = translateText(highlightedText, target_language)

            table.insert(message_history, {
              role = "assistant",
              content = translated_text
            })

            session.title = session.title or ChatHistory.deriveTitle(message_history, highlightedText)
            ChatHistory.save(session)

            local result_text = createResultText(highlightedText, message_history)
            local chatgpt_viewer = ChatGPTViewer:new {
              title = _("Translation"),
              text = result_text,
              onAskQuestion = handleNewQuestion
            }

            UIManager:show(chatgpt_viewer)
          end)
        end
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

local function resumeSession(ui, session)
  local message_history = session.message_history
  local highlightedText = session.highlighted_text or ""

  local function buildStreamingResultTextForResume(partial_content)
    local result_text = _("Highlighted text: ") .. "\"" .. highlightedText .. "\"\n\n"
    for i = 3, #message_history do
      if message_history[i].role == "user" then
        result_text = result_text .. _("User: ") .. message_history[i].content .. "\n\n"
      else
        result_text = result_text .. _("ChatGPT: ") .. message_history[i].content .. "\n\n"
      end
    end
    result_text = result_text .. _("ChatGPT: ") .. partial_content .. "\n\n"
    return result_text
  end

  local function handleNewQuestion(chatgpt_viewer, question)
    table.insert(message_history, {
      role = "user",
      content = question
    })

    if isStreamingEnabled() then
      chatgpt_viewer:update(buildStreamingResultTextForResume(_("Generating...") .. " ▌"))

      local streamState = queryChatGPTStreamAsync(message_history, {},
        function(partial_content)
          chatgpt_viewer:update(buildStreamingResultTextForResume(partial_content .. " ▌"))
        end,
        function(final_content, err)
          if err then
            chatgpt_viewer:update(buildStreamingResultTextForResume(_("Error: ") .. tostring(err)))
            return
          end
          table.insert(message_history, {
            role = "assistant",
            content = final_content
          })
          session.title = session.title or ChatHistory.deriveTitle(message_history, highlightedText)
          ChatHistory.save(session)
          chatgpt_viewer:update(createResultText(highlightedText, message_history))
        end
      )

      if streamState then
        local function doPoll()
          if streamState.poll() then
            UIManager:scheduleIn(0.1, doPoll)
          end
        end
        UIManager:scheduleIn(0.1, doPoll)
      end
    else
      local answer = queryChatGPT(message_history)

      table.insert(message_history, {
        role = "assistant",
        content = answer
      })

      session.title = session.title or ChatHistory.deriveTitle(message_history, highlightedText)
      ChatHistory.save(session)
      chatgpt_viewer:update(createResultText(highlightedText, message_history))
    end
  end

  local result_text = createResultText(highlightedText, message_history)

  local chatgpt_viewer = ChatGPTViewer:new {
    title = session.title or _("AskGPT"),
    text = result_text,
    onAskQuestion = handleNewQuestion,
    session = session,
  }
  UIManager:show(chatgpt_viewer)
end

return {
  showChatGPTDialog = showChatGPTDialog,
  showCustomPromptResult = handleCustomButton,
  resumeSession = resumeSession,
}