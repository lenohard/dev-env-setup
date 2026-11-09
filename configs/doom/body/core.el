;;; body/core.el --- 状态、感知、undo 栈、共享日志等公共状态  -*- lexical-binding: t; -*-
;; body 的一个模块，由 body.el 统一 load，别单独加载。

(require 'gptel)
(require 'cl-lib)
(require 'seq)
(require 'subr-x)

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

(provide 'body-core)
;;; body/core.el ends here
