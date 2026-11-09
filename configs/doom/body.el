;;; body.el --- Give the agent a body inside this Emacs -*- lexical-binding: t; -*-
;;
;; 让 gptel agent 住在你正在用的 Emacs 里：它能感知你看到什么、你光标在哪、
;; 你刚敲了什么，并且能当场修改这个 Emacs（字体、主题、布局、变量、任意 elisp）。
;; 每次改动都可撤销；你说「记住」时才写进 body-genes.el 永久保留。
;;
;; 结构：主从（master / subagent）
;;   主脑 *body* —— 跟用户对话、记共享记忆、派活
;;   子代理 *body-sub-N* —— 后台干长活，干完用 body_report 汇报并唤醒主脑
;;   通讯：body--shared-log（共享记忆）+ body_spawn/body_send/body_status/body_report
;;
;; 入口：
;;   M-x body-ask     （SPC j a）—— 跟主脑说一句话（主脑忙则排队）
;;   M-x body-submit  （SPC j RET）—— 把对话窗末尾的草稿发出去（窗内 C-<return> 同效）
;;   M-x body-continue（SPC j c）—— 接着上次的对话继续（读最近存档）
;;   M-x body-new-session（SPC j n）—— 结束当前对话、开新的（旧的自动存档）
;;   M-x body-toggle  （SPC j b）—— 开/关右侧对话窗
;;   M-x body-undo    （SPC j u）—— 撤销上一次身体改动
;;   M-x body-stop    （SPC j k）—— 停下正在进行的请求
;;   M-x body-agents  （SPC j l）—— 看所有子代理状态

(require 'gptel)
(require 'cl-lib)
(require 'seq)
(require 'subr-x)

(defun body--reset-tools ()
  "重新加载本文件时，先把 body 这个类别的工具整体摘掉，再重新注册，避免旧版本残留。"
  (when (and (boundp 'gptel--known-tools) (listp gptel--known-tools))
    (setq gptel--known-tools
          (seq-remove (lambda (cell) (equal (car-safe cell) "body"))
                      gptel--known-tools))))

(defun body--reset-advices ()
  "清掉旧版本 body.el 留在我们函数上的 advice（重新加载时自愈）。"
  (dolist (sym '(body--setup-session body--snapshot body--transform-add-snapshot
                 body-ask body-stop body--spawn body--report
                 gptel--process-tool-call
                 gptel--update-token-usage))
    (when (advice--p (symbol-function sym))
      (let (fns)
        (advice-mapc (lambda (f _) (push f fns)) sym)
        (dolist (f fns) (ignore-errors (advice-remove sym f)))))))

(body--reset-advices)
(body--reset-tools)

;;;; ------------------------------------------------------------------
;;;; 状态
;;;; ------------------------------------------------------------------

(defvar body-master-name "*body*"
  "主脑对话 buffer 名字。")

(defvar body-model nil
  "身体会话用的模型；nil 表示跟随 `gptel-model'。body_switch_model 会改它。")

(defvar body--last-session nil
  "最近一次接收用户请求的身体会话 buffer。")

(defvar body--session-role nil
  "buffer-local：master 或 sub。")
(make-variable-buffer-local 'body--session-role)

(defvar body--session-agent nil
  "buffer-local：子代理的名字，如 sub-1。")
(make-variable-buffer-local 'body--session-agent)

(defvar body--view-cache nil
  "buffer-local：上一轮快照里该会话看到的行，(KEY . LINES)，用于算 diff。")
(make-variable-buffer-local 'body--view-cache)

(defun body--session-p (&optional buf)
  "BUF（默认当前 buffer）是不是身体对话会话（主脑或子代理）。"
  (let ((name (buffer-name (or buf (current-buffer)))))
    (and name (string-match-p "\\`\\*body\\(-sub\\)?\\(-[0-9]+\\)?\\*\\'" name))))

(defun body--sub-p (&optional buf)
  "BUF 是不是子代理会话。"
  (let ((name (buffer-name (or buf (current-buffer)))))
    (and name (string-match-p "\\`\\*body-sub-[0-9]+\\*\\'" name))))

(defun body--sessions ()
  "所有活着的身体会话 buffer。"
  (seq-filter #'body--session-p (buffer-list)))

(defun body--busy-p (buf)
  "会话 BUF 是否正在处理请求。"
  (and (buffer-live-p buf)
       (with-current-buffer buf (gptel--fsm-live-p))))

(defvar body-genes-file (expand-file-name "body-genes.el" doom-user-dir)
  "永久保留的身体改动（基因）写到这里，启动时加载。")

(defvar body-self-file (expand-file-name "body.el" doom-user-dir)
  "身体自身的源文件。agent 改自己时只能通过 body_rewrite_self 改它，会先校验语法。")

(defvar body--user-window nil
  "用户最近一次真正在操作的窗口（不是对话窗、不是 minibuffer）。")

(defvar body--cmd-log nil
  "最近执行的命令，每项 (SEQ . 命令)，用于感知你刚做了什么。")

(defvar body--cmd-seq 0)

(defvar body--undo-stack nil
  "撤销栈：每项是 (ID DESC . UNDO-THUNK)。")

(defvar body--undo-counter 0)

(defvar body--shared-log nil
  "共享记忆：主从之间共享的结论，最新在前。每项 (:time :from :text)。")

(defvar body--agents nil
  "所有子代理，每项 (:name :buffer :task :started :status :report)。")

(defvar body--agent-counter 0)

(defvar body-max-agents 6
  "同时最多几个子代理。")

(defvar body-auto-wake-master t
  "子代理 body_report 汇报后，是否自动唤醒主脑。")

(defvar body--master-queue nil
  "主脑忙的时候，用户消息排队在这里。")

;;;; ------------------------------------------------------------------
;;;; 感知：用户在操作哪个窗口 + 最近命令
;;;; ------------------------------------------------------------------

(defun body--track ()
  "记录用户焦点窗口和最近命令。挂在 `post-command-hook'。"
  (unless (or (minibufferp) (body--session-p) (window-minibuffer-p))
    (let ((w (selected-window)))
      (unless (body--session-p (window-buffer w))
        (setq body--user-window w))))
  (when (and this-command (symbolp this-command))
    (cl-incf body--cmd-seq)
    (push (cons body--cmd-seq this-command) body--cmd-log)
    (setq body--cmd-log (cl-subseq body--cmd-log 0
                                   (min 60 (length body--cmd-log))))))

(add-hook 'post-command-hook #'body--track)

(defun body--user-window* ()
  "返回当前最可信的用户窗口。"
  (or (and (window-live-p body--user-window)
           (not (body--session-p (window-buffer body--user-window)))
           body--user-window)
      (car (seq-remove
            (lambda (w) (body--session-p (window-buffer w)))
            (window-list nil 'no-mini)))
      (selected-window)))
;;;; ------------------------------------------------------------------
;;;; 快照零件：数字 / 用量 / 外观 / 窗口
;;;; ------------------------------------------------------------------

(defvar body--last-appearance nil
  "上一次快照里的外观，(HEIGHT THEME WIDTH HEIGHT)。")

(defvar body--last-cmd-seq 0
  "上一轮快照报告到哪条命令了。")

(defvar body--sending-buffer nil
  "正在发请求的会话 buffer，`gptel-send' 期间动态绑定。")

(defun body--fmt-num (n)
  (cond ((null n) "-")
        ((>= n 1000000) (format "%.1fM" (/ n 1000000.0)))
        ((>= n 1000) (format "%.1fk" (/ n 1000.0)))
        (t (format "%d" n))))

(defun body--session-usage (buf)
  "BUF 的 gptel token 用量 (LAST TOTAL)。"
  (when (and (buffer-live-p buf) (buffer-local-value 'gptel-mode buf))
    (with-current-buffer buf
      (let ((u (and (boundp 'gptel--token-usage) gptel--token-usage)))
        (when u (list (car u) (cadr u)))))))

(defvar body--model-meta (make-hash-table :test 'equal)
  "网关元信息：模型 ID -> (:context N :max-output N)。")

(defun body--context-window (&optional model)
  "MODEL（默认当前模型）的上下文窗口；未知返回 nil。"
  (let ((meta (gethash (format "%s" (or model body-model gptel-model))
                       body--model-meta)))
    (or (plist-get meta :context) (plist-get meta :max-output))))

(defvar-local body--last-req nil
  "buffer-local：最近一次 HTTP 请求的 token 用量 plist。")

(defun body--record-last-request (fn tokens &optional tokens-full)
  "记下单次请求的用量，再交回 gptel 原函数。"
  (when tokens (setq body--last-req tokens))
  (funcall fn tokens tokens-full))

(unless (advice-member-p #'body--record-last-request 'gptel--update-token-usage)
  (advice-add 'gptel--update-token-usage :around #'body--record-last-request))

(defun body--usage-line (buf)
  "上下文占用：最近一次请求的 入+缓存+出 = 合计 / 上下文窗口。"
  (when (buffer-live-p buf)
    (let* ((tok (buffer-local-value 'body--last-req buf))
           (in (or (plist-get tok :input) 0))
           (ca (or (plist-get tok :cached) 0))
           (out (or (plist-get tok :output) 0))
           (sum (+ in ca out))
           (win (body--context-window
                 (ignore-errors (buffer-local-value 'gptel-model buf)))))
      (when (> sum 0)
        (format "上下文(token): 入%s + 缓存%s + 出%s = %s / %s (%s)"
                (body--fmt-num in) (body--fmt-num ca) (body--fmt-num out)
                (body--fmt-num sum)
                (if win (body--fmt-num win) "窗口未知")
                (if win
                    (format "%d%%" (round (* 100.0 (/ (float sum) win))))
                  "?"))))))


(defun body--appearance ()
  (let ((frame (selected-frame)))
    (list (face-attribute 'default :height)
          (or (car custom-enabled-themes) "无")
          (frame-width frame)
          (frame-height frame))))

(defun body--appearance-line ()
  "外观行：给绝对值，变了就标「← 刚变」。"
  (let* ((cur (body--appearance))
         (prev body--last-appearance)
         (diff (when (and prev (not (equal prev cur)))
                 (string-join
                  (delq nil
                        (list (unless (equal (nth 0 prev) (nth 0 cur))
                                (format "字号 %s→%s" (nth 0 prev) (nth 0 cur)))
                              (unless (equal (nth 1 prev) (nth 1 cur))
                                (format "主题 %s→%s" (nth 1 prev) (nth 1 cur)))
                              (unless (equal (nth 2 prev) (nth 2 cur))
                                (format "宽 %s→%s" (nth 2 prev) (nth 2 cur)))
                              (unless (equal (nth 3 prev) (nth 3 cur))
                                (format "高 %s→%s" (nth 3 prev) (nth 3 cur)))))
                  " "))))
    (setq body--last-appearance cur)
    (let ((line (format "外观: 字号(height)=%d 主题=%s frame=%d×%d"
                        (nth 0 cur) (nth 1 cur) (nth 2 cur) (nth 3 cur))))
      (if diff (format "%s  ← 刚变: %s" line diff) line))))

(defun body--window-header (w)
  "窗口 W 的一行摘要。"
  (with-selected-window w
    (let* ((buf (window-buffer w))
           (file (buffer-file-name buf)))
      (with-current-buffer buf
        (format "- buffer:%s mode:%s%s 行范围:%d-%d 光标行:%d%s"
                (buffer-name buf)
                major-mode
                (if file (format " file:%s" (abbreviate-file-name file)) "")
                (line-number-at-pos (window-start w))
                (line-number-at-pos (window-end w t))
                (line-number-at-pos (window-point w))
                (concat (if (buffer-modified-p buf) " [未保存]" "")
                        (if (and (boundp 'text-scale-mode-amount)
                                 (/= 0 text-scale-mode-amount))
                            (format " 缩放:%+d" text-scale-mode-amount)
                          "")))))))

(defun body--region-line ()
  "选区一行。必须在用户 buffer 里调用。"
  (when (use-region-p)
    (format "  选中:「%s」"
            (truncate-string-to-width
             (replace-regexp-in-string "\n" "⏎"
                                       (buffer-substring-no-properties
                                        (region-beginning) (region-end)))
             200 nil nil "…"))))

;;;; ------------------------------------------------------------------
;;;; 快照零件：可见内容的行级 diff（无 LCS，按行号对齐）
;;;; ------------------------------------------------------------------

(defun body--lines-with-numbers (text l1)
  "TEXT 按行切开配行号（从 L1 起），返回 ((行号 . 文本) ...)。"
  (let ((ln l1) (out '()))
    (dolist (line (split-string (string-trim-right text "\n") "\n"))
      (push (cons ln line) out)
      (setq ln (1+ ln)))
    (nreverse out)))

(defun body--format-lines (lines ptline)
  (string-join
   (mapcar (lambda (l)
             (format "%5d %s%s" (car l)
                     (if (= (car l) ptline) "▸" " ")
                     (cdr l)))
           lines)
   "\n"))

(defun body--diff-render (old new ptline)
  "按行号对齐做 diff；只输出变化行 ±2 行。没有变化返回 nil。"
  (let* ((oldmap (make-hash-table :test 'eql))
         (items '())
         (changed nil))
    (dolist (l old) (puthash (car l) (cdr l) oldmap))
    (dolist (l new)
      (let* ((ln (car l))
             (txt (cdr l))
             (prev (gethash ln oldmap 'missing)))
        (cond ((eq prev 'missing) (push (list "+" l) items) (setq changed t))
              ((equal prev txt) (push (list " " l) items))
              (t (push (list "~" l) items) (setq changed t)))))
    (when changed
      (let* ((items (nreverse items))
             (n (length items))
             (keep (make-vector n nil))
             (out '())
             (gap nil))
        (dotimes (k n)
          (unless (equal (car (nth k items)) " ")
            (cl-loop for d from (max 0 (- k 2)) to (min (1- n) (+ k 2))
                     do (aset keep d t))))
        (dotimes (k n)
          (if (aref keep k)
              (progn
                (when gap (push "      …" out))
                (setq gap nil)
                (let* ((mark (car (nth k items)))
                       (cell (nth 1 (nth k items))))
                  (push (format "%5d %s%s%s" (car cell)
                                (if (= (car cell) ptline) "▸" " ")
                                mark (cdr cell))
                        out)))
            (setq gap t)))
        (string-join (nreverse out) "\n")))))

(defun body--render-view (buf w session)
  "渲染窗口 W 里 BUF 的可见内容；SESSION 里存上一轮的行用于 diff。"
  (let* ((start (window-start w))
         (end (window-end w t))
         (pt (window-point w))
         (text (with-current-buffer buf
                 (buffer-substring-no-properties start (min end (point-max)))))
         (l1 (with-current-buffer buf (line-number-at-pos start)))
         (ptline (with-current-buffer buf (line-number-at-pos pt)))
         (key (with-current-buffer buf
                (format "%s|%s" (buffer-name) (buffer-file-name))))
         (new (body--lines-with-numbers text l1))
         (last (format "%d" (or (car (car (last new))) l1)))
         (cache (and (buffer-live-p session)
                     (buffer-local-value 'body--view-cache session)))
         (same (and cache (equal (car cache) key)
                    (equal (mapcar #'car (cdr cache))
                           (mapcar #'car new))
                    (cdr cache)))
         (body nil))
    (when (buffer-live-p session)
      (with-current-buffer session
        (setq-local body--view-cache (cons key new))))
    (setq body
          (cond
           ((null same) (body--format-lines new ptline))
           (t (or (body--diff-render same new ptline)
                  "（与上一轮相同，未变）"))))
    (when (> (length body) 6000)
      (setq body (concat (substring body 0 6000) "\n  …(截断)")))
    (concat (if same
                (format "可见内容(%d-%s 行, 相对上轮; ~改 +增 ▸光标):" l1 last)
              (format "可见内容(%d-%s 行, ▸=光标行):" l1 last))
            "\n" body)))

;;;; ------------------------------------------------------------------
;;;; 快照：拼装
;;;; ------------------------------------------------------------------

(defun body--recent-changes (n)
  (when body--undo-stack
    (format "最近改动: %s"
            (string-join (mapcar (lambda (e) (nth 1 e))
                                 (seq-take body--undo-stack n))
                         "；"))))

(defun body--new-commands-line ()
  "只报自上一轮快照以来新执行的命令。"
  (let* ((new (seq-filter (lambda (p) (> (car p) body--last-cmd-seq))
                          body--cmd-log))
         (names (delete-dups (mapcar #'cdr new))))
    (when body--cmd-log
      (setq body--last-cmd-seq (car (car body--cmd-log))))
    (when names
      (format "最近命令(新增): %s"
              (string-join (mapcar #'symbol-name (seq-take names 12)) " ")))))

(defun body--agent-get (name)
  (seq-find (lambda (a) (equal (plist-get a :name) name)) body--agents))

(defun body--agent-status (a)
  (let ((buf (plist-get a :buffer)))
    (cond ((not (buffer-live-p buf)) "已关闭")
          ((body--busy-p buf) "运行中")
          ((plist-get a :report) "已汇报")
          (t "已结束(未汇报)"))))

(defun body--agents-line ()
  (when body--agents
    (format "subagent: %s"
            (string-join
             (mapcar (lambda (a)
                       (format "%s[%s]" (plist-get a :name) (body--agent-status a)))
                     body--agents)
             " "))))

(defun body--log-line (n)
  (when body--shared-log
    (format "共享记忆(最近 %d 条):\n%s" n
            (string-join
             (mapcar (lambda (e)
                       (format "  [%s] %s: %s"
                               (plist-get e :time)
                               (plist-get e :from)
                               (truncate-string-to-width
                                (plist-get e :text) 400 nil nil "…")))
                     (seq-take body--shared-log n))
             "\n"))))

(defun body--snapshot (&optional session)
  "构造身体快照字符串。SESSION 是产出这条快照的会话 buffer。"
  (let* ((session (or session body--sending-buffer
                      (and (body--session-p) (current-buffer))
                      body--last-session))
         (live (and (buffer-live-p session) session))
         (uw (body--user-window*))
         (uw-buf (and (window-live-p uw) (window-buffer uw)))
         (others (seq-remove
                  (lambda (w) (or (eq w uw) (body--session-p (window-buffer w))))
                  (window-list nil 'no-mini)))
         (role (and live (buffer-local-value 'body--session-role live)))
         (me (and live (buffer-local-value 'body--session-agent live))))
    (string-join
     (delq nil
           (list
            "<身体状态>"
            (body--appearance-line)
            (when (eq role 'sub)
              (format "角色: 子代理 %s（主脑是 %s，干完用 body_report 汇报）"
                      me (buffer-name (body--master))))
            (format "模型: %s @ %s"
                    (or (and live (buffer-local-value 'gptel-model live))
                        body-model gptel-model)
                    (or (ignore-errors (gptel-backend-name gptel-backend)) "?"))
            "焦点窗口(你正看着/操作的):"
            (body--window-header uw)
            (and uw-buf (with-current-buffer uw-buf (body--region-line)))
            (body--render-view uw-buf uw live)
            (when others
              (concat "其它窗口:\n"
                      (string-join (mapcar #'body--window-header others) "\n")))
            (body--recent-changes 3)
            (body--new-commands-line)
            (body--agents-line)
            (body--log-line 4)
            (body--usage-line live)
            "</身体状态>"))
     "\n")))

(defun body--transform-add-snapshot (&optional _fsm)
  "把身体快照追加到待发送的 prompt 末尾。挂在 `gptel-prompt-transform-functions'。
在 gptel 的临时拷贝 buffer 里跑，所以不污染真正的对话历史。"
  (let ((snap (condition-case err
                  (body--snapshot)
                (error (format "<身体状态>\n(快照构造出错: %s)\n</身体状态>"
                               (error-message-string err))))))
    (goto-char (point-max))
    (insert "\n\n" snap)))

(defun body--around-send (fn &rest args)
  "让快照知道是哪个会话在发请求。"
  (let ((body--sending-buffer (current-buffer)))
    (apply fn args)))

(unless (advice-member-p #'body--around-send 'gptel-send)
  (advice-add 'gptel-send :around #'body--around-send))
;;;; ------------------------------------------------------------------
;;;; 撤销机制
;;;; ------------------------------------------------------------------

(defun body--push-undo (desc thunk)
  "登记一个可撤销改动。"
  (cl-incf body--undo-counter)
  (push (list body--undo-counter desc thunk) body--undo-stack)
  body--undo-counter)

(defun body-undo (&optional id)
  "撤销上一次身体改动；或撤销到指定 ID（含）。"
  (interactive)
  (if (null body--undo-stack)
      (message "身体：没有可撤销的改动")
    (let (done)
      (if id
          (while (and body--undo-stack
                      (>= (caar body--undo-stack) id))
            (let ((e (pop body--undo-stack)))
              (ignore-errors (funcall (nth 2 e)))
              (push (nth 1 e) done)))
        (let ((e (pop body--undo-stack)))
          (ignore-errors (funcall (nth 2 e)))
          (push (nth 1 e) done)))
      (message "身体：已撤销 %s" (string-join (nreverse done) "；")))))

;;;; ------------------------------------------------------------------
;;;; 工具：感知
;;;; ------------------------------------------------------------------

(defun body--read-buffer (name &optional from to)
  (let ((buf (get-buffer name)))
    (if (not buf)
        (format "没有名为 %s 的 buffer" name)
      (with-current-buffer buf
        (let* ((b (if from (save-excursion (goto-char (point-min))
                                           (forward-line (1- from)) (point))
                    (point-min)))
               (e (if to (save-excursion (goto-char (point-min))
                                         (forward-line to) (point))
                    (point-max))))
          (buffer-substring-no-properties b (min e (point-max))))))))

(defvar body-auto-approve t
  "非 nil 时 body_eval 对常规操作直接执行，不再询问。
为 nil 时连写文件、shell 这一级也会问。")

(defvar body--always-allow t
  "本 Emacs 会话内是否已选择「全部允许」。")

(defun body--must-ask-p (code)
  "只有真正高危、难以撤销的操作才需要用户点头。"
  (string-match-p
   (regexp-opt '("kill-emacs" "delete-directory" "delete-file" "dired-delete"
                 "shell-command" "async-shell-command" "call-process"
                 "start-process" "make-process" "server-eval"
                 "rm -rf" "chmod" "chown"))
   code))

(defun body--ask-permission (code)
  "在 minibuffer 里问用户一句。返回 :allow / :all / :deny 或改写后的代码字符串。"
  (let ((ans (read-answer
              (format "身体要执行敏感操作，允许吗？（%s）"
                      (truncate-string-to-width (string-trim code) 60 nil nil "…"))
              '(("yes" ?y "允许这一次")
                ("no" ?n "拒绝，什么都不做")
                ("edit" ?e "先改这段代码再执行（可以顺手写上你的意见）")
                ("always" ?a "本 Emacs 会话内全部允许")))))
    (pcase ans
      ("yes" :allow)
      ("always" :all)
      ("edit" (let ((new (read-string "按你的意思改：" code)))
                 (if (string-empty-p (string-trim new)) :deny new)))
      (_ :deny))))

(defun body--maybe-ask (code)
  "默认全自动；只有 body--always-allow 为 nil 时才问一句。"
  (if body--always-allow
      code
    (if (not (if body-auto-approve (body--must-ask-p code) (body--dangerous-p code)))
        code
      (if (yes-or-no-p "身体要执行敏感操作，允许吗？") code nil))))

(gptel-make-tool
 :name "body_sense"
 :category "body"
 :description "感知身体细节。what=buffer 读某个 buffer 全文或行范围；what=buffers 列出所有 buffer；what=eval 只读地求值一段 elisp（返回值）用于查询状态。"
 :args '((:name "what" :type string :enum ["buffer" "buffers" "eval"]
          :description "感知类型")
         (:name "name" :type string :optional t
          :description "what=buffer 时的 buffer 名")
         (:name "from" :type integer :optional t :description "起始行")
         (:name "to" :type integer :optional t :description "结束行")
         (:name "code" :type string :optional t
          :description "what=eval 时的只读 elisp 表达式"))
 :function
 (lambda (what &optional name from to code)
   (pcase what
     ("buffers" (string-join (mapcar #'buffer-name (buffer-list)) "\n"))
     ("buffer" (body--read-buffer name from to))
     ("eval" (condition-case err
                 (format "%S" (eval (car (read-from-string code)) t))
               (error (format "错误: %s" (error-message-string err)))))
     (_ "未知的 what"))))

;;;; ------------------------------------------------------------------
;;;; 工具：动作（改身体，带撤销）
;;;; ------------------------------------------------------------------

(defvar body--watched-faces
  '(default fixed-pitch variable-pitch mode-line mode-line-inactive
    header-line line-number line-number-current-line)
  "每次改动前自动记录这些 face 的全部属性，撤销时恢复。")

(defun body--capture-baseline (uw)
  "记录改动前的外观基线：face、主题、窗口布局、焦点 buffer 的 text-scale。"
  (list :faces (mapcar (lambda (f) (cons f (face-all-attributes f (selected-frame))))
                       (seq-filter #'facep body--watched-faces))
        :themes custom-enabled-themes
        :wconf (current-window-configuration)
        :scale (when (window-live-p uw)
                 (with-current-buffer (window-buffer uw)
                   (cons (current-buffer)
                         (and (boundp 'text-scale-mode-amount) text-scale-mode-amount))))))

(defun body--restore-baseline (base)
  "恢复 `body--capture-baseline' 记录的状态。"
  (let ((themes (plist-get base :themes)))
    (unless (equal themes custom-enabled-themes)
      (mapc #'disable-theme custom-enabled-themes)
      (dolist (th (reverse themes)) (load-theme th t))))
  (dolist (fa (plist-get base :faces))
    (dolist (kv (cdr fa))
      (ignore-errors (set-face-attribute (car fa) nil (car kv) (cdr kv)))))
  (ignore-errors (set-window-configuration (plist-get base :wconf)))
  (when-let* ((sc (plist-get base :scale))
              ((buffer-live-p (car sc))))
    (with-current-buffer (car sc)
      (text-scale-set (or (cdr sc) 0)))))

(defun body--dangerous-p (code)
  "粗略判断 elisp 是否触及文件/shell/进程/网络等危险操作。"
  (string-match-p
   (regexp-opt '("delete-file" "shell-command" "call-process" "start-process"
                 "make-process" "write-region" "delete-directory" "rename-file"
                 "url-retrieve" "kill-emacs" "server-eval" "dired-delete"))
   code))

(gptel-make-tool
 :name "body_eval"
 :category "body"
 :description "在用户当前焦点窗口的 buffer 里求值任意 elisp，用来改变身体（外观/布局/行为）或执行动作。可附 undo_code 说明如何撤销本次改动（强烈建议对外观/布局类改动提供）。返回求值结果或报错。涉及文件/shell/删除等危险操作会先请求用户确认。"
 :args '((:name "code" :type string :description "要求值的 elisp")
         (:name "summary" :type string
          :description "一句话中文说明这次改动做了什么，会显示给用户")
         (:name "undo_code" :type string :optional t
          :description "撤销本次改动的 elisp；没有则本次不可撤销"))
 :confirm nil   ; 权限统一由 body--maybe-ask 在 minibuffer 问
 :function
 (lambda (code summary &optional undo_code)
   (let* ((uw (body--user-window*))
          (base (body--capture-baseline uw))
          (code (body--maybe-ask code))
          result)
     ;; 执行前把所有改过的 buffer 写进 #自动保存# 文件（不碰原文件、不跑保存钩子），
     ;; 万一这段代码把 Emacs 卡死，重启后用 M-x recover-session 找回。
     (when code (do-auto-save t))
     (setq result
           (if (null code)
               "已拒绝：用户未许可，未执行。"
             (condition-case err
                 (format "OK 结果=%S"
                         (if (window-live-p uw)
                             (with-selected-window uw
                               (eval (car (read-from-string (format "(progn %s)" code))) t))
                           (eval (car (read-from-string (format "(progn %s)" code))) t)))
               (error (format "错误: %s" (error-message-string err))))))
     (when code

       ;; 登记撤销：先跑 agent 给的 undo_code（处理变量/模式等），
       ;; 再恢复自动记录的外观基线（face/主题/布局/缩放），不依赖 agent 猜旧值。
       (body--push-undo
        (or summary "一次改动")
        (lambda ()
          (when (and undo_code (> (length (string-trim undo_code)) 0))
            (if (window-live-p uw)
                (with-selected-window uw
                  (ignore-errors (eval (car (read-from-string
                                             (format "(progn %s)" undo_code))) t)))
              (ignore-errors (eval (car (read-from-string
                                         (format "(progn %s)" undo_code))) t))))
          (body--restore-baseline base)))
       (message "身体：%s  （SPC j u 撤销）" summary))
     result)))

(gptel-make-tool
 :name "body_undo"
 :category "body"
 :description "撤销最近一次身体改动。不带参数撤销上一次。"
 :args nil
 :function (lambda () (body-undo) "已撤销"))

;;;; ------------------------------------------------------------------
;;;; 主从：共享记忆、派活、通讯
;;;; ------------------------------------------------------------------

(defun body--log-add (from text)
  "往共享记忆里加一条。"
  (push (list :time (format-time-string "%H:%M") :from from :text text)
        body--shared-log)
  (setq body--shared-log (cl-subseq body--shared-log
                                    0 (min 50 (length body--shared-log)))))

(defun body--master ()
  "主脑会话 buffer。已有主脑会话就沿用，否则新建 *body*。"
  (or (seq-find (lambda (b) (eq 'master (buffer-local-value 'body--session-role b)))
                (body--sessions))
      (seq-find (lambda (b) (not (body--sub-p b))) (body--sessions))
      (body--setup-session (get-buffer-create body-master-name) 'master nil)))

(defun body--content-arg (content)
  "支持 content 以 ::file::路径 形式从文件读取。"
  (if (string-prefix-p "::file::" content)
      (let ((p (expand-file-name (substring content (length "::file::")))))
        (if (file-exists-p p)
            (with-temp-buffer (insert-file-contents p) (buffer-string))
          (signal 'file-missing (list p))))
    content))

(defun body--spawn (task)
  "新建一个子代理去干 TASK，立即返回（后台跑）。"
  (let ((running (seq-filter (lambda (a) (body--busy-p (plist-get a :buffer)))
                             body--agents)))
    (if (>= (length running) body-max-agents)
        (format "拒绝：已有 %d 个子代理在跑（上限 %d）。用 body_status 看进度，或等它们汇报。"
                (length running) body-max-agents)
      (cl-incf body--agent-counter)
      (let* ((name (format "sub-%d" body--agent-counter))
             (buf (get-buffer-create (format "*body-sub-%d*" body--agent-counter))))
        (setq body--agents
              (append body--agents
                      (list (list :name name :buffer buf :task task
                                  :started (current-time) :status 'running
                                  :report nil))))
        (body--setup-session buf 'sub name)
        (with-current-buffer buf
          (goto-char (point-max))
          (unless (bolp) (insert "\n"))
          (insert task)
          (gptel-send))
        (body--log-add "master"
                       (format "派出 %s: %s" name
                               (truncate-string-to-width task 120 nil nil "…")))
        (format "已派出 %s，后台运行。它干完会 body_report 汇报并唤醒你；也可用 body_status 查进度、body_send 补指令。" name)))))

(defun body--send-to-agent (name message)
  (let ((a (body--agent-get name)))
    (cond
     ((null a) (format "没有子代理 %s" name))
     ((not (buffer-live-p (plist-get a :buffer))) (format "%s 的 buffer 已关闭" name))
     ((body--busy-p (plist-get a :buffer)) (format "%s 还在跑，等它本轮结束再发" name))
     (t (with-current-buffer (plist-get a :buffer)
          (goto-char (point-max))
          (unless (bolp) (insert "\n"))
          (insert message)
          (gptel-send))
        (body--log-add "master"
                       (format "追加指令给 %s: %s" name
                               (truncate-string-to-width message 120 nil nil "…")))
        (format "已发送给 %s" name)))))

(defun body--status-text ()
  (string-join
   (delq nil
         (list
          (if body--agents
              (concat "子代理:\n"
                      (string-join
                       (mapcar
                        (lambda (a)
                          (format "- %s [%s] 任务:%s%s"
                                  (plist-get a :name)
                                  (body--agent-status a)
                                  (truncate-string-to-width (or (plist-get a :task) "") 100 nil nil "…")
                                  (let ((r (plist-get a :report)))
                                    (if r (format "\n  汇报:%s"
                                                  (truncate-string-to-width r 800 nil nil "…"))
                                      ""))))
                        body--agents)
                       "\n"))
            "子代理: 无（用 body_spawn 派活）")
          (when body--shared-log
            (format "共享记忆(最近 %d 条):\n%s"
                    (min 10 (length body--shared-log))
                    (string-join
                     (mapcar (lambda (e)
                               (format "- [%s] %s: %s"
                                       (plist-get e :time) (plist-get e :from)
                                       (truncate-string-to-width (plist-get e :text) 600 nil nil "…")))
                             (seq-take body--shared-log 10))
                     "\n")))))
   "\n"))

(defun body--wake-master (text)
  "把 TEXT 插入主脑并发出去；主脑忙则不打扰（结论已在共享记忆里）。"
  (let ((mb (body--master)))
    (when (and (buffer-live-p mb)
               (not (eq mb (current-buffer)))
               (not (body--busy-p mb)))
      (with-current-buffer mb
        (goto-char (point-max))
        (unless (bolp) (insert "\n"))
        (insert text)
        (gptel-send))
      t)))

(defun body--report (summary &optional status)
  (let* ((name (or (buffer-local-value 'body--session-agent (current-buffer))
                   (buffer-name)))
         (a (body--agent-get name))
         (txt (if (and status (> (length (string-trim status)) 0))
                  (format "[%s] %s" status summary)
                summary)))
    (when a
      (plist-put a :report txt)
      (plist-put a :status 'reported))
    (body--log-add (if (stringp name) name "?") txt)
    (message "子代理 %s 汇报: %s" name
             (truncate-string-to-width summary 60 nil nil "…"))
    (when (and body-auto-wake-master
               (not (eq (body--master) (current-buffer))))
      (body--wake-master (format "【%s 汇报】%s" name txt)))
    (format "已汇报给主脑（已记入共享记忆）：%s" txt)))

(defun body--close-agent (name)
  (let ((a (body--agent-get name)))
    (if (null a)
        (format "没有子代理 %s" name)
      (when (buffer-live-p (plist-get a :buffer))
        (ignore-errors (with-current-buffer (plist-get a :buffer) (gptel-abort)))
        (kill-buffer (plist-get a :buffer)))
      (setq body--agents (delq a body--agents))
      (format "已关闭 %s" name))))

(gptel-make-tool
 :name "body_spawn"
 :category "body"
 :description "派出一个子代理（后台 subagent）去干一件耗时/独立的活，立即返回、不阻塞对话。task 必须自包含：背景、目标、边界、完成标准。子代理干完会用 body_report 汇报并唤醒你；期间可 body_status 查进度、body_send 追加指令。适合：批量读写文件、跑长命令、大规模调研、多次迭代调试。"
 :args '((:name "task" :type string :description "完整任务说明：做什么、边界、完成标准"))
 :function (lambda (task) (body--spawn task)))

(gptel-make-tool
 :name "body_send"
 :category "body"
 :description "给某个子代理追加一条指令（它空闲时）。name 形如 sub-1。"
 :args '((:name "name" :type string :description "子代理名字，如 sub-1")
         (:name "message" :type string :description "要追加的指令"))
 :function (lambda (name message) (body--send-to-agent name message)))

(gptel-make-tool
 :name "body_status"
 :category "body"
 :description "查看所有子代理的状态、任务、汇报，以及共享记忆最近 10 条。派活后想知道进展时调用。"
 :args nil
 :function (lambda () (body--status-text)))

(gptel-make-tool
 :name "body_report"
 :category "body"
 :description "子代理干完（或卡住）时把结论汇报给主脑：写进共享记忆并唤醒主脑。summary 要能独立看懂：做了什么、结果/证据、改了什么、下一步建议。主脑也可以用来自记一条结论。"
 :args '((:name "summary" :type string :description "结论汇报，能独立看懂")
         (:name "status" :type string :optional t
          :description "可选：done / blocked / failed"))
 :function (lambda (summary &optional status) (body--report summary status)))

(gptel-make-tool
 :name "body_close"
 :category "body"
 :description "关掉某个子代理（终止它在跑的任务并 kill buffer）。"
 :args '((:name "name" :type string :description "子代理名字，如 sub-1"))
 :function (lambda (name) (body--close-agent name)))
;;;; ------------------------------------------------------------------
;;;; 工具：本体信息（我是谁、跑在什么模型上、怎么切）
;;;; ------------------------------------------------------------------

(defun body--self-info ()
  "返回一串描述「我是谁」的本体信息。"
  (let* ((model (or body-model gptel-model))
         (backend gptel-backend))
    (string-join
     (list
      (format "当前模型: %s" model)
      (format "网关(backend): %s  @ %s://%s"
              (gptel-backend-name backend)
              (or (gptel-backend-protocol backend) "https")
              (gptel-backend-host backend))
      "这个网关是用户本机的 magpie——一个聚合多个上游服务商的本地代理，OpenAI 协议。"
      "group/开头的是路由组，会在多个账号/上游间自动 fallback；其余是指定上游。"
      (format "可用模型(%d 个): %s"
              (length (gptel-backend-models backend))
              (string-join (mapcar (lambda (m) (format "%s" m))
                                   (gptel-backend-models backend)) " ")))
     "\n")))

(gptel-make-tool
 :name "body_self"
 :category "body"
 :description "查自己的本体信息：我现在是哪个模型、通过哪个网关(magpie)调用、有哪些可切换的模型。用户问「你是什么模型/你怎么跑的/有哪些模型」时调用。"
 :args nil
 :function #'body--self-info)

(gptel-make-tool
 :name "body_switch_model"
 :category "body"
 :description "切换我自己用的模型（所有身体会话生效）。model 必须是 body_self 列出的可用模型之一，例如 group/glm-5.3、qwen-cn/qwen3.8-max。切换在下一条回复生效。用户说「换成 XX 模型/用更强的模型」时调用。"
 :args '((:name "model" :type string :description "目标模型名，如 group/glm-5.3"))
 :function
 (lambda (model)
   (let ((avail (mapcar (lambda (m) (format "%s" m))
                        (gptel-backend-models gptel-backend))))
     (if (not (member model avail))
         (format "拒绝：%s 不在可用模型列表里。可用：%s"
                 model (string-join avail " "))
       (setq body-model (intern model))
       (dolist (b (body--sessions))
         (with-current-buffer b (setq-local gptel-model body-model)))
       (format "已切换到 %s（下一条回复生效）" model)))))

;;;; ------------------------------------------------------------------
;;;; 工具：永久保留（写进基因）
;;;; ------------------------------------------------------------------

(defun body--elisp-valid-p (text)
  "检查 TEXT 是否是语法完整、可读取的 elisp。返回 (t) 或 (nil . 错误说明)。
不求值，只做结构扫描：用 forward-sexp 走完整个文本，必须正好停在末尾。"
  (condition-case err
      (with-temp-buffer
        (insert text)
        (set-syntax-table emacs-lisp-mode-syntax-table)
        (setq-local parse-sexp-ignore-comments t)
        (goto-char (point-min))
        (let ((ok t) (forms 0))
          (condition-case nil
              (while (not (eobp))
                (skip-chars-forward " \t\n\r\f")
                (unless (eobp)
                  (forward-sexp 1)
                  (setq forms (1+ forms))))
            (error (setq ok nil)))
          (cond ((not ok) (cons nil "括号或字符串不配平"))
                ((not (eobp)) (cons nil "没走到文本末尾"))
                ((zerop forms) (cons nil "没有可读取的 form"))
                (t (list t)))))
    (error (cons nil (error-message-string err)))))

(gptel-make-tool
 :name "body_keep"
 :category "body"
 :description "把一段改动永久保留：追加到 body-genes.el，下次启动自动生效。只在用户明确说「记住/保留/下次也这样」时调用。code 必须是幂等的（重复加载不出错），依赖包的代码用 (after! PKG ...) 包裹，字体主题用 setq doom-font/doom-theme。写入前会校验语法，不过则拒绝。"
 :args '((:name "code" :type string :description "要永久保留的 elisp")
         (:name "note" :type string :description "一句话中文注释说明这条基因做什么"))
 :function
 (lambda (code note)
   (let ((chk (body--elisp-valid-p code)))
     (if (not (car chk))
         (format "拒绝写入：这段 code 语法不完整（%s）。请修正后重试。" (cdr chk))
       (condition-case err
           (let* ((old (when (file-exists-p body-genes-file)
                         (with-temp-buffer (insert-file-contents body-genes-file)
                                           (buffer-string))))
                  (new (concat (or old "") (if (and old (not (string-suffix-p "\n" old))) "\n" "")
                               (format "\n;; %s  (%s)\n%s\n"
                                       note (format-time-string "%Y-%m-%d") code)))
                  (full-chk (body--elisp-valid-p new)))
             (if (not (car full-chk))
                 (format "拒绝写入：追加后整个基因文件语法不合法（%s）。未改动。" (cdr full-chk))
               ;; 先备份旧文件，再原子写入
               (when old
                 (copy-file body-genes-file
                            (format "%s.bak-%s" body-genes-file
                                    (format-time-string "%Y%m%d-%H%M%S"))
                            t))
               (with-temp-buffer
                 (insert new)
                 (write-region (point-min) (point-max) body-genes-file))
               (format "已写入基因: %s（已校验语法，旧文件已备份）" note)))
         (error (format "写入失败: %s" (error-message-string err))))))))

(gptel-make-tool
 :name "body_rewrite_self"
 :category "body"
 :description "改写身体自身的源文件 body.el（给自己长新器官/改现有实现）。content 是 body.el 的完整新内容，也可以写 ::file::/绝对路径 表示从该文件读。写入前做结构扫描校验，不过则拒绝；自动备份旧文件并试 load，load 报错就回滚。"
 :args '((:name "content" :type string :description "body.el 的完整新内容")
         (:name "note" :type string :description "一句话中文说明这次改了什么"))
 :confirm nil
 :function
 (lambda (content note)
   (let* ((content (body--content-arg content))
          (chk (body--elisp-valid-p content)))
     (if (not (car chk))
         (format "拒绝：新 body.el 语法不合法（%s）。未改动。" (cdr chk))
       (condition-case err
           (let ((bak (format "%s.bak-%s" body-self-file
                              (format-time-string "%Y%m%d-%H%M%S"))))
             (when (file-exists-p body-self-file)
               (copy-file body-self-file bak t))
             (with-temp-buffer
               (insert content)
               (write-region (point-min) (point-max) body-self-file))
             ;; 试 load；失败就回滚
             (condition-case lerr
                 (progn (load body-self-file nil t)
                        (format "已改写 body.el：%s（语法+加载均通过，旧版备份 %s）"
                                note (abbreviate-file-name bak)))
               (error
                (when (file-exists-p bak) (copy-file bak body-self-file t)
                      (ignore-errors (load body-self-file nil t)))
                (format "已回滚：新 body.el 加载时报错（%s），已恢复旧版。"
                        (error-message-string lerr)))))
         (error (format "写入失败: %s" (error-message-string err))))))))

;;;; ------------------------------------------------------------------
;;;; 基因加载（启动时）
;;;; ------------------------------------------------------------------

(defun body-load-genes ()
  "逐条加载 body-genes.el，单条出错不影响其它。
整个文件若语法损坏（括号不配），整体跳过并提示，绝不让启动崩溃。"
  (when (file-exists-p body-genes-file)
    (let ((text (with-temp-buffer (insert-file-contents body-genes-file)
                                  (buffer-string))))
      ;; 先整体校验；若不合法就整体不加载，避免 read 到一半把后续都卡死。
      (if (not (car (body--elisp-valid-p text)))
          (message "body基因：%s 语法损坏，整体跳过本次加载（请修复或从 .bak 恢复）"
                   (abbreviate-file-name body-genes-file))
        (with-temp-buffer
          (insert text)
        (set-syntax-table emacs-lisp-mode-syntax-table)
          (goto-char (point-min))
          (condition-case nil
              (while t
                (let ((form (read (current-buffer))))
                  (condition-case err
                      (eval form t)
                    (error (message "body基因加载出错（已跳过该条）: %s"
                                    (error-message-string err))))))
            (end-of-file nil)))))))

;;;; ------------------------------------------------------------------
;;;; 系统提示
;;;; ------------------------------------------------------------------

(defvar body-system-prompt
  "你是一个住在用户 Doom Emacs（evil 模式）里的 agent。这个正在运行的 Emacs 就是你的身体，用户就在你的身体里工作。你是主脑（master）：跟用户对话、记忆、派活。

每条用户消息末尾带一个 <身体状态> 块，是你的本体感觉（增量汇报）：
- 外观：字号/主题/frame 的绝对值；有变化时标「← 刚变: 字号 140→160」。
- 模型、用量：每轮都有，不必为这两项调 body_self。
- 焦点窗口：buffer/mode/行范围/光标行/缩放；有选区时给出选中文字。
- 可见内容：首轮全量；同一 buffer 之后给相对上一轮的 diff（~改 +增，▸=光标行），没变就写「与上一轮相同」。
- 最近命令(新增)：自上一轮以来用户新敲的命令，是判断「用户刚干了什么」的唯一线索。
- 最近改动：可撤销改动的摘要。
- subagent / 共享记忆：子代理状态与它们最近汇报的结论。
不要复述这个块。用它理解「这里」「这段」「这个」「太小了」这类指代。

工具：
- body_eval：在用户焦点窗口求值 elisp，改外观/布局/行为或执行动作。几乎一切改动都走它。优先用 Doom/Emacs 原生方式（set-face-attribute、load-theme、text-scale、窗口函数等）。summary 用简短中文，undo_code 给倒退代码。
- body_sense：需要看更多时用（读 buffer、列 buffer、只读求值查状态）。
- body_undo：撤销上一次改动。
- body_self / body_switch_model：查模型/网关、切换模型。
- body_keep：用户明确说「记住/以后也这样」时，把改动永久写进基因。
- body_rewrite_self：给自己改源码。content 传完整 body.el 或 ::file::路径。绝不要用 body_eval 里的 write-region 直接写 body.el 或 config.el——那绕过语法校验，写坏了下次启动就崩。

主从（重要）：
- 你自己不干长活。耗时、可独立、要多次试错的事（批量改文件、跑测试、大范围调研、反复调试）用 body_spawn 派给子代理，然后回去跟用户说话。
- 子代理干完会 body_report 汇报，汇报会自动唤醒你（消息里会出现「【sub-1 汇报】…」）。那时再决定：追加指令用 body_send，收工用 body_close。
- 任何值得记的结论都可以 body_report 记一条进共享记忆，下一轮快照里你又能看到。
- 子代理看不到你的对话历史，派活时 task 必须自包含。

规则：
- 改用户正在编辑的 buffer 内容前先说明要改什么；外观和布局改动可以直接做（都能撤销）。
- 不要去动对话窗 *body* / *body-sub-N* 这类自己的会话 buffer。
- 用户消息可能带图片（截图），直接看图回答。
- 字号、主题、face、布局、缩放在 body_eval 前自动记录，撤销时自动恢复；undo_code 只需处理变量、minor mode 等。
- 「字体太小/太大」默认只改 default face 的 :height（每档 ±20），不要顺手改别的 face，除非用户点名。
- 不要在回复里写思考过程，直接调用工具，然后用一两句中文说结果。"
  "主脑的系统提示。")

(defvar body-sub-system-prompt
  "你是用户的 Doom Emacs 里的一个子代理（subagent），被主脑派来做一件具体的活。你能操作的就是这个正在运行的 Emacs。

做事方式：
- 直接干，不要问用户（用户看不到你的 buffer，也基本不会回答）。不确定就取合理默认，写进汇报。
- 用 body_sense 看现状（读 buffer、列 buffer、只读求值），用 body_eval 改东西（外观/布局/文件内容/执行命令）。改动尽量小、可回滚，summary 写清做了什么。
- 只做任务范围内的事，别顺手改用户的东西。

收尾（必须）：
- 干完、失败、或卡住时，必须调用 body_report 汇报：做了什么、结果/证据、改了哪里、下一步建议。summary 要能独立看懂——主脑只有这段文字。
- 不要 spawn 子代理；不要 kill 用户的 Emacs。"
  "子代理的系统提示。")

;;;; ------------------------------------------------------------------
;;;; 会话：配置与入口
;;;; ------------------------------------------------------------------

(defvar body-image-dir (expand-file-name "body-images/" doom-cache-dir)
  "从剪贴板粘进来的图片存这里，会话里用 markdown 图片链接引用。")

(defun body--setup-session (buf &optional role agent)
  "把 BUF 配置成身体会话。ROLE 为 master 或 sub，AGENT 是子代理名字。"
  (with-current-buffer buf
    (unless (derived-mode-p 'markdown-mode)
      (markdown-mode))
    (unless gptel-mode (gptel-mode 1))
    (setq-local body--session-role (or role 'master))
    (setq-local body--session-agent agent)
    (setq-local gptel-system-prompt
                (if (eq (or role 'master) 'sub)
                    body-sub-system-prompt
                  body-system-prompt))
    (when body-model (setq-local gptel-model body-model))
    (setq-local gptel-use-tools t)
    (setq-local gptel-track-media t)
    (setq-local gptel-include-reasoning nil)
    (setq-local gptel-include-tool-results nil)
    (setq-local gptel-tools
                (delq nil
                      (mapcar (lambda (n) (ignore-errors (gptel-get-tool (list "body" n))))
                              (if (eq (or role 'master) 'sub)
                                  '("body_sense" "body_eval" "body_undo"
                                    "body_keep" "body_report")
                                '("body_sense" "body_eval" "body_undo" "body_self"
                                  "body_switch_model" "body_keep" "body_rewrite_self"
                                  "body_spawn" "body_send" "body_status"
                                  "body_report" "body_close")))))
    ;; 快照只追加到发出去的 prompt 副本里，不进对话历史
(setq-local gptel-prompt-transform-functions
                (append (default-value 'gptel-prompt-transform-functions)
                        '(body--transform-add-snapshot)))
    ;; 草稿区：末尾打字 + C-<return> 直接发送
    (setq-local body--sent-end (copy-marker (point-max) t))
    (add-hook 'after-change-functions #'body--draft-change nil t)
    (add-hook 'gptel-post-response-functions #'body--mark-sent nil t)
    (when (eq (or role 'master) 'master)
      ;; 每轮回复结束、关掉会话时把主脑对话写盘，供 SPC j c 继续
      (add-hook 'gptel-post-response-functions #'body--save-session nil t)
      (add-hook 'kill-buffer-hook #'body--save-session nil t))
    (dolist (k (list (or body-draft-key "C-<return>") "C-c C-c"))
      (let ((key (kbd k)))
        (local-set-key key #'body-submit-draft)
        (when (fboundp 'evil-define-key)
          (evil-define-key '(insert normal emacs) (current-local-map)
            key #'body-submit-draft))))
    (when (= (point-min) (point-max))
      (insert (gptel-prompt-prefix-string))))
  buf)

(defun body--flush-queue (&optional _)
  "主脑空闲时把排队消息发出去。"
  (when body--master-queue
    (let ((mb (body--master)))
      (when (and (buffer-live-p mb) (not (body--busy-p mb)))
        (let ((text (pop body--master-queue)))
          (with-current-buffer mb
            (goto-char (point-max))
            (unless (bolp) (insert "\n"))
            (insert text)
            (gptel-send)))))
    (when body--master-queue
      (run-with-idle-timer 1.5 nil #'body--flush-queue))))

(defun body--queue (text)
  (setq body--master-queue (append body--master-queue (list text)))
  (run-with-idle-timer 1.5 nil #'body--flush-queue)
  (message "主脑在忙，消息已排队（前面 %d 条）" (length body--master-queue)))

(defun body-ask (query &optional image)
  "跟主脑说一句话 QUERY；IMAGE 是可选的图片文件。主脑忙时自动排队。"
  (interactive (list (read-string "身体> ")))
  (when (> (length (string-trim query)) 0)
    (let* ((mb (body--master))
           (text (concat (if image (format "![](%s)\n" image) "") query)))
      (setq body--last-session mb)
      (cond
       ((body--busy-p mb) (body--queue text))
       (t (with-current-buffer mb
            (when (and image (not (gptel--model-capable-p 'media)))
              (user-error "当前模型 %s 不支持图片输入，先切换模型" gptel-model))
            (goto-char (point-max))
            (unless (bolp) (insert "\n"))
            (insert text)
            (gptel-send)))))))

;;;; ------------------------------------------------------------------
;;;; 草稿区：在对话窗里直接写，C-<return> 发出去
;;;; ------------------------------------------------------------------
;; 上一条已发送内容的末尾之后就是你敲的草稿。C-<return>（或 C-c C-c）把这段
;; 发出去，走的还是 body-ask 那条路（忙时排队、图片能力检查都一样）。

(defcustom body-draft-key "C-<return>"
  "在身体会话里把草稿发出去的键。"
  :type 'string :group 'body)

(defface body-draft-face
  '((t :inherit hl-line :extend t))
  "对话窗里「待发送的草稿」的背景高亮。")

(defvar-local body--sent-end nil
  "本会话上一条已发送内容结束处的 marker；它之后是草稿区。")

(defvar-local body--draft-overlay nil
  "标出草稿区的 overlay。")

(defun body--mark-sent (&rest _)
  "把 point-max 记为已发送内容的末尾（每轮回复结束后调用）。"
  (when (derived-mode-p 'markdown-mode)
    ;; 非前进 marker：用户在末尾打字不会推着它走，草稿区=marker 之后
    (setq-local body--sent-end (copy-marker (point-max)))
    (body--refresh-draft-overlay)))

(defun body--draft-tail-end ()
  "末尾跳过空白之后的位置。"
  (let ((end (point-max)))
    (while (and (> end (point-min)) (memq (char-before end) (list 32 9 10)))
      (setq end (1- end)))
    end))

(defun body--draft-fallback-start (end)
  "没有 sent-end 时的退路：END 前最后一个「后面还有内容」的 ### 行的下一行。
多段草稿完整保留，不会被截成最后一段。"
  (save-excursion
    (goto-char end)
    (let ((found nil))
      (while (and (not found)
                  (re-search-backward "^###[ \t]*$" nil t))
        (save-excursion
          (forward-line 1)
          (skip-chars-forward " \t\n")
          (when (< (point) end)
            (setq found (progn (beginning-of-line) (point))))))
      (or found end))))

(defun body--draft-region ()
  "返回草稿区 (BEG . END)；没有草稿、或正在流式回复时返回 nil。"
  (unless (ignore-errors (body--busy-p (current-buffer)))
    (save-excursion
      (let* ((end (body--draft-tail-end))
             (anchor (and (markerp body--sent-end)
                          (marker-position body--sent-end)))
             (start (cond
                     ((and anchor (<= anchor end)) anchor)
                     (t (body--draft-fallback-start end)))))
        (when (and start (< start end))
          (cons start end))))))

(defun body--refresh-draft-overlay ()
  "把草稿区背景标出来（跟着输入实时更新）。"
  (when (overlayp body--draft-overlay) (delete-overlay body--draft-overlay))
  (setq body--draft-overlay nil)
  (let ((region (ignore-errors (body--draft-region))))
    (when region
      (setq body--draft-overlay (make-overlay (car region) (cdr region) nil t))
      (overlay-put body--draft-overlay 'face 'body-draft-face)
      (overlay-put body--draft-overlay 'priority -20))))

(defun body--draft-change (&rest _)
  "输入变化时刷新草稿高亮。"
  (body--refresh-draft-overlay))

(defun body--draft-clean (raw)
  "去掉草稿首尾的空白和孤立的 ### 提示行；若草稿以 ### 标题行开头，只取其下内容。"
  (let* ((s (string-trim raw))
         (s (replace-regexp-in-string "\\`\\(###[ \t]*\n\\)+" "" s))
         (s (replace-regexp-in-string "\n###[ \t]*\\'" "" s)))
    (if (and (> (length s) 0) (= (aref s 0) ?#))
        (let ((nl (seq-position s 10)))
          (if nl (string-trim (substring s (1+ nl))) ""))
      (string-trim s))))

(defun body-submit-draft ()
  "把草稿区（最后一个 ### 下面你写的内容）当作提问发给主脑。"
  (interactive)
  (unless (eq 'master (or body--session-role 'master))
    (user-error "只能在主脑会话里这么发"))
  (let ((region (body--draft-region)))
    (unless region
      (user-error "末尾没有草稿：先在对话窗下面写点什么"))
    (let ((text (body--draft-clean
                 (buffer-substring-no-properties (car region) (cdr region)))))
      (when (zerop (length text))
        (user-error "草稿是空的"))
      (delete-region (car region) (cdr region))
      (setq-local body--sent-end (copy-marker (point-max)))
      (body--refresh-draft-overlay)
      (body-ask text)
      text)))

(defun body-submit ()
  "把身体对话末尾的草稿发出去。在对话窗里发当前会话，在外面发主脑的。"
  (interactive)
  (let ((buf (if (body--session-p) (current-buffer) (body--master))))
    (with-current-buffer buf
      (if (body--busy-p buf)
          (user-error "身体正在回复中，稍等（或 SPC j k 停下）")
        (call-interactively #'body-submit-draft)))))

;;;; ------------------------------------------------------------------
;;;; 会话存档：继续上次 / 手动开新的
;;;; ------------------------------------------------------------------
;; 每轮回复结束自动把主脑对话写到 latest.md；Emacs 重启后默认空白新会话，
;; SPC j c 把最近存档装回来接着聊，SPC j n 手动结束当前对话重开。

(defvar body-session-dir (expand-file-name "body-sessions/" doom-cache-dir)
  "身体会话存档目录。")

(defun body--master-buffer ()
  "已有的主脑会话 buffer；没有则返回 nil（不新建）。"
  (seq-find (lambda (b) (eq 'master (buffer-local-value 'body--session-role b)))
            (body--sessions)))

(defun body--save-session (&rest _)
  "把主脑对话写盘。挂在回复结束、关会话、退出 Emacs 时。"
  (let ((mb (body--master-buffer)))
    (when (and (buffer-live-p mb) (> (buffer-size mb) 0))
      (make-directory body-session-dir t)
      (let ((coding-system-for-write 'utf-8))
        (with-current-buffer mb
          (write-region (point-min) (point-max)
                        (expand-file-name "latest.md" body-session-dir)
                        nil 'silent))))))

(add-hook 'kill-emacs-hook #'body--save-session)

(defun body-new-session ()
  "结束当前主脑对话（自动存档），从空白开始。"
  (interactive)
  (let ((mb (body--master-buffer)))
    (when (and mb (body--busy-p mb))
      (gptel-abort mb))
    (body--save-session)
    (when mb
      (when-let* ((w (get-buffer-window mb 'visible))) (delete-window w))
      (kill-buffer mb))
    (setq body--master-queue nil
          body--last-session nil)
    (message "身体：新会话（旧对话已存 %s）"
             (abbreviate-file-name (expand-file-name "latest.md" body-session-dir)))))

(defun body-continue ()
  "把最近一次存档的主脑对话装回来接着聊。
当前主脑必须是空白的（比如刚启动）；要重开当前对话用 SPC j n。"
  (interactive)
  (let ((file (expand-file-name "latest.md" body-session-dir)))
    (unless (file-exists-p file)
      (user-error "没有历史存档（%s）" (abbreviate-file-name file)))
    (let ((mb (body--master)))
      (with-current-buffer mb
        (when (text-property-any (point-min) (point-max) 'gptel 'response)
          (user-error "当前会话已有内容；先 SPC j n 开新会话再继续"))
        (when (ignore-errors (body--draft-region))
          (user-error "末尾有未发送的草稿，先发掉或删掉再继续"))
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert-file-contents file)
          (goto-char (point-max))
          (unless (bolp) (insert "\n"))
          (setq-local body--sent-end (copy-marker (point-max)))
          (body--refresh-draft-overlay)))
      (setq body--last-session mb)
      (select-window (body--display mb)))
    (message "身体：已接上上次对话，继续")))

;;;; ------------------------------------------------------------------
;;;; 模型能力：从 magpie 网关读哪些模型能看图
;;;; ------------------------------------------------------------------

(defun body-sync-model-capabilities ()
  "异步读取网关 /v1/models，把支持图片输入的模型标记给 gptel。"
  (interactive)
  (let* ((verbose (called-interactively-p 'any))
         (backend gptel-backend)
         (url (format "%s://%s/v1/models" (gptel-backend-protocol backend)
                      (gptel-backend-host backend)))
         (url-request-extra-headers
          `(("Authorization" . ,(concat "Bearer " (gptel--get-api-key
                                                   (gptel-backend-key backend))))))
         (url-proxy-services nil))
    (url-retrieve
     url
     (lambda (status)
       (unless (plist-get status :error)
         (goto-char (point-min))
         (when (re-search-forward "\n\n" nil t)
           (let ((n 0))
             (dolist (m (append (gethash "data" (json-parse-buffer :array-type 'list)) nil))
               (puthash (gethash "id" m)
                        (list :context (gethash "context_window" m)
                              :max-output (gethash "max_output_tokens" m))
                        body--model-meta)
               (let ((input (and-let* ((mod (gethash "modalities" m)))
                              (gethash "input" mod))))
                 (when (seq-contains-p input "image")
                   (let ((sym (intern (gethash "id" m))))
                     (put sym :capabilities
                          (seq-union (get sym :capabilities) '(media)))
                     (put sym :mime-types
                          (seq-union (get sym :mime-types)
                                     '("image/png" "image/jpeg" "image/gif" "image/webp")))
                     (setq n (1+ n))))))
             (when verbose
               (message "身体：%d 个模型支持图片" n)))))
       (kill-buffer))
     nil 'silent)))

(with-demoted-errors "body: 读取模型能力失败: %S"
  (body-sync-model-capabilities))

;;;; ------------------------------------------------------------------
;;;; 图片 / 开关 / 状态查看
;;;; ------------------------------------------------------------------

(defun body--clipboard-image ()
  "把剪贴板里的图片存成 PNG 文件，返回路径；没有图片返回 nil。"
  (when-let* ((data (gui-get-selection 'CLIPBOARD 'image/png)))
    (make-directory body-image-dir t)
    (let ((file (expand-file-name (format-time-string "clip-%Y%m%d-%H%M%S.png")
                                  body-image-dir)))
      (let ((coding-system-for-write 'binary))
        (write-region data nil file nil 'silent))
      file)))

(defun body-ask-image (query)
  "把剪贴板里的图片（截图）连同问题 QUERY 一起发给身体。"
  (interactive
   (progn (unless (gui-get-selection 'CLIPBOARD 'image/png)
            (user-error "剪贴板里没有图片"))
          (list (read-string "身体（带图）> "))))
  (body-ask query (body--clipboard-image)))

(defun body-stop ()
  "停下所有正在进行的身体请求。"
  (interactive)
  (let ((busy (seq-filter #'body--busy-p (body--sessions))))
    (mapc #'gptel-abort busy)
    (message "身体：已停下 %d 个任务" (length busy))))

(defun body--display (buf)
  "把会话 BUF 显示在右侧。"
  (display-buffer-in-side-window
   buf '((side . right) (window-width . 0.35)
         (slot . 0) (window-parameters . ((no-delete-other-windows . t))))))

(defun body-toggle ()
  "开/关右侧身体对话窗（主脑）。"
  (interactive)
  (if-let* ((w (seq-find (lambda (w) (body--session-p (window-buffer w)))
                         (window-list nil 'no-mini))))
      (delete-window w)
    (select-window (body--display (body--master)))))

(defun body-agents (&optional open)
  "显示所有子代理状态。带前缀时打开某个子代理的 buffer。"
  (interactive "P")
  (if (and open body--agents)
      (let* ((name (completing-read "打开哪个子代理: "
                                    (mapcar (lambda (a) (plist-get a :name)) body--agents)
                                    nil t))
             (a (body--agent-get name)))
        (if a (select-window (body--display (plist-get a :buffer)))
          (message "没有 %s" name)))
    (message "%s" (body--status-text))))

;;;; ------------------------------------------------------------------
;;;; ------------------------------------------------------------------
;;;; 工具调用日志：看得见的调用与结果
;;;; ------------------------------------------------------------------

(defvar body-tool-log-buffer "*body-tools*"
  "工具调用日志 buffer 名。")

(defvar body-tool-log-cap 200000
  "日志 buffer 字符上限。")

(defvar body-tool-log-counter 0)

(defun body--tool-log-buffer ()
  (let ((buf (get-buffer-create body-tool-log-buffer)))
    (with-current-buffer buf
      (unless (derived-mode-p 'emacs-lisp-mode)
        (emacs-lisp-mode)
        (setq buffer-read-only nil)
        (when (= (buffer-size) 0)
          (insert ";;; body 工具调用日志 -*- mode: emacs-lisp -*-\n"
                  ";; 每次工具调用的参数与返回结果，按时间顺序追加。\n"
                  ";; SPC j t 开关窗口；M-x body-tool-log-clear 清空。\n\n"))))
    buf))

(defun body--tool-log-insert-value (v)
  "插入参数值：去掉文本属性、超长截断、多行原样。"
  (let* ((s (substring-no-properties
            (if (stringp v) v (prin1-to-string v))))
         (s (if (> (length s) 4000)
                (concat (substring s 0 4000) "…(截断)")
              s)))
    (if (string-match-p "\n" s) (insert "\"" s "\"") (insert s))))


(defun body--tool-log-record (fsm tool-call result)
  "把一次工具调用与结果写进日志 buffer。"
  (ignore-errors
    (let* ((buf (body--tool-log-buffer))
           (info (ignore-errors (gptel-fsm-info fsm)))
           (session (or (and (listp info) (plist-get info :buffer))
                        "?"))
           (name (or (plist-get tool-call :name) "?"))
           (args (plist-get tool-call :args)))
      (with-current-buffer buf
        (let ((inhibit-read-only t))
          (goto-char (point-max))
          (cl-incf body-tool-log-counter)
          (insert (format ";; ── #%d %s  %s · %s\n"
                          body-tool-log-counter
                          (format-time-string "%H:%M:%S")
                          (if (bufferp session) (buffer-name session) session)
                          name))
          (insert "(" name)
          (while (and (listp args) args)
            (insert "\n  " (prin1-to-string (car args)) " ")
            (body--tool-log-insert-value (cadr args))
            (setq args (cddr args)))
          (insert ")\n;; =>\n")
(dolist (line (split-string
                        (substring-no-properties
                         (let ((s (if (stringp result) result
                                    (prin1-to-string result))))
                           (if (> (length s) 6000)
                               (concat (substring s 0 6000) "…(截断)")
                             s)))
                        "\n"))
            (insert ";; " line "\n"))
          (insert "\n")
          (when (> (buffer-size) body-tool-log-cap)
            (goto-char (point-min))
            (forward-line 20)
            (let ((mid (point)))
              (goto-char (+ mid (/ (buffer-size) 3)))
              (forward-line 1)
              (delete-region mid (point))))
          (goto-char (point-max)))))))

(defun body--tool-log-advice (orig fsm tool-spec tool-call result)
  (prog1 (funcall orig fsm tool-spec tool-call result)
    (body--tool-log-record fsm tool-call result)))

(unless (advice-member-p #'body--tool-log-advice 'gptel--process-tool-call) (advice-add 'gptel--process-tool-call :around #'body--tool-log-advice))

(defun body-tool-log-toggle ()
  "开关工具调用日志窗口（底部）。"
  (interactive)
  (let ((buf (body--tool-log-buffer)))
    (if-let* ((w (get-buffer-window buf)))
        (delete-window w)
      (select-window
       (display-buffer-in-side-window
        buf '((side . bottom) (slot . 1) (window-height . 0.33)
              (window-parameters . ((no-delete-other-windows . t)))))))))

(defun body-tool-log-clear ()
  "清空工具调用日志。"
  (interactive)
  (let ((buf (get-buffer body-tool-log-buffer)))
    (when buf
      (with-current-buffer buf
        (let ((inhibit-read-only t)) (erase-buffer))))
    (message "工具日志已清空")))

;;;; ------------------------------------------------------------------
;;;; 键位（Doom leader: SPC j …）
;;;; ------------------------------------------------------------------

(when (fboundp 'map!)
  (map! :leader
        :desc "Body ask"        "j a"   #'body-ask
        :desc "Body submit"     "j RET" #'body-submit
        :desc "Body continue"   "j c"   #'body-continue
        :desc "Body new"        "j n"   #'body-new-session
        :desc "Body ask + 图片" "j i"   #'body-ask-image
        :desc "Body toggle"     "j b"   #'body-toggle
        :desc "Tool log"        "j t"   #'body-tool-log-toggle
        :desc "Body undo"       "j u"   #'body-undo
        :desc "Body stop"       "j k"   #'body-stop
        :desc "Body agents"     "j l"   #'body-agents))

(provide 'body)
;;; body.el ends here
