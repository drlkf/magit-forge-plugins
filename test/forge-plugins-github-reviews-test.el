;;; forge-plugins-github-reviews-test.el --- Tests for GitHub reviews  -*- lexical-binding: t; -*-

(require 'ert)
(require 'forge-pullreq)
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
  "Keep decision reviews without bodies while dropping empty comments."
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
                                                                   (state . "APPROVED"))
                                                                  ((id . "review-3")
                                                                   (author . ((login . "carol")))
                                                                   (body . "")
                                                                   (state . "COMMENTED"))))))))))))
         (parsed (forge-plugins-github-reviews--parse data)))
    (should (= 0 (plist-get parsed :unresolved)))
    (should (= 2 (length (plist-get parsed :reviews))))
    (should (equal "Looks good"
                   (plist-get (car (plist-get parsed :reviews)) :body)))))

(ert-deftest forge-plugins-github-reviews-test-refresh-status-buffer ()
  "Refreshing a status buffer invalidates every displayed pull request."
  (let ((forge-plugins-github-reviews--cache (make-hash-table :test 'equal))
        (t1 (forge-pullreq :id "T1" :head-rev "a"))
        (t2 (forge-pullreq :id "T2" :head-rev "b"))
        (refreshed nil))
    (puthash "T1" '(:head-rev "a" :unresolved 1) forge-plugins-github-reviews--cache)
    (puthash "T2" '(:head-rev "b" :unresolved 2) forge-plugins-github-reviews--cache)
    (with-temp-buffer
      (setq-local major-mode 'magit-status-mode)
      (let ((root (magit-section :type 'root))
            (s1 (magit-section :type 'topic))
            (s2 (magit-section :type 'topic)))
        (oset s1 value t1)
        (oset s2 value t2)
        (oset root children (list s1 s2))
        (setq-local magit-root-section root)
        (cl-letf (((symbol-function 'forge-plugins-github-reviews--target-p)
                   #'forge-pullreq-p)
                  ((symbol-function 'magit-refresh-buffer)
                   (lambda () (setq refreshed t))))
          (forge-plugins-github-reviews-refresh))))
    (should refreshed)
    (should (= 0 (hash-table-count forge-plugins-github-reviews--cache)))))

;;; forge-plugins-github-reviews-test.el ends here
