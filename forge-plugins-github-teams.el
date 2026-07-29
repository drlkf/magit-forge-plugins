;;; forge-plugins-github-teams.el --- GitHub team review requests -*- lexical-binding: t; -*-

;;; Commentary:

;; Add GitHub teams to Forge's existing review-request flow.

;;; Code:

(require 'cl-lib)
(require 'forge)
(require 'forge-github)
(require 'forge-topic)

(defgroup forge-plugins-github-teams nil
  "GitHub team review requests in Forge."
  :group 'forge)

(defcustom forge-plugins-github-teams-enable nil
  "Whether to enable GitHub team review requests."
  :type 'boolean
  :group 'forge-plugins-github-teams)

(defconst forge-plugins-github-teams-tested-on-forge "0.6.6")

(defcustom forge-plugins-github-teams-debug nil
  "Whether to log GitHub team review-request diagnostics."
  :type 'boolean
  :group 'forge-plugins-github-teams)

(defvar forge-plugins-github-teams--cache (make-hash-table :test #'equal))

(defun forge-plugins-github-teams--team-alist (teams owner)
  (mapcar (lambda (team)
            (cons (format "%s/%s" owner (alist-get 'slug team))
                  (alist-get 'node_id team)))
          teams))

(defun forge-plugins-github-teams--partition-reviewers (reviewers)
  (cl-loop with users = nil with teams = nil
           for reviewer in reviewers
           if (string-match-p "/" reviewer)
           do (push reviewer teams)
           else do (push reviewer users)
           finally return (list (nreverse users) (nreverse teams))))

(defun forge-plugins-github-teams--requested-reviewers (data)
  (append (mapcar (lambda (user) (alist-get 'login user))
                  (alist-get 'users data))
          (mapcar (lambda (team)
                    (format "%s/%s"
                            (alist-get 'login (alist-get 'organization team))
                            (alist-get 'slug team)))
                  (alist-get 'teams data))))

(defun forge-plugins-github-teams--teams (repo)
  (or (gethash (oref repo id) forge-plugins-github-teams--cache)
      (let ((teams (forge-rest repo "GET" "/orgs/:owner/teams" nil
                                :unpaginate t :noerror t)))
        (puthash (oref repo id)
                 (if teams
                     (forge-plugins-github-teams--team-alist
                      teams (oref repo owner))
                   'none)
                 forge-plugins-github-teams--cache)
        (gethash (oref repo id) forge-plugins-github-teams--cache))))

(defun forge-plugins-github-teams--read-reviewers (orig &optional topic)
  (let* ((repo (forge-get-repository (or topic :tracked)))
         (teams (and (forge-github-repository--eieio-childp repo)
                     (forge-plugins-github-teams--teams repo))))
    (if (or (not forge-plugins-github-teams-enable)
            (not (forge-github-repository--eieio-childp repo))
            (eq teams 'none))
        (funcall orig topic)
      (oset repo teams (mapcar #'car teams))
      (let* ((value (and topic (oref topic review-requests)))
             (current (and topic
                           (forge-rest topic "GET"
                                       "/repos/:owner/:repo/pulls/:number/requested_reviewers"
                                       nil :noerror t)))
             (choices (nconc (mapcar #'cadr (oref repo assignees))
                            (mapcar #'car teams)))
             (crm-separator ","))
        (magit-completing-read-multiple
         "Request review from: " choices nil 'confirm
         (mapconcat #'identity
                    (or (and current
                             (forge-plugins-github-teams--requested-reviewers current))
                        (mapcar #'cadr value))
                    ","))))))

(defun forge-plugins-github-teams--set-reviewers (orig repo topic reviewers)
  (let* ((teams (and forge-plugins-github-teams-enable
                     (forge-github-repository--eieio-childp repo)
                     (forge-plugins-github-teams--teams repo))))
    (if (or (not teams) (eq teams 'none))
        (funcall orig topic reviewers)
      (pcase-let ((`(,users ,team-names)
                   (forge-plugins-github-teams--partition-reviewers reviewers)))
        (let ((team-ids (mapcar (lambda (name) (or (cdr (assoc name teams))
                                                    (user-error "Unknown team: %s" name)))
                                team-names)))
          (forge--mutate-field topic requestReviews
            ((pullRequestId (oref topic their-id))
             (and users (userIds (vconcat
                                  (forge--their-id users 'assignees repo))))
             (and team-ids (teamIds (vconcat team-ids))))))))))

;;;###autoload
(defun forge-plugins-github-teams-refresh ()
  "Clear the cached GitHub teams for the current repository."
  (interactive)
  (remhash (oref (forge-get-repository :tracked) id)
           forge-plugins-github-teams--cache))

;;;###autoload
(defun forge-plugins-github-teams-enable ()
  "Enable GitHub team review requests."
  (interactive)
  (advice-add 'forge-read-topic-review-requests :around
              #'forge-plugins-github-teams--read-reviewers)
  (advice-add 'forge--set-topic-review-requests :around
              #'forge-plugins-github-teams--set-reviewers))

;;;###autoload
(defun forge-plugins-github-teams-disable ()
  "Disable GitHub team review requests."
  (interactive)
  (advice-remove 'forge-read-topic-review-requests
                #'forge-plugins-github-teams--read-reviewers)
  (advice-remove 'forge--set-topic-review-requests
                #'forge-plugins-github-teams--set-reviewers))

(provide 'forge-plugins-github-teams)
;;; forge-plugins-github-teams.el ends here
