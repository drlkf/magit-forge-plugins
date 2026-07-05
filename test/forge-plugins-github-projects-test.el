;;; forge-plugins-github-projects-test.el --- Tests for the GitHub Projects plugin  -*- lexical-binding: t; -*-

;;; Commentary:

;; Assert the forge and ghub API surface the plugin depends on, so the
;; build fails when an upstream change renames or removes a symbol or
;; slot the plugin relies on.

;;; Code:

(require 'ert)
(require 'forge)
(require 'ghub)
(require 'forge-plugins-github-projects)

(ert-deftest forge-plugins-github-projects-test-api-surface ()
  "The forge and ghub symbols and slots the plugin relies on must exist."
  (should (fboundp 'forge-get-repository))
  (should (fboundp 'ghub-request))
  (should (fboundp 'forge-insert-post))
  (should (boundp 'forge-topic-mode-map))
  (dolist (slot '(owner name apihost))
    (should (cl-find slot (eieio-class-slots 'forge-github-repository)
                     :key #'eieio-slot-descriptor-name)))
  ;; `their-id' is the GraphQL node ID used as the mutation content ID.
  (dolist (class '(forge-issue forge-pullreq))
    (should (cl-find 'their-id (eieio-class-slots class)
                     :key #'eieio-slot-descriptor-name))))

(ert-deftest forge-plugins-github-projects-test-commands-exist ()
  "The topic project commands and their prefix map must be defined."
  (should (commandp 'forge-plugins-github-projects-add))
  (should (commandp 'forge-plugins-github-projects-set-status))
  (should (commandp 'forge-plugins-github-projects-remove))
  (should (keymapp forge-plugins-github-projects-prefix-map)))

(ert-deftest forge-plugins-github-projects-test-queries-are-strings ()
  "Queries must be raw GraphQL strings, not gsexp lists.
`ghub' gsexp cannot express the inline fragments these queries need, so
sending them as gsexp produces malformed GraphQL that GitHub rejects."
  (should (stringp forge-plugins-github-projects--list-query))
  (should (stringp forge-plugins-github-projects--items-query))
  (should (stringp forge-plugins-github-projects--membership-query-template))
  ;; The membership template carries the inline fragment that broke gsexp.
  (should (string-match-p "\\.\\.\\. on ProjectV2ItemFieldSingleSelectValue"
                          forge-plugins-github-projects--membership-query-template))
  (should (string-match-p "pullRequest"
                          (forge-plugins-github-projects--membership-query nil))))

(ert-deftest forge-plugins-github-projects-test-membership-extraction ()
  "Membership response extraction must match the query's response shape.
Feeds a hand-written response `data' object (as `--graphql' returns it)
through the extraction helpers and asserts the resulting cache plist,
so a wrong `alist-get'/`let-alist' path fails the build."
  (let* ((data '((repository
                  (topic
                   (id . "PR_node")
                   (projectItems
                    (nodes
                     ((id . "ITEM_1")
                      (project (id . "PVT_1") (number . 3)
                               (title . "Roadmap") (url . "https://x/1"))
                      (fieldValueByName (name . "In Progress")))
                     ((id . "ITEM_2")
                      (project (id . "PVT_2") (number . 7)
                               (title . "Backlog") (url . "https://x/2"))
                      (fieldValueByName))))))))
         (plist (forge-plugins-github-projects--membership-plist data))
         (items (plist-get plist :items)))
    (should (equal (plist-get plist :content-id) "PR_node"))
    (should (length= items 2))
    (should (equal (plist-get (car items) :id) "ITEM_1"))
    (should (equal (plist-get (car items) :status) "In Progress"))
    (should (equal (alist-get 'title (plist-get (car items) :project))
                   "Roadmap"))
    ;; A project with no Status value yields a nil `:status'.
    (should (null (plist-get (cadr items) :status)))))

(ert-deftest forge-plugins-github-projects-test-disabled-by-default ()
  "The plugin flag defaults to nil and its command refuses when off."
  (let ((forge-plugins-github-projects-enable nil))
    (should-error (forge-plugins-github-projects) :type 'user-error)))

(provide 'forge-plugins-github-projects-test)
;;; forge-plugins-github-projects-test.el ends here
