# pi-chat.nvim

A thin Neovim client for the [pi coding agent](https://github.com/earendil-works/pi)
(`@earendil-works/pi-coding-agent`) over its **RPC mode**. It turns Neovim into a
front-end for pi: ask questions, watch the streamed answer, jump between
messages, and answer approval prompts — all with native editor keys and
markdown rendering.

Not an ACP client. pi speaks its own JSONL RPC (`pi --mode rpc`), so this talks
to pi directly instead of going through the Agent Client Protocol.

## Features

- **Right-side split**: conversation (top) + input (bottom).
- **Streaming**: assistant text appears token-by-token.
- **Answer only**: thinking and tool calls are never rendered — not as a
  placeholder line, not as virtual lines, not as folds. The transcript is
  exactly the prompts plus the answers, so nothing can disturb the markdown
  parse (bold, tables and code fences always render). A `● running…` label in
  the input pane's divider shows that pi is still working. After you send a
  message a floating status popup opens automatically (spinner, elapsed time,
  what pi is doing, seconds since its last event, `⚠ no response` after 30s)
  and closes as soon as answer text starts streaming; it re-opens if no text
  arrives for 1.5s (e.g. during a tool run). `<leader>pi` toggles it manually.
- **Markdown rendering**: the conversation buffer uses the `pichat` filetype,
  which the plugin maps onto the `markdown` treesitter parser and starts the
  markdown highlighter on (`render-markdown.nvim` is driven by it).
- **Message navigation**: `]]` / `[[` jump between `▌ You` / `▌ pi`
  separators.
- **Native approvals**: pi's `extension_ui_request` dialogs (ask tool, git
  safety review, sudo password) render as `vim.ui.select` / `vim.ui.input`.
  Password prompts use `inputsecret()` — never echoed, never written to a
  buffer, never logged.
- **Inline editing (co-editing)**: `<leader>pe` sends the current buffer to a
  one-shot `pi -p` run and inserts the model's answer straight into the buffer
  at the cursor; `<leader>pA` asks a question about the buffer and inserts the
  answer as a comment block. The model must answer with one
  `<<<PI_EDIT>>> … <<<PI_END>>>` block — everything outside it is dropped, so a
  chatty model can never dump prose into the file. The inserted range is
  highlighted with the `PiChatEdit` (DiffAdd) highlight; no marker text is
  written into the file.

## Requirements

- Neovim 0.10+
- `pi` on `$PATH` (`@earendil-works/pi-coding-agent`)
- Optional but recommended: [render-markdown.nvim](https://github.com/MeanderingProgrammer/render-markdown.nvim)
  for in-buffer markdown rendering.

## Install (lazy.nvim)

```lua
{
  dir = vim.fn.expand("~/dev-env-setup/nvim-plugins/pi-chat.nvim"),
  dependencies = { "MeanderingProgrammer/render-markdown.nvim" },
  cmd = {
    "PiChat", "PiChatOpen", "PiChatAsk", "PiChatAskSelection", "PiChatAskSelected",
    "PiChatEdit", "PiChatEditAsk", "PiChatNew",
  },
  keys = {
    { "<leader>pc", "<cmd>PiChat<cr>", desc = "pi-chat toggle" },
    {
      "<leader>pa",
      "<cmd>PiChatAskSelected<cr>",
      mode = { "n", "v" },
      desc = "pi: send selection as prompt",
    },
    { "<leader>pe", "<cmd>PiChatEdit<cr>", desc = "pi: inline edit (continue at cursor)" },
    { "<leader>pA", "<cmd>PiChatEditAsk<cr>", desc = "pi: inline edit (ask, insert answer)" },
    { "<leader>pn", "<cmd>PiChatNew<cr>", desc = "pi-chat new session" },
    { "<leader>pv", ":PiChatAskSelection<cr>", mode = "v", desc = "pi ask selection" },
  },
  opts = {
    -- pi_bin = "pi",
    -- model = "...",        -- optional, passed as `--model`
    -- provider = "...",     -- optional, passed as `--provider`
    -- no_session = false,   -- keep sessions so history persists
    -- width = 80,           -- conversation split width (default ~40% cols)
    -- edit = {              -- inline editing (see below)
    --   model = "...",      -- model for the one-shot run (default: chat model)
    --   tools = { "read", "grep", "find", "ls" }, -- false = none, "*" = all
    --   comment_answers = true,
    -- },
  },
}
```

## Commands

| Command | Description |
|---|---|
| `:PiChat` | Toggle the chat window |
| `:PiChatOpen` | Open (or focus) the chat |
| `:PiChatClose` | Close the chat and stop the agent |
| `:PiChatAsk [text]` | Open and send a prompt |
| `:PiChatAskSelection` | Ask about the visual selection (with a question) |
| `:PiChatAskSelected` | Send the visual selection to pi as the prompt (no question) |
| `:PiChatEdit` | Inline edit: continue writing at the cursor |
| `:PiChatEditAsk` | Inline edit: ask about the buffer, insert the answer |
| `:PiChatNew` | Start a fresh session (discard the current conversation) |
| `:PiChatSessions` | Pick a recent session to continue |
| `:PiChatContinue` | Continue the most recent session |
| `:PiChatModel` | Pick the model |
| `:PiChatInfo` | Toggle the info popup (status / session / model / context / cost) |

## Inline editing (co-editing)

| Command | Key | What it does |
|---|---|---|
| `:PiChatEdit` | `<leader>pe` | **Continue** the file at the cursor |
| `:PiChatEditAsk` | `<leader>pA` | **Ask** a question about the buffer; the answer is inserted |

Both modes work the same way:

1. Collect the whole buffer, mark the cursor with `<<<PI_CURSOR>>>`, and add
   metadata (path, filetype, cursor line). Files above `edit.max_context_bytes`
   are trimmed to a window around the cursor.
2. Run a **separate** `pi -p --no-extensions --no-skills --no-session` process
   (the prompt goes in through stdin), so the run never enters the chat
   transcript. By default it gets the **read-only** tools
   (`--tools read,grep,find,ls`): the model can look at the project for
   context, but it cannot modify anything. Set `edit.tools = false` to take
   even those away, or `edit.tools = "*"` to give it everything.
3. Parse `<<<PI_EDIT>>> … <<<PI_END>>>`. If the markers are missing, nothing is
   inserted (an error is shown instead) — the model's chatter never reaches the
   file.
4. Insert the content and highlight it with `PiChatEdit` (linked to `DiffAdd`).
   The highlight is a visual marker only: no text is added to the file, and `u`
   undoes the insertion in one step.

In **continue** mode the model outputs only the text to insert; **the plugin
decides where it goes**:

| Situation | Placement |
|---|---|
| the current line is blank | the text fills that line |
| the line is unfinished (`=`, `(`, `,`, `.`, `->`, … before the cursor) | the text continues the same line |
| anything else | the text goes on new lines under the current one |

The inserted text is indented to match the cursor line: if the model dropped
the leading indentation, the whole block is shifted by the indentation of the
current line (closing lines such as `end` are left alone).

In **ask** mode the answer is inserted below the current line, prefixed with
the filetype's comment string (`-- `, `// `, `# ` …); markdown/text buffers get
the plain answer.

Options (`opts.edit`):

| Option | Default | Meaning |
|---|---|---|
| `model` / `provider` | the chat session's model | model for the one-shot run |
| `tools` | `{ "read", "grep", "find", "ls" }` | tools for the one-shot run; `false` = none, `"*"` = all |
| `timeout_ms` | 120000 | kill the run after this long |
| `max_context_bytes` | 60000 | above this only a window around the cursor is sent |
| `window_lines` | 200 | window size on each side of the cursor |
| `comment_answers` | true | prefix answers with the filetype comment string |

## Keys (inside the chat)

| Key | Where | Action |
|---|---|---|
| `<CR>` (normal) / `<C-s>` | input | Send prompt (or steer if agent is busy) |
| `<C-c>` | both | Abort current turn |
| `q` | both | Close chat |
| `<Tab>` | both | Toggle focus between input / conversation |
| `<leader>pn` | both | New session |
| `<leader>pi` | both | Toggle info popup |
| `<leader>pm` | both | Pick model |
| `<leader>ps` | both | Pick / switch session |
| `<C-v>` / `<leader>pp` | input | Paste a clipboard image (attached to next send) |
| `<leader>po` | conversation | Open the image on the current line |
| `]]` / `[[` | conversation | Jump to next / previous message |

The input pane has a slightly tinted background so it's easy to tell apart
from the conversation. Session status / model / context% / cost live in the
info popup (`<leader>pi`), not in a persistent bar.

## Scope / limitations

- One active chat at a time.
- Tool calls and thinking are not shown at all (by design): the conversation
  only contains prompts and answers. Use pi's own session log for a full
  record of what the agent ran.
- `editor` dialogs open a floating scratch buffer (`<C-s>` or `:w` to submit).
