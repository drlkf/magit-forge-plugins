;;; forge-plugins-github-reviews-test.el --- Tests for GitHub reviews  -*- lexical-binding: t; -*-

(require 'ert)
(require 'forge-plugins-github-reviews)

(ert-deftest forge-plugins-github-reviews-test-refresh-skips-active-minibuffer ()
  "Do not refresh topic buffers while a minibuffer is active."
  (let ((buffer (generate-new-buffer " *forge-plugins-reviews-test*"))
        (refreshed nil))
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (setq major-mode 'forge-pullreq-mode))
          (cl-letf (((symbol-function 'active-minibuffer-window)
                     (lambda () t))
                    ((symbol-function 'magit-refresh-buffer)
                     (lambda () (setq refreshed t))))
            (forge-plugins-github-reviews--refresh-buffers))
          (should-not refreshed))
      (kill-buffer buffer))))

(ert-deftest forge-plugins-github-reviews-test-parse-review-bodies ()
  "Parse review bodies while dropping reviews without a body."
  (let* ((data '((repository . ((pullRequest .
                                             ((reviewThreads . ((nodes . nil)))
                                              (reviews . ((nodes .
                                                                 (((id . "review-1")
                                                                   (author . ((login . "alice")))
                                                                   (body . "Looks good")
                                                                   (state . "APPROVED")
                                                                   (url . "https://example/review"))
                                                                  ((id . "review-2")
                                                                   (author . ((login . "bob")))
                                                                   (body . "")
                                                                   (state . "APPROVED"))))))))))))
         (parsed (forge-plugins-github-reviews--parse data)))
    (should (= 0 (plist-get parsed :unresolved)))
    (should (= 1 (length (plist-get parsed :reviews))))
    (should (equal "Looks good"
                   (plist-get (car (plist-get parsed :reviews)) :body)))))

;;; forge-plugins-github-reviews-test.el ends here
