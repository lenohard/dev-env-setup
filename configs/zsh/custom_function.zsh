# Custom Functions

# Add a new PATH entry with timestamp
function addpath() {
    cp ~/.zshrc ~/.zshrc.backup.$(date +%Y%m%d%H%M%S)
    local new_path_entry="export PATH=\"$1:\$PATH\"\n"
    local timestamp=$(date +"# == Added on %Y-%m-%d %H:%M:%S ==")
    echo -e "$timestamp\n$new_path_entry\n$(cat ~/.zshrc)" > ~/.zshrc
}

function  mkdircd() { mkdir -p "$1" && cd "$1"; }

# Change directory and list contents
function cdp() {
    if [ -z "$1" ]; then
        builtin cd
        return
    fi

    target="$1"

    if [ -f "$target" ]; then
        target="$(dirname "$target")"
    elif [ ! -d "$target" ] && [ ! -L "$target" ]; then
        echo "Invalid path or filename."
        return 1
    fi

    builtin cd "$target"
}

# Download music from URL using yt-dlp
function download_music(){
    local url=$(pbpaste)
    if [[ -z "$url" ]]; then
        echo "No url in clipboard"
        return 1
    fi
    local music_dir="$HOME/wan_music"
    if [[ ! -d "$music_dir" ]]; then
        mkdir "$music_dir"
    fi
    cd "$music_dir" || return 1
    yt-dlp -x --audio-format mp3 "$url"
    cd - || return 1
}

# Check siliconflow API balance
function sf_balance() {
    local api_key=${SILICONFLOW_API_KEY}
    if [[ -z "$api_key" ]]; then
        echo "Error: SILICONFLOW_API_KEY environment variable is not set."
        return 1
    fi

    local response=$(curl -s -L -X GET 'https://api.siliconflow.cn/v1/user/info' \
        -H 'Accept: application/json' \
        -H "Authorization: Bearer $api_key")

    if [[ $? -ne 0 ]]; then
        echo "Error: Failed to fetch userInfo."
        return 1
    fi

    local total_balance=$(echo "$response" | jq -r '.data.totalBalance')

    if [[ -z "$total_balance" ]]; then
        echo "Error: Failed to parse total balance from response."
        return 1
    fi

    echo "Total Balance: $total_balance"
}

# Check DeepSeek API balance
function dsk_balance() {
    local api_key=${DEEPSEEK_API_KEY}
    if [[ -z "$api_key" ]]; then
        echo "Error: DEEPSEEK_API_KEY environment variable is not set."
        return 1
    fi

    local response=$(curl -s -L -X GET 'https://api.deepseek.com/user/balance' \
        -H 'Accept: application/json' \
        -H "Authorization: Bearer $api_key")

    if [[ $? -ne 0 ]]; then
        echo "Error: Failed to fetch balance."
        return 1
    fi

    local total_balance=$(echo "$response" | grep -o '"total_balance":"[^"]*' | cut -d'"' -f4)

    if [[ -z "$total_balance" ]]; then
        echo "Error: Failed to parse total balance from response."
        return 1
    fi

    echo "Total Balance: $total_balance"
}

# Checkout file from another branch
function checkout_file_from_branch() {
    branch_name=$1
    filename=$(git ls-tree -r --name-only $branch_name | fzf)
    git checkout $branch_name -- "$filename"
}

# Remove duplicates from PATH
function remove_duplicates_from_path() {
    local path_array path_entry deduplicated_path
    path_array=(${(s.:.)PATH})
    deduplicated_path=""
    for path_entry in "${path_array[@]}"; do
        if [[ ! ":$deduplicated_path:" == *":$path_entry:"* ]]; then
            deduplicated_path="${deduplicated_path}:${path_entry}"
        fi
    done
    export PATH="${deduplicated_path:1}"
}

# Setup Wan Music environment in tmux
function wan_music() {
    working_dir="/Users/senaca/code/music_download"
    tmux new-window -n wan_music -c "$working_dir"
    tmux split-window -h -c "$working_dir"
    tmux split-window -v -c "$working_dir"
    tmux send-keys -t wan_music.3 "netease_service" C-m
    tmux send-keys -t wan_music.2 "unblock_service" C-m
    while ! lsof -i :3000; do
        printf "waiting for netease_service to start...\n"
        sleep 1
    done
    tmux send-keys -t wan_music.1 "./wan.py -q" C-m
    tmux select-pane -t wan_music.1
}

# Setup sub2sub environment in tmux
function sub2sub() {
    working_dir="/Users/senaca/code/sub2sub"
    tmux new-window -n sub2sub -c "$working_dir"
    tmux split-window -h -c "$working_dir"
    tmux send-keys -t sub2sub.2 "PORT=5003 && python3.11 ./app.py" C-m
    tmux select-window -t sub2sub.1
    while ! lsof -i :5003; do
        printf "waiting for sub2sub to start...\n"
        sleep 1
    done
    tmux send-keys -t sub2sub.1 'curl -X GET http://127.0.0.1:5003/sub2sub > "/Users/senaca/Library/Application Support/Surge/Profiles/sub2sub.conf" ' C-m
    tmux select-pane -t sub2sub.1
}


# Fetch latest USD/CNY exchange rate
function usd2cny(){
    curl -s "https://api.exchangerate-api.com/v4/latest/USD" | jq '.rates.CNY'
}

# Fetch latest ETH price and 24h change
function eth(){
    curl -s "https://api.coingecko.com/api/v3/coins/ethereum" | jq '.market_data.current_price.usd, .market_data.price_change_percentage_24h'
}

# Get raw GitHub URL for current repo
function rawUrl() {
    local user=$(git config --get remote.origin.url | sed -n 's/.*github.com[:/]\(.*\)\/.*/\1/p')
    local repo=$(git rev-parse --show-toplevel | xargs basename)
    echo "https://raw.githubusercontent.com/$user/$repo/main/$1"
}

# GPT-3 data processing
function data_gpt() {
    Prompt=$1
    data=$2
    prompt_input="${Prompt}: ${data}"

    gpt=$(curl https://api.openai.com/v1/chat/completions -s \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $OPENAI_API_KEY" \
        -d "{\"model\": \"gpt-3.5-turbo\", \"messages\": [{\"role\": \"user\", \"content\": \"${prompt_input}\"}], \"temperature\": 0.7}")
    echo $gpt
    echo -E $gpt | jq -r '.choices[0].message.content'
}

# Generate image using DALL-E
function img_gpt() {
    Prompt=$1
    size=${2:-"512x512"}

    create_img=$(curl 'https://api.openai.com/v1/images/generations' -s \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $OPENAI_API_KEY" \
        -d "{\"prompt\": \"${Prompt}\", \"n\": 1, \"size\": \"${size}\"}")
    echo $create_img | jq
    url=$(echo $create_img | jq -r '.data[0].url')
    rand_num=$(($RANDOM % 1000000 + 1))
    mkdir -p ~/everything/ai-images
    while [ -f ~/everything/ai-images/img-"$rand_num".png ]; do
        rand_num=$(($RANDOM % 1000000 + 1))
    done
    curl -s $url -o ~/everything/ai-images/dalle2-"$rand_num".png
    open ~/everything/ai-images/dalle2-"$rand_num".png
    echo ${Prompt} >> ~/everything/ai-images/dalle2-"$rand_num".txt
    echo "image saved to ~/everything/ai-images/dalle2-$rand_num.png"
    echo ~/everything/ai-images/dalle2-"$rand_num".png | pbcopy
    echo "image path copied to clipboard"
}

# unset proxy
function unset_proxy() {
    unset http_proxy
    unset https_proxy
    unset HTTP_PROXY
    unset HTTPS_PROXY
}

# Setup mify environments in tmux
function start-mify() {
    case "$1" in
        eval)
            eval_dir="/Users/senaca/code/xiaomi/mify/mify-eval"
            tmux new-window -n mify-eval -c "$eval_dir"
            tmux split-window -h -c "$eval_dir"
            tmux send-keys -t mify-eval.1 "uv run flask run --host 0.0.0.0 --port=5010 --debug" C-m
            tmux send-keys -t mify-eval.2 "export LOG_LEVEL=INFO && python run_huey_consumer.py" C-m
            tmux select-pane -t mify-eval.1
            ;;
        server)
            mify_dir="/Users/senaca/code/xiaomi/mify/mify-server/api"
            tmux new-window -n mify-server -c "$mify_dir"
            tmux send-keys -t mify-server "uv run flask run --host 0.0.0.0 --port=5001 --debug" C-m
            ;;
        worker)
            mify_dir="/Users/senaca/code/xiaomi/mify/mify-server/api"
            # Check if mify-server window exists
            if tmux list-windows -F '#W' 2>/dev/null | grep -q '^mify-server$'; then
                current_window=$(tmux display-message -p '#W')
                tmux select-window -t mify-server
                tmux split-window -h -c "$mify_dir"
                tmux send-keys "uv run celery -A app.celery worker --prefetch-multiplier=1 -P gevent --autoscale=4,1 --max-tasks-per-child=50 --loglevel INFO -Q dataset" C-m
                tmux select-pane -t mify-server.1
                tmux select-window -t "$current_window" 2>/dev/null
                echo "Started worker in mify-server window (right split). Check logs in mify-server window."
            else
                tmux new-window -n mify-worker -c "$mify_dir"
                tmux send-keys -t mify-worker "uv run celery -A app.celery worker --prefetch-multiplier=1 -P gevent --autoscale=4,1 --max-tasks-per-child=50 --loglevel INFO -Q dataset" C-m
                echo "Started standalone mify-worker window."
            fi
            ;;
        all)
            current_window=$(tmux display-message -p '#W')
            mify_dir="/Users/senaca/code/xiaomi/mify/mify-server/api"
            tmux new-window -n mify-all -c "$mify_dir"
            tmux split-window -h -c "$mify_dir"
            tmux send-keys -t mify-all.1 "uv run flask run --host 0.0.0.0 --port=5001 --debug" C-m
            tmux send-keys -t mify-all.2 "uv run celery -A app.celery worker --prefetch-multiplier=1 -P gevent --autoscale=4,1 --max-tasks-per-child=50 --loglevel INFO -Q dataset" C-m
            tmux select-pane -t mify-all.1
            tmux select-window -t "$current_window" 2>/dev/null
            echo "Started mify-all (server + worker in left-right splits). Check logs in mify-all window."
            ;;
        *)
            echo "Usage: start-mify {eval|server|worker|all}"
            echo "  eval   - Start mify-eval with Flask server and Huey consumer"
            echo "  server - Start mify-server with Flask server"
            echo "  worker - Start mify-worker for dataset queue"
            echo "  all    - Start server and worker in left-right splits"
            ;;
    esac
}

# Close mify environments in tmux
function close-mify() {
    case "$1" in
        eval)
            tmux kill-window -t mify-eval 2>/dev/null && echo "Closed mify-eval window" || echo "mify-eval window not found"
            ;;
        server)
            tmux kill-window -t mify-server 2>/dev/null && echo "Closed mify-server window" || echo "mify-server window not found"
            ;;
        worker)
            tmux kill-window -t mify-worker 2>/dev/null && echo "Closed mify-worker window" || echo "mify-worker window not found"
            ;;
        all)
            tmux kill-window -t mify-all 2>/dev/null && echo "Closed mify-all window" || echo "mify-all window not found"
            ;;
        *)
            echo "Usage: close-mify {eval|server|worker|all}"
            echo "  eval   - Close mify-eval window"
            echo "  server - Close mify-server window"
            echo "  worker - Close mify-worker window"
            echo "  all    - Close mify-all window"
            ;;
    esac
}

# Restart mify environments in tmux
function restart-mify() {
    case "$1" in
        eval)
            close-mify eval
            sleep 2
            start-mify eval
            ;;
        server)
            close-mify server
            sleep 2
            start-mify server
            ;;
        worker)
            close-mify worker
            sleep 2
            start-mify worker
            ;;
        all)
            echo "Restarting all mify services..."
            close-mify all
            sleep 2
            start-mify all
            ;;
        *)
            echo "Usage: restart-mify {eval|server|worker|all}"
            echo "  eval   - Restart mify-eval"
            echo "  server - Restart mify-server"
            echo "  worker - Restart mify-worker"
            echo "  all    - Restart mify-all"
            ;;
    esac
}
# List of Functions and Descriptions
# 1. addpath: Adds a new PATH entry with a timestamp.
# 2. cdp: Changes directory and lists contents.
# 3. download_music: Downloads music from a URL using yt-dlp.
# 4. dsk_balance: Checks DeepSeek API balance.
# 5. checkout_file_from_branch: Checks out a file from another branch.
# 6. remove_duplicates_from_path: Removes duplicates from PATH.
# 7. wan_music: Sets up Wan Music environment in tmux.
# 8. sub2sub: Sets up sub2sub environment in tmux.
# 9. start-mify: Sets up mify environments in tmux (eval|server).
# 10. close-mify: Closes mify environments in tmux (eval|server).
# 11. restart-mify: Restarts mify environments in tmux (eval|server).
# 12. usd2cny: Fetches the latest USD/CNY exchange rate.
# 13. eth: Fetches the latest ETH price and 24h change.
# 14. rawUrl: Gets the raw GitHub URL for the current repo.
# 15. data_gpt: Processes data using GPT-3.
# 16. img_gpt: Generates an image using DALL-E.
# 17. unset_proxy: Unsets proxy settings.
