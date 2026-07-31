;;; forge-plugins-log.el --- Error buffers for forge plugins -*- lexical-binding: t; -*-

;;; Code:

(require 'cl-lib)

(defun forge-plugins-log-buffer-name (plugin)
  "Return the error buffer name for PLUGIN."
  (format "*forge-plugins-%s-errors*" plugin))

(defun forge-plugins-log-error (plugin format-string &rest args)
  "Append a formatted error for PLUGIN to its dedicated buffer."
  (let ((buffer (get-buffer-create (forge-plugins-log-buffer-name plugin))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'special-mode)
        (special-mode))
      (let ((inhibit-read-only t))
        (goto-char (point-max))
        (insert (format-time-string "[%Y-%m-%d %H:%M:%S] "))
        (insert (apply #'format format-string args))
        (insert "\n")))))

(defun forge-plugins-log-error-message (error)
  "Return a readable message from a Ghub ERROR value."
  (or (and (stringp error) error)
      (and (listp error)
           (alist-get 'message
                      (cl-find-if (lambda (value)
                                    (and (listp value)
                                         (alist-get 'message value)))
                                  (reverse error))))
      (format "%S" error)))

;;;###autoload
(defun forge-plugins-log-show (plugin)
  "Pop to PLUGIN's error buffer."
  (interactive "sPlugin: ")
  (if-let ((buffer (get-buffer (forge-plugins-log-buffer-name plugin))))
      (pop-to-buffer buffer)
    (user-error "No errors logged for %s" plugin)))

(provide 'forge-plugins-log)
;;; forge-plugins-log.el ends here
