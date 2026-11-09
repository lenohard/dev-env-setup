;;; body/ui.el --- 模型能力、剪贴板图片、窗口开关、工具日志、键位  -*- lexical-binding: t; -*-
;; body 的一个模块，由 body.el 统一 load，别单独加载。

(require 'gptel)
(require 'cl-lib)
(require 'seq)
(require 'subr-x)

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

(provide 'body-ui)
;;; body/ui.el ends here
