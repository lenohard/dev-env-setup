;;; body/agents.el --- 主从代理：共享记忆、spawn/send/report  -*- lexical-binding: t; -*-
;; body 的一个模块，由 body.el 统一 load，别单独加载。

(require 'gptel)
(require 'cl-lib)
(require 'seq)
(require 'subr-x)

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

(provide 'body-agents)
;;; body/agents.el ends here
