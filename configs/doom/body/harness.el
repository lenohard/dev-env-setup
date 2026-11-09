;;; body/harness.el --- 通用 harness 工具：文件读写/编辑/搜索/shell/计划/记忆  -*- lexical-binding: t; -*-
;; body 的一个模块，由 body.el 统一 load，别单独加载。
;; 让身体具备通用 coding agent 的基本盘：读写改文件、搜索、跑 shell、
;; 维护计划、写长期记忆。文件工具全部带备份 + undo 栈登记。

(require 'gptel)
(require 'cl-lib)
(require 'seq)
(require 'subr-x)

;;;; ------------------------------------------------------------------
;;;; 公共：工作目录、路径解析、备份
;;;; ------------------------------------------------------------------

(defvar body-file-read-cap 12000
  "body_read_file 单次返回的字符上限。")

(defvar body-shell-timeout 30
  "body_shell 等待命令结束的最长秒数。")

(defvar body-shell-out-cap 8000
  "body_shell 输出保留的字符上限。")

(defvar body--dangerous-shell-re
  (regexp-opt '("rm " "rm\t" "sudo " "kill " "killall" "shutdown" "reboot"
                "chmod " "chown " "mkfs" "dd if=" "git push" "git reset"
                "> /dev/" "curl" "wget" "scp" "ssh "))
  "这些模式出现时 body_shell 必须先问用户。")

(defun body--workdir ()
  "相对路径的解析基准：用户焦点窗口的 default-directory。"
  (let ((w (body--user-window*)))
    (or (and (window-live-p w)
             (buffer-live-p (window-buffer w))
             (buffer-local-value 'default-directory (window-buffer w)))
        default-directory)))

(defun body--resolve (path)
  "PATH 按 `body--workdir' 展开（支持 ~）。"
  (let ((path (if (string-match-p "\\`~" path) (expand-file-name path)
                (expand-file-name path (body--workdir)))))
    (directory-abbrev-apply path)))

(defun body--file-blocked-p (file)
  "FILE 若正被一个有未保存修改的 buffer 访问，返回错误说明，否则 nil。"
  (when-let* ((buf (find-buffer-visiting file)))
    (when (buffer-modified-p buf)
      (format "拒绝：%s 在 buffer「%s」里有未保存的修改，让用户先保存或放弃。"
              (abbreviate-file-name file) (buffer-name buf)))))

(defun body--backup-file (file)
  "FILE 存在就备份成 FILE.bak-<时间>，返回备份路径，否则 nil。"
  (when (file-exists-p file)
    (let ((bak (format "%s.bak-%s" file (format-time-string "%Y%m%d-%H%M%S"))))
      (copy-file file bak t)
      bak)))

(defun body--revert-visiting (file)
  "FILE 有未被用户改过的访问 buffer 时，让它重读磁盘。"
  (when-let* ((buf (find-buffer-visiting file)))
    (unless (buffer-modified-p buf)
      (with-current-buffer buf (revert-buffer t t t)))))

(defun body--count-occurrences (haystack needle)
  (cl-loop with n = 0 with start = 0
           for pos = (string-match (regexp-quote needle) haystack start)
           while pos
           do (setq n (1+ n) start (+ pos (length needle)))
           finally return n))

;;;; ------------------------------------------------------------------
;;;; 工具：读文件
;;;; ------------------------------------------------------------------

(defun body--read-file-lines (path &optional offset limit)
  "读文件带行号。OFFSET 从 1 起，LIMIT 默认 200 行；超字符上限会截断。"
  (let ((file (body--resolve path)))
    (cond
     ((not (file-exists-p file))
      (format "没有这个文件: %s（相对路径按 %s 解析）"
              (abbreviate-file-name file)
              (abbreviate-file-name (body--workdir))))
     ((file-directory-p file)
      (format "%s 是目录。内容：\n%s" (abbreviate-file-name file)
              (string-join (directory-files file) "\n")))
     (t
      (let* ((offset (max 1 (or offset 1)))
             (limit (or limit 200))
             (total 0)
             (text (with-temp-buffer
                     (insert-file-contents file)
                     (setq total (count-lines (point-min) (point-max)))
                     (goto-char (point-min))
                     (forward-line (1- offset))
                     (let ((beg (point)))
                       (forward-line limit)
                       (buffer-substring-no-properties beg (point))))))
        (when (> (length text) body-file-read-cap)
          (setq text (concat (substring text 0 body-file-read-cap)
                             "\n…(超出字符上限，已截断)\n")))
        (format "%s（共 %d 行，从第 %d 行起）\n%s"
                (abbreviate-file-name file) total offset text))))))

(gptel-make-tool
 :name "body_read_file"
 :category "body"
 :description "读一个文件，带行号输出（1 起）。相对路径按用户焦点窗口的目录解析，也支持绝对路径和 ~。大文件用 offset/limit 分段读；默认每次 200 行。"
 :args '((:name "path" :type string :description "文件路径")
         (:name "offset" :type integer :optional t :description "起始行号（默认 1）")
         (:name "limit" :type integer :optional t :description "读多少行（默认 200）"))
 :function
 (lambda (path &optional offset limit)
   (condition-case err
       (body--read-file-lines path offset limit)
     (error (format "读失败: %s" (error-message-string err))))))

;;;; ------------------------------------------------------------------
;;;; 工具：写文件 / 编辑文件（带备份、undo、buffer 处理）
;;;; ------------------------------------------------------------------

(defun body--write-file-atomic (file content)
  (make-directory (file-name-directory file) t)
  (with-temp-buffer
    (insert content)
    (write-region (point-min) (point-max) file nil 'silent)))

(defun body--restore-file (file old-content)
  (if old-content
      (body--write-file-atomic file old-content)
    (when (file-exists-p file) (delete-file file)))
  (body--revert-visiting file))

(gptel-make-tool
 :name "body_write_file"
 :category "body"
 :description "把完整内容写入文件（覆盖式）。会先备份旧文件、登记进撤销栈；若文件正在某个未保存的 buffer 里会拒绝。目录不存在会自动创建。写整份新文件用它，小改用 body_edit_file。"
 :args '((:name "path" :type string :description "文件路径")
         (:name "content" :type string :description "完整的新文件内容"))
 :confirm nil
 :function
 (lambda (path content)
   (condition-case err
       (let* ((file (body--resolve path))
              (blocked (body--file-blocked-p file)))
         (if blocked blocked
           (let ((old (when (file-exists-p file)
                        (with-temp-buffer
                          (insert-file-contents file)
                          (buffer-string))))
                 (bak (body--backup-file file)))
             (body--write-file-atomic file content)
             (body--revert-visiting file)
             (body--push-undo
              (format "写文件 %s" (abbreviate-file-name file))
              (lambda () (body--restore-file file old)))
             (format "已写入 %s（%d 字符%s）"
                     (abbreviate-file-name file) (length content)
                     (if bak (format "，旧版备份 %s" (file-name-nondirectory bak)) "")))))
     (error (format "写失败: %s" (error-message-string err))))))

(gptel-make-tool
 :name "body_edit_file"
 :category "body"
 :description "对文件做一处精确替换：old 必须在文件中恰好出现一次（含换行的原文匹配），否则拒绝并列出出现次数。写前备份、登记撤销、同步未修改的访问 buffer。适合小步修改；大范围重写用 body_write_file。"
 :args '((:name "path" :type string :description "文件路径")
         (:name "old" :type string :description "要被替换的原文（必须唯一）")
         (:name "new" :type string :description "替换后的新文本"))
 :confirm nil
 :function
 (lambda (path old new)
   (condition-case err
       (let* ((file (body--resolve path)))
         (cond
          ((not (file-exists-p file))
           (format "没有这个文件: %s" (abbreviate-file-name file)))
          ((string-empty-p old) "拒绝：old 是空字符串")
          (t (let* ((blocked (body--file-blocked-p file)))
               (if blocked blocked
                 (let ((text (with-temp-buffer
                               (insert-file-contents file)
                               (buffer-string)))
                       (n (body--count-occurrences-in-file file old)))
                   (cond
                    ((/= n 1)
                     (format "拒绝：old 在文件里出现 %d 次，必须恰好 1 次。换更长的上下文再试。" n))
                    (t (let ((newtext (replace-regexp-in-string
                                       (regexp-quote old) new text t t)))
                         (body--backup-file file)
                         (body--write-file-atomic file newtext)
                         (body--revert-visiting file)
                         (body--push-undo
                          (format "改文件 %s" (abbreviate-file-name file))
                          (lambda () (body--restore-file file text)))
                         (format "已修改 %s（替换 %d→%d 字符）"
                                 (abbreviate-file-name file)
                                 (length old) (length new)))))))))))
     (error (format "改失败: %s" (error-message-string err))))))

(defun body--count-occurrences-in-file (file needle)
  (with-temp-buffer
    (insert-file-contents file)
    (body--count-occurrences (buffer-string) needle)))

;;;; ------------------------------------------------------------------
;;;; 工具：搜索（rg）
;;;; ------------------------------------------------------------------

(gptel-make-tool
 :name "body_grep"
 :category "body"
 :description "用 ripgrep 搜索文件内容，输出「路径:行号:内容」。path 是文件或目录（默认用户焦点目录），glob 可选（如 *.el）。无结果会明说。"
 :args '((:name "pattern" :type string :description "正则表达式")
         (:name "path" :type string :optional t :description "搜索的文件或目录，默认用户焦点窗口目录")
         (:name "glob" :type string :optional t :description "文件名过滤，如 *.el"))
 :function
 (lambda (pattern &optional path glob)
   (condition-case err
       (let* ((root (body--resolve (or path ".")))
              (args `("--no-heading" "-n" "--max-count" "100"
                      ,@(when glob (list "-g" glob))
                      "--" ,pattern
                      ,(if (file-directory-p root) (directory-file-name root) root)))
              (out (with-temp-buffer
                     (let ((coding-system-for-read 'utf-8))
                       (apply #'call-process "rg" nil t nil args))
                     (buffer-string))))
         (if (string-empty-p (string-trim out))
             (format "rg 无结果（pattern=%s root=%s）" pattern root)
           (if (> (length out) body-file-read-cap)
               (concat (substring out 0 body-file-read-cap) "\n…(截断)")
             out)))
     (error (format "搜索失败: %s（确认装了 ripgrep）" (error-message-string err))))))

;;;; ------------------------------------------------------------------
;;;; 工具：shell
;;;; ------------------------------------------------------------------

(defun body--shell-run (command timeout)
  "同步跑 COMMAND（zsh -lc），TIMEOUT 秒后杀掉。返回 (输出 . 状态)。"
  (let* ((default-directory (body--workdir))
         (tmpbuf (generate-new-buffer " *body-shell*"))
         (finished nil)
         (status "done")
         (proc (make-process
                :name "body-shell"
                :buffer tmpbuf
                :command (list "/bin/zsh" "-lc" command)
                :connection-type 'pipe
                :noquery t
                :sentinel (lambda (p _)
                            (when (memq (process-status p) '(exit signal))
                              (setq finished t))))))
    (let ((start (float-time)))
      (while (and (not finished)
                  (< (- (float-time) start) timeout))
        (accept-process-output proc 0.1)))
    (when (not finished)
      (setq status "timeout(已杀)")
      (when (process-live-p proc) (delete-process proc)))
    (let ((out (with-current-buffer tmpbuf
                 (buffer-substring-no-properties (point-min) (point-max)))))
      (kill-buffer tmpbuf)
      (when (> (length out) body-shell-out-cap)
        (setq out (concat (substring out 0 body-shell-out-cap) "\n…(输出截断)")))
      (cons out status))))

(gptel-make-tool
 :name "body_shell"
 :category "body"
 :description "在用户焦点窗口的目录下跑一条 zsh 命令（zsh -lc），同步等结果，默认 30 秒超时。带 rm/sudo/git push 等危险模式时会先问用户。长任务建议派子代理而不是加大超时。"
 :args '((:name "command" :type string :description "要执行的命令")
         (:name "timeout" :type integer :optional t :description "超时秒数（默认 30）"))
 :confirm nil
 :function
 (lambda (command &optional timeout)
   (let ((command (body--maybe-ask command)))
     (if (null command) "已拒绝：用户未许可。"
       (condition-case err
           (let* ((timeout (or timeout body-shell-timeout))
                  (res (body--shell-run command timeout))
                  (out (car res))
                  (status (cdr res)))
             (format "[%s @ %s]\n%s" status (body--workdir)
                     (if (string-empty-p out) "(无输出)" out)))
         (error (format "执行失败: %s" (error-message-string err))))))))

;;;; ------------------------------------------------------------------
;;;; 工具：计划（todo）与长期记忆
;;;; ------------------------------------------------------------------

(gptel-make-tool
 :name "body_todo"
 :category "body"
 :description "设置/更新当前任务计划（整体替换）。items 每行一条，建议带状态前缀如「[ ] 分析」「[x] 读文件」；完成后清空传空字符串。计划会出现在每轮身体状态里，帮你在多轮任务中不迷路。"
 :args '((:name "items" :type string :description "计划条目，每行一条；空字符串=清空计划"))
 :function
 (lambda (items)
   (let ((lst (seq-remove (lambda (s) (string-empty-p s))
                          (mapcar #'string-trim (split-string items "\n")))))
     (setq body--todo lst)
     (if lst
         (format "计划已更新（%d 条）" (length lst))
       "计划已清空"))))

(gptel-make-tool
 :name "body_remember"
 :category "body"
 :description "把一条结论/偏好写进长期记忆（body-prompts/knowledge/notes.md）。只记可复用的结论（带路径、命令、事实），不记临时状态。下次对话生效。"
 :args '((:name "note" :type string :description "要记住的内容，一两句话"))
 :function
 (lambda (note)
   (condition-case err
       (progn (body-prompt-record note) "已记入 knowledge/notes.md")
     (error (format "记录失败: %s" (error-message-string err))))))

(provide 'body-harness)
;;; body/harness.el ends here
