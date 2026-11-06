-- pi-chat.nvim :: command registration
if vim.g.loaded_pi_chat then
  return
end
vim.g.loaded_pi_chat = true

local function pi()
  return require("pi-chat")
end

vim.api.nvim_create_user_command("PiChat", function()
  pi().toggle()
end, { desc = "Toggle pi-chat window" })

vim.api.nvim_create_user_command("PiChatOpen", function()
  pi().open()
end, { desc = "Open pi-chat window" })

vim.api.nvim_create_user_command("PiChatClose", function()
  pi().close()
end, { desc = "Close pi-chat window" })

vim.api.nvim_create_user_command("PiChatAsk", function(opts)
  pi().ask(opts.args)
end, { nargs = "*", desc = "Ask pi a question" })

vim.api.nvim_create_user_command("PiChatAskSelection", function()
  pi().ask_selection()
end, { range = true, desc = "Ask pi about the visual selection" })

vim.api.nvim_create_user_command("PiChatModel", function()
  pi().pick_model()
end, { desc = "Pick pi-chat model" })

vim.api.nvim_create_user_command("PiChatSessions", function()
  pi().pick_session()
end, { desc = "Pick a recent pi session to continue" })

vim.api.nvim_create_user_command("PiChatContinue", function()
  pi().continue()
end, { desc = "Continue the most recent pi session" })
