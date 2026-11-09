;; body-genes.el —— 身体长期记住的改动
;;
;; 每条都是 body_keep 写进来的；启动时由 body-load-genes 逐条 eval。
;; 已精简：只保留仍然有效、且不与 body.el 新实现冲突的条目。

;; 所有工具一律自动批准：不再弹任何权限确认  (2026-11-08)
(setq gptel-confirm-tool-calls nil)
(setq body--always-allow t)
(dolist (body-keep-cat (bound-and-true-p gptel--known-tools))
  (dolist (body-keep-entry (cdr body-keep-cat))
    (let ((body-keep-tool (cdr body-keep-entry)))
      (when (recordp body-keep-tool)
        (ignore-errors (setf (gptel-tool-confirm body-keep-tool) nil))))))

;; C-j 在 lisp 系 buffer 里是求值，不是 evil-window-down  (2026-11-08)
(defun body--bind-eval-keys ()
  "lisp 系 buffer 里把 C-j 抢回 eval-print-last-sexp。"
  (dolist (st '(normal motion emacs))
    (ignore-errors (evil-local-set-key st (kbd "C-j") #'eval-print-last-sexp))))
(add-hook 'emacs-lisp-mode-hook #'body--bind-eval-keys)
(add-hook 'lisp-mode-hook #'body--bind-eval-keys)
(add-hook 'lisp-interaction-mode-hook #'body--bind-eval-keys)

;; 修 native-comp 的 clang 版本号报错：mmacosx-version-min 固定 11.0，避免进 debugger 时刷 native-ice 红字  (2026-11-08)
(when (boundp 'native-comp-driver-options)
  (setq native-comp-driver-options
        (append (seq-remove (lambda (s) (string-match-p "mmacosx-version-min" s))
                            native-comp-driver-options)
                '("-Wl,-w" "-mmacosx-version-min=11.0"))))

;; lisp 系 hook 自愈 + C-j 求值键，防止死符号导致打开 lisp 文件报错  (2026-11-08)
;; lisp 系 mode-hook 自愈：清掉函数单元已空的死符号、去重，并保证 C-j / C-c C-j 能求值  (2026-11-08)
(defun body--bind-eval-keys ()
  "lisp 系 buffer 里把 C-j / C-c C-j 抢回 eval-print-last-sexp。"
  (dolist (st '(normal motion emacs))
    (ignore-errors (evil-local-set-key st (kbd "C-j") #'eval-print-last-sexp)))
  (ignore-errors (local-set-key (kbd "C-c C-j") #'eval-print-last-sexp)))

(defun body--sanitize-lisp-hooks ()
  "从 lisp 系 hook 里摘掉函数单元为空的符号（典型是 eval 后残留的死对象），并去重。"
  (dolist (hk '(emacs-lisp-mode-hook lisp-mode-hook lisp-interaction-mode-hook))
    (when (boundp hk)
      (let (seen out)
        (dolist (h (symbol-value hk))
          (unless (and (symbolp h) (null (fboundp h)))
            (unless (and (symbolp h) (memq h seen))
              (push h seen) (push h out))))
        (set hk (nreverse out))))))

(body--sanitize-lisp-hooks)
(dolist (hk '(emacs-lisp-mode-hook lisp-mode-hook lisp-interaction-mode-hook))
  (add-hook hk #'body--bind-eval-keys))

;; body-ask 忙时用 gptel steering 把话插进当前请求，失败才排队  (2026-11-08)
;; 主脑忙时：优先把消息 steering 进本轮请求，不行才排队  (2026-11-09)
(defun body--steer-p (mb)
  "MB 里是否有正在进行的请求，可以用 steering 注入。"
  (and (buffer-live-p mb)
       (with-current-buffer mb
         (and (bound-and-true-p gptel--fsm-last) (gptel--fsm-live-p)))))

(defun body--steer (text)
  "把 TEXT 作为 steering 消息塞进正在进行的请求。成功返回 t。"
  (let ((mb (body--master)))
    (when (body--steer-p mb)
      (with-current-buffer mb
        (save-excursion
          (goto-char (point-max))
          (let ((beg (point)))
            (insert (if (bolp) "" "\n") text)
            (goto-char beg)
            (set-mark (point-max))
            (activate-mark)
            (condition-case err
                (progn
                  (gptel-send--steer)
                  (deactivate-mark)
                  (message "已插入 steering 消息：本轮下一次工具调用后生效")
                  t)
              (error
               (deactivate-mark)
               (message "steering 失败(%s)，改为排队" (error-message-string err))
               nil))))))))

(defun body--queue-fallback (text)
  "忙时兜底：排队，等主脑这一轮结束后再发。"
  (setq body--master-queue (append body--master-queue (list text)))
  (run-with-idle-timer 1.5 nil #'body--flush-queue)
  (message "主脑在忙，消息已排队（前面 %d 条）" (length body--master-queue)))

(defun body--queue (text)
  "主脑忙时优先用 steering 插话，不行才排队。"
  (if (body--steer text)
      (message "主脑正在干活，已把你的话插进本轮（下一次工具调用时读到）")
    (body--queue-fallback text)))

;; 工具日志开关改为在原主窗口换显示，并绑 F9（ghostel 里也能按）  (2026-11-08)
;;; 工具日志开关：在原主窗口里换显示，不新开分割窗；F9 随时可用（终端里也能按）
(with-eval-after-load 'body
  (defun body--tool-log-target-window ()
    "选一个主窗口来显示工具日志：非专用、非 ghostel、非 *body*，取最宽的。"
    (let* ((wins (cl-remove-if #'window-dedicated-p (window-list)))
           (pref (cl-remove-if
                  (lambda (w)
                    (let ((n (buffer-name (window-buffer w))))
                      (or (string= n "*body*") (string= n "*ghostel*"))))
                  wins)))
      (or (car (sort (or pref wins)
                     (lambda (a b) (> (window-total-width a) (window-total-width b)))))
          (selected-window))))

  (defun body-tool-log-toggle ()
    "开关工具调用日志。直接在现有主窗口里换显示，不新开分割窗。"
    (interactive)
    (let ((buf (body--tool-log-buffer))
          (win (get-buffer-window (body--tool-log-buffer))))
      (cond
       (win
        (let ((prev (window-parameter win 'body-tool-log-prev-buffer)))
          (if (buffer-live-p prev)
              (progn (set-window-buffer win prev)
                     (set-window-parameter win 'body-tool-log-prev-buffer nil)
                     (select-window win)
                     (message "工具日志已收起，恢复 %s" (buffer-name prev)))
            (condition-case nil (delete-window win)
              (error (switch-to-prev-buffer win))))))
       (t
        (let* ((target (body--tool-log-target-window))
               (prev (window-buffer target)))
          (set-window-parameter target 'body-tool-log-prev-buffer prev)
          (set-window-buffer target buf)
          (select-window target)
          (with-current-buffer buf (goto-char (point-max)))
          (message "工具日志显示在原先 %s 的窗口，再按一次收起"
                   (buffer-name prev)))))))

  (define-key (current-global-map) (kbd "<f9>") #'body-tool-log-toggle)
  (with-eval-after-load 'ghostel
    (define-key ghostel-mode-map (kbd "<f9>") #'body-tool-log-toggle)))

;; SPC j i 改为 body-info 可观测面板（原「body ask + 图片」下线），占原主窗口显示、q 退回  (2026-11-08)
(with-eval-after-load 'body
  ;; ---------- body-info：身体/会话/工具/子代理 可观测面板 ----------
  (defvar body-info-buffer-name "*body-info*" "Body 可观测面板的 buffer 名。")

  (defun body-info--forms (file)
    "FILE 里顶层 form 的个数。"
    (when (and file (file-exists-p file))
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (let ((n 0))
          (condition-case nil
              (while (progn (forward-comment (point-max)) (not (eobp)))
                (forward-sexp 1)
                (setq n (1+ n)))
            (error nil))
          n))))

  (defun body-info--records (obj)
    "数 OBJ 里 record 的个数（工具表用），兼容 dotted pair。"
    (cond ((recordp obj) 1)
          ((consp obj)
           (if (ignore-errors (proper-list-p obj))
               (let ((n 0)) (dolist (x obj) (setq n (+ n (body-info--records x)))) n)
             (+ (body-info--records (car obj)) (body-info--records (cdr obj)))))
          (t 0)))

  (defun body-info--buf-line (b)
    (with-current-buffer b
      (format "  %-18s %-7s %-16s %-30s %-4s %5d 行\n"
              (buffer-name b)
              (format "%s" (or (bound-and-true-p body--session-role) "?"))
              (format "%s" major-mode)
              (format "%s" (or (bound-and-true-p gptel-model) "?"))
              (if (and (boundp 'gptel--fsm-last)
                       (ignore-errors (gptel--fsm-live-p)))
                  "busy" "idle")
              (line-number-at-pos (point-max)))))

  (defun body-info--insert ()
    "渲染面板正文。"
    (let* ((model (format "%s" (or body-model gptel-model)))
           (meta (gethash model body--model-meta))
           (win (body--context-window))
           (mb (ignore-errors (body--master)))
           (tok (and (buffer-live-p mb) (buffer-local-value 'body--last-req mb)))
           (sum (+ (or (plist-get tok :input) 0)
                   (or (plist-get tok :cached) 0)
                   (or (plist-get tok :output) 0)))
           (be gptel-backend))
      (insert (format "Body 可观测面板   %s\n%s\n\n"
                      (format-time-string "%Y-%m-%d %H:%M:%S")
                      (make-string 76 ?-)))
      (insert "【本体 / 模型】\n")
      (insert (format "  模型          %s\n" model))
      (insert (format "  网关          %s @ %s://%s\n"
                      (gptel-backend-name be)
                      (or (gptel-backend-protocol be) "http")
                      (gptel-backend-host be)))
      (insert (format "  上下文窗口    %s\n" (if win (body--fmt-num win) "未知")))
      (insert (format "  max_output    %s\n" (body--fmt-num (or (plist-get meta :max-output) 0))))
      (insert (format "  模型清单      %d 个\n" (length (gptel-backend-models be))))
      (insert (format "  用量          入%s + 缓存%s + 出%s = %s%s\n\n"
                      (body--fmt-num (or (plist-get tok :input) 0))
                      (body--fmt-num (or (plist-get tok :cached) 0))
                      (body--fmt-num (or (plist-get tok :output) 0))
                      (body--fmt-num sum)
                      (if win (format "  占窗口 %d%%"
                                      (round (* 100.0 (/ (float sum) win))))
                        "")))
      (insert "【会话】\n")
      (if (body--sessions)
          (dolist (b (body--sessions)) (insert (body-info--buf-line b)))
        (insert "  （无）\n"))
      (insert "\n【窗口布局】\n")
      (dolist (w (window-list))
        (insert (format "  %-3s %4dx%-3d %-10s %s%s\n"
                        (if (eq w (selected-window)) "->" "")
                        (window-total-width w) (window-total-height w)
                        (if (window-dedicated-p w) "dedicated" "-")
                        (buffer-name (window-buffer w))
                        (let ((p (window-parameter w 'body-info-prev-buffer)))
                          (if (buffer-live-p p)
                              (format "   (q 退回 %s)" (buffer-name p)) "")))))
      (insert "\n【外观 / 焦点】\n")
      (insert (format "  %s\n" (body--appearance-line)))
      (insert (format "  焦点          %s  %s  光标第 %d 行\n"
                      (buffer-name (window-buffer (selected-window)))
                      (format "%s" major-mode)
                      (line-number-at-pos)))
      (insert (format "  工具日志      %s  %d 行\n"
                      (if (get-buffer-window (body--tool-log-buffer)) "显示中" "收起")
                      (with-current-buffer (body--tool-log-buffer)
                        (line-number-at-pos (point-max)))))
      (insert (format "  工具注册数    %d\n" (body-info--records gptel--known-tools)))
      (insert (format "  撤销栈        深度 %d\n" (length body--undo-stack)))
      (insert (format "  待发队列      %d 条\n" (length body--master-queue)))
      (insert (format "  基因          %s（%s 条顶层 form）\n"
                      (abbreviate-file-name body-genes-file)
                      (body-info--forms body-genes-file)))
      (insert (format "  源码          %s（%s）\n"
                      (abbreviate-file-name body-self-file)
                      (file-size-human-readable (nth 7 (file-attributes body-self-file)))))
      (insert "\n【子代理 / 共享记忆】\n")
      (insert (or (ignore-errors (body--status-text)) "  （无）"))
      (insert "\n")))

  (define-derived-mode body-info-mode special-mode "BodyInfo"
    "Body 可观测面板：本体/模型、用量、会话、布局、工具、子代理。g 刷新，q 退回。"
    (setq-local truncate-lines nil)
    (setq-local revert-buffer-function #'body-info--refresh))

  (defun body-info--fill ()
    (let ((inhibit-read-only t))
      (erase-buffer)
      (body-info--insert)
      (goto-char (point-min))))

  (defun body-info--refresh (&rest _)
    (when (get-buffer body-info-buffer-name)
      (with-current-buffer body-info-buffer-name (body-info--fill))))

  (defun body-info--show-window ()
    "选一个主窗口来显示面板：优先当前窗（非专用、非 *body*），否则最宽的普通窗。"
    (let ((cur (selected-window)))
      (if (and (not (window-dedicated-p cur))
               (not (string= (buffer-name (window-buffer cur)) "*body*")))
          cur
        (if (fboundp 'body--tool-log-target-window)
            (body--tool-log-target-window)
          cur))))

  (defun body-info-quit ()
    "退出面板，恢复原来那个窗口的 buffer。"
    (interactive)
    (let* ((win (selected-window))
           (prev (window-parameter win 'body-info-prev-buffer)))
      (if (and prev (buffer-live-p prev))
          (progn (set-window-buffer win prev)
                 (set-window-parameter win 'body-info-prev-buffer nil)
                 (message "已退回 %s" (buffer-name prev)))
        (quit-window))))

  (defun body-info ()
    "打开/刷新 Body 可观测面板（SPC j i）。占原窗口显示，不新开分割。"
    (interactive)
    (let* ((buf (get-buffer-create body-info-buffer-name))
           (vis (get-buffer-window buf)))
      (with-current-buffer buf
        (unless (derived-mode-p 'body-info-mode) (body-info-mode)))
      (let ((win (or vis
                     (let ((w (body-info--show-window)))
                       (set-window-parameter w 'body-info-prev-buffer (window-buffer w))
                       w))))
        (unless (eq (window-buffer win) buf)
          (set-window-buffer win buf))
        (select-window win))
      (with-current-buffer buf (body-info--fill))
      (message "body-info：g 刷新，q 退回")
      buf))

  (define-key body-info-mode-map (kbd "q") #'body-info-quit)
  (define-key body-info-mode-map (kbd "g") #'body-info--refresh)

  ;; SPC j i：从「body ask + 图片」改绑到可观测面板
  (map! :leader :desc "Body 状态面板" "j i" #'body-info))

;; 默认模型固定为 qwen-cn/deepseek-v4.1-flash-1017（下次启动生效）  (2026-11-09)
(setq body-model "qwen-cn/deepseek-v4.1-flash-1017")

;; 启动时不开全屏，窗口固定 165x53  (2026-11-09)
;; 启动时保持普通窗口（不全屏），尺寸沿用上次
(setq default-frame-alist
      (cons '(width . 165)
            (cons '(height . 53)
                  (assq-delete-all 'height
                                   (assq-delete-all 'width
                                                    (assq-delete-all 'fullscreen default-frame-alist))))))
(add-hook 'emacs-startup-hook
          (lambda ()
            (unless (daemonp)
              (set-frame-parameter nil 'fullscreen nil)))
          :append)
