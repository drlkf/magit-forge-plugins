;;; forge-plugins-topic-kill-test.el --- Tests for topic kill -*- lexical-binding: t; -*-

(require 'ert)
(require 'forge)
(require 'forge-plugins-topic-kill)

(ert-deftest forge-plugins-topic-kill-test-kills-only-topics ()
  "Quitting kills topic buffers and leaves other magit buffers alone."
  (let (seen)
    (unwind-protect
        (cl-letf (((symbol-function 'magit-mode-quit-window)
                   (lambda (kill) (push kill seen))))
          (forge-plugins-topic-kill-enable)
          (let ((magit-bury-buffer-function #'magit-mode-quit-window))
            (with-temp-buffer
              (forge-topic-mode)
              (magit-mode-bury-buffer))
            (with-temp-buffer
              (magit-mode)
              (magit-mode-bury-buffer)))
          (should (equal seen '(nil t))))
      (forge-plugins-topic-kill-disable))))

(provide 'forge-plugins-topic-kill-test)
;;; forge-plugins-topic-kill-test.el ends here
