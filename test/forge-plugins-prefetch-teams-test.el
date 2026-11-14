;;; forge-plugins-prefetch-teams-test.el --- Tests for team prefetch -*- lexical-binding: t; -*-

(require 'ert)
(require 'forge-plugins-github-teams)

(defun forge-plugins-prefetch-teams-test--data (next)
  `((number . 7)
    (teamReviewRequests
     (pageInfo (hasNextPage . ,next))
     (nodes ((requestedReviewer))
            ((requestedReviewer (slug . "backend") (name . "Backend")))))))

(ert-deftest forge-plugins-prefetch-teams-test-fills-cache ()
  "Team nodes land in the requests cache; user nodes are skipped."
  (let ((forge-plugins-github-teams--requests (make-hash-table :test #'equal)))
    (cl-letf (((symbol-function 'forge--object-id) (lambda (&rest _) "id7")))
      (forge-plugins-github-teams--prefetch
       nil (forge-plugins-prefetch-teams-test--data :false))
      (should (equal (plist-get (gethash "id7" forge-plugins-github-teams--requests)
                                :teams)
                     '(((slug . "backend") (name . "Backend"))))))))

(ert-deftest forge-plugins-prefetch-teams-test-next-page-not-cached ()
  "An incomplete page must not be cached."
  (let ((forge-plugins-github-teams--requests (make-hash-table :test #'equal)))
    (cl-letf (((symbol-function 'forge--object-id) (lambda (&rest _) "id7")))
      (forge-plugins-github-teams--prefetch
       nil (forge-plugins-prefetch-teams-test--data t))
      (should-not (gethash "id7" forge-plugins-github-teams--requests)))))

(ert-deftest forge-plugins-prefetch-teams-test-registered ()
  (should (assq 'github-teams forge-plugins-prefetch--providers)))

;;; forge-plugins-prefetch-teams-test.el ends here
