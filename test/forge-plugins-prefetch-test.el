;;; forge-plugins-prefetch-test.el --- Tests for forge-plugins-prefetch  -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'gsexp)
(require 'forge-plugins)

(ert-deftest forge-plugins-prefetch-test-query-encodes ()
  (let ((forge-plugins-github-actions-enable t)
        (forge-plugins-pullreq-approvals-enable t)
        (forge-plugins-github-reviews-enable t)
        (forge-plugins-github-teams-enable t))
    (dolist (var forge-plugins-prefetch--query-vars)
      (when (boundp var)
        (let ((q (gsexp-encode
                  (ghub--graphql-prepare-query
                   (cons 'query (forge-plugins-prefetch--fragment (symbol-value var)))))))
          (dolist (field '("statusCheckRollup" "reviewThreads" "teamReviewRequests"))
            (should (string-match-p field q))))))))

(ert-deftest forge-plugins-prefetch-test-disabled-is-identity ()
  (let ((forge-plugins-prefetch--providers
         '((x nil-flag ((foo)) ignore))))
    (defvar nil-flag nil)
    (dolist (var forge-plugins-prefetch--query-vars)
      (when (boundp var)
        (should (eq (forge-plugins-prefetch--fragment (symbol-value var))
                    (symbol-value var)))))))

;;; forge-plugins-prefetch-test.el ends here
