;;; body/tools.el --- 基础工具：感知、执行、撤销  -*- lexical-binding: t; -*-
;; body 的一个模块，由 body.el 统一 load，别单独加载。

(require 'gptel)
(require 'cl-lib)
(require 'seq)
(require 'subr-x)

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

(defvar body-sense-cap 12000
  "body_sense 读 buffer 时的字符上限（更长用 body_read_file 分段读）。")

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
                    (point-max)))
               (text (buffer-substring-no-properties b (min e (point-max)))))
          (if (> (length text) body-sense-cap)
              (concat (substring text 0 body-sense-cap)
                      (format "\n…(共 %d 字符已截断；用 from/to 行号或 body_read_file 分段读)"
                              (length text)))
            text))))))

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
  (if (or body--always-allow
          (not (eq (current-thread) main-thread)))
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

(provide 'body-tools)
;;; body/tools.el ends here
