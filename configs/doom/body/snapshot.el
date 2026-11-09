;;; body/snapshot.el --- 每轮请求前拼装的身体快照（数字/用量/外观/可见内容 diff）  -*- lexical-binding: t; -*-
;; body 的一个模块，由 body.el 统一 load，别单独加载。

(require 'gptel)
(require 'cl-lib)
(require 'seq)
(require 'subr-x)

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

(defun body--todo-line ()
  "当前计划（body_todo 维护）。"
  (when body--todo
    (concat "计划(body_todo 更新):\n"
            (string-join
             (cl-loop for i from 1 for it in body--todo
                      collect (format "  %d. %s" i
                                      (truncate-string-to-width it 120 nil nil "…")))
             "\n"))))

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
            (body--todo-line)
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

(provide 'body-snapshot)
;;; body/snapshot.el ends here
