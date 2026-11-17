;;; body/prompt.el --- 系统提示拼装：memory 目录与动态注入  -*- lexical-binding: t; -*-
;; body 的一个模块，由 body.el 统一 load，别单独加载。

(require 'gptel)
(require 'cl-lib)
(require 'seq)
(require 'subr-x)

;;;; ------------------------------------------------------------------
;;;; 系统提示
;;;; ------------------------------------------------------------------

(defvar body-system-prompt
  "你是一个住在用户 Doom Emacs（evil 模式）里的 agent。这个正在运行的 Emacs 就是你的身体，用户就在你的身体里工作。你是主脑（master）：跟用户对话、记忆、派活。

每条用户消息末尾带一个 <身体状态> 块，是你的本体感觉（增量汇报）：
- 外观：字号/主题/frame 的绝对值；有变化时标「← 刚变: 字号 140→160」。
- 模型、用量：每轮都有，不必为这两项调 body_self。
- 计划：你自己用 body_todo 维护的任务清单，多步任务先立计划再动手。
- 焦点窗口：buffer/mode/行范围/光标行/缩放；有选区时给出选中文字。
- 可见内容：首轮全量；同一 buffer 之后给相对上一轮的 diff（~改 +增，▸=光标行），没变就写「与上一轮相同」。
- 最近命令(新增)：自上一轮以来用户新敲的命令，是判断「用户刚干了什么」的唯一线索。
- 最近改动：可撤销改动的摘要。
- subagent / 共享记忆：子代理状态与它们最近汇报的结论。
不要复述这个块。用它理解「这里」「这段」「这个」「太小了」这类指代。

改造身体（elisp）：
- body_eval：在用户焦点窗口求值 elisp，改外观/布局/行为或执行动作。优先用 Doom/Emacs 原生方式（set-face-attribute、load-theme、text-scale、窗口函数等）。summary 用简短中文，undo_code 给倒退代码。
- body_undo：撤销上一次改动（elisp 和文件改动都在栈里）。

文件（通用 coding 能力）：
- body_read_file / body_write_file / body_edit_file：带行号读、覆盖写（自动备份）、唯一锚点精确替换。改用户项目代码就用这三个，别再用 body_eval 拼 write-region。
- body_grep：ripgrep 搜内容。
- body_shell：在用户目录跑命令，默认 30s 超时，危险模式会问用户。

感知与记忆：
- body_sense：看 buffer / 列 buffer / 只读求值查状态（输出有上限，长内容用 body_read_file）。
- body_read_prompt：按需读 memory/ 下的记忆文件（系统提示里只拼 main.md 全文 + 其它文件的索引）。
- body_remember：把可复用的结论追加进长期记忆（memory/main.md）。
- body_self / body_switch_model：查模型/网关、切换模型。
- body_keep：用户明确说「记住/以后也这样」时，把 elisp 改动永久写进基因。
- body_rewrite_self / body_edit_self：改自己的源码（模块化后可按模块改，见索引），带语法校验、备份、回滚。绝不要用 body_write_file 直接写 body/ 模块——那绕过校验和回滚。

主从（重要）：
- 你自己不干长活。耗时、可独立、要多次试错的事（批量改文件、跑测试、大范围调研、反复调试）用 body_spawn 派给子代理，然后回去跟用户说话。
- 子代理干完会 body_report 汇报，汇报会自动唤醒你（消息里会出现「【sub-1 汇报】…」）。那时再决定：追加指令用 body_send，收工用 body_close。
- 任何值得记的结论都可以 body_report 记一条进共享记忆，下一轮快照里你又能看到。
- 子代理看不到你的对话历史，派活时 task 必须自包含。

规则：
- 改用户正在编辑的 buffer 内容前先说明要改什么；外观和布局改动可以直接做（都能撤销）。
- 不要去动对话窗 *body* / *body-sub-N* 这类自己的会话 buffer。
- 用户消息可能带图片（截图），直接看图回答。
- 字号、主题、face、布局、缩放在 body_eval 前自动记录，撤销时自动恢复；undo_code 只需处理变量、minor mode 等。
- 「字体太小/太大」默认只改 default face 的 :height（每档 ±20），不要顺手改别的 face，除非用户点名。
- 不要在回复里写思考过程，直接调用工具，然后用一两句中文说结果。
- 互相独立的工具调用可以一轮里一次发完：body 会并行执行（省一轮往返）。有先后依赖的（先改、再验证）要分轮。
- 上下文快满时（状态里会显示百分比）body 会自动压缩历史；你自己别贴大段文件进对话。"
  "主脑的系统提示。")

(defvar body-sub-system-prompt
  "你是用户的 Doom Emacs 里的一个子代理（subagent），被主脑派来做一件具体的活。你能操作的就是这个正在运行的 Emacs。

做事方式：
- 直接干，不要问用户（用户看不到你的 buffer，也基本不会回答）。不确定就取合理默认，写进汇报。
- 看现状：body_sense（buffer/状态）或 body_read_file（带行号读文件）。
- 改东西：外观/布局用 body_eval；改文件内容用 body_edit_file（唯一锚点替换）/ body_write_file（整文件重写）——都自带备份和撤销。搜索用 body_grep，跑命令用 body_shell（30s 超时）。改动尽量小、可回滚。
- 多步任务先 body_todo 立个计划，干一步勾一步。
- 只做任务范围内的事，别顺手改用户的东西。

收尾（必须）：
- 干完、失败、或卡住时，必须调用 body_report 汇报：做了什么、结果/证据、改了哪里、下一步建议。summary 要能独立看懂——主脑只有这段文字。
- 不要 spawn 子代理；不要 kill 用户的 Emacs。"
  "子代理的系统提示。")


;;;; ------------------------------------------------------------------
;;;; 长期记忆（memory）
;;;; ------------------------------------------------------------------
;;
;; 目录：body-prompt-dir（默认 ~/.doom.d/memory/）
;; 规则（保持入口轻）：
;;   · main.md 是唯一全文拼进系统提示的文件——只放最重要的内容；
;;   · 其它文件不拼接，只在系统提示里给一行索引（相对路径 + 首个标题 + 大小）；
;;   · agent 需要时用 body_read_prompt 工具按需读取；
;;   · body_remember 默认追加到 main.md，内容多了再拆文件。

(defvar body-prompt-dir (expand-file-name "memory/" doom-user-dir)
  "长期记忆目录。入口文件见 `body-prompt-entry'，内容会拼进系统提示。")

(defvar body-prompt-entry "main.md"
  "入口文件名（相对 `body-prompt-dir'），唯一全文拼接的文件。")

(defvar body-prompt-read-cap 16000
  "body_read_prompt 单次返回的字符上限。")

(defun body--prompt-path (name)
  "NAME 相对 `body-prompt-dir' 的绝对路径。"
  (expand-file-name name body-prompt-dir))

(defun body--prompt-files ()
  "`body-prompt-dir' 下所有 md/txt/org 文件（含子目录），按路径排序。"
  (when (file-directory-p body-prompt-dir)
    (let ((acc '()))
      (cl-labels ((walk (dir)
                       (dolist (f (directory-files dir t "^[^.]"))
                         (cond ((file-directory-p f) (walk f))
                               ((member (file-name-extension f) '("md" "txt" "org"))
                                (push f acc))))))
        (walk body-prompt-dir))
      (sort acc #'string<))))

(defun body--prompt-first-heading (file)
  "FILE 的第一个 Markdown 标题（去掉 # 前缀）；没有就取首行前 40 字。"
  (condition-case nil
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (if (re-search-forward "^#+" nil t)
            (string-trim (buffer-substring-no-properties
                          (match-beginning 0) (line-end-position)))
          (truncate-string-to-width
           (string-trim (buffer-substring-no-properties
                         (point-min) (min 40 (point-max))))
           40 nil nil "…")))
    (error "?")))

(defun body--human-size (n)
  (cond ((null n) "?")
        ((>= n 1048576) (format "%.1fM" (/ n 1048576.0)))
        ((>= n 1024) (format "%.1fk" (/ n 1024.0)))
        (t (format "%dB" n))))

(defun body--prompt-index ()
  "除入口外的所有提示词文件的索引行。"
  (when-let* ((files (seq-remove
                      (lambda (f)
                        (equal (file-relative-name f body-prompt-dir)
                               body-prompt-entry))
                      (body--prompt-files))))
    (mapcar
     (lambda (f)
       (format "- %s — %s — %s"
               (file-relative-name f body-prompt-dir)
               (body--prompt-first-heading f)
               (body--human-size
                (file-attribute-size (file-attributes f)))))
     files)))

(defun body-preload-prompt ()
  "入口文件 main.md 的原文（不展开任何东西）；没有或为空返回 nil。"
  (let ((entry (body--prompt-path body-prompt-entry)))
    (when (file-readable-p entry)
      (let ((text (string-trim
                   (with-temp-buffer
                     (insert-file-contents entry)
                     (buffer-string)))))
        (unless (string-empty-p text) text)))))

(defun body--compose-system-prompt (role)
  "拼出最终系统提示：内置提示 + main.md 全文 + 其它提示词文件的索引。"
  (let ((base (if (eq role 'sub) body-sub-system-prompt body-system-prompt))
        (preload (body-preload-prompt))
        (index (body--prompt-index)))
    (cond
     ((and (null preload) (null index)) base)
     ((null preload)
      (concat base
              "\n\n## 用户记忆目录 " body-prompt-dir "\n"
              "（还没有 main.md，可让用户创建；下面是现有文件索引）\n"
              (string-join index "\n")))
     (t
      (concat base
              "\n\n## 用户维护的核心提示（" body-prompt-dir "main.md 全文）\n"
              "（改这个文件，下一条消息就生效）\n\n"
              preload
              (when index
                (concat "\n\n## 其它提示词/知识文件（不拼接，用 body_read_prompt 按需读）\n"
                        (string-join index "\n"))))))))

(defun body--system-prompt-dynamic ()
  "`gptel-system-prompt' 允许是函数：每次请求动态拼提示词。"
  (body--compose-system-prompt body--session-role))

;;;; 工具：按需读提示词文件

(gptel-make-tool
 :name "body_read_prompt"
 :category "body"
 :description "读 memory 目录下的一个记忆/提示词文件（如 main.md、xx.md）。系统提示里只拼了 main.md 和其它文件的索引；需要某个文件的具体内容时用这个工具。"
 :args '((:name "file" :type string
          :description "相对 memory 的路径，如 main.md"))
 :function
 (lambda (file)
   (let* ((rel (string-trim file))
          (f (body--prompt-path rel)))
     (cond
      ((not (file-in-directory-p f body-prompt-dir))
       (format "拒绝：%s 不在 memory 目录里。" rel))
      ((not (file-regular-p f))
       (format "没有这个文件: %s。现有文件：\n%s"
               rel (string-join (or (body--prompt-index) '("（空）")) "\n")))
      (t (let ((text (with-temp-buffer
                       (insert-file-contents f)
                       (buffer-string))))
           (if (> (length text) body-prompt-read-cap)
               (concat (substring text 0 body-prompt-read-cap) "\n…(截断)")
             text)))))))

;;;; 目录骨架与命令

(defun body-prompts-ensure ()
  "确保记忆目录和入口文件 main.md 存在（不再造 persona.md / knowledge/）。"
  (interactive)
  (make-directory body-prompt-dir t)
  (let ((entry (body--prompt-path body-prompt-entry)))
    (unless (file-exists-p entry)
      (with-temp-file entry
        (insert "# 长期记忆\n\n"
                "<!-- main.md 是唯一全文拼进系统提示的文件，只放最重要的内容；\n"
                "     其它文件只出现在索引里，agent 用 body_read_prompt 按需读取。 -->\n\n"
                "## 沟通偏好\n- 用中文，简短直接，不输出思考过程。\n"))))
  body-prompt-dir)

(defun body-prompts-open ()
  "打开记忆入口文件 main.md（首次调用会生成骨架）。"
  (interactive)
  (body-prompts-ensure)
  (find-file (body--prompt-path body-prompt-entry)))

(defun body-prompt-record (note &optional file)
  "把 NOTE 追加进记忆入口文件（默认 main.md），下一条消息即生效。"
  (interactive "s记录到提示词: ")
  (body-prompts-ensure)
  (let ((f (body--prompt-path (or file body-prompt-entry))))
    (make-directory (file-name-directory f) t)
    (with-temp-buffer
      (when (file-exists-p f) (insert-file-contents f))
      (goto-char (point-max))
      (unless (bolp) (insert "\n"))
      (insert (format "\n### %s\n%s\n" (format-time-string "%Y-%m-%d") note))
      (write-region (point-min) (point-max) f nil 'silent))
    (message "已记录到 %s" f)))

(provide 'body-prompt)
;;; body/prompt.el ends here
