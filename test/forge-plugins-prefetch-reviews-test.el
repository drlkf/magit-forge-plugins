;;; forge-plugins-prefetch-reviews-test.el --- Prefetch consumers tests  -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'forge)
(require 'forge-plugins-pullreq-approvals)
(require 'forge-plugins-github-reviews)

(defun forge-plugins-prefetch-reviews-test--pr (more-reviews more-threads)
  `((number . 7) (headRefOid . "abc")
    (reviews
     (pageInfo (hasNextPage . ,more-reviews))
     (nodes ((id . "R1") (databaseId . 11) (state . "APPROVED")
             (submittedAt . "t1") (author (login . "alice"))
             (commit (oid . "abc")) (body . "lgtm") (url . "u1"))
            ((id . "R2") (databaseId . 12) (state . "CHANGES_REQUESTED")
             (submittedAt . "t2") (author (login . "bob"))
             (commit (oid . "abc")) (body . "") (url . "u2"))))
    (reviewThreads
     (pageInfo (hasNextPage . nil))
     (nodes ((id . "T1") (isResolved . nil) (isOutdated . nil)
             (path . "a.el") (line . 3)
             (comments (pageInfo (hasNextPage . ,more-threads))
                       (nodes ((id . "C1") (author (login . "bob")) (body . "hm")
                               (url . "cu") (viewerDidAuthor . t)))))))))

(ert-deftest forge-plugins-prefetch-reviews-test-approvals ()
  (let ((forge-plugins-pullreq-approvals--prefetched (make-hash-table :test 'equal))
        (forge-plugins-pullreq-approvals--cache (make-hash-table :test 'equal)))
    (cl-letf (((symbol-function 'forge--object-id) (lambda (&rest _) "ID")))
      (forge-plugins-pullreq-approvals--prefetch
       nil (forge-plugins-prefetch-reviews-test--pr nil nil))
      (should (equal (gethash "ID" forge-plugins-pullreq-approvals--prefetched)
                     '("abc"
                       ((id . 11) (state . "APPROVED") (submitted_at . "t1")
                        (commit_id . "abc") (user (login . "alice")))
                       ((id . 12) (state . "CHANGES_REQUESTED")
                        (submitted_at . "t2") (commit_id . "abc")
                        (user (login . "bob"))))))
      (should (equal (forge-plugins-pullreq-approvals--count-approved
                      (cdr (gethash "ID" forge-plugins-pullreq-approvals--prefetched)))
                     '(1 ("alice" . "APPROVED") ("bob" . "CHANGES_REQUESTED"))))
      (clrhash forge-plugins-pullreq-approvals--prefetched)
      (forge-plugins-pullreq-approvals--prefetch
       nil (forge-plugins-prefetch-reviews-test--pr t nil))
      (should-not (gethash "ID" forge-plugins-pullreq-approvals--prefetched)))))

(ert-deftest forge-plugins-prefetch-reviews-test-github-reviews ()
  (let ((forge-plugins-github-reviews--cache (make-hash-table :test 'equal)))
    (cl-letf (((symbol-function 'forge--object-id) (lambda (&rest _) "ID")))
      (forge-plugins-github-reviews--prefetch
       nil (forge-plugins-prefetch-reviews-test--pr nil nil))
      (should (equal (gethash "ID" forge-plugins-github-reviews--cache)
                     '(:head-rev "abc"
                       :threads ((:id "T1" :resolved nil :outdated nil
                                  :path "a.el" :line 3
                                  :comments ((:id "C1" :login "bob" :body "hm"
                                              :url "cu" :viewer t))))
                       :unresolved 1
                       :reviews ((:id "R1" :login "alice" :body "lgtm"
                                  :state "APPROVED" :url "u1")
                                 (:id "R2" :login "bob" :body ""
                                  :state "CHANGES_REQUESTED" :url "u2"))
                       :fetching nil)))
      (clrhash forge-plugins-github-reviews--cache)
      (forge-plugins-github-reviews--prefetch
       nil (forge-plugins-prefetch-reviews-test--pr nil t))
      (should-not (gethash "ID" forge-plugins-github-reviews--cache))
      (forge-plugins-github-reviews--prefetch
       nil (forge-plugins-prefetch-reviews-test--pr t nil))
      (should-not (gethash "ID" forge-plugins-github-reviews--cache)))))

(provide 'forge-plugins-prefetch-reviews-test)
;;; forge-plugins-prefetch-reviews-test.el ends here
