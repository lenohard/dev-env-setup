;;; body/parallel.el --- 并行工具调用调度（拆 gptel 工具串行）  -*- lexical-binding: t; -*-
;; body 的一个模块，由 body.el 统一 load，别单独加载。

(require 'gptel)
(require 'cl-lib)
(require 'seq)
(require 'subr-x)

;;;; ------------------------------------------------------------------
;;;; 并行工具调用
;;;; ------------------------------------------------------------------
;;
;; 模型一轮里可能一次返回多个 tool call。gptel 默认串行执行，耗时相加。
;; 这里把同一轮的工具分两路：
;;   · body--ptools-sync-names 里的（纯 elisp、毫秒级、顺序敏感）：主线程顺序执行；
;;   · 其余（会弹确认、起进程、写文件）：每个起一个线程并行。
;; 结果按原 tool-call 顺序回填，并且只从主线程交回 gptel，
;; 所以 assistant 的 tool_calls 与随后的 tool 结果仍一一对应，历史始终合法。

(defvar body-parallel-tools t
  "非 nil 时，同一轮里的多个工具调用并行执行。")

(defvar body--ptools-sync-names
  '(body_sense body_undo body_status body_self body_switch_model
    body_todo body_remember body_read_prompt body_read_file
    body_write_file body_edit_file body_edit_self body_eval)
  "这些工具在主线程顺序执行：要么毫秒级、要么顺序敏感，
要么像 body_eval 需要在主线程上弹 minibuffer 问权限
（子线程里 body--maybe-ask 只能跳过询问直接放行，不安全）。")

(defvar body--ptools-timeout 60
  "等线程结果的最长秒数；超时按报错回填，别把对话卡死。")

(defun body--ptools-async-p (spec)
  "SPEC 本身是不是 gptel 的异步工具（那种交给 gptel 自己处理）。"
  (and (fboundp 'gptel-tool-async) (gptel-tool-async spec)))

(defun body--ptools-name-sym (spec)
  (intern (gptel-tool-name spec)))

(defun body--ptools-call (item)
  "跑一个工具调用（可能在子线程里），结果写进它的 BOX。"
  (let* ((spec (nth 0 item))
         (args (nth 1 item))
         (box (nth 3 item))
         (result (condition-case err
                     (apply (gptel-tool-function spec)
                            (gptel--map-tool-args spec args))
                   (error (mapconcat #'gptel--to-string err " ")))))
    (setcar box result)
    (setcdr box t)))

(defun body--ptools-deliver (items)
  "按原顺序把 BOX 里的结果交给 gptel（只在主线程调用）。"
  (dolist (it (sort (copy-sequence items)
                    (lambda (a b) (< (nth 2 a) (nth 2 b)))))
    (funcall (nth 4 it) (car (nth 3 it)))))

(defun body--ptools-finish (items server start timer)
  "所有线程写完后一次性交付；从定时器里跑（主线程）。"
  (cond
   ((seq-every-p (lambda (it) (cdr (nth 3 it))) items)
    (when (timerp timer) (cancel-timer timer))
    (when (process-live-p server) (delete-process server))
    (body--ptools-deliver items)
    (message "并行工具完成（%d 个）" (length items)))
   ((> (- (float-time) start) body--ptools-timeout)
    (when (timerp timer) (cancel-timer timer))
    (dolist (it items)
      (unless (cdr (nth 3 it))
        (setcar (nth 3 it) "工具超时，未返回结果")
        (setcdr (nth 3 it) t)))
    (when (process-live-p server) (delete-process server))
    (body--ptools-deliver items)
    (message "并行工具超时（%d 个）" (length items)))
   (t
    (accept-process-output server 0.02))))

(defun body--ptools-run (fn tool-calls &rest args)
  "把 TOOL-CALLS 并行化执行后再走 gptel 的交付路径。"
  (if (or (null body-parallel-tools)
          (null (cdr tool-calls))
          (seq-some (lambda (call) (body--ptools-async-p (car call))) tool-calls)
          (not (fboundp 'make-thread)))
      (apply fn tool-calls args)
    (let* ((items (cl-loop for (spec arg-plist proc) in tool-calls
                           for i from 0
                           collect (list spec arg-plist i (cons nil nil) proc)))
           (threads '())
           (start (float-time)))
      (dolist (it items)
        (when (memq (body--ptools-name-sym (nth 0 it)) body--ptools-sync-names)
          (body--ptools-call it)))
      (dolist (it items)
        (unless (memq (body--ptools-name-sym (nth 0 it)) body--ptools-sync-names)
          (push (make-thread (lambda () (body--ptools-call it))
                             (format "body-tool:%s"
                                     (gptel-tool-name (nth 0 it))))
                threads)))
      (if (null threads)
          (progn (body--ptools-deliver items)
                 (message "工具完成（%d 个，主线程）" (length items)))
        (let ((server (make-pipe-process :name "body-parallel-tools" :noquery t))
              (timer nil))
          (setq timer (run-at-time 0.01 0.02
                                   (lambda ()
                                     (body--ptools-finish items server start timer))))
          (message "并行执行 %d 个工具…" (length threads))))
      nil)))

(unless (advice-member-p #'body--ptools-run 'gptel--accept-tool-calls)
  (advice-add 'gptel--accept-tool-calls :around #'body--ptools-run))

(provide 'body-parallel)
;;; body/parallel.el ends here
