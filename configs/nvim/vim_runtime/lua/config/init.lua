-- OSC 52 clipboard handled by nvim-osc52 plugin (see plugins.lua)

-- lualine
require("lualine").setup({
        options = {
                section_separators = { "", "" },
                component_separators = { "", "" },
        },
        sections = {
                lualine_a = { "mode" },
                lualine_b = { "branch" },
                lualine_c = { "filename" },
                lualine_x = { "encoding", "fileformat", "filetype" },
                lualine_y = { "progress" },
                lualine_z = { "location" },
        },
})

-- fzf-lua configuration
require("fzf-lua").setup({
        files = {
                cmd = "fd --type f --hidden --no-ignore "
                        .. "--no-ignore-vcs "
                        .. "--exclude .git "
                        .. "--exclude node_modules "
                        .. "--exclude .next "
                        .. "--exclude dist "
                        .. "--exclude build "
                        .. "--exclude __pycache__ "
                        .. "--exclude .pytest_cache "
                        .. "--exclude .venv "
                        .. "--exclude venv "
                        .. "--exclude .mypy_cache "
                        .. "--exclude .ruff_cache "
                        .. "--exclude .cache "
                        .. "--exclude .DS_Store",
        },
})

-- LSP Configuration
local navic = require("nvim-navic")
require("mason").setup({})
require("mason-lspconfig").setup({})

-- Ensure Mason bin is in PATH (for vim.lsp.config cmd lookup)
local mason_bin = vim.fn.stdpath("data") .. "/mason/bin"
vim.env.PATH = mason_bin .. ":" .. vim.env.PATH

local on_attach = function(client, bufnr)
        if client.server_capabilities.documentSymbolProvider then
                navic.attach(client, bufnr)
        end

        local opts = { noremap = true, silent = true }
        local buf_set_keymap = vim.api.nvim_buf_set_keymap

        -- Key mappings
        buf_set_keymap(bufnr, "n", "gd", "<cmd>lua vim.lsp.buf.definition()<CR>", opts)
        buf_set_keymap(bufnr, "n", "K", "<cmd>lua vim.lsp.buf.hover()<CR>", opts)
        buf_set_keymap(bufnr, "n", "<leader>rn", "<cmd>lua vim.lsp.buf.rename()<CR>", opts)
end

local capabilities = require("cmp_nvim_lsp").default_capabilities()

-- Helper to setup LSP using lspconfig (Bypassing deprecation warning)
local function setup_lsp(name, opts)
    -- Access the internal configs registry directly to avoid the warning in the main module's __index
    local lsp_configs = require("lspconfig.configs")
    
    -- If the config hasn't been loaded/hydrated yet, load it manually
    if not lsp_configs[name] then
        local ok, config_def = pcall(require, "lspconfig.configs." .. name)
        if ok then
            -- Assigning to the registry triggers the __newindex metamethod
            -- which "hydrates" the config with the .setup() method
            lsp_configs[name] = config_def
        else
            vim.notify("Could not find config for " .. name, vim.log.levels.ERROR)
            return
        end
    end

    -- Now we can call setup() on the hydrated config object
    if lsp_configs[name].setup then
        -- Merge options if needed, though setup() handles user_config
        opts = opts or {}
        opts.on_attach = opts.on_attach or on_attach
        opts.capabilities = opts.capabilities or capabilities
        
        lsp_configs[name].setup(opts)
    else
        vim.notify("Config for " .. name .. " is missing setup() method", vim.log.levels.ERROR)
    end
end

-- Pyright
setup_lsp("pyright", {
        cmd = { mason_bin .. "/pyright-langserver", "--stdio" },
        on_attach = on_attach,
        capabilities = capabilities,
        root_dir = function(fname)
                -- Use the directory containing the file as the root if no project root is found
                return vim.fs.root(fname, {
                        "pyrightconfig.json",
                        "setup.py",
                        "setup.cfg",
                        "pyproject.toml",
                        ".git",
                }) or vim.fn.fnamemodify(fname, ":p:h")
        end,
        settings = {
                python = {
                        analysis = {
                                autoSearchPaths = true,
                                useLibraryCodeForTypes = true,
                                diagnosticSeverityOverrides = {
                                        reportUnknownMemberType = "none",
                                        reportUnknownParameterType = "none",
                                        reportUnknownVariableType = "none",
                                        reportUnknownArgumentType = "none",
                                },
                        },
                },
        },
})

-- Ruff
setup_lsp("ruff", {
    cmd = { mason_bin .. "/ruff", "server" },
    root_dir = function(fname)
        return vim.fs.root(fname, {
            "pyproject.toml",
            "ruff.toml",
            ".ruff.toml",
            ".git",
        }) or vim.fn.fnamemodify(fname, ":p:h")
    end,
})

-- Java (jdtls)
setup_lsp("jdtls", {
    cmd = { mason_bin .. "/jdtls" },
    on_attach = on_attach,
    capabilities = capabilities,
    root_dir = function(fname)
        return vim.fs.root(fname, {
            "pom.xml",
            "build.gradle",
            "build.gradle.kts",
            ".git",
        }) or vim.fn.fnamemodify(fname, ":p:h")
    end,
    settings = {
        java = {
            configuration = {
                runtimes = {
                    { name = "JavaSE-21", path = "/opt/homebrew/opt/openjdk@21" },
                },
            },
        },
    },
})

-- Other servers
local servers = { "ts_ls", "jsonls", "gopls", "sqls" }
for _, lsp in ipairs(servers) do
     setup_lsp(lsp, {
         on_attach = on_attach,
         capabilities = capabilities,
     })
end

-- lua_ls needs full path since Homebrew bin may not be in Neovim's PATH
setup_lsp("lua_ls", {
    cmd = { "/opt/homebrew/bin/lua-language-server" },
    on_attach = on_attach,
    capabilities = capabilities,
})

-- Set up nvim-cmp.
local cmp = require("cmp")
cmp.setup({
        snippet = {
                expand = function(args)
                        require("luasnip").lsp_expand(args.body)
                end,
        },
        mapping = cmp.mapping.preset.insert({
                ["<C-b>"] = cmp.mapping.scroll_docs(-4),
                ["<C-f>"] = cmp.mapping.scroll_docs(4),
                ["<C-Space>"] = cmp.mapping.complete(),
                ["<C-e>"] = cmp.mapping.abort(),
                ["<CR>"] = cmp.mapping.confirm({ select = true }),
        }),
        sources = cmp.config.sources({
                { name = "nvim_lsp" },
                { name = "luasnip" },
        }, {
                { name = "buffer" },
        }),
})
local augroup = vim.api.nvim_create_augroup("LspFormatting", {})
-- local null_ls = require("null-ls")
-- null_ls.setup({
--      on_attach = function(client, bufnr)
--              if client.supports_method("textDocument/formatting") then
--                      vim.api.nvim_clear_autocmds({ group = augroup, buffer = bufnr })
--                      vim.api.nvim_create_autocmd("BufWritePre", {
--                              group = augroup,
--                              buffer = bufnr,
--                              callback = function()
--                                      -- on 0.8, you should use vim.lsp.buf.format({ bufnr = bufnr }) instead
--                                      vim.lsp.buf.format({ bufnr = bufnr })
--                              end,
--                      })
--              end
--      end,
--      sources = {
--              null_ls.builtins.formatting.stylua,
--              null_ls.builtins.formatting.ruff.with({
--                      extra_args = { "--line-length", "79" },
--              }),
--              null_ls.builtins.diagnostics.ruff,
--      },
-- })
-- toggle autoformatting --
local format_enabled = true

function ToggleAutoFormat()
        format_enabled = not format_enabled
        if format_enabled then
                print("Autoformat enabled")
        else
                vim.api.nvim_clear_autocmds({ group = "LspFormatting" })
                print("Autoformat disabled")
        end
end

vim.api.nvim_set_keymap("n", "<leader>tf", "<cmd>lua ToggleAutoFormat()<CR>", { noremap = true, silent = true })
--

-- set termguicolors
vim.o.termguicolors = true

-- setup for nvim-colorizer
require("colorizer").setup({
        "*", -- Highlight all files, but you can also restrict to specific file types
}, {
        RGB = true, -- #RGB hex codes
        RRGGBB = true, -- #RRGGBB hex codes
        names = false, -- Disable "Name" colors like Blue or Green
        RRGGBBAA = true, -- #RRGGBBAA hex codes
        rgb_fn = false, -- Disable CSS rgb() and rgba() functions
        hsl_fn = false, -- Disable CSS hsl() and hsla() functions
        css = true, -- Enable all CSS features: rgb_fn, hsl_fn, names, RGB, RRGGBB
        css_fn = true, -- Enable all CSS *functions*: rgb_fn, hsl_fn
})

require("nightfox").setup({
        options = {
                transparent = false,
                dim_inactive = false,
                styles = {
                        comments = "italic",
                        keywords = "bold",
                },
        },
})

vim.api.nvim_set_keymap("n", "<leader>ta", ":$tabnew<CR>", { noremap = true })
vim.api.nvim_set_keymap("n", "<leader>tc", ":tabclose<CR>", { noremap = true })
vim.api.nvim_set_keymap("n", "<leader>to", ":tabonly<CR>", { noremap = true })
vim.api.nvim_set_keymap("n", "<leader>tn", ":tabn<CR>", { noremap = true })
vim.api.nvim_set_keymap("n", "<leader>tp", ":tabp<CR>", { noremap = true })
-- move current tab to previous position
vim.api.nvim_set_keymap("n", "<leader>tmp", ":-tabmove<CR>", { noremap = true })
-- move current tab to next position
vim.api.nvim_set_keymap("n", "<leader>tmn", ":+tabmove<CR>", { noremap = true })

-- Function to toggle colorscheme
function ToggleColorSchemes()
    if vim.g.colors_name == "nightfox" then
        vim.cmd("colorscheme peaksea")
    else
        vim.cmd("colorscheme nightfox")
    end
end
vim.keymap.set("n", "<leader>cm", "<cmd>lua ToggleColorSchemes()<CR>", { noremap = true, silent = true, desc = "Toggle colorscheme" })


vim.o.showtabline = 2 -- 2 means show tabline only when there are more than one tab

-- Tabby: Handle Tabs
require("tabby").setup({
        preset = "active_wins_at_tail",
        option = {
                theme = {
                        fill = "TabLineFill",
                        head = "TabLine",
                        current_tab = "TabLineSel",
                        tab = "TabLine",
                        win = "TabLine",
                        tail = "TabLine",
                },
                nerdfont = true,
                lualine_theme = nil,
                tab_name = {
                        name_fallback = function(tabid)
                                return "Tab " .. tabid
                        end,
                },
                buf_name = {
                        mode = "tail",
                },
        },
})

-- Bufferline: Focus on Buffers and Avoid Showing Tabs
require("bufferline").setup({
        options = {
                numbers = "ordinal",
                show_buffer_close_icons = false,
                show_close_icon = false,
                show_tab_indicators = false, -- Disable tab indicators to prevent confusion with Tabby
                always_show_bufferline = true, -- Show bufferline even with single buffer
                diagnostics = "nvim_lsp", -- Optional: Show LSP diagnostics on bufferline
                max_name_length = 15,
                max_prefix_length = 15,
        },
})

vim.cmd([[
  augroup diagnostics
    autocmd!
    autocmd BufEnter * lua vim.diagnostic.open_float(nil, {focus=true})
  augroup END
]])
-- bind <leader>da to open float diagnostics
vim.api.nvim_set_keymap("n", "<leader>da", ":lua vim.diagnostic.open_float(nil, {focus=true})<CR>", { noremap = true })

-- key for hop.nvim
vim.api.nvim_set_keymap("n", "s", ":HopWord<CR>", { silent = true })

-- In your init.lua or a dedicated keymaps file
local wk = require("which-key")
wk.add({
        { "<space>z", "<cmd>e ~/.zshrc<CR>", desc = "Open Zsh configuration" },
        { "<leader>jq", "<cmd>%!jq .<CR>", desc = "Format" },
        { "<leader>c", group = "ChatGPT" },
        { "<leader>cc", "<cmd>ChatGPT<CR>", desc = "ChatGPT" },
        {
                mode = { "n", "v" },
                { "<leader>ca", "<cmd>ChatGPTRun add_tests<CR>", desc = "Add Tests" },
                { "<leader>cd", "<cmd>ChatGPTRun docstring<CR>", desc = "Docstring" },
                { "<leader>ce", "<cmd>ChatGPTEditWithInstruction<CR>", desc = "Edit with instruction" },
                { "<leader>cf", "<cmd>ChatGPTRun fix_bugs<CR>", desc = "Fix Bugs" },
                { "<leader>cg", "<cmd>ChatGPTRun grammar_correction<CR>", desc = "Grammar Correction" },
                { "<leader>ck", "<cmd>ChatGPTRun keywords<CR>", desc = "Keywords" },
                { "<leader>cl", "<cmd>ChatGPTRun code_readability_analysis<CR>", desc = "Code Readability Analysis" },
                { "<leader>co", "<cmd>ChatGPTRun optimize_code<CR>", desc = "Optimize Code" },
                { "<leader>cr", "<cmd>ChatGPTRun roxygen_edit<CR>", desc = "Roxygen Edit" },
                { "<leader>cs", "<cmd>ChatGPTRun summarize<CR>", desc = "Summarize" },
                { "<leader>ct", "<cmd>ChatGPTRun taanslate<CR>", desc = "Translate" },
                { "<leader>cx", "<cmd>ChatGPTRun explain_code<CR>", desc = "Explain Code" },
        },
        {
                mode = { "v" },
                { "<leader>c", group = "ChatGPT" },
                { "<leader>ca", "<cmd>ChatGPTRun add_tests<CR>", desc = "Add Tests" },
                { "<leader>cd", "<cmd>ChatGPTRun docstring<CR>", desc = "Docstring" },
                { "<leader>ce", "<cmd>ChatGPTEditWithInstruction<CR>", desc = "Edit with instruction" },
                { "<leader>cf", "<cmd>ChatGPTRun fix_bugs<CR>", desc = "Fix Bugs" },
                { "<leader>cg", "<cmd>ChatGPTRun grammar_correction<CR>", desc = "Grammar Correction" },
                { "<leader>ck", "<cmd>ChatGPTRun keywords<CR>", desc = "Keywords" },
                { "<leader>cl", "<cmd>ChatGPTRun code_readability_analysis<CR>", desc = "Code Readability Analysis" },
                { "<leader>co", "<cmd>ChatGPTRun optimize_code<CR>", desc = "Optimize Code" },
                { "<leader>cr", "<cmd>ChatGPTRun roxygen_edit<CR>", desc = "Roxygen Edit" },
                { "<leader>cs", "<cmd>ChatGPTRun summarize<CR>", desc = "Summarize" },
                { "<leader>ct", "<cmd>ChatGPTRun translate<CR>", desc = "Translate" },
                { "<leader>cx", "<cmd>ChatGPTRun explain_code<CR>", desc = "Explain Code" },
        },
})

vim.opt.number = true
vim.opt.relativenumber = true

-- Set up luasnip
local ls = require("luasnip")
local s = ls.snippet
local t = ls.text_node
local i = ls.insert_node
vim.keymap.set({ "i", "s" }, "<C-k>", function()
        if ls.expand_or_jumpable() then
                ls.expand_or_jump()
        end
end, { silent = true })
ls.add_snippets("python", {
        s("ipdb", {
                t("import ipdb; ipdb.set_trace()"),
        }),
        -- add snippet for pudb
        s("pudb", {
                t("import pudb; pudb.set_trace()"),
        }),
})

local actions = require("telescope.actions")
local action_state = require("telescope.actions.state")

local function close_selected_buffers(prompt_bufnr)
        local picker = action_state.get_current_picker(prompt_bufnr)
        local multi_selection = picker:get_multi_selection()

        if #multi_selection > 0 then
                actions.close(prompt_bufnr)
                for _, entry in ipairs(multi_selection) do
                        vim.api.nvim_buf_delete(entry.bufnr, { force = true })
                end
        else
                local selection = action_state.get_selected_entry()
                actions.close(prompt_bufnr)
                if selection then
                        vim.api.nvim_buf_delete(selection.bufnr, { force = true })
                end
        end
end

vim.keymap.set("n", "<leader>bc", function()
        require("telescope.builtin").buffers({
                attach_mappings = function(prompt_bufnr, map)
                        map("i", "<CR>", function()
                                close_selected_buffers(prompt_bufnr)
                        end)
                        map("n", "<CR>", function()
                                close_selected_buffers(prompt_bufnr)
                        end)
                        return true
                end,
        })
end)

vim.api.nvim_create_user_command("RgContent", function(opts)
        fzf = require("fzf-lua")
        fzf.live_grep({
                search = opts.args,
                previewer = "builtin",
        exclude = { ".git", "node_modules", "vendor", "logs" }, -- Exclude common directories
        })
end, { nargs = "*", bang = true })
vim.keymap.set(
        "n",
        "<leader>rg",
        ":RgContent<CR>",
        { noremap = true, silent = true, desc = "Search file contents with fzf-lua" }
)

-- Generic function to select options and run a command
local function select_and_run_generic_command(options, prompt, action_func)
        require("fzf-lua").fzf_exec(options, {
                prompt = prompt .. ": ",
                winopts = { width = 0.5, height = 0.3 },
                actions = {
                        ["default"] = function(selected)
                                action_func(selected[1])
                        end,
                },
        })
end

-- Function to open config file
local function open_config_file(selected)
        vim.cmd(":e! ~/.vim_runtime/" .. selected)
end

-- Function to select config file
local function select_config_file()
        local options = {
                "my_configs.vim",
                "lua/config/init.lua",
                "lua/plugins/plugins.lua",
                "vimrcs/basic.vim",
                "vimrcs/extended.vim",
                "vimrcs/filetypes.vim",
                "vimrcs/plugins_config.vim",
        }
        select_and_run_generic_command(options, "Select config file", open_config_file)
end

-- Map the custom functions to their respective keybindings
vim.keymap.set("n", "<leader>ee", select_config_file, { desc = "Select config file to Open" })

-- Function to set file type
local function set_file_type(selected)
        vim.cmd(":set filetype=" .. selected)
end

-- Function to select file type
local function select_file_type()
        -- Comprehensive list of common filetypes
        local options = {
                "python",
                "javascript",
                "typescript",
                "json",
                "html",
                "css",
                "markdown",
                "vim",
                "lua",
                "sh",
                "bash",
                "yaml",
                "toml",
                "xml",
                "rust",
                "go",
                "c",
                "cpp",
                "java",
                "php",
                "ruby",
                "perl",
                "sql",
                "dockerfile",
                "conf",
                "text",
                "tex",
        }
        select_and_run_generic_command(options, "Select filetype", set_file_type)
end

-- Map the file type selection function to <leader>af
vim.keymap.set("n", "<leader>ef", select_file_type, { desc = "Select filetype to Set" })

-- Function to checkout a specific Git version of the current file
local function checkout_file_version()
        -- Get the full file path for the current buffer
        local file = vim.api.nvim_buf_get_name(0)
        if file == "" then
                vim.notify("No file name found for the current buffer.", vim.log.levels.ERROR)
                return
        end

        -- Retrieve the commit history for the file with author and relative time.
        -- Format: "%h - %s (%an, %ar)"
        --   %h: Short commit hash
        --   %s: Commit message
        --   %an: Author name
        --   %ar: Relative time (e.g., "2 hours ago")
        local cmd = "git --no-pager log --pretty=format:'%h - %s (%an, %ar)' " .. file
        local commits = vim.fn.systemlist(cmd)
        if vim.v.shell_error ~= 0 then
                vim.notify("Error retrieving commit history for " .. file, vim.log.levels.ERROR)
                return
        end

        if #commits == 0 then
                vim.notify("No commits found for " .. file, vim.log.levels.INFO)
                return
        end

        -- Let the user select a commit from the list
        vim.ui.select(commits, { prompt = "Select commit to checkout version:" }, function(selected)
                if selected then
                        -- Extract the commit hash (assumes the hash is the first word)
                        local commit = selected:match("^(%w+)")
                        if commit then
                                -- Build and run the git checkout command.
                                -- This checks out the file in the working directory to that commit's version.
                                local checkout_cmd = "git checkout " .. commit .. " -- " .. file
                                local result = vim.fn.system(checkout_cmd)
                                if vim.v.shell_error == 0 then
                                        vim.notify("Checked out version " .. commit .. " for " .. file, vim.log.levels.INFO)
                                        -- Optionally reload the file after checkout
                                        vim.cmd("edit!")
                                else
                                        vim.notify("Error checking out version: " .. result, vim.log.levels.ERROR)
                                end
                        else
                                vim.notify("Could not extract the commit hash.", vim.log.levels.ERROR)
                        end
                end
        end)
end

-- Map the new function to a keybinding (for example, <leader>ev)
vim.keymap.set("n", "<leader>gv", checkout_file_version, {
        desc = "Checkout a specific version of the current file from Git",
})

-- set conceallevel to 0 for json
vim.cmd("autocmd FileType json setlocal conceallevel=0")

-- Function to insert current datetime
function InsertDateTime()
        local datetime = os.date("%Y-%m-%d %A %H:%M:%S")
        vim.api.nvim_put({ datetime }, "c", true, true)
end

-- Map the datetime function to <leader>td
vim.api.nvim_set_keymap(
        "n",
        "<leader>td",
        "<cmd>lua InsertDateTime()<CR>",
        { noremap = true, silent = true, desc = "Insert current datetime" }
)

-- Function to select conceallevel from 0, 1, 2, 3
function SelectConcealLevel()
        local fzf = require("fzf-lua")
        local options = {
                "0 - No concealing",
                "1 - Conceal text with one-character placeholder",
                "2 - Completely hide concealed text",
                "3 - Completely hide concealed text (including hl-Conceal)",
        }

        fzf.fzf_exec(options, {
                prompt = "Select conceal level: ",
                winopts = { width = 0.5, height = 0.3 },
                actions = {
                        ["default"] = function(selected)
                                local level = tonumber(selected[1]:match("^(%d+)"))
                                vim.o.conceallevel = level
                                print("Conceal level set to: " .. level .. " - " .. selected[1]:match("- (.+)"))
                        end,
                },
        })
end

-- Map the select function to <leader>ts
vim.api.nvim_set_keymap(
        "n",
        "<leader>ts",
        "<cmd>lua SelectConcealLevel()<CR>",
        { noremap = true, silent = true, desc = "Select conceal level" }
)

-- 减少键映射的等待时间
vim.opt.timeout = true
vim.opt.timeoutlen = 300 -- 映射等待时间
vim.opt.ttimeoutlen = 50 -- 键码等待时间

-- copilot disable files rules
vim.api.nvim_create_autocmd("FileType", {
    pattern = {"markdown", "text", "plaintext"}, -- 指定不想使用 Copilot 的文件类型
    callback = function()
        vim.b.copilot_enabled = false -- 禁用 Copilot 自动补全
    end,
})

-- disable copilot in .env and .envrc
vim.api.nvim_create_autocmd("BufRead", {
    pattern = {"*.env", "*.envrc"},
    callback = function()
        vim.b.copilot_enabled = false -- 禁用 Copilot 自动补全
    end,
})



-- Finder: open/reveal current buffer in macOS Finder
-- Command: :OpenInFinder
-- Keymap: <leader>of
local function open_in_finder()
  local path = vim.fn.expand('%:p')
  if path == nil or path == '' then
    vim.fn.jobstart({ 'open', '.' }, { detach = true })
    return
  end
  if vim.fn.isdirectory(path) == 1 then
    vim.fn.jobstart({ 'open', path }, { detach = true })
  elseif vim.fn.filereadable(path) == 1 then
    vim.fn.jobstart({ 'open', '-R', path }, { detach = true })
  else
    vim.fn.jobstart({ 'open', '.' }, { detach = true })
  end
end

vim.api.nvim_create_user_command('OpenInFinder', open_in_finder, {})
vim.keymap.set('n', '<leader>of', open_in_finder, { noremap = true, silent = true, desc = 'Reveal current file in Finder' })

-- use <leader>jq to format json using jq
vim.api.nvim_set_keymap('n', '<leader>jq', ':%!jq .<CR>', { noremap = true, silent = true, desc = 'Format JSON using jq' })

-- Open file under cursor in current buffer
vim.keymap.set('n', 'gf', function()
    local file = vim.fn.expand('<cfile>')
    if file and file ~= '' then
        vim.cmd('edit ' .. file)
    else
        vim.notify('No file found under cursor', vim.log.levels.WARN)
    end
end, { noremap = true, silent = true, desc = 'Open file under cursor in current buffer' })

-- Alternative: use <leader>gf as a more explicit mapping
vim.keymap.set('n', '<leader>gf', function()
    local file = vim.fn.expand('<cfile>')
    if file and file ~= '' then
        vim.cmd('edit ' .. file)
    else
        vim.notify('No file found under cursor', vim.log.levels.WARN)
    end
end, { noremap = true, silent = true, desc = 'Open file under cursor in current buffer' })

-- Delete current file from disk
local function delete_current_file()
  local file = vim.fn.expand('%:p')
  if file == '' or file == nil then
    vim.notify('No file name found for the current buffer', vim.log.levels.ERROR)
    return
  end

  -- Confirm deletion
  vim.ui.input(
    { prompt = 'Delete file? (type "yes" to confirm): ' },
    function(input)
      if input == 'yes' then
        local result = vim.fn.delete(file)
        if result == 0 then
          vim.notify('File deleted: ' .. file, vim.log.levels.INFO)
          -- Close the buffer without saving
          vim.cmd('bdelete!')
        else
          vim.notify('Failed to delete file: ' .. file, vim.log.levels.ERROR)
        end
      else
        vim.notify('File deletion cancelled', vim.log.levels.INFO)
      end
    end
  )
end

vim.api.nvim_create_user_command('DeleteFile', delete_current_file, {})
vim.keymap.set('n', '<leader>df', delete_current_file, { noremap = true, silent = true, desc = 'Delete current file from disk' })

-- Copy current line reference to pasteboard
local function copy_line_reference(path_style)
  local path = vim.fn.expand('%:p')
  if path == nil or path == '' then
    vim.notify('No file name found for the current buffer', vim.log.levels.ERROR)
    return
  end

  local line_no = vim.fn.line('.')
  local line_text = vim.api.nvim_get_current_line()
  local final_path = path
  if path_style == 'relative' then
    final_path = vim.fn.fnamemodify(path, ':.')
  end

  local text = string.format('%s:%d:%s', final_path, line_no, line_text)
  vim.fn.setreg('+', text)
  vim.fn.setreg('*', text)
  vim.notify('Copied line reference to clipboard', vim.log.levels.INFO)
end

vim.keymap.set('n', '<leader>yr', function()
  copy_line_reference('relative')
end, { noremap = true, silent = true, desc = 'Copy line reference (relative path)' })

vim.keymap.set('n', '<leader>ya', function()
  copy_line_reference('absolute')
end, { noremap = true, silent = true, desc = 'Copy line reference (absolute path)' })

-- Remove leading line numbers (e.g., from cat -n output)
vim.keymap.set('n', '<leader>rl', ':%s/^\\s*\\d\\+\\s//<CR>', { noremap = true, silent = true, desc = 'Remove leading line numbers' })
