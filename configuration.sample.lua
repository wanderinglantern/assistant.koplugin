local CONFIGURATION = {
    -- Anthropic Claude API settings
    provider_settings = {
        anthropic = {
            model = "claude-sonnet-4-6",
            base_url = "https://api.anthropic.com/v1/messages",
            api_key = "your-anthropic-api-key",
            additional_parameters = {
                anthropic_version = "2023-06-01",
                max_tokens = 8096,
                stream = true,
            }
        },
    },

    -- Claude-specific feature flags
    -- These control Anthropic API features that improve quality and reduce cost.
    claude = {
        -- Extended thinking token budgets per feature (minimum 1024, set to 0 to disable).
        -- Thinking improves quality for complex analysis at the cost of latency.
        thinking_budget = {
            xray      = 10000,  -- X-Ray: complex multi-section narrative analysis
            recap     = 8000,   -- Recap: recent plot summary
            term_xray = 5000,   -- Term X-Ray: context-aware term analysis
            default   = 0,      -- All other features: no thinking
        },
        -- Prompt caching: cache book text in system prompt for session reuse.
        -- Second+ queries in a session cost ~10% of the original input token price.
        prompt_caching = true,
    },

    -- Optional features
    features = {
        hide_highlighted_text = false,         -- Set to true to hide the highlighted text at the top
        hide_long_highlights = true,           -- Hide highlighted text if longer than threshold
        long_highlight_threshold = 500,        -- Number of characters considered "long"
        render_markdown = true,                -- Set to true to render markdown in the AI responses
        updater_disabled = false,              -- Set to true to disable update check
        default_folder_for_logs = nil,         -- Set the default folder for auto saved logs
        max_text_length_for_analysis = 100000, -- max text length for xray/recap/book analysis
        max_page_size_for_analysis = 250,      -- max page count for page-based documents (PDF)

        -- Term X-Ray context expansion settings
        term_xray_context_sentences_before = 5,
        term_xray_context_sentences_after = 5,

        -- LexRank algorithm configuration
        lexrank_max_sentences = 2500,
        lexrank_min_selection_percentage = 0.99,
        lexrank_max_selection_percentage = 1.0,
        lexrank_threshold_term_specific = 0.01,
        lexrank_threshold_general = 0.01,
        lexrank_threshold_very_inclusive = 0.005,
        term_filter_context_window = 15,
        term_xray_max_characters = 100000,

        -- Custom prompts: override or add prompts shown as buttons in the dialog.
        -- Each prompt has: text, system_prompt, user_prompt, order, show_on_main_popup
        -- Available placeholders: {user_input},{highlight},{title},{author},{language},{progress}
        prompts = {
            -- example: myprompt = { text = "My Prompt", system_prompt = "...", user_prompt = "...", order = 50, show_on_main_popup = true },
        },

        book_level_prompts = {
            -- see wiki for examples
        },
    }
}

return CONFIGURATION
