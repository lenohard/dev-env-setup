;;; body/session.el --- gptel 会话配置、草稿区、存档  -*- lexical-binding: t; -*-
;; body 的一个模块，由 body.el 统一 load，别单独加载。

(require 'gptel)
(require 'cl-lib)
(require 'seq)
(require 'subr-x)

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
    (setq-local gptel-system-prompt #'body--system-prompt-dynamic)
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
                                    "body_read_file" "body_write_file"
                                    "body_edit_file" "body_grep" "body_shell"
                                    "body_todo" "body_report" "body_keep")
                                '("body_sense" "body_eval" "body_undo" "body_self"
                                  "body_switch_model" "body_keep"
                                  "body_rewrite_self" "body_edit_self"
                                  "body_read_prompt" "body_read_file"
                                  "body_write_file" "body_edit_file"
                                  "body_grep" "body_shell" "body_todo"
                                  "body_remember" "body_spawn" "body_send"
                                  "body_status" "body_report" "body_close")))))
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
      (add-hook 'gptel-post-response-functions #'body--maybe-auto-compact nil t)
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

(defun body--refresh-session-tools ()
  "重载 body 源码后，把所有活会话的 gptel-tools 换成新注册的工具对象。"
  (dolist (b (body--sessions))
    (with-current-buffer b
      (let ((names (delq nil (mapcar (lambda (spec)
                                       (and (gptel-tool-p spec)
                                            (gptel-tool-name spec)))
                                     gptel-tools))))
        (setq-local gptel-tools
                    (delq nil
                          (mapcar (lambda (n)
                                    (ignore-errors (gptel-get-tool (list "body" n))))
                                  names)))))))

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

(defun body--archive-session (&optional mb)
  "把主脑对话存一份带时间戳的存档（MB 默认主脑）。返回存档路径。"
  (let ((mb (or mb (body--master-buffer))))
    (when (and (buffer-live-p mb) (> (buffer-size mb) 0))
      (make-directory body-session-dir t)
      (let ((file (expand-file-name
                   (format "%s.md" (format-time-string "%Y%m%d-%H%M%S"))
                   body-session-dir)))
        (let ((coding-system-for-write 'utf-8))
          (with-current-buffer mb
            (write-region (point-min) (point-max) file nil 'silent)))
        file))))

(defun body--session-archives ()
  "存档文件列表，新的在前。"
  (when (file-directory-p body-session-dir)
    (reverse (sort (directory-files body-session-dir t "\\.md\\'" t)
                   #'string<))))

(defun body--load-archive (mb file)
  "把存档 FILE 装进主脑 MB（MB 必须是空会话）。"
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
      (body--refresh-draft-overlay))))

(defun body-continue ()
  "把最近一次存档的主脑对话装回来接着聊。
当前主脑必须是空白的（比如刚启动）；要重开当前对话用 SPC j n。"
  (interactive)
  (let ((file (expand-file-name "latest.md" body-session-dir)))
    (unless (file-exists-p file)
      (user-error "没有历史存档（%s）" (abbreviate-file-name file)))
    (let ((mb (body--master)))
      (body--load-archive mb file)
      (setq body--last-session mb)
      (select-window (body--display mb)))
    (message "身体：已接上上次对话，继续")))

(defun body-continue-archive ()
  "从历史存档列表里挑一份接上（新的在前；默认第一份=最新）。"
  (interactive)
  (let* ((files (body--session-archives))
         (names (mapcar (lambda (f)
                          (concat (file-name-nondirectory f)
                                  (format "  (%s)"
                                          (format-time-string
                                           "%m-%d %H:%M"
                                           (file-attribute-modification-time
                                            (file-attributes f))))))
                        files))
         (pick (if (null files)
                   (user-error "没有历史存档（%s）" body-session-dir)
                 (completing-read "接上哪份存档: " names nil t nil nil
                                  (car (or names '(nil))))))
         (file (when pick (nth (seq-position names pick) files))))
    (when file
      (let ((mb (body--master)))
        (body--load-archive mb file)
        (setq body--last-session mb)
        (select-window (body--display mb)))
      (message "身体：已接上存档 %s" (file-name-nondirectory file)))))

;;;; ------------------------------------------------------------------
;;;; 上下文压缩：历史太长时，交给模型做交接摘要，替换对话内容
;;;; ------------------------------------------------------------------

(defvar body-auto-compact t
  "非 nil 时，主脑上下文占用超过 `body-compact-threshold' 自动压缩。")

(defvar body-compact-threshold 0.85
  "自动压缩的上下文占用比例（0-1）。")

(defvar body-compact-prompt
  "把上面这段对话压缩成一份交接摘要，给同一个 agent 接着干。必须保留：用户的目标与偏好、已完成的改动（文件/路径）、重要结论与事实、未完成的步骤与下一步、错误教训。丢掉寒暄与已验证无用的尝试细节。用中文，直接输出摘要正文。"
  "压缩请求附在历史末尾的指令。")

(defvar body--compacting nil
  "正在压缩主脑上下文的标记（防重入）。")

(defun body--context-ratio (buf)
  "BUF 的上下文占用比例（token / 窗口）；未知返回 nil。"
  (when (buffer-live-p buf)
    (let* ((tok (buffer-local-value 'body--last-req buf))
           (sum (+ (or (plist-get tok :input) 0)
                   (or (plist-get tok :cached) 0)
                   (or (plist-get tok :output) 0)))
           (win (body--context-window
                 (ignore-errors (buffer-local-value 'gptel-model buf)))))
      (when (and (> sum 0) win (> win 0))
        (/ (float sum) win)))))

(defun body--maybe-auto-compact (&rest _)
  "回复结束后看一眼上下文水位，超阈值就自动压缩。"
  (when (and body-auto-compact (not body--compacting))
    (let ((mb (body--master-buffer)))
      (when (and (buffer-live-p mb) (not (body--busy-p mb)))
        (let ((r (body--context-ratio mb)))
          (when (and r (> r body-compact-threshold))
            (message "身体：上下文已到 %d%%，自动压缩…"
                     (round (* 100 r)))
            (run-with-idle-timer 0.5 nil
                                 (lambda ()
                                   (ignore-errors (body-compact))))))))))

(defun body--apply-compact (mb summary)
  "用 SUMMARY 替换 MB 的对话内容（原文已另存时间戳存档）。"
  (with-current-buffer mb
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert (gptel-prompt-prefix-string)
              "（前面对话已压缩 @ "
              (format-time-string "%m-%d %H:%M")
              "，原文在 body-sessions/ 时间戳存档）\n\n"
              gptel-response-separator
              (gptel-response-prefix-string)
              (string-trim summary) "\n")
      (goto-char (point-max))
      (setq-local body--sent-end (copy-marker (point-max)))
      (body--refresh-draft-overlay)))
  (setq body--last-session mb)
  (message "身体：对话已压缩"))

(defun body-compact ()
  "压缩主脑对话：全文先另存时间戳存档，再把历史交给当前模型做交接摘要，
用摘要替换对话内容。模型不可达时不破坏原对话。"
  (interactive)
  (let ((mb (body--master-buffer)))
    (unless (and (buffer-live-p mb) (> (buffer-size mb) 0))
      (user-error "主脑没有可压缩的对话"))
    (when (body--busy-p mb)
      (user-error "主脑正在回复，稍后再压"))
    (let ((file (body--archive-session mb))
          (body--compacting t))
      (message "身体：正在压缩（原文已存 %s）"
               (if file (file-name-nondirectory file) "（空）"))
      (with-current-buffer mb
        (let ((gptel-use-tools nil))
          (gptel-request
           body-compact-prompt
           :buffer mb
           :stream nil
           :callback
           (lambda (response info)
             (setq body--compacting nil)
             (if (not (stringp response))
                 (message "身体：压缩失败（%s），对话未动"
                          (or (plist-get info :status) "无响应"))
               (condition-case err
                   (body--apply-compact mb response)
                 (error (message "身体：压缩后写回失败: %s"
                                 (error-message-string err))))))))))))

(add-hook 'kill-emacs-hook #'body--save-session)

(defun body-new-session ()
  "结束当前主脑对话（自动存档），从空白开始。"
  (interactive)
  (let ((mb (body--master-buffer)))
    (when (and mb (body--busy-p mb))
      (gptel-abort mb))
    (body--archive-session)
    (body--save-session)
    (when mb
      (when-let* ((w (get-buffer-window mb 'visible))) (delete-window w))
      (kill-buffer mb))
    (setq body--master-queue nil
          body--last-session nil)
    (message "身体：新会话（旧对话已存档于 %s）"
             (abbreviate-file-name body-session-dir))))

(provide 'body-session)
;;; body/session.el ends here
