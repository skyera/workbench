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
      { "<leader>h",  function() Snacks.dashboard() end, desc = "Open Dashboard" },
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
    build = "./install --all",
  },
  {
    "junegunn/fzf.vim",
    dependencies = { "junegunn/fzf" },
    cmd = { "Files", "GFiles", "Buffers", "Colors", "Ag", "Rg", "RG", "Frg", "FzfRG", "FRG", "Lines", "BLines", "Tags", "BTags", "Marks", "Windows", "Locate", "History", "Snippets", "Commits", "BCommits", "Commands", "Maps", "Helptags", "Filetypes" },
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
        map("n", "<leader>tb", gs.toggle_current_line_blame, "Toggle Line Blame")
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
    "Exafunction/windsurf.vim",
    event = "InsertEnter",
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
        { path = "luvit-meta/library", words = { "vim%.uv" } },
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

      -- Configure global LspAttach autocmd for keymaps
      vim.api.nvim_create_autocmd("LspAttach", {
        callback = function(args)
          local bufnr = args.buf
          local _client = vim.lsp.get_client_by_id(args.data.client_id)
          local map = function(mode, lhs, rhs, desc)
            vim.keymap.set(mode, lhs, rhs, { buffer = bufnr, silent = true, desc = "LSP: " .. desc })
          end

          -- Helper for LSP navigation with fallback to native Vim gd / gD
          local jump_with_fallback = function(method, fallback_cmd)
            local offset_enc = _client and _client.offset_encoding or "utf-16"
            local params = vim.lsp.util.make_position_params(0, offset_enc)
            vim.lsp.buf_request(bufnr, method, params, function(err, result, _ctx, _config)
              local locations = {}
              if not err and result then
                locations = vim.islist(result) and result or { result }
                locations = vim.tbl_filter(function(loc)
                  return type(loc) == "table" and (loc.uri ~= nil or loc.targetUri ~= nil)
                end, locations)
              end

              if #locations == 0 then
                vim.schedule(function()
                  pcall(vim.cmd, "normal! " .. fallback_cmd)
                end)
                return
              end

              local ok, items = pcall(vim.lsp.util.locations_to_items, locations, offset_enc)
              if not ok or not items or vim.tbl_isempty(items) then
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
          -- K: Open LSP Hover documentation in a top split window (with Man page fallback)
          map("n", "K", function()
            local cword = vim.fn.expand("<cword>")
            local params = vim.lsp.util.make_position_params(0, _client and _client.offset_encoding)
            vim.lsp.buf_request(bufnr, "textDocument/hover", params, function(err, result, _ctx, _config)
              local lines = {}
              if not err and result and result.contents then
                lines = vim.lsp.util.convert_input_to_markdown_lines(result.contents)
                if type(lines) == "table" then
                  lines = vim.tbl_filter(function(line) return line and line:match("%S") end, lines)
                end
              end

              -- Fallback to man page if LSP hover returned no documentation
              local is_man = false
              if vim.tbl_isempty(lines) and cword ~= "" then
                local man_output = vim.fn.systemlist("man 3 " .. vim.fn.shellescape(cword) .. " 2>/dev/null || man " .. vim.fn.shellescape(cword) .. " 2>/dev/null")
                if vim.v.shell_error == 0 and not vim.tbl_isempty(man_output) then
                  lines = man_output
                  is_man = true
                end
              end

              if vim.tbl_isempty(lines) then return end

              vim.cmd("topleft 14split")
              local scratch_buf = vim.api.nvim_create_buf(false, true)
              vim.api.nvim_win_set_buf(0, scratch_buf)
              vim.api.nvim_buf_set_lines(scratch_buf, 0, -1, false, lines)
              vim.bo[scratch_buf].filetype = is_man and "man" or "markdown"
              vim.bo[scratch_buf].bufhidden = "wipe"
              vim.bo[scratch_buf].buftype = "nofile"
              vim.keymap.set("n", "q", "<cmd>close<CR>", { buffer = scratch_buf, silent = true })
            end)
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
