local logger = require("logger")
local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")
local TextBoxWidget = require("ui/widget/textboxwidget")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox = require("ui/widget/confirmbox")
local Event = require("ui/event")
local _ = require("assistant_gettext")
local T = require("ffi/util").template
local Trapper = require("ui/trapper")
local koutil = require("util")
local ChatGPTViewer = require("assistant_viewer")
local assistant_prompts = require("assistant_prompts").assistant_prompts
local NetworkMgr = require("ui/network/manager")
local assistant_utils = require("assistant_utils")
local extractBookTextForAnalysis = assistant_utils.extractBookTextForAnalysis
local extractHighlightsNotesAndNotebook = assistant_utils.extractHighlightsNotesAndNotebook
local normalizeMarkdownHeadings = assistant_utils.normalizeMarkdownHeadings
local json = require("json")

--- Extract structured index from X-Ray response JSON code block
local function extractXRayIndex(answer)
    if not answer then return nil end
    -- Match ```json ... ``` block (the JSON index appended to X-Ray responses)
    local json_str = answer:match("```json%s*\n(.-)```")
    if not json_str then return nil end
    local ok, data = pcall(json.decode, json_str)
    if not ok or type(data) ~= "table" then return nil end
    return data  -- { characters = [...], locations = [...], terms = [...] }
end

--- Merge new X-Ray index data into existing dictionary for a book
local function mergeXRayData(existing, new_data, progress_percent)
    existing = existing or { characters = {}, locations = {}, terms = {} }

    -- Merge characters by primary name
    for _, entry in ipairs(new_data.characters or {}) do
        if entry.name then
            local key = entry.name
            local curr = existing.characters[key]
            if curr then
                -- Merge aliases without duplicates
                local alias_set = {}
                for _, a in ipairs(curr.aliases or {}) do alias_set[a:lower()] = a end
                for _, a in ipairs(entry.aliases or {}) do
                    if not alias_set[a:lower()] then
                        table.insert(curr.aliases, a)
                        alias_set[a:lower()] = a
                    end
                end
                -- Update description and relationships with newer data
                curr.description = entry.description or curr.description
                curr.relationships = entry.relationships or curr.relationships
                curr.updated_progress = progress_percent
            else
                existing.characters[key] = {
                    description = entry.description or "",
                    relationships = entry.relationships or "",
                    aliases = entry.aliases or {},
                    updated_progress = progress_percent,
                }
            end
        end
    end

    -- Merge locations by name
    for _, entry in ipairs(new_data.locations or {}) do
        if entry.name then
            existing.locations[entry.name] = {
                description = entry.description or "",
                updated_progress = progress_percent,
            }
        end
    end

    -- Merge terms by name
    for _, entry in ipairs(new_data.terms or {}) do
        if entry.name then
            existing.terms[entry.name] = {
                description = entry.description or "",
                updated_progress = progress_percent,
            }
        end
    end

    existing.last_progress = progress_percent
    return existing
end

local function showFeatureDialog(assistant, feature_type, title, author, progress_percent, message_history)
    local CONFIGURATION = assistant.CONFIGURATION
    local Querier = assistant.querier
    local ui = assistant.ui

    -- Check if Querier is initialized
    local ok, err = Querier:load_model(assistant:getModelProvider())
    if not ok then
        UIManager:show(InfoMessage:new{ icon = "notice-warning", text = err })
        return
    end

    local formatted_progress_percent = string.format("%.2f", progress_percent * 100)
    local feature_title, loading_message, system_prompt, user_prompt_template, book_text, highlights_notes, feature_config

    local language = assistant.settings:readSetting("response_language") or assistant.ui_language

    if type(feature_type) == "table" then
        -- Custom feature from configuration
        local custom_config = feature_type
        feature_title = custom_config.text or _("Custom Prompt")
        loading_message = custom_config.loading_message or _("Loading...")
        system_prompt = custom_config.system_prompt
        user_prompt_template = custom_config.user_prompt

        -- Handle use flags
        book_text = nil
        highlights_notes = nil
        if custom_config.use_book_text and custom_config.use_book_text == true then
            book_text = extractBookTextForAnalysis(CONFIGURATION, ui)
        end
        if custom_config.use_highlight_with_notebook and custom_config.use_highlight_with_notebook == true then
            highlights_notes = extractHighlightsNotesAndNotebook(CONFIGURATION, ui, true)
        elseif custom_config.use_highlight_without_notebook and custom_config.use_highlight_without_notebook == true then
            highlights_notes = extractHighlightsNotesAndNotebook(CONFIGURATION, ui, false)
        end
    else
        -- Original feature type handling
        -- Feature type configurations for easy extension
        local feature_configurations = {
            recap = {
                title = _("Recap"),
                loading_message = _("Loading Recap..."),
                config_key = "recap_config",
                prompts_key = "recap",
                thinking_budget = 8000,
            },
            xray = {
                title = _("X‑Ray"),
                loading_message = _("Loading X-Ray..."),
                config_key = "xray_config",
                prompts_key = "xray",
                thinking_budget = 10000,
            },
            xray_dictionary_update = {
                title = _("Update Dictionary"),
                loading_message = _("Updating dictionary..."),
                config_key = "xray_config",
                prompts_key = "xray_dictionary_update",
                thinking_budget = 5000,
            },
            book_info = {
                title = _("Book Information"),
                loading_message = _("Loading Book Information..."),
                config_key = "book_info_config",
                prompts_key = "book_info",
                web_search = true,
            },
            annotations = {
                title = _("Highlight & Note Analysis"),
                loading_message = _("Loading Highlight & Note Analysis..."),
                config_key = "annotations_config",
                prompts_key = "annotations"
            },
            summary_using_annotations = {
                title = _("Summary Using Highlights & Notes"),
                loading_message = _("Loading Summary Using Highlights & Notes..."),
                config_key = "summary_using_annotations_config",
                prompts_key = "summary_using_annotations"
            }
        }
        
        -- Get feature configuration
        feature_config = feature_configurations[feature_type]
        if not feature_config then
            UIManager:show(InfoMessage:new{ 
                icon = "notice-warning", 
                text = string.format(_("Unknown feature type: %s"), feature_type) 
            })
            return
        end
        
        feature_title = feature_config.title
        loading_message = feature_config.loading_message
        local config_key = feature_config.config_key
        local prompts_key = feature_config.prompts_key
        
        -- Get feature CONFIGURATION with fallbacks
        local file_config = koutil.tableGetValue(CONFIGURATION, "features", config_key) or {}
        
        -- Prompts for feature (from config or prompts.lua)
        system_prompt = koutil.tableGetValue(file_config, "system_prompt")
            or koutil.tableGetValue(assistant_prompts, prompts_key, "system_prompt")

        user_prompt_template = koutil.tableGetValue(file_config, "user_prompt")
            or koutil.tableGetValue(assistant_prompts, prompts_key, "user_prompt")

        book_text = nil
        highlights_notes = nil
        if feature_type == "xray" or feature_type == "recap" or feature_type == "xray_dictionary_update" then
          if assistant.settings:readSetting("use_book_text_for_analysis", false) then
            book_text = extractBookTextForAnalysis(CONFIGURATION, ui)
          end
        elseif feature_type == "annotations" then
          highlights_notes = extractHighlightsNotesAndNotebook(CONFIGURATION, ui,true)
        elseif feature_type == "summary_using_annotations" then
          book_text = extractBookTextForAnalysis(CONFIGURATION, ui)
          highlights_notes = extractHighlightsNotesAndNotebook(CONFIGURATION, ui,false)
        end
    end

    if assistant.settings:readSetting("auto_prompt_suggest", false) then
      local suggestions_prompt = assistant_prompts.suggestions_prompt:gsub("{(%w+)}", {language = language})
      system_prompt = system_prompt .. suggestions_prompt
    end
    
    local book_text_prompt = ""
    if book_text and #book_text <= 3000 then
        book_text_prompt = string.format("\n\n[! IMPORTANT !] Here is the book text up to my current position, only consider this text for your response:\n [BOOK TEXT BEGIN]\n%s\n[BOOK TEXT END]", book_text)
    end

    local highlights_notes_prompt = ""
    if highlights_notes and highlights_notes ~= "" then
        highlights_notes_prompt = string.format("\n\n[BOOK HIGHLIGHTS, NOTES AND NOTEBOOK CONTENT BEGIN]\n%s\n[BOOK HIGHLIGHTS, NOTES AND NOTEBOOK CONTENT END]", highlights_notes)
    end

    local message_history = message_history or {
        {
            role = "system",
            content = system_prompt,
        },
    }
    
    -- Check for existing X-Ray dictionary data for incremental mode
    local last_progress_str = "0"
    local known_entities_str = ""
    if feature_type == "xray" or feature_type == "xray_dictionary_update" then
        local props = ui.document and ui.document.getProps and ui.document:getProps() or {}
        local book_hash = props.md5
            or (ui.document and ui.document.file and tostring(ui.document.file):gsub("[^%w]", "_"))
            or "unknown"
        local xray_data = assistant.settings:readSetting("xray_dictionary") or {}
        local book_dict = xray_data[book_hash]
        if book_dict and book_dict.last_progress then
            last_progress_str = tostring(book_dict.last_progress)
            -- Build a compact summary of known entities
            local parts = {}
            if book_dict.characters then
                local names = {}
                for name, data in pairs(book_dict.characters) do
                    table.insert(names, name)
                end
                if #names > 0 then
                    table.insert(parts, "Characters: " .. table.concat(names, ", "))
                end
            end
            if book_dict.locations then
                local names = {}
                for name, data in pairs(book_dict.locations) do
                    table.insert(names, name)
                end
                if #names > 0 then
                    table.insert(parts, "Locations: " .. table.concat(names, ", "))
                end
            end
            if book_dict.terms then
                local names = {}
                for name, data in pairs(book_dict.terms) do
                    table.insert(names, name)
                end
                if #names > 0 then
                    table.insert(parts, "Terms: " .. table.concat(names, ", "))
                end
            end
            known_entities_str = table.concat(parts, "\n")

            -- For full X-Ray, prepend the incremental prefix
            if feature_type == "xray" and tonumber(last_progress_str) > 0 then
                local incremental_prefix = assistant_prompts.xray_incremental_prefix or ""
                incremental_prefix = incremental_prefix:gsub("{(%w+)}", {
                    last_progress = last_progress_str,
                    progress = formatted_progress_percent,
                    known_entities = known_entities_str,
                })
                user_prompt_template = incremental_prefix .. user_prompt_template
            end
        end
    end

    -- Format the user prompt with variables
    local user_content = user_prompt_template:gsub("{(%w+)}", {
      title = title,
      author = author,
      progress = formatted_progress_percent,
      language = language,
      last_progress = last_progress_str,
      known_entities = known_entities_str,
    })

    user_content = user_content .. book_text_prompt .. highlights_notes_prompt
    
    local context_message = {
        role = "user",
        content = user_content
    }
    table.insert(message_history, context_message)

    local function createResultText(answer)
      local normalized_answer = normalizeMarkdownHeadings(answer, 2, 6) or answer
      local result_text = 
        TextBoxWidget.PTF_HEADER ..
        TextBoxWidget.PTF_BOLD_START .. title .. TextBoxWidget.PTF_BOLD_END .. " by " .. author .. " is " .. formatted_progress_percent .. "% complete.\n\n" ..  normalized_answer
      return result_text
    end

    local function prepareMessageHistoryForAdditionalQuestion(message_history, user_question, title, author)
      local context = {
        role = "user",
        content = string.format("I'm reading something titled '%s' by %s. Only answer the following question, do not add any additional information or context that is not directly related to the question, the question is: %s", title, author, user_question)
      }
      table.insert(message_history, context)
    end

    -- Build query_options for Claude-specific features
    local query_options = {}

    -- Extended thinking (from feature config or custom config)
    local thinking_budget = (type(feature_type) == "table" and feature_type.thinking_budget)
        or (feature_config and feature_config.thinking_budget)
        or 0
    if thinking_budget >= 1024 then
        query_options.thinking_budget = thinking_budget
    end

    -- Prompt caching: move book text from user message to cached system block
    if book_text and #book_text > 3000 then
        query_options.cache_book_text = true
        query_options.book_text = string.format(
            "[BOOK TEXT BEGIN]\n%s\n[BOOK TEXT END]", book_text)
    end

    -- Web search (from feature config)
    local web_search = (type(feature_type) == "table" and feature_type.web_search)
        or (feature_config and feature_config.web_search)
    if web_search then
        query_options.web_search = true
    end

    local answer, err = Querier:query(message_history, loading_message, query_options)
    if err then
      assistant.querier:showError(err)
      return
    end

    table.insert(message_history, {
      role = "assistant",
      content = answer
    })

    -- Extract and persist X-Ray dictionary data
    if feature_type == "xray" or feature_type == "xray_dictionary_update" then
        local index = extractXRayIndex(answer)
        if index then
            local props = ui.document and ui.document.getProps and ui.document:getProps() or {}
            local book_hash = props.md5
                or (ui.document and ui.document.file and tostring(ui.document.file):gsub("[^%w]", "_"))
                or "unknown"
            local xray_data = assistant.settings:readSetting("xray_dictionary") or {}
            xray_data[book_hash] = mergeXRayData(
                xray_data[book_hash],
                index,
                formatted_progress_percent
            )
            assistant.settings:saveSetting("xray_dictionary", xray_data)
            assistant.settings:flush()
            logger.info("X-Ray dictionary updated for book:", book_hash)
        end
    end

    local chatgpt_viewer
    chatgpt_viewer = ChatGPTViewer:new {
      assistant = assistant,
      ui = ui,
      title = feature_title,
      text = createResultText(answer),
      disable_add_note = true,
      message_history = message_history,
      onAskQuestion = function(viewer, user_question)
        local viewer_title = ""

        if type(user_question) == "string" then
          prepareMessageHistoryForAdditionalQuestion(message_history, user_question, title, author)
        elseif type(user_question) == "table" then
          viewer_title = user_question.text or "Custom Prompt"
          table.insert(message_history, {
            role = "user",
            content = string.format("I'm reading something titled '%s' by %s. Only answer the following question, do not add any additional information or context that is not directly related to the question, the question is: %s", title, author, user_question.user_prompt or user_question)
          })
        end

        viewer:trimMessageHistory()
        NetworkMgr:runWhenOnline(function()
          Trapper:wrap(function()
            local answer, err = Querier:query(message_history, nil, query_options)
            
            if err then
              Querier:showError(err)
              return
            end
            
            table.insert(message_history, {
              role = "assistant",
              content = answer
            })
            local normalized_answer = normalizeMarkdownHeadings(answer, 3, 6) or answer
            local additional_text = "\n\n### ⮞ User: \n" .. (type(user_question) == "string" and user_question or (user_question.text or user_question)) .. "\n\n### ⮞ Assistant:\n" .. normalized_answer
            viewer:update(viewer.text .. additional_text)
            
            if viewer.scroll_text_w then
              viewer.scroll_text_w:resetScroll()
            end
          end)
        end)
      end,
      default_hold_callback = function ()
        chatgpt_viewer:HoldClose()
      end,
    }

    UIManager:show(chatgpt_viewer)
end

return {
    showFeatureDialog = showFeatureDialog,
    extractXRayIndex = extractXRayIndex,
    mergeXRayData = mergeXRayData,
}
