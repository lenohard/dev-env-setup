# pi-chat.nvim

A thin Neovim client for the [pi coding agent](https://github.com/earendil-works/pi)
(`@earendil-works/pi-coding-agent`) over its **RPC mode**. It turns Neovim into a
front-end for pi: ask questions, watch streamed output, collapse tool calls,
jump between messages, and answer approval prompts — all with native editor
keys and markdown rendering.

Not an ACP client. pi speaks its own JSONL RPC (`pi --mode rpc`), so this talks
to pi directly instead of going through the Agent Client Protocol.

## Features

- **Right-side split**: conversation (top) + input (bottom).
- **Streaming**: assistant text appears token-by-token.
- **Collapsible tool blocks**: each tool call shows a one-line summary
  (`🔧 bash: ls -la`), folded by default; `za` to expand the full output.
- **Heading navigation**: `]]` / `[[` jump between `## You` / `## pi` / tool
  headings; works with telescope/imenu too.
- **Native approvals**: pi's `extension_ui_request` dialogs (ask tool, git
  safety review, sudo password) render as `vim.ui.select` / `vim.ui.input`.
  Password prompts use `inputsecret()` — never echoed, never written to a
  buffer, never logged.

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
  cmd = { "PiChat", "PiChatOpen", "PiChatAsk", "PiChatAskSelection", "PiChatNew" },
  keys = {
    { "<leader>pc", "<cmd>PiChat<cr>", desc = "pi-chat toggle" },
    { "<leader>pa", "<cmd>PiChatAsk<cr>", desc = "pi ask" },
    { "<leader>pn", "<cmd>PiChatNew<cr>", desc = "pi-chat new session" },
    { "<leader>pv", ":PiChatAskSelection<cr>", mode = "v", desc = "pi ask selection" },
  },
  opts = {
    -- pi_bin = "pi",
    -- model = "...",        -- optional, passed as `--model`
    -- provider = "...",     -- optional, passed as `--provider`
    -- no_session = false,   -- keep sessions so history persists
    -- width = 80,           -- conversation split width (default ~40% cols)
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
| `:PiChatNew` | Start a fresh session (discard the current conversation) |
| `:PiChatSessions` | Pick a recent session to continue |
| `:PiChatContinue` | Continue the most recent session |
| `:PiChatModel` | Pick the model |

## Keys (inside the chat)

| Key | Where | Action |
|---|---|---|
| `<CR>` (normal) / `<C-s>` | input | Send prompt (or steer if agent is busy) |
| `<C-c>` | both | Abort current turn |
| `q` | both | Close chat |
| `<Tab>` | both | Toggle focus between input / conversation |
| `<leader>pn` | both | New session |
| `<leader>pm` | both | Pick model |
| `<leader>ps` | both | Pick / switch session |
| `<C-v>` / `<leader>pp` | input | Paste a clipboard image (attached to next send) |
| `<leader>po` | conversation | Open the image on the current line |
| `]]` / `[[` | conversation | Jump to next / previous message |
| `za` / `zM` / `zR` | conversation | Toggle / close-all / open-all folds |

## Scope / limitations

- One active chat at a time.
- Diff preview for edit/write tools is not rendered; the raw tool result is
  shown in the collapsed block.
- `editor` dialogs open a floating scratch buffer (`<C-s>` or `:w` to submit).
