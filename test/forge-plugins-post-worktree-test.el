;;; forge-plugins-post-worktree-test.el --- Tests for post worktree validation -*- lexical-binding: t; -*-

(require 'ert)
(require 'forge)
(require 'forge-plugins-post-worktree)

(ert-deftest forge-plugins-post-worktree-test-stale-worktree-falls-back ()
  "A missing recorded worktree yields a draft path in the fallback directory."
  (let ((repo (make-instance 'forge-github-repository
                             :githost "github.com" :owner "o" :name "n"))
        (forge-post-fallback-directory "/tmp/forge-posts/")
        (default-directory "/"))
    (unwind-protect
        (progn
          (oset repo worktree "/nonexistent/clone/")
          (forge-plugins-post-worktree-enable)
          (cl-letf (((symbol-function 'forge-get-worktree) #'ignore))
            (should (equal (forge--post-expand-file-name "new-issue" repo)
                           "/tmp/forge-posts/github.com_o-n_new-issue")))
          (should-not (oref repo worktree)))
      (forge-plugins-post-worktree-disable))))

(provide 'forge-plugins-post-worktree-test)
;;; forge-plugins-post-worktree-test.el ends here
