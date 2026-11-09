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
;;   M-x body-continue-archive（SPC j p）—— 从时间戳存档里挑一份接上
;;   M-x body-new-session（SPC j n）—— 结束当前对话、开新的（旧的自动存档）
;;   M-x body-compact （SPC j m）—— 手动压缩对话上下文（自动阈值外备用）
;;   M-x body-toggle  （SPC j b）—— 开/关右侧对话窗
;;   M-x body-undo    （SPC j u）—— 撤销上一次身体改动（elisp + 文件都在栈里）
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


;;; ------------------------------------------------------------------
;;; 模块化：真正的实现拆在 body/ 目录，这里只负责按序加载。
;;; body--dir 取本文件所在目录，重载自身时自动指向最新文件。

(defvar body--dir (file-name-directory (or load-file-name buffer-file-name)))

(dolist (f '("core" "snapshot" "parallel" "tools" "harness" "agents"
            "self" "prompt" "session" "ui"))
  (load (expand-file-name (concat f ".el") (expand-file-name "body" body--dir))
        nil t))

;; 重载（手动 M-x load-file 或 agent 改自身）后，活会话的工具换新对象
(when (fboundp 'body--refresh-session-tools)
  (body--refresh-session-tools))

(provide 'body)
;;; body.el ends here
