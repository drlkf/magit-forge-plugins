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
                          (list (list (cons 'slug "backend")))))))
    (should (equal (forge-plugins-github-teams--requested-reviewers data "acme")
                   '("alice" "bob" "acme/backend")))))

(ert-deftest forge-plugins-github-teams-test-user-ids-preserve-requested ()
  "Requested users use their REST node IDs when available."
  (let ((current '(((login . "alice") (node_id . "U_alice")))))
    (cl-letf (((symbol-function 'forge--their-id)
               (lambda (&rest _) nil)))
      (should (equal
               (forge-plugins-github-teams--user-ids '("alice") current nil)
               '("U_alice"))))))

(ert-deftest forge-plugins-github-teams-test-fallback-passes-repository ()
  "The fallback setter receives the repository argument."
  (let ((forge-plugins-github-teams-enable nil)
        (repo 'repo)
        (topic 'topic)
        args)
    (cl-letf (((symbol-function 'forge-plugins-github-teams--teams)
               (lambda (_) 'none)))
      (forge-plugins-github-teams--set-reviewers
       (lambda (&rest values) (setq args values)) repo topic '("alice")))
    (should (equal args '(repo topic ("alice"))))))

(ert-deftest forge-plugins-github-teams-test-format-teams ()
  "Team names are formatted for the pull-request header."
  (should (equal
           (substring-no-properties
            (forge-plugins-github-teams--format
             '(((organization . "acme") (slug . "backend")))))
           "@acme/backend")))

(provide 'forge-plugins-github-teams-test)
;;; forge-plugins-github-teams-test.el ends here
