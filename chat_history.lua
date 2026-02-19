local DataStorage = require("datastorage")
local json = require("json")
local lfs = require("libs/libkoreader-lfs")

local ChatHistory = {}

function ChatHistory.getHistoryDir()
    local base = DataStorage:getDataDir() .. "/askgpt"
    lfs.mkdir(base)
    local dir = base .. "/history"
    lfs.mkdir(dir)
    return dir
end

function ChatHistory.generateId()
    local time = os.time()
    local rand = string.format("%04x", math.random(0, 0xFFFF))
    return tostring(time) .. "_" .. rand
end

function ChatHistory.deriveTitle(message_history, highlighted_text)
    for i = 2, #message_history do
        if message_history[i].role == "user" then
            local content = message_history[i].content
            if #content > 50 then
                content = content:sub(1, 47) .. "..."
            end
            return content
        end
    end
    if highlighted_text and #highlighted_text > 0 then
        local ht = highlighted_text
        if #ht > 50 then
            ht = ht:sub(1, 47) .. "..."
        end
        return ht
    end
    return "Untitled Chat"
end

function ChatHistory.save(session)
    if not session.id then
        session.id = ChatHistory.generateId()
        session.created_at = os.time()
    end
    session.updated_at = os.time()

    local dir = ChatHistory.getHistoryDir()
    local path = dir .. "/" .. session.id .. ".json"
    local file, err = io.open(path, "w")
    if not file then
        print("ChatHistory: failed to save: " .. tostring(err))
        return false
    end
    file:write(json.encode(session))
    file:close()
    return true
end

function ChatHistory.load(session_id)
    local path = ChatHistory.getHistoryDir() .. "/" .. session_id .. ".json"
    local file = io.open(path, "r")
    if not file then return nil end
    local content = file:read("*a")
    file:close()
    local ok, session = pcall(json.decode, content)
    if ok then return session end
    return nil
end

function ChatHistory.list(doc_file)
    local dir = ChatHistory.getHistoryDir()
    local sessions = {}
    for filename in lfs.dir(dir) do
        if filename:match("%.json$") then
            local path = dir .. "/" .. filename
            local file = io.open(path, "r")
            if file then
                local content = file:read("*a")
                file:close()
                local ok, session = pcall(json.decode, content)
                if ok and session then
                    if not doc_file or session.doc_file == doc_file then
                        table.insert(sessions, {
                            id = session.id,
                            title = session.title or "Untitled",
                            book_title = session.book_title,
                            book_authors = session.book_authors,
                            updated_at = session.updated_at or 0,
                            message_count = session.message_history and #session.message_history or 0,
                        })
                    end
                end
            end
        end
    end
    table.sort(sessions, function(a, b)
        return a.updated_at > b.updated_at
    end)
    return sessions
end

function ChatHistory.delete(session_id)
    local path = ChatHistory.getHistoryDir() .. "/" .. session_id .. ".json"
    return os.remove(path)
end

return ChatHistory
