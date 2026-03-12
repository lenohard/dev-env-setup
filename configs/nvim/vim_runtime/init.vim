set runtimepath+=~/.vim_runtime

lua require('config.lazy')
lua require('config.init')
source ~/.vim_runtime/vimrcs/basic.vim
source ~/.vim_runtime/vimrcs/filetypes.vim
source ~/.vim_runtime/vimrcs/plugins_config.vim
source ~/.vim_runtime/vimrcs/extended.vim

let &packpath=&runtimepath

try
source ~/.vim_runtime/my_configs.vim
catch
endtry

if @% == ""
  bd
endif
