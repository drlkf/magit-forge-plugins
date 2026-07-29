;;; forge-plugins-github-teams-test.el --- Tests for GitHub team reviewers -*- lexical-binding: t; -*-

(require 'ert)
(require 'forge-plugins-github-teams)

(ert-deftest forge-plugins-github-teams-test-team-alist ()
  "Team API objects become completion names and node IDs."
  (should (equal
           (forge-plugins-github-teams--team-alist
            '(((slug . "backend") (node_id . "T_backend"))
              ((slug . "ops") (node_id . "T_ops")))
            "acme")
           '(("acme/backend" . "T_backend")
             ("acme/ops" . "T_ops")))))

(ert-deftest forge-plugins-github-teams-test-reviewer-partition ()
  "Reviewer names containing a slash are teams."
  (should (equal
           (forge-plugins-github-teams--partition-reviewers
            '("alice" "acme/backend" "bob" "acme/ops"))
           '(("alice" "bob") ("acme/backend" "acme/ops")))))

(ert-deftest forge-plugins-github-teams-test-requested-reviewers ()
  "Current users and teams become completing-read initial input."
  (let ((data (list (cons 'users
                          (list (list (cons 'login "alice"))
                                (list (cons 'login "bob"))))
                    (cons 'teams
                          (list (list (cons 'organization
                                             (list (cons 'login "acme")))
                                      (cons 'slug "backend")))))))
    (should (equal (forge-plugins-github-teams--requested-reviewers data)
                   '("alice" "bob" "acme/backend")))))

(provide 'forge-plugins-github-teams-test)
;;; forge-plugins-github-teams-test.el ends here
