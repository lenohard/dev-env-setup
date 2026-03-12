# Custom Aliases

# General
alias src='source ~/.zshrc'
alias ,e="nvim ~/.zshrc"
alias grep='grep --color=always'
alias ssh='TERM=xterm-256color ssh'
alias whatsmyip="wget -qO- http://ipecho.net/plain ; echo"
alias localip="ip a | grep -Eo 'inet (addr:)?([0-9]*\.){3}[0-9]*' | grep -Eo '([0-9]*\.){3}[0-9]*' | grep -v '127.0.0.1'"

# Directory and File Management
alias lld='ls -d */'
alias du1='du -hd0'
alias stsize='du -hd1 ./* | sort -hr | more'

# Git
alias gs="gh copilot suggest"
alias git-root='cd $(git rev-parse --show-toplevel)'

# Node.js
alias ng="sudo npm list -g --depth=0 2>/dev/null"
alias nl="npm list --depth=0 2>/dev/null"

# Python
alias pip='python -m pip'
alias pip11='python3.11 -m pip'
alias pip10='python3.10 -m pip'

# Applications
alias matlab_cli="/Applications/MATLAB_R2022b.app/bin/matlab -nodesktop"
alias alacritty_nvim="alacritty -e nvim"

# System
alias wifion='nmcli radio wifi on'
alias suspendw='nmcli radio wifi off && systemctl suspend'

# Tmux
alias unblock_service="node /Users/senaca/code/music_download/unblock.js"
alias netease_service="npx NeteaseCloudMusicApi@latest" 
alias kill_wan='tmux kill-window -t wan_music'
alias kill_sub2sub='tmux kill-window -t sub2sub'

# File Sync and Upload
alias rsynccl='rsync -rv --delete /home/carl/mounts/galileo/main/  /home/carl/mounts/RACOON/Calibre_Library'
alias uploadProd='rsync -av --delete /Users/senaca/code/abChain/dapp/unpackage/dist/build/h5/ root@148.72.246.2:/www/wwwroot/fil.xiqumeta.com/public/wap'
alias uploadShop='rsync -av --delete --exclude=".user.ini" /Users/senaca/code/switch-shop/unpackage/dist/build/h5/ root@112.74.54.233:/www/wwwroot/dhd.xiqumeta.com/public/h5'
alias uploadDev='rsync -av --delete /Users/senaca/code/abChain/dapp/unpackage/dist/build/h5/ root@103.144.245.112:/www/wwwroot/fil.xiqumeta.com/public/wap'
alias uploadKg='rsync -av --delete /Users/senaca/school/kgraph/kg_react/build/ root@112.74.54.233:/www/wwwroot/dapp.xiqumeta.com'
alias uploadShopProd='rsync -av --delete --exclude=".user.ini" /Users/senaca/code/switch-shop/unpackage/dist/build/h5/ root@97.74.93.33:/www/wwwroot/duihuandian/public/h5'

# Miscellaneous
alias cnpm='npm --registry=https://registry.npmmirror.com --cache=$HOME/.npm/.cache/cnpm --disturl=https://npmmirror.com/mirrors/node --userconfig=$HOME/.cnpmrc'
alias sub_surge='curl -s https://sub2sub.vercel.app/sub2sub -o ~/Library/Application\ Support/Surge/Profiles/sub2sub.conf'
alias ibook='du -sh /Users/senaca/Library/Containers/com.apple.BKAgentService/Data/Documents/iBooks/Books/'
alias rrm='/opt/homebrew/bin/grm'

# GNU coreutils aliases
alias cp="gcp"
alias mv="gmv"
alias ls="gls --color=auto"
alias mkdir="gmkdir"
alias rm="grm"
alias ln="gln"
alias df="gdf"
alias du="gdu"
alias cat="gcat"
alias grep="ggrep"
alias sort="gsort"
alias uniq="guniq"
