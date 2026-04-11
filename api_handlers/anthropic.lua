local BaseHandler = require("api_handlers.base")
local json = require("json")
local koutil = require("util")
local logger = require("logger")
local http = require("socket.http")
local ltn12 = require("ltn12")
local https = require("ssl.https")
local socketutil = require("socketutil")
local socket = require("socket")

local AnthropicHandler = BaseHandler:new()

local function prepare_anthropic_messages(message_history, options)
    -- options = { cache_book_text = bool, book_text = string, book_title = string,
    --             cache_system_prompt = bool }
    options = options or {}
    local anthropic_messages = {}
    local system_blocks = {}

    -- Collect all system messages as individual text blocks
    for _, msg in ipairs(message_history) do
        if msg.role == "system" then
            table.insert(system_blocks, {
                type = "text",
                text = msg.content,
            })
        end
    end

    -- Optionally append book text as a separate cacheable block
    if options.cache_book_text and type(options.book_text) == "string" then
        table.insert(system_blocks, {
            type = "text",
            text = options.book_text,
            cache_control = { type = "ephemeral" },
        })
    end

    -- Cache the system prompt for session reuse (Anthropic matches by prefix,
    -- so marking the last non-cached block ensures the full sequence is cached)
    if options.cache_system_prompt and #system_blocks > 0 then
        for i = #system_blocks, 1, -1 do
            if not system_blocks[i].cache_control then
                system_blocks[i].cache_control = { type = "ephemeral" }
                break
            end
        end
    end

    -- Process non-system messages (user and assistant)
    for _, msg in ipairs(message_history) do
        if msg.role ~= "system" then
            table.insert(anthropic_messages, {
                role = msg.role,
                content = msg.content,
            })
        end
    end

    -- Optionally add a document block with citations to the first user message
    if options.citations_book_text then
        for i, msg in ipairs(anthropic_messages) do
            if msg.role == "user" then
                anthropic_messages[i].content = {
                    {
                        type = "document",
                        source = {
                            type = "text",
                            media_type = "text/plain",
                            data = options.citations_book_text,
                        },
                        title = options.book_title or "Book Text",
                        citations = { enabled = true },
                    },
                    {
                        type = "text",
                        text = type(msg.content) == "string" and msg.content or "",
                    },
                }
                break
            end
        end
    end

    return {
        messages = anthropic_messages,
        -- If only one text block with no cache_control, fall back to plain string
        -- for backward compat with basic calls
        system = (#system_blocks == 1 and not system_blocks[1].cache_control)
                 and system_blocks[1].text
                 or system_blocks,
    }
end

local function extract_text_from_content(content_blocks)
    if type(content_blocks) ~= "table" then
        return nil
    end

    local text_chunks = {}
    for _, block in ipairs(content_blocks) do
        if type(block) == "table" and block.type == "text" and type(block.text) == "string" then
            table.insert(text_chunks, block.text)
        end
    end

    if #text_chunks > 0 then
        return table.concat(text_chunks, "\n\n")
    end
end


function AnthropicHandler:query(message_history, anthropic_settings, query_options)
    query_options = query_options or {}
    local requestBodyTable = prepare_anthropic_messages(message_history, query_options)
    requestBodyTable.model = anthropic_settings.model
    requestBodyTable.max_tokens = query_options.max_tokens
        or koutil.tableGetValue(anthropic_settings, "additional_parameters", "max_tokens")
    requestBodyTable.stream = koutil.tableGetValue(anthropic_settings, "additional_parameters", "stream") or false
    local tools = koutil.tableGetValue(anthropic_settings, "additional_parameters", "tools")
    if type(tools) == "table" and next(tools) ~= nil then
        requestBodyTable.tools = tools
    end

    -- Web search tool (built-in Anthropic tool, enabled via query_options)
    if query_options.web_search then
        requestBodyTable.tools = requestBodyTable.tools or {}
        table.insert(requestBodyTable.tools, {
            type = "web_search_20250305",
            name = "web_search",
            max_uses = 3,
        })
    end

    -- Extended thinking (Claude Sonnet/Opus only — Haiku does not support it)
    local use_thinking = query_options and query_options.thinking_budget
        and query_options.thinking_budget >= 1024
    if use_thinking then
        local model = requestBodyTable.model or ""
        if model:find("haiku") then
            -- Haiku models do not support extended thinking; skip silently
        elseif model:find("4%-6") then
            -- Claude 4.6+ supports adaptive thinking (model manages its own budget)
            requestBodyTable.thinking = { type = "adaptive" }
        elseif model:find("4%-5") or model:find("opus%-4") or model:find("sonnet%-4") then
            -- Claude 4.0/4.5 Sonnet/Opus requires explicit budget_tokens.
            -- budget_tokens must be < max_tokens (both share the same output pool).
            local max_tok = requestBodyTable.max_tokens or 8096
            local budget = math.min(query_options.thinking_budget, max_tok - 1024)
            if budget >= 1024 then
                requestBodyTable.max_tokens = max_tok + budget
                requestBodyTable.thinking = {
                    type = "enabled",
                    budget_tokens = budget,
                }
            end
        end
    end

    local requestBody = json.encode(requestBodyTable)
    local headers = {
        ["Content-Type"] = "application/json",
        ["x-api-key"] = anthropic_settings.api_key,
        ["anthropic-version"] = koutil.tableGetValue(anthropic_settings, "additional_parameters", "anthropic_version")
    }
    if query_options.citations_book_text then
        -- Combine beta headers if both thinking and citations are active
        local existing_beta = headers["anthropic-beta"]
        if existing_beta then
            headers["anthropic-beta"] = existing_beta .. ",citations-2025-05-06"
        else
            headers["anthropic-beta"] = "citations-2025-05-06"
        end
    end
    if requestBodyTable.stream then
        -- For streaming responses, we need to handle the response differently
        headers["Accept"] = "text/event-stream"
        return self:backgroundRequest(anthropic_settings.base_url, headers, requestBody)
    end

    local success, code, response = self:makeRequest(anthropic_settings.base_url, headers, requestBody)

    if not success then
        if code == BaseHandler.CODE_CANCELLED then
            return nil, response
        end
        return nil,"Error: Failed to connect to Anthropic API - " .. tostring(response)
    end

    local success_parse, parsed = pcall(json.decode, response)
    if not success_parse then
        logger.warn("JSON Decode Error:", parsed)
        return nil, "Error: Failed to parse Anthropic API response"
    end

    -- Extract token usage from response
    local token_usage = nil
    if parsed.usage then
        token_usage = {
            input = parsed.usage.input_tokens or 0,
            output = parsed.usage.output_tokens or 0,
            cache_read = parsed.usage.cache_read_input_tokens or 0,
            cache_write = parsed.usage.cache_creation_input_tokens or 0,
        }
    end

    local content = extract_text_from_content(parsed.content)
    if type(content) ~= "string" or #content == 0 then
        content = koutil.tableGetValue(parsed, "content", 1, "text")
    end
    if type(content) == "string" and #content > 0 then
        return content, nil, token_usage
    end

    local err_msg = koutil.tableGetValue(parsed, "error", "message")
    if err_msg then
        return nil, err_msg
    else
        return nil, "Error: Unexpected response format from API"
    end
end

--- Fetch available models from the Anthropic API
--- @param api_key string
--- @param anthropic_version string|nil
--- @return table|nil models, string|nil error
function AnthropicHandler:fetchModels(api_key, anthropic_version)
    if not api_key or api_key == "" then
        return nil, "API key is required"
    end

    local url = "https://api.anthropic.com/v1/models"
    https.cert_verify = false

    local sink = {}
    socketutil:set_timeout(15, 30)
    local request = {
        url = url,
        method = "GET",
        headers = {
            ["x-api-key"] = api_key,
            ["anthropic-version"] = anthropic_version or "2023-06-01",
        },
        sink = ltn12.sink.table(sink),
    }
    local code, resp_headers, status = socket.skip(1, http.request(request))
    socketutil:reset_timeout()

    if not resp_headers then
        return nil, "Network error: " .. tostring(status or code or "unreachable")
    end

    local content = table.concat(sink)
    if code ~= 200 then
        return nil, "API error: " .. tostring(code) .. " " .. tostring(status)
    end

    local ok, parsed = pcall(json.decode, content)
    if not ok or type(parsed) ~= "table" then
        return nil, "Failed to parse models response"
    end

    local models = {}
    for _, model in ipairs(parsed.data or {}) do
        if type(model) == "table" and model.id then
            table.insert(models, {
                id = model.id,
                display_name = model.display_name or model.id,
            })
        end
    end

    -- Sort by display name
    table.sort(models, function(a, b)
        return (a.display_name or "") < (b.display_name or "")
    end)

    return models
end

return AnthropicHandler