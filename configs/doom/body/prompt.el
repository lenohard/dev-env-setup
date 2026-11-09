;;; body/prompt.el --- 系统提示拼装：body-prompts 目录与动态注入  -*- lexical-binding: t; -*-
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
- 焦点窗口：buffer/mode/行范围/光标行/缩放；有选区时给出选中文字。
- 可见内容：首轮全量；同一 buffer 之后给相对上一轮的 diff（~改 +增，▸=光标行），没变就写「与上一轮相同」。
- 最近命令(新增)：自上一轮以来用户新敲的命令，是判断「用户刚干了什么」的唯一线索。
- 最近改动：可撤销改动的摘要。
- subagent / 共享记忆：子代理状态与它们最近汇报的结论。
不要复述这个块。用它理解「这里」「这段」「这个」「太小了」这类指代。

工具：
- body_eval：在用户焦点窗口求值 elisp，改外观/布局/行为或执行动作。几乎一切改动都走它。优先用 Doom/Emacs 原生方式（set-face-attribute、load-theme、text-scale、窗口函数等）。summary 用简短中文，undo_code 给倒退代码。
- body_sense：需要看更多时用（读 buffer、列 buffer、只读求值查状态）。
- body_undo：撤销上一次改动。
- body_self / body_switch_model：查模型/网关、切换模型。
- body_keep：用户明确说「记住/以后也这样」时，把改动永久写进基因。
- body_rewrite_self：给自己改源码。content 传完整 body.el 或 ::file::路径。绝不要用 body_eval 里的 write-region 直接写 body.el 或 config.el——那绕过语法校验，写坏了下次启动就崩。

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
- 互相独立的工具调用可以一轮里一次发完：body 会并行执行（省一轮往返）。有先后依赖的（先改、再验证）要分轮。"
  "主脑的系统提示。")

(defvar body-sub-system-prompt
  "你是用户的 Doom Emacs 里的一个子代理（subagent），被主脑派来做一件具体的活。你能操作的就是这个正在运行的 Emacs。

做事方式：
- 直接干，不要问用户（用户看不到你的 buffer，也基本不会回答）。不确定就取合理默认，写进汇报。
- 用 body_sense 看现状（读 buffer、列 buffer、只读求值），用 body_eval 改东西（外观/布局/文件内容/执行命令）。改动尽量小、可回滚，summary 写清做了什么。
- 只做任务范围内的事，别顺手改用户的东西。

收尾（必须）：
- 干完、失败、或卡住时，必须调用 body_report 汇报：做了什么、结果/证据、改了哪里、下一步建议。summary 要能独立看懂——主脑只有这段文字。
- 不要 spawn 子代理；不要 kill 用户的 Emacs。"
  "子代理的系统提示。")


;;;; ------------------------------------------------------------------
;;;; 预制提示词 / 长期知识（body-prompts）
;;;; ------------------------------------------------------------------
;;
;; 目录：body-prompt-dir（默认 ~/.doom.d/body-prompts/）
;; 入口：main.md，每次请求都拼在内置系统提示之后。
;; 入口里单独写一行 {{include: 文件名}} 或 {{include: knowledge/*.md}}，
;; 就能把偏好 / 知识 / 项目约定拆成小文件，入口本身永远不会膨胀。
;; 支持通配符和目录名；循环引用、超过 body-prompt-max-depth 的会被跳过并留注释。

(defvar body-prompt-dir (expand-file-name "body-prompts/" doom-user-dir)
  "预制提示词目录。入口文件见 `body-prompt-entry'，内容会拼进系统提示。")

(defvar body-prompt-entry "main.md"
  "入口文件名（相对 `body-prompt-dir'）。")

(defvar body-prompt-max-depth 6
  "{{include: ...}} 的最大嵌套层数。")

(defun body--prompt-path (name)
  "NAME 相对 `body-prompt-dir' 的绝对路径。"
  (expand-file-name name body-prompt-dir))

(defun body--prompt-include-spec (line)
  "LINE 形如 {{include: X}} 时返回 X，否则 nil。"
  (let ((line (string-trim line)))
    (when (and (> (length line) 12)
               (string-prefix-p "{{include:" line)
               (string-suffix-p "}}" line))
      (let ((spec (string-trim (substring line 10 (- (length line) 2)))))
        (unless (string-empty-p spec) spec)))))

(defun body--prompt-include-files (spec seen depth)
  "把 SPEC 展开成文本：SPEC 可以是文件、通配符或目录。
SEEN 是已展开文件的 truename 列表（防环），DEPTH 是当前层数（防深）。"
  (if (> depth body-prompt-max-depth)
      (format "<!-- include 层数超过 %d，已跳过: %s -->\n" body-prompt-max-depth spec)
    (let* ((base (body--prompt-path spec))
           (files (cond ((file-directory-p base)
                         (seq-filter (lambda (f)
                                       (and (file-regular-p f)
                                            (member (file-name-extension f)
                                                    '("md" "txt" "org"))))
                                     (sort (directory-files base t) #'string<)))
                        ((string-match-p "[*?]" spec)
                         (sort (file-expand-wildcards base) #'string<))
                        (t (list base)))))
      (mapconcat
       (lambda (f)
         (cond
          ((not (file-regular-p f))
           (format "<!-- include 找不到: %s -->\n" spec))
          ((member (file-truename f) seen)
           (format "<!-- include 循环引用，已跳过: %s -->\n" spec))
          (t
           (with-temp-buffer
             (insert-file-contents f)
             (body--prompt-expand-text (buffer-string)
                                       (cons (file-truename f) seen)
                                       (1+ depth))))))
       files "\n"))))

(defun body--prompt-expand-text (text seen depth)
  "把 TEXT 里所有 {{include: ...}} 行原地展开。"
  (with-temp-buffer
    (insert text)
    (goto-char (point-min))
    (while (not (eobp))
      (let* ((beg (line-beginning-position))
             (end (line-end-position))
             (spec (body--prompt-include-spec
                    (buffer-substring-no-properties beg end))))
        (if (not spec)
            (forward-line 1)
          (let ((replacement (body--prompt-include-files spec seen depth)))
            (delete-region beg end)
            (goto-char beg)
            (insert replacement)
            (goto-char (+ beg (length replacement)))
            (forward-line 1)))))
    (buffer-string)))

(defun body-preload-prompt ()
  "读取入口文件并展开 include；没有入口文件时返回 nil。"
  (let ((entry (body--prompt-path body-prompt-entry))
        (text nil))
    (when (file-readable-p entry)
      (setq text (string-trim
                  (with-temp-buffer
                    (insert-file-contents entry)
                    (body--prompt-expand-text
                     (buffer-string) (list (file-truename entry)) 0)))))
    (unless (or (null text) (string-empty-p text)) text)))

(defun body--compose-system-prompt (role)
  "拼出最终系统提示：内置提示 + 用户预制的提示词 / 长期知识。"
  (let ((base (if (eq role 'sub) body-sub-system-prompt body-system-prompt))
        (preload (body-preload-prompt)))
    (if preload
        (concat base
                "\n\n## 用户维护的预制提示词 / 长期知识\n"
                "（来自 " body-prompt-dir "，改里面的文件下一条消息就生效）\n\n"
                preload)
      base)))

(defun body--system-prompt-dynamic ()
  "`gptel-system-prompt' 允许是函数：每次请求动态拼提示词。"
  (body--compose-system-prompt body--session-role))

;;;; 目录骨架与命令

(defun body-prompts-ensure ()
  "确保预制提示词目录骨架存在（入口文件、persona.md、knowledge/）。"
  (interactive)
  (make-directory (body--prompt-path "knowledge") t)
  (let ((entry (body--prompt-path body-prompt-entry)))
    (unless (file-exists-p entry)
      (with-temp-file entry
        (insert "# 用户偏好与长期知识\n\n"
                "<!-- 每次请求都会拼进系统提示。按主题拆成小文件，用单独一行\n"
                "     {{include: persona.md}} 或 {{include: knowledge/*.md}} 引进来，\n"
                "     这样入口文件不会膨胀。 -->\n\n"
                "## 沟通偏好\n"
                "{{include: persona.md}}\n\n"
                "## 知识库\n"
                "{{include: knowledge/*.md}}\n"))))
  (let ((persona (body--prompt-path "persona.md")))
    (unless (file-exists-p persona)
      (with-temp-file persona
        (insert "# 沟通偏好\n\n- 用中文，简短直接，不输出思考过程。\n"))))
  (let ((notes (body--prompt-path "knowledge/notes.md")))
    (unless (file-exists-p notes)
      (with-temp-file notes
        (insert "# notes\n\n一条结论一行，附上路径或证据。\n"))))
  body-prompt-dir)

(defun body-prompts-open ()
  "打开预制提示词入口文件（首次调用会生成骨架）。"
  (interactive)
  (body-prompts-ensure)
  (find-file (body--prompt-path body-prompt-entry)))

(defun body-prompt-record (note &optional file)
  "把 NOTE 追加进知识文件（默认 knowledge/notes.md），下一条消息即生效。"
  (interactive "s记录到提示词: ")
  (body-prompts-ensure)
  (let ((f (body--prompt-path (or file "knowledge/notes.md"))))
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
