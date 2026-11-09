;;; body/self.el --- 本体工具：自我信息、改写自身、永久基因  -*- lexical-binding: t; -*-
;; body 的一个模块，由 body.el 统一 load，别单独加载。

(require 'gptel)
(require 'cl-lib)
(require 'seq)
(require 'subr-x)

;;;; ------------------------------------------------------------------
;;;; 工具：本体信息（我是谁、跑在什么模型上、怎么切）
;;;; ------------------------------------------------------------------

(defun body--self-info ()
  "返回一串描述「我是谁」的本体信息。"
  (let* ((model (or body-model gptel-model))
         (backend gptel-backend))
    (string-join
     (list
      (format "当前模型: %s" model)
      (format "网关(backend): %s  @ %s://%s"
              (gptel-backend-name backend)
              (or (gptel-backend-protocol backend) "https")
              (gptel-backend-host backend))
      "这个网关是用户本机的 magpie——一个聚合多个上游服务商的本地代理，OpenAI 协议。"
      "group/开头的是路由组，会在多个账号/上游间自动 fallback；其余是指定上游。"
      (format "可用模型(%d 个): %s"
              (length (gptel-backend-models backend))
              (string-join (mapcar (lambda (m) (format "%s" m))
                                   (gptel-backend-models backend)) " ")))
     "\n")))

(gptel-make-tool
 :name "body_self"
 :category "body"
 :description "查自己的本体信息：我现在是哪个模型、通过哪个网关(magpie)调用、有哪些可切换的模型。用户问「你是什么模型/你怎么跑的/有哪些模型」时调用。"
 :args nil
 :function #'body--self-info)

(gptel-make-tool
 :name "body_switch_model"
 :category "body"
 :description "切换我自己用的模型（所有身体会话生效）。model 必须是 body_self 列出的可用模型之一，例如 group/glm-5.3、qwen-cn/qwen3.8-max。切换在下一条回复生效。用户说「换成 XX 模型/用更强的模型」时调用。"
 :args '((:name "model" :type string :description "目标模型名，如 group/glm-5.3"))
 :function
 (lambda (model)
   (let ((avail (mapcar (lambda (m) (format "%s" m))
                        (gptel-backend-models gptel-backend))))
     (if (not (member model avail))
         (format "拒绝：%s 不在可用模型列表里。可用：%s"
                 model (string-join avail " "))
       (setq body-model (intern model))
       (dolist (b (body--sessions))
         (with-current-buffer b (setq-local gptel-model body-model)))
       (format "已切换到 %s（下一条回复生效）" model)))))

;;;; ------------------------------------------------------------------
;;;; 工具：永久保留（写进基因）
;;;; ------------------------------------------------------------------

(defun body--elisp-valid-p (text)
  "检查 TEXT 是否是语法完整、可读取的 elisp。返回 (t) 或 (nil . 错误说明)。
不求值，只做结构扫描：用 forward-sexp 走完整个文本，必须正好停在末尾。"
  (condition-case err
      (with-temp-buffer
        (insert text)
        (set-syntax-table emacs-lisp-mode-syntax-table)
        (setq-local parse-sexp-ignore-comments t)
        (goto-char (point-min))
        (let ((ok t) (forms 0))
          (condition-case nil
              (while (not (eobp))
                (skip-chars-forward " \t\n\r\f")
                (unless (eobp)
                  (forward-sexp 1)
                  (setq forms (1+ forms))))
            (error (setq ok nil)))
          (cond ((not ok) (cons nil "括号或字符串不配平"))
                ((not (eobp)) (cons nil "没走到文本末尾"))
                ((zerop forms) (cons nil "没有可读取的 form"))
                (t (list t)))))
    (error (cons nil (error-message-string err)))))

(gptel-make-tool
 :name "body_keep"
 :category "body"
 :description "把一段改动永久保留：追加到 body-genes.el，下次启动自动生效。只在用户明确说「记住/保留/下次也这样」时调用。code 必须是幂等的（重复加载不出错），依赖包的代码用 (after! PKG ...) 包裹，字体主题用 setq doom-font/doom-theme。写入前会校验语法，不过则拒绝。"
 :args '((:name "code" :type string :description "要永久保留的 elisp")
         (:name "note" :type string :description "一句话中文注释说明这条基因做什么"))
 :function
 (lambda (code note)
   (let ((chk (body--elisp-valid-p code)))
     (if (not (car chk))
         (format "拒绝写入：这段 code 语法不完整（%s）。请修正后重试。" (cdr chk))
       (condition-case err
           (let* ((old (when (file-exists-p body-genes-file)
                         (with-temp-buffer (insert-file-contents body-genes-file)
                                           (buffer-string))))
                  (new (concat (or old "") (if (and old (not (string-suffix-p "\n" old))) "\n" "")
                               (format "\n;; %s  (%s)\n%s\n"
                                       note (format-time-string "%Y-%m-%d") code)))
                  (full-chk (body--elisp-valid-p new)))
             (if (not (car full-chk))
                 (format "拒绝写入：追加后整个基因文件语法不合法（%s）。未改动。" (cdr full-chk))
               ;; 先备份旧文件，再原子写入
               (when old
                 (copy-file body-genes-file
                            (format "%s.bak-%s" body-genes-file
                                    (format-time-string "%Y%m%d-%H%M%S"))
                            t))
               (with-temp-buffer
                 (insert new)
                 (write-region (point-min) (point-max) body-genes-file))
               (format "已写入基因: %s（已校验语法，旧文件已备份）" note)))
         (error (format "写入失败: %s" (error-message-string err))))))))

(gptel-make-tool
 :name "body_rewrite_self"
 :category "body"
 :description "改写身体自身的源文件 body.el（给自己长新器官/改现有实现）。content 是 body.el 的完整新内容，也可以写 ::file::/绝对路径 表示从该文件读。写入前做结构扫描校验，不过则拒绝；自动备份旧文件并试 load，load 报错就回滚。"
 :args '((:name "content" :type string :description "body.el 的完整新内容")
         (:name "note" :type string :description "一句话中文说明这次改了什么"))
 :confirm nil
 :function
 (lambda (content note)
   (let* ((content (body--content-arg content))
          (chk (body--elisp-valid-p content)))
     (if (not (car chk))
         (format "拒绝：新 body.el 语法不合法（%s）。未改动。" (cdr chk))
       (condition-case err
           (let ((bak (format "%s.bak-%s" body-self-file
                              (format-time-string "%Y%m%d-%H%M%S"))))
             (when (file-exists-p body-self-file)
               (copy-file body-self-file bak t))
             (with-temp-buffer
               (insert content)
               (write-region (point-min) (point-max) body-self-file))
             ;; 试 load；失败就回滚
             (condition-case lerr
                 (progn (load body-self-file nil t)
                        (format "已改写 body.el：%s（语法+加载均通过，旧版备份 %s）"
                                note (abbreviate-file-name bak)))
               (error
                (when (file-exists-p bak) (copy-file bak body-self-file t)
                      (ignore-errors (load body-self-file nil t)))
                (format "已回滚：新 body.el 加载时报错（%s），已恢复旧版。"
                        (error-message-string lerr)))))
         (error (format "写入失败: %s" (error-message-string err))))))))

;;;; ------------------------------------------------------------------
;;;; 基因加载（启动时）
;;;; ------------------------------------------------------------------

(defun body-load-genes ()
  "逐条加载 body-genes.el，单条出错不影响其它。
整个文件若语法损坏（括号不配），整体跳过并提示，绝不让启动崩溃。"
  (when (file-exists-p body-genes-file)
    (let ((text (with-temp-buffer (insert-file-contents body-genes-file)
                                  (buffer-string))))
      ;; 先整体校验；若不合法就整体不加载，避免 read 到一半把后续都卡死。
      (if (not (car (body--elisp-valid-p text)))
          (message "body基因：%s 语法损坏，整体跳过本次加载（请修复或从 .bak 恢复）"
                   (abbreviate-file-name body-genes-file))
        (with-temp-buffer
          (insert text)
        (set-syntax-table emacs-lisp-mode-syntax-table)
          (goto-char (point-min))
          (condition-case nil
              (while t
                (let ((form (read (current-buffer))))
                  (condition-case err
                      (eval form t)
                    (error (message "body基因加载出错（已跳过该条）: %s"
                                    (error-message-string err))))))
            (end-of-file nil)))))))

(provide 'body-self)
;;; body/self.el ends here
