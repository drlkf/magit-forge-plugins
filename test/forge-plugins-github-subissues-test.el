;;; forge-plugins-github-subissues-test.el --- Tests for GitHub sub-issues -*- lexical-binding: t; -*-
(require 'ert)
(require 'forge-plugins-github-subissues)

(ert-deftest forge-plugins-github-subissues-test-tree-order ()
  (let* ((parent (make-instance 'forge-issue :id 1 :number 1))
         (child (make-instance 'forge-issue :id 2 :number 2))
         (grandchild (make-instance 'forge-issue :id 3 :number 3))
         (result (forge-plugins-github-subissues--tree-order
                  (list child parent grandchild)
                  (let ((table (make-hash-table :test #'eql)))
                    (puthash 2 1 table) (puthash 3 2 table) table))))
    (should (equal (mapcar (lambda (x) (oref x number)) (car result)) '(1 2 3)))
    (should (= (gethash 1 (cadr result)) 0))
    (should (= (gethash 2 (cadr result)) 1))
    (should (= (gethash 3 (cadr result)) 2))))

(ert-deftest forge-plugins-github-subissues-test-disabled-by-default ()
  (should-not forge-plugins-github-subissues-enable))

(ert-deftest forge-plugins-github-subissues-test-insert-without-depths ()
  (let ((forge-plugins-github-subissues--depths nil)
        (topic (make-instance 'forge-issue :id 1 :number 1)))
    (should (equal
             (forge-plugins-github-subissues--insert-advice
              (lambda (topic &optional _width) (oref topic number)) topic)
             1))))

(ert-deftest forge-plugins-github-subissues-test-omits-nil-cursor ()
  (let ((repo (make-instance 'forge-github-repository :owner "o" :name "n")))
    (should-not (assq 'after
                      (forge-plugins-github-subissues--variables repo nil)))
    (should (equal (alist-get 'after
                              (forge-plugins-github-subissues--variables repo "c"))
                   "c"))))

(ert-deftest forge-plugins-github-subissues-test-stale-cache-does-not-fetch-synchronously ()
  (let ((forge-plugins-github-subissues--cache (make-hash-table :test #'equal))
        (repo (make-instance 'forge-github-repository :id 1)))
    (should-not (forge-plugins-github-subissues--cached-parents repo))))

(provide 'forge-plugins-github-subissues-test)
