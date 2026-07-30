;;; forge-plugins-github-teams.el --- GitHub team review requests -*- lexical-binding: t; -*-

;;; Commentary:

;; Add GitHub teams to Forge's existing review-request flow.

;;; Code:

(require 'cl-lib)
(require 'forge)
(require 'forge-github)
(require 'forge-topic)
(require 'forge-plugins-log)

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

(defcustom forge-plugins-github-teams-ttl 300
  "Seconds to cache requested teams in pull-request buffers."
  :type 'number
  :group 'forge-plugins-github-teams)

(defvar forge-plugins-github-teams--cache (make-hash-table :test #'equal))
(defvar forge-plugins-github-teams--warned (make-hash-table :test #'equal))
(defvar forge-plugins-github-teams--requests (make-hash-table :test #'equal))
(defvar forge-plugins-github-teams--refresh-timer nil)

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

(defun forge-plugins-github-teams--requested-reviewers (data owner)
  (append (mapcar (lambda (user) (alist-get 'login user))
                  (alist-get 'users data))
          (mapcar (lambda (team)
                    (format "%s/%s" owner (alist-get 'slug team)))
                  (alist-get 'teams data))))

(defun forge-plugins-github-teams--format (teams)
  (mapconcat
   (lambda (team)
     (let ((organization (alist-get 'organization team)))
       (propertize
        (format "@%s/%s"
                (if (listp organization)
                    (alist-get 'login organization)
                  organization)
                (alist-get 'slug team))
        'face 'transient-value)))
   teams ", "))

(defun forge-plugins-github-teams--request-teams (topic)
  (let ((id (oref topic id))
        (buffer (current-buffer)))
    (puthash id (list :fetching t) forge-plugins-github-teams--requests)
    (forge-rest topic "GET"
      "/repos/:owner/:repo/pulls/:number/requested_reviewers"
      nil :noerror t
      :callback
      (lambda (data &rest _)
        (puthash id (list :teams (alist-get 'teams data)
                          :time (float-time))
                 forge-plugins-github-teams--requests)
        (when (buffer-live-p buffer)
          (run-at-time 0 nil
                       (lambda ()
                         (with-current-buffer buffer
                           (when (derived-mode-p 'forge-pullreq-mode)
                             (magit-refresh-buffer)))))))
      :errorback
      (lambda (err &rest _)
        (forge-plugins-log-error "github-teams"
                                 "Failed to fetch requested teams for %s: %S"
                                 id err)
        (puthash id (list :teams nil :time (float-time))
                 forge-plugins-github-teams--requests)))))

(defun forge-plugins-github-teams--format-review-requests (orig topic)
  (let ((value (funcall orig topic)))
    (if (and forge-plugins-github-teams-enable
             (forge-pullreq-p topic)
             (forge-github-repository--eieio-childp
              (forge-get-repository topic)))
        (let* ((id (oref topic id))
               (cached (gethash id forge-plugins-github-teams--requests))
               (teams (plist-get cached :teams)))
          (cond
           ((and cached (plist-get cached :fetching)) value)
           ((and cached (< (- (float-time) (plist-get cached :time))
                           forge-plugins-github-teams-ttl))
            (mapconcat #'identity (delq nil (list value
                                                  (and teams
                                                       (forge-plugins-github-teams--format
                                                        teams))))
                       ", "))
           (t (forge-plugins-github-teams--request-teams topic) value)))
      value)))

(defun forge-plugins-github-teams--teams (repo)
  (or (gethash (oref repo id) forge-plugins-github-teams--cache)
      (let ((teams (forge-rest repo "GET" "/orgs/:owner/teams" nil
                     :unpaginate t :noerror t)))
        (unless teams
          (forge-plugins-log-error "github-teams"
                                   "Failed to fetch teams for %s"
                                   (oref repo owner))
          (unless (gethash (oref repo id) forge-plugins-github-teams--warned)
            (puthash (oref repo id) t forge-plugins-github-teams--warned)
            (message "Could not fetch GitHub teams; check the token's read:org scope")))
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
                             (forge-plugins-github-teams--requested-reviewers
                              current (oref repo owner)))
                        (mapcar #'cadr value))
                    ","))))))

(defun forge-plugins-github-teams--user-ids (users current repo)
  (mapcar
   (lambda (login)
     (or (alist-get 'node_id
                    (cl-find login current :key (lambda (user)
                                                  (alist-get 'login user))
                             :test #'equal))
         (forge--their-id login 'assignee repo)))
   users))

(defun forge-plugins-github-teams--set-reviewers (orig repo topic reviewers)
  (let* ((teams (and forge-plugins-github-teams-enable
                     (forge-github-repository--eieio-childp repo)
                     (forge-plugins-github-teams--teams repo))))
    (if (or (not teams) (eq teams 'none))
        (funcall orig repo topic reviewers)
      (pcase-let ((`(,users ,team-names)
                   (forge-plugins-github-teams--partition-reviewers reviewers)))
        (let* ((current (or (forge-rest topic "GET"
                              "/repos/:owner/:repo/pulls/:number/requested_reviewers"
                              nil :noerror t)
                            '((users))))
               (team-ids (mapcar (lambda (name) (or (cdr (assoc name teams))
                                                    (user-error "Unknown team: %s" name)))
                                 team-names))
               (user-ids (delq nil
                               (forge-plugins-github-teams--user-ids
                                users (alist-get 'users current) repo))))
          (forge--mutate-field topic requestReviews
            ((pullRequestId (oref topic their-id))
             (and user-ids (userIds (vconcat user-ids)))
             (and team-ids (teamIds (vconcat team-ids))))))))))

;;;###autoload
(defun forge-plugins-github-teams-refresh ()
  "Clear the cached GitHub teams for the current repository."
  (interactive)
  (remhash (oref (forge-get-repository :tracked) id)
           forge-plugins-github-teams--cache)
  (clrhash forge-plugins-github-teams--requests))

;;;###autoload
(defun forge-plugins-github-teams-enable ()
  "Enable GitHub team review requests."
  (interactive)
  (advice-add 'forge-read-topic-review-requests :around
              #'forge-plugins-github-teams--read-reviewers)
  (advice-add 'forge--set-topic-review-requests :around
              #'forge-plugins-github-teams--set-reviewers)
  (advice-add 'forge--format-topic-review-requests :around
              #'forge-plugins-github-teams--format-review-requests))

;;;###autoload
(defun forge-plugins-github-teams-disable ()
  "Disable GitHub team review requests."
  (interactive)
  (advice-remove 'forge-read-topic-review-requests
                 #'forge-plugins-github-teams--read-reviewers)
  (advice-remove 'forge--set-topic-review-requests
                 #'forge-plugins-github-teams--set-reviewers)
  (advice-remove 'forge--format-topic-review-requests
                 #'forge-plugins-github-teams--format-review-requests))

;;;###autoload
(defun forge-plugins-github-teams-show-errors ()
  "Pop to the GitHub teams plugin error buffer."
  (interactive)
  (forge-plugins-log-show "github-teams"))

(provide 'forge-plugins-github-teams)
;;; forge-plugins-github-teams.el ends here
