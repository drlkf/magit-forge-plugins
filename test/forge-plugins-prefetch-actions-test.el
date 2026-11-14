;;; forge-plugins-prefetch-actions-test.el --- Tests for GitHub Actions prefetch  -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'forge-plugins-github-actions)

(defun forge-plugins-prefetch-actions-test--data (&optional next oid)
  (let ((node (lambda (name status conclusion)
                `((name . ,name) (status . ,status) (conclusion . ,conclusion)
                  (detailsUrl . "https://github.com/o/r/actions/runs/1/job/2")
                  (databaseId . 2)
                  (startedAt . "2026-01-01T00:00:00Z")
                  (completedAt . nil)))))
    `((number . 7)
      (headRefOid . "abc")
      (commits
       (nodes
        ((commit
          (oid . ,(or oid "abc"))
          (statusCheckRollup
           (contexts
            (pageInfo (hasNextPage . ,next))
            (nodes ,(funcall node "build" "COMPLETED" "SUCCESS")
                   ,(funcall node "lint" "COMPLETED" "FAILURE")
                   ,(funcall node "docs" "COMPLETED" "SKIPPED")
                   ,(funcall node "e2e" "IN_PROGRESS" nil)
                   ((__typename . "StatusContext"))))))))))))

(defun forge-plugins-prefetch-actions-test--run (data)
  (clrhash forge-plugins-github-actions--cache)
  (cl-letf (((symbol-function 'forge--object-id)
             (lambda (_class _repo number) (format "id-%s" number))))
    (forge-plugins-github-actions--prefetch nil data))
  (gethash "id-7" forge-plugins-github-actions--cache))

(ert-deftest forge-plugins-prefetch-actions-test-consumer-fills-cache ()
  (let ((c (forge-plugins-prefetch-actions-test--run
            (forge-plugins-prefetch-actions-test--data))))
    (should (equal (plist-get c :head-rev) "abc"))
    (should (equal (list (plist-get c :total) (plist-get c :success)
                         (plist-get c :failure) (plist-get c :skipped)
                         (plist-get c :completed))
                   '(4 1 1 1 3)))
    (should (equal (car (plist-get c :runs))
                   '((name . "build") (status . "completed")
                     (conclusion . "success")
                     (html_url . "https://github.com/o/r/actions/runs/1/job/2")
                     (details_url . "https://github.com/o/r/actions/runs/1/job/2")
                     (id . 2) (started_at . "2026-01-01T00:00:00Z")
                     (completed_at))))))

(ert-deftest forge-plugins-prefetch-actions-test-consumer-skips-truncated ()
  (should-not (forge-plugins-prefetch-actions-test--run
               (forge-plugins-prefetch-actions-test--data t))))

(ert-deftest forge-plugins-prefetch-actions-test-consumer-skips-stale-head ()
  (should-not (forge-plugins-prefetch-actions-test--run
               (forge-plugins-prefetch-actions-test--data nil "old"))))

(ert-deftest forge-plugins-prefetch-actions-test-fragment-includes-fields ()
  (let ((base '((pullRequests [(first 1)] number)))
        (enabled forge-plugins-github-actions-enable))
    (unwind-protect
        (progn
          (setq forge-plugins-github-actions-enable t)
          (should (member (car forge-plugins-github-actions--prefetch-fields)
                          (cdddr (car (forge-plugins-prefetch--fragment base)))))
          (setq forge-plugins-github-actions-enable nil)
          (should-not (member (car forge-plugins-github-actions--prefetch-fields)
                              (cdddr (car (forge-plugins-prefetch--fragment base))))))
      (setq forge-plugins-github-actions-enable enabled))))

;;; forge-plugins-prefetch-actions-test.el ends here
