return {
  -- Core & UI
  { "catppuccin/nvim", name = "catppuccin", priority = 1000 },
  "ellisonleao/gruvbox.nvim",
  "rafi/awesome-vim-colorschemes",
  "ryanoasis/vim-devicons",
  "nvim-tree/nvim-web-devicons",
  {
    "folke/snacks.nvim",
    priority = 1000,
    lazy = false,
    opts = {
      bigfile = { enabled = true },
      bufdelete = { enabled = true },
      dashboard = {
        enabled = true,
        preset = {
          keys = {
            { icon = " ", key = "f", desc = "Find File", action = ":lua Snacks.picker.files()" },
            { icon = " ", key = "n", desc = "New File", action = ":ene | startinsert" },
            { icon = " ", key = "g", desc = "Find Text", action = ":lua Snacks.picker.grep()" },
            { icon = " ", key = "r", desc = "Recent Files", action = ":lua Snacks.picker.recent()" },
            { icon = " ", key = "c", desc = "Neovim Config", action = ":lua Snacks.picker.files({ cwd = vim.fn.stdpath('config') })" },
            { icon = "󰒲 ", key = "l", desc = "Lazy Plugins", action = ":Lazy" },
            { icon = " ", key = "q", desc = "Quit", action = ":qa" },
          },
        },
        sections = {
          { section = "header" },
          { section = "keys", gap = 1, padding = 1 },
          { pane = 2, icon = " ", title = "Recent Files", section = "recent_files", indent = 2, padding = 1 },
          { pane = 2, icon = " ", title = "Projects", section = "projects", indent = 2, padding = 1 },
          {
            pane = 2,
            icon = " ",
            title = "Git Status",
            section = "terminal",
            enabled = function() return Snacks.git.get_root() ~= nil end,
            cmd = "git status --short --branch",
            height = 5,
            padding = 1,
            ttl = 5 * 60,
            indent = 3,
          },
          { section = "startup" },
        },
      },
      dim = { enabled = true },
      explorer = { enabled = true },
      git = { enabled = true },
      indent = { enabled = false, only_scope = true },
      input = { enabled = true },
      lazygit = { enabled = true },
      notifier = { enabled = true, timeout = 3000 },
      picker = { enabled = true },
      quickfile = { enabled = true },
      scratch = { enabled = true },
      scroll = { enabled = true },
      statuscolumn = { enabled = true },
      terminal = { enabled = true },
      words = { enabled = true },
      zen = { enabled = true },
    },
    init = function()
      vim.api.nvim_create_autocmd("User", {
        pattern = "VeryLazy",
        callback = function()
          -- Expose Snacks debug helpers globally
          _G.dd = function(...) Snacks.debug.inspect(...) end
          _G.bt = function() Snacks.debug.backtrace() end
          vim.print = _G.dd
        end,
      })
    end,
    keys = {
      -- Snacks Picker Mappings (<leader>s* namespace)
      { "<leader>sf", function() Snacks.picker.files() end, desc = "Find Files (Snacks)" },
      { "<leader>sg", function() Snacks.picker.grep() end, desc = "Live Grep (Snacks)" },
      { "<leader>sb", function() Snacks.picker.buffers() end, desc = "Buffers (Snacks)" },
      { "<leader>sr", function() Snacks.picker.recent() end, desc = "Recent Files (Snacks)" },
      { "<leader>sh", function() Snacks.picker.help() end, desc = "Help Tags (Snacks)" },
      { "<leader>su", function() Snacks.picker.undo() end, desc = "Undo Tree (Snacks)" },
      { "<leader>sG", function() Snacks.picker.git_status() end, desc = "Git Status (Snacks)" },
      { "<leader>sn", function() Snacks.picker.notifications() end, desc = "Notifications History (Snacks)" },
      { "<leader>sp", function() Snacks.picker.pickers() end, desc = "All Pickers List (Snacks)" },
      { "<leader>sl", function() Snacks.picker.lines() end, desc = "Search Buffer Lines (Snacks)" },
      { "<leader>sw", function() Snacks.picker.grep_word() end, desc = "Search Cursor Word (Snacks)" },
      { "<leader>sk", function() Snacks.picker.keymaps() end, desc = "Search Keymaps (Snacks)" },
      { "<leader>sc", function() Snacks.picker.command_history() end, desc = "Command History (Snacks)" },
      { "<leader>sC", function() Snacks.picker.commands() end, desc = "Vim Commands (Snacks)" },
      { "<leader>se", function() Snacks.picker.explorer() end, desc = "File Explorer Picker (Snacks)" },
      { "<leader>sd", function() Snacks.picker.diagnostics() end, desc = "Workspace Diagnostics (Snacks)" },
      { "<leader>sD", function() Snacks.picker.diagnostics_buffer() end, desc = "Buffer Diagnostics (Snacks)" },
      { "<leader>ss", function() Snacks.picker.lsp_symbols() end, desc = "LSP Document Symbols (Snacks)" },
      { "<leader>sS", function() Snacks.picker.lsp_workspace_symbols() end, desc = "LSP Workspace Symbols (Snacks)" },
      { "<leader>sq", function() Snacks.picker.qflist() end, desc = "Quickfix List (Snacks)" },
      { "<leader>sm", function() Snacks.picker.marks() end, desc = "Marks (Snacks)" },
      { "<leader>sj", function() Snacks.picker.jumps() end, desc = "Jumps (Snacks)" },
      -- Snacks Utilities & Git
      { "<leader>hh", function() Snacks.dashboard() end, desc = "Open Dashboard" },
      { "<leader>z",  function() Snacks.zen() end, desc = "Toggle Zen Mode" },
      { "<leader>Z",  function() Snacks.zen.zoom() end, desc = "Toggle Zoom" },
      { "<leader>.",  function() Snacks.scratch() end, desc = "Toggle Scratch Buffer" },
      { "<leader>S",  function() Snacks.scratch.select() end, desc = "Select Scratch Buffer" },
      { "<leader>nh", function() Snacks.notifier.show_history() end, desc = "Notification History" },
      { "<leader>bd", function() Snacks.bufdelete() end, desc = "Delete Buffer" },
      { "<leader>gb", function() Snacks.git.blame_line() end, desc = "Git Blame Line" },
      { "<leader>gL", function() Snacks.picker.git_log() end, desc = "Git Log (Snacks)" },
      { "<leader>lg", function() Snacks.lazygit() end, desc = "Toggle Lazygit (Snacks)" },
      { "<leader>un", function() Snacks.notifier.hide() end, desc = "Dismiss All Notifications" },
      -- Snacks Toggles (<leader>u* namespace)
      { "<leader>us", function() Snacks.toggle.option("spell"):toggle() end, desc = "Toggle Spelling" },
      { "<leader>uw", function() Snacks.toggle.option("wrap"):toggle() end, desc = "Toggle Line Wrap" },
      { "<leader>uL", function() Snacks.toggle.line_number():toggle() end, desc = "Toggle Line Numbers" },
      { "<leader>ud", function() Snacks.toggle.diagnostics():toggle() end, desc = "Toggle Diagnostics" },
      { "<leader>uC", function() Snacks.toggle.option("conceallevel", { off = 0, on = 2, name = "Conceal" }):toggle() end, desc = "Toggle Conceal" },
      { "<leader>ui", function() Snacks.toggle.indent():toggle() end, desc = "Toggle Indent Guides" },
      { "<leader>uD", function() Snacks.toggle.dim():toggle() end, desc = "Toggle Focus Dimming" },
      { "<leader>ub", function() Snacks.toggle.option("background", { off = "light", on = "dark", name = "Dark Background" }):toggle() end, desc = "Toggle Dark Background" },
      { "<c-/>",      function() Snacks.terminal() end, mode = { "n", "t" }, desc = "Toggle Terminal" },
      { "<c-_>",      function() Snacks.terminal() end, mode = { "n", "t" }, desc = "Toggle Terminal" },
    },
  },
  {
    "goolord/alpha-nvim",
    enabled = false,
    config = function() require("alpha").setup(require("alpha.themes.startify").config) end,
  },
  {
    "nvim-lualine/lualine.nvim",
    event = "VeryLazy",
    dependencies = { "nvim-tree/nvim-web-devicons" },
    config = function()
      require("lualine").setup({
        options = {
          theme = "catppuccin-mocha",
          component_separators = { left = "|", right = "|" },
          section_separators = { left = "", right = "" },
        },
      })
    end,
  },

  -- Navigation (Telescope - mapped under <leader>t*)
  {
    "nvim-telescope/telescope.nvim",
    dependencies = { "nvim-lua/plenary.nvim" },
    config = function()
      require("telescope").setup({
        defaults = {
          sorting_strategy = "ascending",
          layout_strategy = "vertical",
          layout_config = {
            vertical = {
              prompt_position = "top",
              mirror = true,        -- Places Results above Preview (Top->Bottom: Prompt -> Results -> Preview)
              preview_height = 0.50, -- 50% height reserved for preview at bottom
              preview_cutoff = 0,    -- Always scale by percent without hiding
            },
            width = 0.90,  -- 90% of editor width
            height = 0.90, -- 90% of editor height
          },
        },
      })
      local builtin = require("telescope.builtin")
      vim.keymap.set("n", "<leader>tf", builtin.find_files, { desc = "Search Files (Telescope)" })
      vim.keymap.set("n", "<leader>tg", builtin.live_grep, { desc = "Search Live Grep (Telescope)" })
      vim.keymap.set("n", "<leader>tb", builtin.buffers, { desc = "Search Buffers (Telescope)" })
      vim.keymap.set("n", "<leader>th", builtin.help_tags, { desc = "Search Help Tags (Telescope)" })
      vim.keymap.set("n", "<leader>tw", builtin.grep_string, { desc = "Search Word under cursor (Telescope)" })
      vim.keymap.set("n", "<leader>tr", builtin.oldfiles, { desc = "Search Recent Files (Telescope)" })
      vim.keymap.set("n", "<leader>tc", builtin.colorscheme, { desc = "Search Colorschemes (Telescope)" })
      vim.keymap.set("n", "<leader>tk", builtin.keymaps, { desc = "Search Keymaps (Telescope)" })
    end,
  },

  -- Navigation (Fzf-lua)
  {
    "ibhagwan/fzf-lua",
    dependencies = { "nvim-tree/nvim-web-devicons" },
    config = function()
      local fzf = require("fzf-lua")
      fzf.setup({
        winopts = {
          height = 0.90, -- 90% of editor height
          width = 0.90,  -- 90% of editor width
          preview = {
            layout = "vertical",
            vertical = "down:50%", -- 50% bottom preview window
          },
        },
        fzf_opts = {
          ["--layout"] = "reverse",
        },
        keymap = {
          fzf = {
            ["ctrl-q"] = "select-all+accept",
          },
        },
      })
      -- Recommended Best Practice <leader>f* Mappings (Find Prefix)
      vim.keymap.set("n", "<leader>ff", fzf.files, { silent = true, desc = "Find Files" })
      vim.keymap.set("n", "<leader>fg", fzf.live_grep, { silent = true, desc = "Find Live Grep" })
      vim.keymap.set("n", "<leader>fb", fzf.buffers, { silent = true, desc = "Find Buffers" })
      vim.keymap.set("n", "<leader>fh", fzf.help_tags, { silent = true, desc = "Find Help Tags" })
      vim.keymap.set("n", "<leader>fw", fzf.grep_cword, { silent = true, desc = "Find Word under cursor" })
      vim.keymap.set("n", "<leader>fr", fzf.oldfiles, { silent = true, desc = "Find Recent Files (MRU)" })
      vim.keymap.set("n", "<leader>fl", fzf.lines, { silent = true, desc = "Find Buffer Lines" })
      vim.keymap.set("n", "<leader>fc", fzf.colorschemes, { silent = true, desc = "Find Colorschemes" })

      -- Legacy <leader>p* Aliases (Project Prefix)
      vim.keymap.set("n", "<leader>pf", fzf.files, { silent = true, desc = "FZF Files" })
      vim.keymap.set("n", "<leader>pg", fzf.live_grep, { silent = true, desc = "FZF Live Grep" })
      vim.keymap.set("n", "<leader>pb", fzf.buffers, { silent = true, desc = "FZF Buffers" })
    end,
  },

  -- File Explorer (Oil)
  {
    "stevearc/oil.nvim",
    dependencies = { "nvim-tree/nvim-web-devicons" },
    config = function()
      require("oil").setup({
        columns = { "icon" },
        view_options = { show_hidden = true },
      })
      vim.keymap.set("n", "-", "<CMD>Oil<CR>", { desc = "Open parent directory" })
    end,
  },

  -- Navigation (Classic Tools)
  {
    "scrooloose/nerdtree",
    cmd = { "NERDTree", "NERDTreeToggle", "NERDTreeFind", "NERDTreeFocus", "NERDTreeCWD", "NERDTreeFromBookmark" },
  },
  {
    "tiagofumo/vim-nerdtree-syntax-highlight",
    dependencies = { "scrooloose/nerdtree" },
    cmd = { "NERDTree", "NERDTreeToggle", "NERDTreeFind", "NERDTreeFocus" },
  },
  {
    "jlanzarotta/bufexplorer",
    cmd = { "BufExplorer", "BufExplorerHorizontalSplit", "BufExplorerVerticalSplit", "ToggleBufExplorer" },
  },
  {
    "yegappan/mru",
    cmd = { "MRU" },
  },
  {
    "vim-scripts/lookupfile",
    dependencies = { "vim-scripts/genutils" },
    cmd = { "LookupFile" },
  },
  {
    "junegunn/fzf",
    -- fzf#install() picks install.ps1 on native Windows and `install --bin`
    -- elsewhere. Both only download the binary (unlike `install --all`,
    -- which edits ~/.bashrc/.zshrc). A raw "./install" breaks under cmd.exe.
    build = ":call fzf#install()",
  },
  {
    "junegunn/fzf.vim",
    dependencies = { "junegunn/fzf" },
    -- Names carry the "Fzf" prefix because vim.g.fzf_command_prefix = "Fzf"
    -- (options.lua); unprefixed names would never match a typed command.
    cmd = {
      "FzfFiles", "FzfGFiles", "FzfBuffers", "FzfColors", "FzfAg", "FzfRg",
      "FzfLines", "FzfBLines", "FzfTags", "FzfBTags", "FzfMarks", "FzfWindows",
      "FzfLocate", "FzfHistory", "FzfSnippets", "FzfCommits", "FzfBCommits",
      "FzfCommands", "FzfMaps", "FzfHelptags", "FzfFiletypes",
      "FzfRG", "FRG", "Frg",
    },
  },
  {
    "jremmen/vim-ripgrep",
    cmd = { "Rg" },
  },
  {
    "mhinz/vim-grepper",
    cmd = { "Grepper" },
  },
  {
    "mileszs/ack.vim",
    cmd = { "Ack", "AckAdd", "AckFile", "AckHelp", "AckWindow" },
  },
  {
    "vim-scripts/Color-Scheme-Explorer",
    cmd = { "ColorExplorer" },
  },

  -- Tree
  {
    "nvim-tree/nvim-tree.lua",
    dependencies = { "nvim-tree/nvim-web-devicons" },
    cmd = { "NvimTreeToggle", "NvimTreeOpen", "NvimTreeFocus", "NvimTreeFindFile", "NvimTreeCollapse" },
    keys = {
      { "<leader>e", "<cmd>NvimTreeToggle<cr>", desc = "Toggle NvimTree" },
      { "<leader>E", "<cmd>NvimTreeFindFile<cr>", desc = "Find file in NvimTree" },
    },
    config = function()
      require("nvim-tree").setup({
        view = { width = 30, preserve_window_proportions = true },
        actions = { open_file = { resize_window = false } },
      })
    end,
  },

  -- Coding
  {
    "dhananjaylatkar/cscope_maps.nvim",
    cmd = { "Cscope", "Cs", "Cstag", "CsPrompt", "CsStackView" },
    event = { "BufReadPre", "BufNewFile" },
    config = function() require("cscope_maps").setup({ prefix = "<C-\\>", skip_input_prompt = true }) end,
  },
  "tpope/vim-surround",
  "tpope/vim-commentary",
  "tpope/vim-unimpaired",
  {
    "tpope/vim-fugitive",
    cmd = { "G", "Git", "Gdiffsplit", "Gvdiffsplit", "Gedit", "Gread", "Gwrite", "Ggrep", "Glgrep", "Gclog" },
  },
  {
    "lewis6991/gitsigns.nvim",
    cmd = { "Gitsigns" },
    event = { "BufReadPre", "BufNewFile" },
    opts = {
      signs = {
        add          = { text = "│" },
        change       = { text = "│" },
        delete       = { text = "_" },
        topdelete    = { text = "‾" },
        changedelete = { text = "~" },
      },
      on_attach = function(bufnr)
        local gs = package.loaded.gitsigns
        local function map(mode, l, r, desc)
          vim.keymap.set(mode, l, r, { buffer = bufnr, silent = true, desc = "Git: " .. desc })
        end

        -- Navigation
        map("n", "]c", function()
          if vim.wo.diff then return "]c" end
          vim.schedule(function() gs.next_hunk() end)
          return "<Ignore>"
        end, "Next Hunk")
        map("n", "[c", function()
          if vim.wo.diff then return "[c" end
          vim.schedule(function() gs.prev_hunk() end)
          return "<Ignore>"
        end, "Prev Hunk")

        -- Actions
        map("n", "<leader>hs", gs.stage_hunk, "Stage Hunk")
        map("n", "<leader>hr", gs.reset_hunk, "Reset Hunk")
        map("v", "<leader>hs", function() gs.stage_hunk({ vim.fn.line("."), vim.fn.line("v") }) end, "Stage Hunk (Visual)")
        map("v", "<leader>hr", function() gs.reset_hunk({ vim.fn.line("."), vim.fn.line("v") }) end, "Reset Hunk (Visual)")
        map("n", "<leader>hp", gs.preview_hunk, "Preview Hunk Diff")
        map("n", "<leader>hb", function() gs.blame_line({ full = true }) end, "Blame Line (Popup)")
        map("n", "<leader>hB", gs.toggle_current_line_blame, "Toggle Line Blame")
        map("n", "<leader>hd", gs.diffthis, "Diff This Buffer")
      end,
    },
  },
  {
    "windwp/nvim-autopairs",
    event = "InsertEnter",
    config = true,
  },
  {
    "godlygeek/tabular",
    cmd = { "Tabularize" },
  },
  {
    "christoomey/vim-tmux-navigator",
    event = "VeryLazy",
  },
  {
    "tmhedberg/SimpylFold",
    ft = "python",
  },
  {
    "majutsushi/tagbar",
    cmd = { "Tagbar", "TagbarToggle", "TagbarOpen" },
  },
  {
    "vimwiki/vimwiki",
    lazy = false,
  },
  {
    "vim-scripts/a.vim",
    cmd = { "A", "AS", "AV", "AT", "AN", "IH", "IHS", "IHV", "IHT", "IHN" },
  },
  {
    "rbgrouleff/bclose.vim",
    cmd = "Bclose",
  },

  -- LSP & Autocomplete (C/C++, Python, Bash, Lua)
  {
    "folke/lazydev.nvim",
    cmd = { "LazyDev" },
    ft = "lua",
    opts = {
      library = {
        { path = "${3rd}/luv/library", words = { "vim%.uv" } },
      },
    },
  },
  {
    "williamboman/mason.nvim",
    cmd = "Mason",
    opts = {},
  },
  {
    "williamboman/mason-lspconfig.nvim",
    dependencies = { "williamboman/mason.nvim" },
    config = function()
      require("mason-lspconfig").setup({
        ensure_installed = { "pyright", "bashls", "lua_ls" },
        automatic_installation = false,
        automatic_enable = false,
      })
    end,
  },
  {
    "neovim/nvim-lspconfig",
    cmd = { "LspInfo", "LspLog", "LspStart", "LspRestart", "LspStop" },
    event = { "BufReadPre", "BufNewFile" },
    dependencies = {
      "williamboman/mason.nvim",
      "williamboman/mason-lspconfig.nvim",
      "hrsh7th/cmp-nvim-lsp",
    },
    config = function()
      local capabilities = vim.lsp.protocol.make_client_capabilities()
      capabilities = require("cmp_nvim_lsp").default_capabilities(capabilities)

      ------------------------------------------------------------------------
      -- Hover / navigation helpers
      -- These use buf_request_all so a buffer with several attached servers
      -- gets ONE callback (and one result) instead of one per server.
      ------------------------------------------------------------------------

      -- Hover window shared by every K press, so repeated presses reuse it.
      local hover_window = nil

      -- Returns the position params for `client`, using its offset encoding.
      local function position_params_for(client, bufnr)
        return vim.lsp.util.make_position_params(0, client.offset_encoding)
      end

      -- Returns the non-blank markdown lines for an LSP hover result, or {}.
      local function hover_result_lines(result)
        if not result or not result.contents then
          return {}
        end

        local lines = vim.lsp.util.convert_input_to_markdown_lines(result.contents)
        if type(lines) ~= "table" then
          return {}
        end

        return vim.tbl_filter(function(line)
          return line and line:match("%S")
        end, lines)
      end

      -- Picks the first server that returned hover text.
      -- Returns lines (possibly empty) and a human-readable reason when empty.
      local function first_hover(results)
        local reason = "no hover result"

        for _, response in pairs(results or {}) do
          if response.err then
            reason = "error: " .. tostring(response.err.message or response.err)
          else
            local lines = hover_result_lines(response.result)
            if not vim.tbl_isempty(lines) then
              return lines, nil
            end
          end
        end

        return {}, reason
      end

      -- Looks up `word` in the man pages (section 3 first, then any section).
      -- Returns lines on success, or nil plus the reason it failed.
      local function man_page_lines(word)
        if vim.fn.executable("man") == 0 then
          return nil, "man not installed"
        end

        local attempts = { { "man", "3", word }, { "man", word } }
        for _, command in ipairs(attempts) do
          local result = vim.system(command, { text = true }):wait(3000)
          if result.code == 0 and result.stdout and result.stdout ~= "" then
            return vim.split(result.stdout, "\n", { plain = true }), nil
          end
        end

        return nil, "no man entry"
      end

      -- Shows `lines` in the top hover window, reusing it when still open.
      local function show_in_hover_window(lines, filetype)
        local reusable = hover_window and vim.api.nvim_win_is_valid(hover_window)
        if reusable then
          vim.api.nvim_set_current_win(hover_window)
        else
          vim.cmd("topleft 14split")
          hover_window = vim.api.nvim_get_current_win()
        end

        local scratch_buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_win_set_buf(hover_window, scratch_buf)
        vim.api.nvim_buf_set_lines(scratch_buf, 0, -1, false, lines)
        vim.bo[scratch_buf].filetype = filetype
        vim.bo[scratch_buf].bufhidden = "wipe"
        vim.bo[scratch_buf].buftype = "nofile"
        vim.keymap.set("n", "q", "<cmd>close<CR>", { buffer = scratch_buf, silent = true })
      end

      -- K: hover docs from the first server that has some, else a man page,
      -- else an explanatory message.
      local function hover_or_man(bufnr)
        local word = vim.fn.expand("<cword>")
        if word == "" then
          vim.notify("No identifier under cursor", vim.log.levels.INFO)
          return
        end

        vim.lsp.buf_request_all(bufnr, "textDocument/hover", position_params_for, function(results)
          local lines, lsp_reason = first_hover(results)
          local filetype = "markdown"
          local man_reason = nil

          if vim.tbl_isempty(lines) then
            lines, man_reason = man_page_lines(word)
            filetype = "man"
          end

          if not lines or vim.tbl_isempty(lines) then
            vim.notify(
              string.format("No documentation found for '%s' (LSP: %s; man: %s)", word, lsp_reason, man_reason),
              vim.log.levels.INFO
            )
            return
          end

          vim.schedule(function()
            show_in_hover_window(lines, filetype)
          end)
        end)
      end

      -- Collects LSP locations from the first server that returned any.
      -- Returns the filtered locations and that server's offset encoding.
      local function first_locations(results)
        for client_id, response in pairs(results or {}) do
          local result = response.result
          if not response.err and result then
            local locations = vim.islist(result) and result or { result }
            locations = vim.tbl_filter(function(loc)
              return type(loc) == "table" and (loc.uri ~= nil or loc.targetUri ~= nil)
            end, locations)

            if #locations > 0 then
              local client = vim.lsp.get_client_by_id(client_id)
              return locations, client and client.offset_encoding or "utf-16"
            end
          end
        end

        return {}, "utf-16"
      end

      -- Configure global LspAttach autocmd for keymaps
      vim.api.nvim_create_autocmd("LspAttach", {
        callback = function(args)
          local bufnr = args.buf
          local _client = vim.lsp.get_client_by_id(args.data.client_id)
          local map = function(mode, lhs, rhs, desc)
            vim.keymap.set(mode, lhs, rhs, { buffer = bufnr, silent = true, desc = "LSP: " .. desc })
          end

          -- LSP navigation with fallback to native Vim gd / gD when no server answers
          local jump_with_fallback = function(method, fallback_cmd)
            vim.lsp.buf_request_all(bufnr, method, position_params_for, function(results)
              local locations, offset_enc = first_locations(results)

              local items = {}
              if #locations > 0 then
                local ok, converted = pcall(vim.lsp.util.locations_to_items, locations, offset_enc)
                if ok and converted then
                  items = converted
                end
              end

              if vim.tbl_isempty(items) then
                vim.schedule(function()
                  pcall(vim.cmd, "normal! " .. fallback_cmd)
                end)
                return
              end

              vim.schedule(function()
                if #items == 1 then
                  local item = items[1]
                  local target_buf = item.bufnr or vim.fn.bufadd(item.filename)
                  vim.cmd("normal! m'")
                  vim.bo[target_buf].buflisted = true
                  vim.api.nvim_set_current_buf(target_buf)
                  local line = math.max(1, item.lnum or 1)
                  local col = math.max(0, (item.col or 1) - 1)
                  vim.api.nvim_win_set_cursor(0, { line, col })
                  pcall(vim.cmd, "normal! zv")
                else
                  vim.fn.setqflist({}, " ", { title = "LSP Locations", items = items })
                  vim.cmd("botright copen")
                end
              end)
            end)
          end

          map("n", "gd", function() jump_with_fallback("textDocument/definition", "gd") end, "Goto Definition (with Vim fallback)")
          map("n", "gD", function() jump_with_fallback("textDocument/declaration", "gD") end, "Goto Declaration (with Vim fallback)")
          map("n", "gr", vim.lsp.buf.references, "Goto References")
          map("n", "gi", vim.lsp.buf.implementation, "Goto Implementation")
          map("n", "gy", vim.lsp.buf.type_definition, "Goto Type Definition")
          -- K: LSP hover in a reusable top split (man page fallback, then a message)
          map("n", "K", function()
            hover_or_man(bufnr)
          end, "Hover Documentation (Top Window)")

          -- gK: Open LSP Hover documentation in floating preview window
          map("n", "gK", vim.lsp.buf.hover, "Hover Documentation (Float)")
          map("n", "<C-k>", vim.lsp.buf.signature_help, "Signature Help")
          map("n", "<leader>rn", vim.lsp.buf.rename, "Rename Symbol")
          map("n", "<leader>ca", vim.lsp.buf.code_action, "Code Action")
          map("n", "[d", function() vim.diagnostic.jump({ count = -1 }) end, "Previous Diagnostic")
          map("n", "]d", function() vim.diagnostic.jump({ count = 1  }) end, "Next Diagnostic")
          map("n", "<leader>cd", vim.diagnostic.open_float, "Line Diagnostics (Float)")
        end,
      })

      -- C / C++ / CUDA Server Setup
      local clangd_capabilities = vim.tbl_deep_extend("force", capabilities, {
        offsetEncoding = { "utf-16" },
      })
      local clangd_cmd = vim.fn.executable("/usr/bin/clangd") == 1 and "/usr/bin/clangd" or "clangd"

      vim.lsp.config.clangd = {
        capabilities = clangd_capabilities,
        filetypes = { "c", "cpp", "objc", "objcpp", "cuda" },
        root_markers = { "compile_commands.json", "compile_flags.txt", ".git" },
        cmd = {
          clangd_cmd,
          "--background-index",
          "--completion-style=detailed",
          "--header-insertion=never",
          "--pch-storage=disk",
          "-j=4",
        },
      }

      -- Python Server Setup
      vim.lsp.config.pyright = {
        capabilities = capabilities,
        settings = {
          python = {
            analysis = {
              autoSearchPaths = true,
              useLibraryCodeForTypes = true,
              diagnosticMode = "openFilesOnly",
            },
          },
        },
      }

      -- Bash / Shell Server Setup
      vim.lsp.config.bashls = {
        capabilities = capabilities,
      }

      -- Lua Server Setup
      vim.lsp.config.lua_ls = {
        capabilities = capabilities,
        settings = {
          Lua = {
            completion = { callSnippet = "Replace" },
            diagnostics = { globals = { "vim" } },
            workspace = { checkThirdParty = false },
            telemetry = { enable = false },
          },
        },
      }

      -- Enable servers via Nvim 0.11+ native LSP enable API
      vim.lsp.enable({ "clangd", "pyright", "bashls", "lua_ls" })

    end,
  },
  {
    "hrsh7th/nvim-cmp",
    event = "InsertEnter",
    dependencies = {
      "hrsh7th/cmp-nvim-lsp",
      "hrsh7th/cmp-nvim-lsp-signature-help",
      "hrsh7th/cmp-buffer",
      "hrsh7th/cmp-path",
      "L3MON4D3/LuaSnip",
      "saadparwaiz1/cmp_luasnip",
      "rafamadriz/friendly-snippets",
    },
    config = function()
      local cmp = require("cmp")
      local luasnip = require("luasnip")
      require("luasnip.loaders.from_vscode").lazy_load()

      local kind_icons = {
        Text = "󰉿",
        Method = "ƒ",
        Function = "󰊕",
        Constructor = "",
        Field = "",
        Variable = "󰆧",
        Class = "󰌗",
        Interface = "",
        Module = "",
        Property = "",
        Unit = "",
        Value = "󰎠",
        Enum = "",
        Keyword = "󰌋",
        Snippet = "",
        Color = "󰏘",
        File = "󰈙",
        Reference = "",
        Folder = "󰉋",
        EnumMember = "",
        Constant = "󰏿",
        Struct = "",
        Event = "",
        Operator = "󰆕",
        TypeParameter = "󰅲",
      }

      cmp.setup({
        performance = {
          debounce = 60,
          throttle = 30,
          fetching_timeout = 500,
        },
        snippet = {
          expand = function(args)
            luasnip.lsp_expand(args.body)
          end,
        },
        formatting = {
          fields = { "kind", "abbr", "menu" },
          format = function(entry, vim_item)
            vim_item.kind = string.format("%s %s", kind_icons[vim_item.kind] or "", vim_item.kind)
            vim_item.menu = ({
              nvim_lsp = "[LSP]",
              nvim_lsp_signature_help = "[Sig]",
              luasnip = "[Snippet]",
              buffer = "[Buffer]",
              path = "[Path]",
            })[entry.source.name]
            return vim_item
          end,
        },
        mapping = cmp.mapping.preset.insert({
          ["<C-b>"] = cmp.mapping.scroll_docs(-4),
          ["<C-f>"] = cmp.mapping.scroll_docs(4),
          ["<C-Space>"] = cmp.mapping.complete(),
          ["<C-e>"] = cmp.mapping.abort(),
          ["<C-k>"] = cmp.mapping(function()
            vim.lsp.buf.signature_help()
          end, { "i", "s" }),
          ["<CR>"] = cmp.mapping.confirm({ select = false }),
          ["<Tab>"] = cmp.mapping(function(fallback)
            if cmp.visible() then
              cmp.select_next_item()
            elseif luasnip.expand_or_jumpable() then
              luasnip.expand_or_jump()
            else
              fallback()
            end
          end, { "i", "s" }),
          ["<S-Tab>"] = cmp.mapping(function(fallback)
            if cmp.visible() then
              cmp.select_prev_item()
            elseif luasnip.jumpable(-1) then
              luasnip.jump(-1)
            else
              fallback()
            end
          end, { "i", "s" }),
        }),
        sources = cmp.config.sources({
          { name = "nvim_lsp", max_item_count = 20 },
          { name = "nvim_lsp_signature_help" },
          { name = "luasnip", max_item_count = 5 },
        }, {
          {
            name = "buffer",
            max_item_count = 5,
            keyword_length = 3,
            option = {
              get_bufnrs = function()
                return { vim.api.nvim_get_current_buf() }
              end,
            },
          },
          { name = "path", max_item_count = 5 },
        }),
      })
    end,
  },


  -- Terminal Utilities (Conditional)
  {
    "francoiscabrol/ranger.vim",
    dependencies = { "rbgrouleff/bclose.vim" },
    init = function() vim.g.ranger_map_keys = 0 end,
    enabled = function() return vim.fn.has("win32") == 0 and vim.fn.has("gui_running") == 0 end,
  },
  {
    "ptzz/lf.vim",
    init = function() vim.g.lf_map_keys = 0 end,
    enabled = function() return vim.fn.has("gui_running") == 0 end,
  },
  {
    "voldikss/vim-floaterm",
    enabled = function() return vim.fn.has("gui_running") == 0 end,
  },
  {
    "vifm/vifm.vim",
    enabled = function() return vim.fn.has("gui_running") == 0 end,
  },
}
