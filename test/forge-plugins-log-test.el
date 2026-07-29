;;; forge-plugins-log-test.el --- Tests for plugin error logging -*- lexical-binding: t; -*-

(require 'ert)
(require 'forge-plugins-log)

(ert-deftest forge-plugins-log-test-appends-errors-to-plugin-buffer ()
  "Errors are appended to the dedicated plugin buffer."
  (let ((buffer-name (forge-plugins-log-buffer-name "test")))
    (unwind-protect
        (progn
          (when-let ((buffer (get-buffer buffer-name)))
            (kill-buffer buffer))
          (forge-plugins-log-error "test" "first: %s" "failure")
          (forge-plugins-log-error "test" "second")
          (with-current-buffer buffer-name
            (should (string-match-p "first: failure" (buffer-string)))
            (should (string-match-p "second" (buffer-string)))))
      (when-let ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest forge-plugins-log-test-show-errors-requires-existing-buffer ()
  "Showing errors signals when the plugin has no error buffer."
  (let ((buffer-name (forge-plugins-log-buffer-name "missing")))
    (when-let ((buffer (get-buffer buffer-name)))
      (kill-buffer buffer))
    (should-error (forge-plugins-log-show "missing") :type 'user-error)))

(provide 'forge-plugins-log-test)
;;; forge-plugins-log-test.el ends here
