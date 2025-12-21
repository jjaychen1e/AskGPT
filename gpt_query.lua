local api_key = nil
local CONFIGURATION = nil

-- Attempt to load the api_key module. IN A LATER VERSION, THIS WILL BE REMOVED
local success, result = pcall(function() return require("api_key") end)
if success then
  api_key = result.key
else
  print("api_key.lua not found, skipping...")
end

-- Attempt to load the configuration module
success, result = pcall(function() return require("configuration") end)
if success then
  CONFIGURATION = result
else
  print("configuration.lua not found, skipping...")
end

-- Define your queryChatGPT function
local https = require("ssl.https")
local http = require("socket.http")
local ltn12 = require("ltn12")
local json = require("json")

-- Helper function to strip <think>...</think> tags from response
local function stripThinkingTags(content)
  -- Remove <think>...</think> blocks (handles multiline content)
  local result = content:gsub("<think>.-</think>", "")
  -- Trim leading/trailing whitespace
  result = result:gsub("^%s+", ""):gsub("%s+$", "")
  return result
end

local function queryChatGPT(message_history, options)
  options = options or {}
  -- Use api_key from CONFIGURATION or fallback to the api_key module
  local api_key_value = CONFIGURATION and CONFIGURATION.api_key or api_key
  local api_url = CONFIGURATION and CONFIGURATION.base_url or "https://api.openai.com/v1/chat/completions"
  -- Use model from options if provided, otherwise fall back to CONFIGURATION or default
  local model = options.model or (CONFIGURATION and CONFIGURATION.model) or "gpt-4o-mini"

  -- Determine whether to use http or https
  local request_library = api_url:match("^https://") and https or http

  -- Start building the request body
  local requestBodyTable = {
    model = model,
    messages = message_history,
  }

  -- Add additional parameters if they exist
  if CONFIGURATION and CONFIGURATION.additional_parameters then
    for key, value in pairs(CONFIGURATION.additional_parameters) do
      requestBodyTable[key] = value
    end
  end

  -- Encode the request body as JSON
  local requestBody = json.encode(requestBodyTable)

  local headers = {
    ["Content-Type"] = "application/json",
    ["Authorization"] = "Bearer " .. api_key_value,
  }

  local responseBody = {}

  -- Make the HTTP/HTTPS request
  local res, code, responseHeaders = request_library.request {
    url = api_url,
    method = "POST",
    headers = headers,
    source = ltn12.source.string(requestBody),
    sink = ltn12.sink.table(responseBody),
  }

  if code ~= 200 then
    error("Error querying ChatGPT API: " .. code)
  end

  local response = json.decode(table.concat(responseBody))
  local content = response.choices[1].message.content

  -- Strip thinking tags if configured
  if CONFIGURATION and CONFIGURATION.strip_thinking_tags then
    content = stripThinkingTags(content)
  end

  return content
end

-- Parse URL into components
local function parseUrl(url)
  local protocol, host, port, path = url:match("^(https?)://([^:/]+):?(%d*)(.*)$")
  if not protocol then
    return nil
  end
  port = port ~= "" and tonumber(port) or (protocol == "https" and 443 or 80)
  path = path ~= "" and path or "/"
  return {
    protocol = protocol,
    host = host,
    port = port,
    path = path,
    is_https = protocol == "https"
  }
end

-- Async streaming version using non-blocking sockets and polling
-- Returns a state object with a poll() function for UIManager to call
local function queryChatGPTStreamAsync(message_history, options, onChunk, onComplete)
  options = options or {}
  local api_key_value = CONFIGURATION and CONFIGURATION.api_key or api_key
  local api_url = CONFIGURATION and CONFIGURATION.base_url or "https://api.openai.com/v1/chat/completions"
  local model = options.model or (CONFIGURATION and CONFIGURATION.model) or "gpt-4o-mini"
  local chunk_size = CONFIGURATION and CONFIGURATION.streaming_chunk_size or 500

  local url_parts = parseUrl(api_url)
  if not url_parts then
    if onComplete then
      onComplete(nil, "Invalid API URL")
    end
    return nil
  end

  local requestBodyTable = {
    model = model,
    messages = message_history,
    stream = true,
  }

  if CONFIGURATION and CONFIGURATION.additional_parameters then
    for key, value in pairs(CONFIGURATION.additional_parameters) do
      requestBodyTable[key] = value
    end
  end

  local requestBody = json.encode(requestBodyTable)

  -- Build HTTP request
  local request_lines = {
    "POST " .. url_parts.path .. " HTTP/1.1",
    "Host: " .. url_parts.host,
    "Content-Type: application/json",
    "Authorization: Bearer " .. api_key_value,
    "Content-Length: " .. #requestBody,
    "Connection: close",
    "",
    requestBody
  }
  local request_str = table.concat(request_lines, "\r\n")

  -- Create socket
  local socket = require("socket")
  local sock = socket.tcp()

  -- State for the streaming connection
  local state = {
    sock = sock,
    connected = false,
    headers_received = false,
    response_buffer = "",
    accumulated_content = "",
    last_chunk_length = 0,
    line_buffer = "",
    finished = false,
    error_msg = nil,
    ssl_wrapped = false,
  }

  -- Set initial timeout for connection (blocking initially)
  sock:settimeout(10)

  -- Connect to server
  local conn_ok, conn_err = sock:connect(url_parts.host, url_parts.port)
  if not conn_ok then
    if onComplete then
      onComplete(nil, "Connection failed: " .. tostring(conn_err))
    end
    return nil
  end

  -- Wrap with SSL if HTTPS
  if url_parts.is_https then
    local ssl = require("ssl")
    local params = {
      mode = "client",
      protocol = "any",
      verify = "none",
      options = "all",
    }
    local wrapped, ssl_err = ssl.wrap(sock, params)
    if not wrapped then
      sock:close()
      if onComplete then
        onComplete(nil, "SSL wrap failed: " .. tostring(ssl_err))
      end
      return nil
    end
    wrapped:settimeout(10)
    local hs_ok, hs_err = wrapped:dohandshake()
    if not hs_ok then
      wrapped:close()
      if onComplete then
        onComplete(nil, "SSL handshake failed: " .. tostring(hs_err))
      end
      return nil
    end
    state.sock = wrapped
    state.ssl_wrapped = true
  end

  -- Send request
  local send_ok, send_err = state.sock:send(request_str)
  if not send_ok then
    state.sock:close()
    if onComplete then
      onComplete(nil, "Send failed: " .. tostring(send_err))
    end
    return nil
  end

  -- Now set to non-blocking for polling
  state.sock:settimeout(0)
  state.connected = true

  -- Process SSE data line
  local function processDataLine(data)
    if data == "[DONE]" then
      return true  -- Stream complete
    end

    local ok, parsed = pcall(json.decode, data)
    if ok and parsed and parsed.choices and parsed.choices[1] then
      local delta = parsed.choices[1].delta
      if delta and delta.content then
        state.accumulated_content = state.accumulated_content .. delta.content

        local current_length = #state.accumulated_content
        if current_length - state.last_chunk_length >= chunk_size then
          state.last_chunk_length = current_length
          if onChunk then
            local display_content = state.accumulated_content
            if CONFIGURATION and CONFIGURATION.strip_thinking_tags then
              display_content = stripThinkingTags(display_content)
            end
            onChunk(display_content)
          end
        end
      end
    end
    return false
  end

  -- Process buffered lines
  local function processLines()
    while true do
      local line_end = state.line_buffer:find("\n")
      if not line_end then
        break
      end

      local line = state.line_buffer:sub(1, line_end - 1)
      state.line_buffer = state.line_buffer:sub(line_end + 1)

      -- Remove carriage return if present
      line = line:gsub("\r$", "")

      if line ~= "" then
        if line:match("^data: ") then
          local data = line:sub(7)
          if processDataLine(data) then
            return true  -- Stream complete
          end
        end
      end
    end
    return false
  end

  -- Poll function - returns true if should continue polling, false if done
  state.poll = function()
    if state.finished then
      return false
    end

    -- Try to read data (non-blocking)
    local data, err, partial = state.sock:receive("*a")

    -- Handle received data
    local received = data or partial
    if received and #received > 0 then
      state.response_buffer = state.response_buffer .. received

      -- Skip HTTP headers if not yet done
      if not state.headers_received then
        local header_end = state.response_buffer:find("\r\n\r\n")
        if header_end then
          -- Check for HTTP status in headers
          local status_line = state.response_buffer:match("^HTTP/[%d.]+ (%d+)")
          if status_line and tonumber(status_line) ~= 200 then
            state.finished = true
            state.sock:close()
            if onComplete then
              onComplete(nil, "HTTP error: " .. status_line)
            end
            return false
          end
          state.line_buffer = state.response_buffer:sub(header_end + 4)
          state.headers_received = true
        end
      else
        state.line_buffer = state.line_buffer .. received
      end

      -- Process any complete lines
      if state.headers_received then
        local stream_done = processLines()
        if stream_done then
          state.finished = true
          state.sock:close()
          local final_content = state.accumulated_content
          if CONFIGURATION and CONFIGURATION.strip_thinking_tags then
            final_content = stripThinkingTags(final_content)
          end
          if onComplete then
            onComplete(final_content)
          end
          return false
        end
      end
    end

    -- Check for connection close
    if err == "closed" then
      state.finished = true
      state.sock:close()
      local final_content = state.accumulated_content
      if CONFIGURATION and CONFIGURATION.strip_thinking_tags then
        final_content = stripThinkingTags(final_content)
      end
      if onComplete then
        onComplete(final_content)
      end
      return false
    end

    -- Continue polling (timeout just means no data available yet)
    return true
  end

  -- Cancel function to abort the request
  state.cancel = function()
    if not state.finished then
      state.finished = true
      state.sock:close()
    end
  end

  return state
end

-- Check if streaming is enabled in configuration (default: true)
local function isStreamingEnabled()
  if CONFIGURATION and CONFIGURATION.streaming ~= nil then
    return CONFIGURATION.streaming
  end
  return true  -- Default to enabled
end

return {
  query = queryChatGPT,
  streamAsync = queryChatGPTStreamAsync,
  isStreamingEnabled = isStreamingEnabled,
}