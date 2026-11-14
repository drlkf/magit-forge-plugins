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

(ert-deftest forge-plugins-prefetch-test-batch ()
  (let* ((forge-plugins-prefetch--providers nil)
         (forge-plugins-prefetch-batch-size 2)
         (repo 'repo)
         (topics (mapcar (lambda (n) (cons repo n)) '(1 2 3)))
         queries consumed batches)
    (forge-plugins-prefetch-register
     'x 'ignore '((foo [(first 5)] bar))
     (lambda (_repo data) (push (alist-get 'number data) consumed)))
    (cl-letf (((symbol-function 'forge-get-repository) #'car)
              ((symbol-function 'eieio-oref)
               (lambda (obj slot) (if (eq slot 'number) (cdr obj) (symbol-name slot))))
              ((symbol-function 'forge--query)
               (lambda (_repo query _vars &rest args)
                 (push query queries)
                 (funcall (plist-get args :callback)
                          `((repository
                             ,@(mapcar (lambda (f)
                                         (list (intern (caar f))
                                               (cons 'number (cadr (aref (cadr f) 0)))))
                                       (cddr (cadr query)))))))))
      (forge-plugins-prefetch-batch 'x topics (lambda (b) (push b batches))))
    (should (= (length queries) 2))
    (should (equal (sort consumed #'<) '(1 2 3)))
    (should (equal (mapcar #'length (reverse batches)) '(2 1)))
    (should (string-match-p "pr_1: pullRequest (number: 1)"
                            (gsexp-encode (ghub--graphql-prepare-query (car (last queries))))))))

;;; forge-plugins-prefetch-test.el ends here
