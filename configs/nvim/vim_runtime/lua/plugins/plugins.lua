return {
    -- lazy.nvim
    {
        "robitx/gp.nvim",
        config = function()
            local conf = {
                agents = {
                    {
                        name = "gpt",
                        provider = "litellm",
                        chat = true,
                        command = true,
                        model = { model = "mify-gateway/gpt-5.2" },
                        system_prompt = "",
                    },
                    {
                        name = "mimo",
                        provider = "litellm",
                        chat = true,
                        command = true,
                        model = { model = "xiaomi/mimo-v2-flash" },
                        system_prompt = "",
                    },
                    {
                        name = "gemini-3-flash",
                        provider = "litellm",
                        chat = true,
                        command = true,
                        model = { model = "mify-gateway/gemini-3-flash" },
                        system_prompt = "",
                    }
                },
                providers = { 
                    openai = {},
                    litellm = { 
                        disable = false, 
                        endpoint = "http://127.0.0.1:4000/chat/completions", 
                        secret = os.getenv("LITELLM_PROXY_API_KEY"), 
                    }
                }
            }
            require("gp").setup(conf)

            -- Setup shortcuts here (see Usage > Shortcuts in the Documentation/Readme)
        end,
    },
    { "pablopunk/pi.nvim" },
    {
        -- pi-chat.nvim: Neovim front-end for the pi coding agent via RPC mode.
        -- Local plugin, source lives in the dev-env-setup repo.
        dir = vim.fn.expand("~/dev-env-setup/nvim-plugins/pi-chat.nvim"),
        dependencies = { "MeanderingProgrammer/render-markdown.nvim" },
        cmd = {
            "PiChat", "PiChatOpen", "PiChatClose", "PiChatAsk", "PiChatAskSelection",
            "PiChatModel", "PiChatSessions", "PiChatContinue", "PiChatNew", "PiChatInfo",
        },
        keys = {
            { "<leader>pc", "<cmd>PiChat<cr>", desc = "pi-chat toggle" },
            { "<leader>pa", "<cmd>PiChatAsk<cr>", desc = "pi-chat ask" },
            { "<leader>pn", "<cmd>PiChatNew<cr>", desc = "pi-chat new session" },
            { "<leader>pv", ":PiChatAskSelection<cr>", mode = "v", desc = "pi-chat ask selection" },
        },
        opts = {},
        config = function(_, opts)
            require("pi-chat").setup(opts)
        end,
    },
    {
        -- render-markdown: pulled in by pi-chat. Default behaviour for real
        -- markdown files is unchanged; we only ADD a soft style for pi-chat's
        -- dedicated `pichat` filetype so the conversation reads calmly.
        "MeanderingProgrammer/render-markdown.nvim",
        dependencies = { "nvim-tree/nvim-web-devicons" },
        ft = { "markdown", "pichat" },
        opts = {
            file_types = { "markdown", "pichat" },
            overrides = {
                filetype = {
                    -- Calm preset for the pi-chat conversation buffer.
                    pichat = {
                        -- render-markdown reads the GLOBAL editor mode, not the
                        -- per-window mode. The input pane sits in insert mode
                        -- while you type, so without 'i' here the conversation
                        -- would show raw markdown (**bold**, # heading) until you
                        -- left insert mode. Include 'i' so it always renders.
                        render_modes = { "n", "c", "t", "i" },
                        heading = {
                            -- No full-width background blocks; small inline icon.
                            backgrounds = {},
                            icons = { "▸ ", "▸ ", "▸ ", "▸ ", "▸ ", "▸ " },
                            position = "inline",
                            width = "block",
                            left_pad = 0,
                            right_pad = 1,
                            sign = false,
                        },
                        code = {
                            -- Quiet code blocks: subtle background, no heavy border,
                            -- language name shown but no big banner.
                            style = "normal",
                            border = "thin",
                            sign = false,
                            left_pad = 1,
                            right_pad = 1,
                        },
                        dash = { enabled = false }, -- we draw our own role rules
                        sign = { enabled = false },
                    },
                },
            },
        },
    },
    {
        "nvim-pack/nvim-spectre",
        dependencies = { "nvim-lua/plenary.nvim" },
        config = function()
            require('spectre').setup({
                -- 这里可以添加你的自定义配置，默认即可用
                open_cmd = 'vnew', -- 打开 Spectre 面板的命令，可改为 'vsplit'/'split'/'tabnew'
                live_update = true, -- 实时预览替换结果
                line_sep_start = "┌-----------------------------------------",
                result_padding = "│ ",
                line_sep       = "└-----------------------------------------",
            })
            -- 可选：绑定快捷键
            vim.keymap.set('n', '<leader>sr', function() require('spectre').open() end, { desc = '打开 Spectre 搜索替换' })
            vim.keymap.set('n', '<leader>sw', function() require('spectre').open_visual({select_word=true}) end, { desc = '搜索光标下单词' })
            vim.keymap.set('v', '<leader>sw', function() require('spectre').open_visual() end, { desc = '搜索选中文本' })
        end,
    },
    {
        "sindrets/diffview.nvim",
        event = "BufRead",
        config = function()
            require("diffview").setup()
        end,
    },
    -- nvim-treesitter removed: nvim 0.12+ has native treesitter support
    -- Parsers are bundled or installed via :TSInstall (built-in)
    {
        "sindrets/diffview.nvim",
        event = "BufRead",
        config = function()
            require("diffview").setup()
        end,
    },
    {
        "SmiteshP/nvim-navic",
        dependencies = "neovim/nvim-lspconfig",
        config = function()
            require("nvim-navic").setup()
        end,
    },
    {
        -- gitsigns
        "lewis6991/gitsigns.nvim",
        event = "BufRead",
        config = function()
            require("gitsigns").setup({
                current_line_blame = true, -- Enable inline blame
                on_attach = function(bufnr)
                    local gs = package.loaded.gitsigns

                    local function map(mode, l, r, opts)
                        opts = opts or {}
                        opts.buffer = bufnr
                        vim.keymap.set(mode, l, r, opts)
                    end

                    -- Navigation
                    map('n', ']c', function()
                        if vim.wo.diff then return ']c' end
                        vim.schedule(function() gs.next_hunk() end)
                        return '<Ignore>'
                    end, {expr=true})

                    map('n', '[c', function()
                        if vim.wo.diff then return '[c' end
                        vim.schedule(function() gs.prev_hunk() end)
                        return '<Ignore>'
                    end, {expr=true})
                end
            })
        end,
    },
    -- {
        --     "CopilotC-Nvim/CopilotChat.nvim",
        --     branch = "main",
        --     dependencies = {
            --         { "zbirenbaum/copilot.lua" }, -- or github/copilot.vim
            --         { "nvim-lua/plenary.nvim" }, -- for curl, log wrapper
            --     },
            --     build = "make tiktoken", -- Only on MacOS or Linux
            --     opts = {
                --         debug = true, -- Enable debugging
                --         -- See Configuration section for rest
                --     },
                --     -- See Commands section for default commands if you want to lazy load on them
                -- },
                -- sqls.nvim
                {
                    "nanotee/sqls.nvim",
                    ft = "sql",
                },

                -- minimap.vim
                {
                    "wfxr/minimap.vim",
                    run = "cargo install --locked code-minimap",
                    cmd = "Minimap",
                },
                {
                    "folke/which-key.nvim",
                    event = "VeryLazy",
                    opts = {
                        -- your configuration comes here
                        -- or leave it empty to use the default settings
                        -- refer to the configuration section below
                    },
                    keys = {},
                },
                {
                    -- Hop
                    "phaazon/hop.nvim",
                    event = "BufRead",
                    branch = "v2",
                    config = function()
                        require("hop").setup()
                    end,
                },
                {
                    "HakonHarnes/img-clip.nvim",
                    event = "VeryLazy",
                    opts = {
                        -- add options here
                        -- or leave it empty to use the default settings
                    },
                    keys = {
                        -- suggested keymap
                        { "<leader>p", "<cmd>PasteImage<cr>", desc = "Paste image from system clipboard" },
                    },
                },
                {
                    "folke/trouble.nvim",
                    opts = {}, -- for default options, refer to the configuration section for custom setup.
                    cmd = "Trouble",
                    keys = {
                        {
                            "<leader>xx",
                            "<cmd>Trouble diagnostics toggle<cr>",
                            desc = "Diagnostics (Trouble)",
                        },
                        {
                            "<leader>xX",
                            "<cmd>Trouble diagnostics toggle filter.buf=0<cr>",
                            desc = "Buffer Diagnostics (Trouble)",
                        },
                        {
                            "<leader>cs",
                            "<cmd>Trouble symbols toggle focus=false<cr>",
                            desc = "Symbols (Trouble)",
                        },
                        {
                            "<leader>cl",
                            "<cmd>Trouble lsp toggle focus=false win.position=right<cr>",
                            desc = "LSP Definitions / references / ... (Trouble)",
                        },
                        {
                            "<leader>xL",
                            "<cmd>Trouble loclist toggle<cr>",
                            desc = "Location List (Trouble)",
                        },
                        {
                            "<leader>xQ",
                            "<cmd>Trouble qflist toggle<cr>",
                            desc = "Quickfix List (Trouble)",
                        },
                    },
                },
                -- UI and Themes
                -- { "vim-airline/vim-airline" },
                -- { "vim-airline/vim-airline-themes" },
                {
                    "nvim-lualine/lualine.nvim",
                    dependencies = {
                        "nvim-tree/nvim-web-devicons",
                        "SmiteshP/nvim-navic",
                    },
                    config = function()
                        require("lualine").setup({
                            sections = {
                                lualine_c = {
                                    { "filename" },
                                    {
                                        function()
                                            return require("nvim-navic").get_location()
                                        end,
                                        cond = function()
                                            return require("nvim-navic").is_available()
                                        end,
                                    },
                                },
                            },
                        })
                    end,
                },
                {
                    -- nightfox
                    "EdenEast/nightfox.nvim",
                    config = function()
                        require("nightfox").load()
                    end,
                },
                {
                    -- colorizer
                    "norcalli/nvim-colorizer.lua",
                },
                {
                    "nanozuki/tabby.nvim",
                    -- event = 'VimEnter', -- if you want lazy load, see below
                    dependencies = "nvim-tree/nvim-web-devicons",
                    config = function()
                        -- configs...
                    end,
                },
                { "akinsho/bufferline.nvim", version = "*", dependencies = "nvim-tree/nvim-web-devicons" },
                { "nanotech/jellybeans.vim" },
                { "morhetz/gruvbox" },
                { "altercation/vim-colors-solarized" },
                { "ap/vim-css-color" },

                -- File Navigation and Search
                {
                    "scrooloose/nerdtree",
                    cmd = "NERDTreeToggle",
                    keys = {
                        { "<leader>nn", ":NERDTreeToggle<CR>", desc = "Toggle NERDTree" },
                        { "<leader>nb", ":NERDTreeFromBookmark<Space>", desc = "NERDTree from Bookmark" },
                        { "<leader>nf", ":NERDTreeFind<CR>", desc = "NERDTree Find" },
                    },
                },
                { "Xuyuanp/nerdtree-git-plugin", dependencies = { "scrooloose/nerdtree" } },
                { "ctrlpvim/ctrlp.vim" },
                {
                    "junegunn/fzf",
                    build = function()
                        vim.fn["fzf#install"]()
                    end,
                },
                { "junegunn/fzf.vim", dependencies = { "junegunn/fzf" } },
                {
                    "ibhagwan/fzf-lua",
                    -- optional for icon support
                    dependencies = { "nvim-tree/nvim-web-devicons" },
                    -- or if using mini.icons/mini.nvim
                    -- dependencies = { "echasnovski/mini.icons" },
                    opts = {},
                },
                { "mileszs/ack.vim" },
                -- { "dyng/ctrlsf.vim" },

                -- Code Editing and Navigation
                { "tpope/vim-surround" },
                { "tpope/vim-repeat" },
                { "tpope/vim-commentary" },
                { "tpope/vim-unimpaired" },
                { "michaeljsmith/vim-indent-object" },
                { "wellle/targets.vim" },
                { "easymotion/vim-easymotion" },
                { "andymass/vim-matchup" },

                -- Git Integration
                { "tpope/vim-fugitive" },

                -- Language Support
                { "neovim/nvim-lspconfig" },
                { "williamboman/mason.nvim" },
                { "williamboman/mason-lspconfig.nvim" },
                { "hrsh7th/nvim-cmp" },
                { "hrsh7th/cmp-nvim-lsp" },
                { "hrsh7th/cmp-buffer" },
                { "hrsh7th/cmp-path" },
                { "L3MON4D3/LuaSnip" },
                { "saadparwaiz1/cmp_luasnip" },
                -- { "github/copilot.vim" },
                -- { "jose-elias-alvarez/null-ls.nvim" },

                -- Language-specific plugins
                { "pangloss/vim-javascript" },
                { "leafgarland/typescript-vim" },
                { "maxmellon/vim-jsx-pretty" },
                { "jparise/vim-graphql" },
                { "posva/vim-vue" },
                { "lervag/vimtex" },
                { "JuliaEditorSupport/julia-vim" },
                { "neovimhaskell/haskell-vim" },
                { "alx741/vim-hindent" },

                -- Misc
                { "junegunn/vim-easy-align" },
                { "junegunn/rainbow_parentheses.vim" },
                { "Raimondi/delimitMate" },
                { "xolox/vim-session", dependencies = { "xolox/vim-misc" } },
                { "Chiel92/vim-autoformat" },
                { "nanotee/zoxide.vim" },

                -- Smooth Scrolling
                {
                    "karb94/neoscroll.nvim",
                    config = function()
                        require("neoscroll").setup()
                    end,
                },

                -- Neovim-specific plugins
                {
                    "Vigemus/iron.nvim",
                    cond = vim.fn.has("nvim") == 1,
                },
                {
                    "Yggdroot/indentLine",
                    cond = vim.fn.has("nvim") == 1,
                },
                {
                    "ms-jpq/coq_nvim",
                    branch = "coq",
                    cond = vim.fn.has("nvim") == 1,
                },
                {
                    "ms-jpq/coq.artifacts",
                    branch = "artifacts",
                    cond = vim.fn.has("nvim") == 1,
                },
                {
                    "nvim-lua/plenary.nvim",
                    cond = vim.fn.has("nvim") == 1,
                },
                {
                    "nvim-telescope/telescope.nvim",
                    dependencies = { "nvim-lua/plenary.nvim" },
                    cond = vim.fn.has("nvim") == 1,
                },
                -- starttime
                {
                    "dstein64/vim-startuptime",
                    cmd = "StartupTime",
                    keys = {
                        { "<leader>tt", ":StartupTime<CR>", desc = "Show startup time" },
                    },
                },

                -- Local plugins
                { dir = "~/.vim_runtime/sources_forked/peaksea" },
                { dir = "~/.vim_runtime/sources_forked/vim-peepopen" },
                { dir = "~/.vim_runtime/sources_forked/vim-irblack-forked" },
                {
                    "elzr/vim-json",
                    ft = { "json", "jsonc" }, -- 仅在打开 json 或 jsonc 文件时加载
                    config = function()
                        -- 可选的配置 (根据你的需要调整)
                        vim.g.vim_json_syntax_conceal = 0 -- 禁用隐藏字符，更容易看到引号等
                    end,
                },
                {
                    "othree/yajs.vim",
                    ft = { "json", "jsonc" },
                },
                -- {
                    --     "3rd/image.nvim",
                    --     config = function()
                        --         require("image").setup()
                        --     end,
                        -- },
    -- OSC 52 clipboard: copy from remote nvim to local clipboard over SSH+tmux
    {
        "ojroques/nvim-osc52",
        config = function()
            require("osc52").setup({ max_length = 0, silent = true, trim = false })
            -- Auto-copy to local clipboard on any yank
            vim.api.nvim_create_autocmd("TextYankPost", {
                callback = function()
                    if vim.v.event.operator == "y" and (
                        vim.v.event.regname == "+" or
                        vim.v.event.regname == "*" or
                        vim.v.event.regname == ""
                    ) then
                        require("osc52").copy_register("+")
                    end
                end,
            })
        end,
    },
                    }
