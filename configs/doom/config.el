;;; $DOOMDIR/config.el -*- lexical-binding: t; -*-

;; Place your private configuration here! Remember, you do not need to run 'doom
;; sync' after modifying this file!


;; Some functionality uses this to identify you, e.g. GPG configuration, email
;; clients, file templates and snippets. It is optional.
;; (setq user-full-name "John Doe"
;;       user-mail-address "john@doe.com")

;; Performance optimizations (migrated from Spacemacs)
(setq gc-cons-threshold 100000000)  ; 100MB
(setq gc-cons-percentage 0.1)
(setq read-process-output-max (* 1024 1024))  ; 1MB for LSP performance

;; Fix auto-save path to be absolute (prevents "No such file or directory" errors)
(setq auto-save-list-file-prefix
      (expand-file-name "autosave/" (concat doom-local-dir "cache/")))
(setq auto-save-file-name-transforms
      `(("\\`/[^/]*:\\([^/]*/\\)*\\([^/]*\\)\\'"
         ,(concat auto-save-list-file-prefix "tramp/\\2-") sha1)
        (".*" ,(concat auto-save-list-file-prefix "\\1-") sha1)))

;; Doom exposes five (optional) variables for controlling fonts in Doom:
;;
;; - `doom-font' -- the primary font to use
;; - `doom-variable-pitch-font' -- a non-monospace font (where applicable)
;; - `doom-big-font' -- used for `doom-big-font-mode'; use this for
;;   presentations or streaming
;; - `doom-symbol-font' -- for symbols
;; - `doom-serif-font' -- for the `fixed-pitch-serif' face
;;
;; See 'C-h v doom-font' for documentation and more examples of what they
;; accept. For example:
;;
;; 字号：macOS 的 `:size' 按 pt 解释（Retina 2x ≈ 2x px），Linux/X11 下按 px 解释；
;; 本机面板 3072x1920 + GNOME 2x（Xft.dpi=192），故 Linux 侧取 30，与其它 GTK 应用观感一致。
;; 临时缩放仍可用 `SPC t +' / `SPC t -' / `SPC t f'。
(setq my/font-size (if (featurep :system 'macos) 14 28))
(setq doom-font (font-spec :family "FiraCode Nerd Font" :size my/font-size :weight 'normal)
      doom-variable-pitch-font (font-spec :family "FiraCode Nerd Font" :size my/font-size)
      doom-symbol-font (font-spec :family "FiraCode Nerd Font" :size my/font-size))
;;
;; If you or Emacs can't find your font, use 'M-x describe-font' to look them
;; up, `M-x eval-region' to execute elisp code, and 'M-x doom/reload-font' to
;; refresh your font settings. If Emacs still can't find your font, it likely
;; wasn't installed correctly. Font issues are rarely Doom issues!

;; There are two ways to load a theme. Both assume the theme is installed and
;; available. You can either set `doom-theme' or manually load a theme with the
;; `load-theme' function. This is the default:
(setq doom-theme 'doom-gruvbox)

;; This determines the style of line numbers in effect. If set to `nil', line
;; numbers are disabled. For relative line numbers, set this to `relative'.
(setq display-line-numbers-type 'relative)


;; If you use `org' and don't want your org files in the default location below,
;; change `org-directory'. It must be set before org loads!
(setq org-directory "~/org/")

;; Evil configuration (migrated from Spacemacs)
(after! evil
  (setq evil-escape-key-sequence "jk")
  (setq evil-escape-unordered-key-sequence t)
  (setq evil-escape-delay 0.1))


;; Company configuration for auto-completion
(after! company
  (setq company-idle-delay 0)
  (setq company-show-numbers t))

;; AI/LLM Integration Configuration
;; GPTel: 只有本机 magpie 网关一个后端（http://127.0.0.1:3425/v1）。
;; 模型列表来自 `curl -s http://127.0.0.1:3425/v1/models -H 'Authorization: Bearer magpie'`；
;; 网关新增模型后来这里补一行，临时切换用 M-x gptel-select-model（SPC j s）。
(setq gptel-magpie-backend
      (gptel-make-openai "magpie"
        :protocol "http"                        ;important, default is https
        :host "127.0.0.1:3425"
        :endpoint "/v1/chat/completions"
        :key "magpie"                           ;网关接受任意 Bearer
        :stream t
        :models '(;; 路由组：跨账号/上游自动 fallback，优先用这些
                  group/glm-5.3
                  group/flash
                  group/oss-best
                  group/gpt-best
                  group/free
                  ;; 指定上游
                  zai/glm-5.3
                  zai/glm-5.3-flash
                  zai/glm-5.3-flashx
                  qwen-cn/qwen3.8-flash
                  qwen-cn/qwen3.8-max
                  qwen-cn/qwen3.8-omni-flash
                  qwen-cn/kimi-k3
                  qwen-cn/glm-5.3
                  qwen-cn/deepseek-v4.1-flash
                  qwen-cn/deepseek-v4.1-flash-1017
                  qwen-cn/xiaomi/mimo-v2.6-pro-ultraspeed
                  qwen-cn/MiniMax/MiniMax-M3.1-Flash
                  opencode-go/gpt-6-luna
                  opencode-go/claude-haiku-5-5
                  opencode-go/gemini-4-argon
                  opencode-go/deepseek-v4.1-flash
                  opencode-go/beam-free
                  opencode-go/muse-spark-1.3-contributor
                  opencode-go/mimo-v2.6-flash
                  opencode-go/mimo-v2.6-pro
                  opencode-zen/glm-5.3
                  opencode-zen/glm-5.3-flash-free
                  opencode-zen/claude-sonnet-5-5
                  opencode-zen/claude-opus-5-5
                  opencode-zen/claude-haiku-5-5
                  opencode-zen/gemini-3.8-flash
                  opencode-zen/gemini-4-argon
                  opencode-zen/deepseek-v4.1-flash
                  opencode-zen/mimo-v2.6-flash-free
                  opencode-zen/nemotron-3.5-lightning-free
                  opencode-zen/big-pickle
                  opencode-zen/beam-free
                  opencode-zen/nemotron-3.5-super-vl-free
                  opencode-zen/deepseek-v4.1-flash-free
                  aicodemirror/gpt-6.1-sol
                  aicodemirror/gpt-6-astra
                  kaiaicloud/gpt-6-luna
                  kaiaicloud/gpt-6.1-sol
                  kaiaicloud/gpt-6.1-terra
                  kaiaicloud/gpt-6-astra
                  kaiaicloud/grok-4.7
                  kaiaicloud/grok-4.7-build-fast
                  apifun/claude-sonnet-5-5
                  apifun/claude-opus-5-5
                  apifun/claude-opus-5
                  minimax-cn/MiniMax-M3.1-Flash
                  minimax-cn/MiniMax-M3)))

;; 默认模型 / 后端
(setq gptel-model 'group/flash
      gptel-backend gptel-magpie-backend)

(after! gptel
  (when (fboundp 'gptel-make-preset)
    (gptel-make-preset 'completion                       ;preset name, a symbol
      :description "for completion in place" ;for your reference
      :backend "magpie"                      ;gptel backend or backend name
      :model 'group/flash
      :system "based on the current buffer and requirement return the text that can be appended into the buffer directly to fullfill the requirement in the last comments, don't include it in the codeblock!")))

;; gptel-agent: gptel 的 agent 模式（工具调用 / 子代理 / skills）
;; M-x gptel-agent 开专用会话；或在任意提示里加 @gptel-agent 只让这一条走 agent。
;; 子代理定义读包内 agents/ 与 gptel-agent-dirs；skills 默认扫 ~/.agents/skills。
(use-package! gptel-agent
  :config
  (gptel-agent-update))


(defun gptel-select-model ()
  "Interactively select a model from all configured gptel backends."
  (interactive)
  (let* ((backend-models '())
         (current-selection (format "%s:%s" 
                                   (gptel-backend-name gptel-backend)
                                   gptel-model)))
    ;; Collect all models from all backends using association list
    (dolist (backend-pair gptel--known-backends)
      (let ((backend-name (car backend-pair))
            (backend (cdr backend-pair)))
        (dolist (model (gptel-backend-models backend))
          (push (cons (format "%s:%s" backend-name model)
                     (list backend model))
                backend-models))))
    
    ;; Sort for better UX
    (setq backend-models (sort backend-models (lambda (a b) (string< (car a) (car b)))))
    
    ;; Interactive selection
    (let* ((choices (mapcar #'car backend-models))
           (selection (completing-read 
                      (format "Select model (current: %s): " current-selection)
                      choices nil t nil nil current-selection)))
      (when selection
        (let* ((backend-model (cdr (assoc selection backend-models)))
               (backend (nth 0 backend-model))
               (model (nth 1 backend-model)))
          (setq gptel-backend backend
                gptel-model model)
          (message "Selected: %s" selection))))))



;; ;; Copilot configuration
;; (use-package! copilot
;;   :defer t
;;   :hook (find-file . (lambda () (when (derived-mode-p 'prog-mode) (copilot-mode))))
;;   :config
;;   (setq copilot-network-proxy '(:host "127.0.0.1" :port 6152))
;;   :bind (:map copilot-completion-map
;;               ("<tab>" . copilot-accept-completion)
;;               ("TAB" . copilot-accept-completion)
;;               ("C-TAB" . copilot-accept-completion-by-word)
;;               ("C-<tab>" . copilot-accept-completion-by-word)))

;; Disable company inline previews when using copilot
(after! company
  (delq 'company-preview-if-just-one-frontend company-frontends))

;; Obsidian configuration
;; NOTE: PlatoMac 上 obsidian 是走 package.el（~/.emacs.d/.local/elpa）装的，未在 packages.el 声明；
;; 未安装该包的机器（如本机）用 locate-library 兜住，避免加载报错。
(when (locate-library "obsidian")
  (use-package! obsidian
    :config
    (global-obsidian-mode t)
    (obsidian-backlinks-mode t)
    :custom
    (obsidian-directory (expand-file-name "~/Documents/Rain"))
    (obsidian-inbox-directory "Inbox")
    (markdown-enable-wiki-links t)
    :bind (:map obsidian-mode-map
                ("C-c C-n" . obsidian-capture)
                ("C-c C-l" . obsidian-insert-link)
                ("C-c C-o" . obsidian-follow-link-at-point)
                ("C-c C-p" . obsidian-jump)
                ("C-c C-b" . obsidian-backlink-jump))))

;; Devel;; Import Magic for Python
(use-package! importmagic
  :defer t
  :hook (python-mode . importmagic-mode))

;; Ghostel — libghostty-vt 驱动的终端模拟器（替代 vterm）
;; 入口：M-x ghostel（当前目录）/ SPC o t（项目根 popup 开关）/ SPC o T（当前项目新开）
;; 首次使用会下载原生模块；这里预设为自动下载，避免弹出交互提问。
(setq ghostel-module-auto-install 'download)
;; 原生模块放到包目录之外，`doom sync'/包升级重建 build 目录时不会把它删掉。
(setq ghostel-module-directory "~/.config/emacs/ghostel/")

(after! ghostel
  ;; 让 popup 里的终端与其它 buffer 共享 doom 主题的 solaire 背景由模块自己处理；
  ;; 这里只调几项体感相关的设置。
  (setq ghostel-max-scrollback (* 10 1024 1024)   ; 10MB 回滚历史
        ghostel-kill-buffer-on-exit t             ; shell 退出即关 buffer
        ghostel-buffer-identification-format "%b (%.30t)"))

;; Zoxide configuration
(use-package! zoxide
  :defer t
  :commands (zoxide-query-dired zoxide-query-eshell)
  :config
  (setq zoxide-use-fuzzy-matching t)
  (setq zoxide-prompt-prefix "zoxide> ")
  (setq zoxide-completion-function 'completing-read))

;; Custom Functions (migrated from Spacemacs)
(defun occur-dwim ()
  "Call `occur' with a sane default, chosen as the thing under point or selected region"
  (interactive)
  (push (if (region-active-p)
            (buffer-substring-no-properties
             (region-beginning)
             (region-end))
          (let ((sym (thing-at-point 'symbol)))
            (when (stringp sym)
              (regexp-quote sym))))
        regexp-history)
  (call-interactively 'occur))

(defun window-split-toggle ()
  "Toggle between horizontal and vertical split with two windows."
  (interactive)
  (if (> (length (window-list)) 2)
      (error "Can't toggle with more than 2 windows!")
    (let ((func (if (window-full-height-p)
                    #'split-window-vertically
                  #'split-window-horizontally)))
      (delete-other-windows)
      (funcall func)
      (save-selected-window
        (other-window 1)
        (switch-to-buffer (other-buffer))))))

(defun reattach-occur ()
  (if (get-buffer "*Occur*")
      (switch-to-buffer-other-window "*Occur*")
    (hydra-occur-dwim/body)))

;; Hydra for occur navigation
(defhydra hydra-occur-dwim ()
  "Occur mode"
  ("o" occur-dwim "Start occur-dwim" :color red)
  ("j" occur-next "Next" :color red)
  ("k" occur-prev "Prev":color red)
  ("h" delete-window "Hide" :color blue)
  ("r" (reattach-occur) "Re-attach" :color red))

;; Key bindings
(map! :leader
      :desc "M-x" "SPC" #'execute-extended-command
      :desc "Zoxide dired" "f z" #'zoxide-query-dired
      :desc "Zoxide eshell" "f Z" #'zoxide-query-eshell
      :desc "Window split toggle" "w ." #'window-split-toggle)

;; Override isearch binding to use C-s for save
(map! :gi "C-s" #'save-buffer
      :g "C-h o" #'hydra-occur-dwim/body)

;; Rebind isearch to C-f (or another key if preferred)
(map! :g "C-f" #'isearch-forward)

;; Custom functions for copying file paths
(defun copy-absolute-file-path ()
  "Copy the absolute path of the current file to clipboard."
  (interactive)
  (when buffer-file-name
    (let ((absolute-path (expand-file-name buffer-file-name)))
      (kill-new absolute-path)
      (message "Copied absolute path: %s" absolute-path))))

(defun copy-relative-file-path ()
  "Copy the relative path of the current file to clipboard."
  (interactive)
  (when buffer-file-name
    (let ((relative-path (file-relative-name buffer-file-name (projectile-project-root))))
      (kill-new relative-path)
      (message "Copied relative path: %s" relative-path))))

;; Evil key bindings
(after! evil
  (evil-global-set-key 'normal (kbd ",w") 'evil-write)
  (evil-global-set-key 'motion (kbd "0") 'evil-first-non-blank)
  ;; Leader2 keybindings with comma
  (evil-global-set-key 'normal (kbd ",cp") 'copy-absolute-file-path)
  (evil-global-set-key 'normal (kbd ",cq") 'copy-relative-file-path))

;; Org mode configuration
(after! org
  (add-hook 'org-mode-hook 'visual-line-mode))

;; Clipboard sync for terminal
(when (not window-system)
  (defun copy-to-clipboard (text &optional push)
    (let ((process-connection-type nil)
          ;; macOS: pbcopy; Wayland: wl-copy; else X11: xclip
          (clip-tool (cond ((executable-find "pbcopy") "pbcopy")
                           ((executable-find "wl-copy") "wl-copy")
                           ((executable-find "xclip") "xclip")
                           (t nil))))
      (when clip-tool
        (let ((proc (apply #'start-process "clipboard" "*Messages*"
                           clip-tool (unless (equal clip-tool "wl-copy") '("-selection" "clipboard")))))
          (process-send-string proc text)
          (process-send-eof proc)))))
  (setq interprogram-cut-function 'copy-to-clipboard))

;; Frame settings
;; 默认全屏：X11/Wayland 用 maximized（保留 GNOME 顶栏）；macOS 不支持 maximized，
;; 要用 fullboth 才是真全屏。对首个 frame 和 emacsclient -c 新建的 frame 都生效。
(add-to-list 'default-frame-alist
             (if (featurep :system 'macos)
                 '(fullscreen . fullboth)
               '(fullscreen . maximized)))

;; Transparent background
;; (set-frame-parameter (selected-frame) 'alpha '(90 . 85))
;; (add-to-list 'default-frame-alist '(alpha . (90 . 85)))

;; Additional settings
(setq ispell-program-name "aspell")
(add-to-list 'auto-mode-alist '("\\.js\\'" . rjsx-mode))

;; Font and icon configuration for better symbol display
(after! doom-modeline
  (setq doom-modeline-icon t)
  (setq doom-modeline-unicode-fallback t))

;; Ensure proper font fallback for symbols
(when (display-graphic-p)
  (let ((emoji-font (car (seq-filter (lambda (f) (find-font (font-spec :family f)))
                                     '("Apple Color Emoji" "Noto Color Emoji")))))
    ;; 只给 emoji 脚本用 emoji 字体，且用 append（最后的 fallback）。
    ;; 之前这里是 `(set-fontset-font t 'unicode ... 'prepend)'，等于把所有 unicode 字符
    ;; 的首选字体换成 Apple Color Emoji：数字/符号会走非等宽 emoji 字体，行高也会被
    ;; 撑大，看起来就是「字形错乱 + 字号偏大」。
    (when emoji-font
      (set-fontset-font t 'emoji (font-spec :family emoji-font) nil 'append))))


;; Whenever you reconfigure a package, make sure to wrap your config in an
;; `after!' block, otherwise Doom's defaults may override your settings. E.g.
;;
;;   (after! PACKAGE
;;     (setq x y))
;;
;; The exceptions to this rule:
;;
;;   - Setting file/directory variables (like `org-directory')
;;   - Setting variables which explicitly tell you to set them before their
;;     package is loaded (see 'C-h v VARIABLE' to look up their documentation).
;;   - Setting doom variables (which start with 'doom-' or '+').
;;
;; Here are some additional functions/macros that will help you configure Doom.
;;
;; - `load!' for loading external *.el files relative to this one
;; - `use-package!' for configuring packages
;; - `after!' for running code after a package has loaded
;; - `add-load-path!' for adding directories to the `load-path', relative to
;;   this file. Emacs searches the `load-path' when you load packages with
;;   `require' or `use-package'.
;; - `map!' for binding new keys
;;
;; To get information about any of these functions/macros, move the cursor over
;; the highlighted symbol at press 'K' (non-evil users must press 'C-c c k').
;; This will open documentation for it, including demos of how they are used.
;; Alternatively, use `C-h o' to look up a symbol (functions, variables, faces,
;; etc).
;;
;; You can also try 'gd' (or 'C-c c d') to jump to their definition and see how
;; they are implemented.
(after! evil
  ;; Remap C-h/l/j/k to move focus among windows/panels
  (map! :n "C-h" #'evil-window-left
        :n "C-j" #'evil-window-down
        :n "C-k" #'evil-window-up
        :n "C-l" #'evil-window-right))

;; use spc j t for commdn gptel
;; spc j m for gptel-menu
;; spc j ret for gptel-send
(map! :leader
      :desc "GPTel Menu" "j m" #'gptel-menu
      :desc "GPTel Send" "j RET" #'gptel-send
      :desc "GPTel Toggle" "j t" #'gptel
      :desc "GPTel Select Model" "j s" #'gptel-select-model)

;; (require 'dap-python)
;; (after! dap-mode
;;   (setq dap-python-debugger 'debugpy))


;; (after! evil
;;   ;; 先清除可能冲突的绑定
;;   (map! :leader "d" nil)  ; 清除 leader d 的绑定 (for dape)

;;   ;; 然后重新定义
;;   (map! :map dap-mode-map
;;         :leader
;;         :prefix ("d" . "dap")
;;         :desc "dap next"          "n" #'dap-next
;;         :desc "dap step in"       "i" #'dap-step-in
;;         :desc "dap step out"      "o" #'dap-step-out
;;         :desc "dap continue"      "c" #'dap-continue
;;         :desc "dap hydra"         "h" #'dap-hydra
;;         :desc "dap debug restart" "r" #'dap-debug-restart
;;         :desc "dap debug"         "s" #'dap-debug

;;         ;; debug
;;         :prefix ("dd" . "Debug")  ; 改用单个字母避免冲突
;;         :desc "dap debug recent"  "r" #'dap-debug-recent
;;         :desc "dap debug last"    "l" #'dap-debug-last

;;         ;; eval
;;         :prefix ("de" . "Eval")
;;         :desc "eval"                "e" #'dap-eval
;;         :desc "eval region"         "r" #'dap-eval-region
;;         :desc "eval thing at point" "s" #'dap-eval-thing-at-point
;;         :desc "add expression"      "a" #'dap-ui-expressions-add
;;         :desc "remove expression"   "d" #'dap-ui-expressions-remove

;;         :prefix ("db" . "Breakpoint")
;;         :desc "dap breakpoint toggle"      "b" #'dap-breakpoint-toggle
;;         :desc "dap breakpoint condition"   "c" #'dap-breakpoint-condition
;;         :desc "dap breakpoint hit count"   "h" #'dap-breakpoint-hit-condition
;;         :desc "dap breakpoint log message" "l" #'dap-breakpoint-log-message))



(add-hook 'emacs-lisp-mode-hook
          (lambda ()
            (setq-local indent-tabs-mode nil)
            (setq-local tab-width 2)
            (setq-local lisp-indent-offset 2)))

;; Function to insert current date and time at point
(defun my/insert-current-datetime ()
  "Insert current date and time in the format: 2025-08-18 星期一 09:34:24"
  (interactive)
  (insert (format-time-string "%Y-%m-%d %A %H:%M:%S")))

;; Bind the function to SPC t d using Doom's leader key system
(map! :leader
      :desc "Insert current datetime"
      "t d" #'my/insert-current-datetime)

;; (use-package aidermacs
;;   :bind (("C-c a" . aidermacs-transient-menu))
;;   :config
;;   ; Set API_KEY in .bashrc, that will automatically picked up by aider or in elisp
;;   ;; (setenv "ANTHROPIC_API_KEY" "sk-...")
;;   ; defun my-get-openrouter-api-key yourself elsewhere for security reasons
;;   ;; (setenv "OPENROUTER_API_KEY" (my-get-openrouter-api-key))
;;   :custom
;;   ; See the Configuration section below
;;   (aidermacs-use-architect-mode t)
;;   (aidermacs-default-model "sonnet"))

;; 身体：让 gptel agent 感知并控制这个 Emacs。实现见 ~/.doom.d/body.el，
;; 永久改动写在 ~/.doom.d/body-genes.el。SPC j a 说话 / SPC j b 对话窗 / SPC j u 撤销。
(load! "body")
(body-load-genes)
