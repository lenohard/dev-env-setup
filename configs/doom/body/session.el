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

(provide 'body-session)
;;; body/session.el ends here
