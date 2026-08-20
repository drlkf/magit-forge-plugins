;;; forge-plugins-github-subissues.el --- GitHub sub-issues  -*- lexical-binding: t; -*-

;;; Commentary:
;; Display and manage GitHub issue hierarchies.

;;; Code:
(require 'cl-lib)
(require 'forge)
(require 'forge-issue)
(require 'forge-topic)
(require 'forge-plugins-log)
(require 'ghub)

(defconst forge-plugins-github-subissues-tested-on-forge "0.6.6")
(defcustom forge-plugins-github-subissues-enable nil
  "Whether to enable GitHub sub-issue support."
  :type 'boolean :group 'forge
  :set (lambda (symbol value)
         (set-default symbol value)
         (when (featurep 'forge-plugins-github-subissues)
           (if value (forge-plugins-github-subissues-enable)
             (forge-plugins-github-subissues-disable)))))
(defcustom forge-plugins-github-subissues-ttl 300
  "Seconds to retain fetched issue hierarchy data."
  :type 'number :group 'forge)

(defvar forge-plugins-github-subissues--cache (make-hash-table :test #'equal))
(defvar forge-plugins-github-subissues--pending (make-hash-table :test #'equal))
(defvar-local forge-plugins-github-subissues--depths nil)
(defvar forge-plugins-github-subissues--pending-parent nil)

(defconst forge-plugins-github-subissues--query
  "query($owner:String!,$name:String!,$after:String){repository(owner:$owner,name:$name){issues(first:100,after:$after){pageInfo{hasNextPage endCursor}nodes{id number parent{number}}}}}")

(defun forge-plugins-github-subissues--variables (repo after)
  (append `((owner . ,(oref repo owner)) (name . ,(oref repo name)))
          (and after `((after . ,after)))))

(defun forge-plugins-github-subissues--tree-order (topics parents)
  "Return TOPICS in pre-order according to child-to-parent PARENTS."
  (let ((by-number (make-hash-table :test #'eql))
        (children (make-hash-table :test #'eql))
        (depths (make-hash-table :test #'eql))
        roots result)
    (dolist (topic topics) (puthash (oref topic number) topic by-number))
    (dolist (topic topics)
      (let ((parent (gethash (oref topic number) parents)))
        (if (and parent (gethash parent by-number))
            (push topic (gethash parent children))
          (push topic roots))))
    (cl-labels ((visit (topic depth)
                  (puthash (oref topic id) depth depths)
                  (push topic result)
                  (dolist (child (nreverse (gethash (oref topic number) children)))
                    (visit child (1+ depth)))))
      (dolist (root (nreverse roots)) (visit root 0)))
    (list (nreverse result) depths)))

(defun forge-plugins-github-subissues--graphql (repo query variables)
  (let ((body (ghub-request "POST" "/graphql"
                `((query . ,query) (variables . ,variables))
                :auth 'forge :host (oref repo apihost)
                :forge 'github)))
    (when (alist-get 'errors body)
      (user-error "GitHub GraphQL error: %s"
                  (mapconcat (lambda (e) (alist-get 'message e))
                             (alist-get 'errors body) "; ")))
    (alist-get 'data body)))

(defun forge-plugins-github-subissues--cached-parents (repo)
  (let ((entry (gethash (oref repo id) forge-plugins-github-subissues--cache)))
    (if (and entry (< (- (float-time) (car entry)) forge-plugins-github-subissues-ttl))
        (cdr entry))))

(cl-defun forge-plugins-github-subissues--fetch-async
    (repo buffer &optional after parents)
  (let ((parents (or parents (make-hash-table :test #'eql))))
    (ghub-request
      "POST" "/graphql" nil
      :payload `((query . ,forge-plugins-github-subissues--query)
                 (variables . ,(forge-plugins-github-subissues--variables repo after)))
      :auth 'forge :host (oref repo apihost) :forge 'github
      :callback
      (lambda (body _headers _status _request)
        (if-let ((errors (alist-get 'errors body)))
            (forge-plugins-github-subissues--fetch-error
             repo (mapconcat (lambda (e) (alist-get 'message e)) errors "; "))
          (let-alist (alist-get 'data body)
            (dolist (issue .repository.issues.nodes)
              (when-let ((parent (alist-get 'number (alist-get 'parent issue))))
                (puthash (alist-get 'number issue) parent parents)))
            (if .repository.issues.pageInfo.hasNextPage
                (forge-plugins-github-subissues--fetch-async
                 repo buffer .repository.issues.pageInfo.endCursor parents)
              (puthash (oref repo id) (cons (float-time) parents)
                       forge-plugins-github-subissues--cache)
              (remhash (oref repo id) forge-plugins-github-subissues--pending)
              (when (buffer-live-p buffer)
                (with-current-buffer buffer
                  (when (fboundp 'magit-refresh) (magit-refresh))))))))
      :errorback
      (lambda (error _headers _status _request)
        (forge-plugins-github-subissues--fetch-error repo (format "%S" error))))))

(defun forge-plugins-github-subissues--fetch-error (repo message)
  (remhash (oref repo id) forge-plugins-github-subissues--pending)
  (forge-plugins-log-error "github-subissues" "%s" message))

(defun forge-plugins-github-subissues--ensure-fetch (repo buffer)
  (unless (gethash (oref repo id) forge-plugins-github-subissues--pending)
    (puthash (oref repo id) t forge-plugins-github-subissues--pending)
    (forge-plugins-github-subissues--fetch-async repo buffer)))

(defun forge-plugins-github-subissues--list-advice (orig spec repo)
  (let ((topics (funcall orig spec repo)))
    (if (and topics (cl-typep repo 'forge-github-repository)
             (eq (oref spec type) 'issue))
        (if-let ((parents (forge-plugins-github-subissues--cached-parents repo)))
            (pcase-let ((`(,ordered ,depths)
                         (forge-plugins-github-subissues--tree-order topics parents)))
              (setq forge-plugins-github-subissues--depths depths)
              ordered)
          (setq forge-plugins-github-subissues--depths nil)
          (forge-plugins-github-subissues--ensure-fetch repo (current-buffer))
          topics)
      topics)))

(defun forge-plugins-github-subissues--insert-advice (orig topic &optional width)
  (let ((depth (and forge-plugins-github-subissues--depths
                    (gethash (oref topic id) forge-plugins-github-subissues--depths 0))))
    (when (and depth (> depth 0)) (insert (make-string (* 2 depth) ?\s)))
    (funcall orig topic width)))

(defun forge-plugins-github-subissues--current-issue ()
  (or (forge-current-issue) (user-error "No issue at point")))

(defun forge-plugins-github-subissues--mutate (mutation variables)
  (let ((repo (forge-get-repository :tracked)))
    (forge-plugins-github-subissues--graphql
     repo (format "mutation($input:%sInput!){%s(input:$input){clientMutationId}}"
                  (if (equal mutation "addSubIssue") "AddSubIssue"
                    "RemoveSubIssue") mutation)
     `((input . ,variables)))))

;;;###autoload
(defun forge-plugins-github-subissues-set-parent (parent child)
  "Set CHILD as a sub-issue of PARENT."
  (interactive
   (let ((child (forge-plugins-github-subissues--current-issue)))
     (list (forge-read-open-issue "Parent issue: ") child)))
  (forge-plugins-github-subissues--mutate
   "addSubIssue" `((issueId . ,(oref parent their-id))
                   (subIssueId . ,(oref child their-id))
                   (replaceParent . t)))
  (message "Issue #%s is now a sub-issue of #%s" (oref child number) (oref parent number))
  (forge-plugins-github-subissues-refresh))

;;;###autoload
(defun forge-plugins-github-subissues-remove-parent ()
  "Remove the current issue from its parent."
  (interactive)
  (let* ((child (forge-plugins-github-subissues--current-issue))
         (repo (forge-get-repository child))
         (data (forge-plugins-github-subissues--graphql repo
                                                        "query($id:ID!){node(id:$id){... on Issue{parent{id}}}}"
                                                        `((id . ,(oref child their-id)))))
         (parent (let-alist data .node.parent.id)))
    (unless parent (user-error "Issue #%s has no parent" (oref child number)))
    (forge-plugins-github-subissues--mutate
     "removeSubIssue" `((issueId . ,parent) (subIssueId . ,(oref child their-id))))
    (forge-plugins-github-subissues-refresh)))

;;;###autoload
(defun forge-plugins-github-subissues-create ()
  "Create an issue using Forge's native UI, then attach it to a parent."
  (interactive)
  (setq forge-plugins-github-subissues--pending-parent
        (oref (forge-read-open-issue "Parent issue: ") their-id))
  (call-interactively #'forge-create-issue))

(defun forge-plugins-github-subissues--submit-create-issue (orig repo object)
  (if (not forge-plugins-github-subissues--pending-parent)
      (funcall orig repo object)
    (pcase-let ((`(,title . ,body) (forge--post-buffer-text)))
      (let ((parent forge-plugins-github-subissues--pending-parent)
            (input `((repositoryId . ,(forge--their-id repo))
                     (title . ,title) (body . ,body))))
        (setq forge-plugins-github-subissues--pending-parent nil)
        (ghub-request
          "POST" "/graphql"
          `((query . "mutation($input:CreateIssueInput!){createIssue(input:$input){issue{id number}}}")
            (variables . ((input . ,input))))
          :auth 'forge :host (oref repo apihost) :forge 'github
          :callback
          (lambda (value &rest _)
            (let ((issue (let-alist value .data.createIssue.issue)))
              (ghub-request
                "POST" "/graphql"
                `((query . "mutation($input:AddSubIssueInput!){addSubIssue(input:$input){clientMutationId}}")
                  (variables . ((input . ((issueId . ,parent)
                                          (subIssueId . ,(alist-get 'id issue)))))))
                :auth 'forge :host (oref repo apihost) :forge 'github
                :callback (forge--post-submit-callback t)
                :errorback (forge--post-submit-errorback))))
          :errorback (forge--post-submit-errorback))))))

;;;###autoload
(defun forge-plugins-github-subissues-refresh ()
  "Clear cached hierarchy data and refresh the current buffer."
  (interactive)
  (clrhash forge-plugins-github-subissues--cache)
  (clrhash forge-plugins-github-subissues--pending)
  (when (fboundp 'magit-refresh) (magit-refresh)))

;;;###autoload
(defun forge-plugins-github-subissues-enable ()
  "Enable GitHub sub-issue support."
  (interactive)
  (setq forge-plugins-github-subissues-enable t)
  (advice-add 'forge--list-topics :around #'forge-plugins-github-subissues--list-advice)
  (advice-add 'forge--insert-topic :around #'forge-plugins-github-subissues--insert-advice)
  (advice-add 'forge--submit-create-issue :around
              #'forge-plugins-github-subissues--submit-create-issue)
  (when (boundp 'forge-issue-mode-map)
    (keymap-set forge-issue-mode-map "C-c s p" #'forge-plugins-github-subissues-set-parent)
    (keymap-set forge-issue-mode-map "C-c s r" #'forge-plugins-github-subissues-remove-parent))
  (when (boundp 'forge-issues-section-map)
    (keymap-set forge-issues-section-map "C-c C-s" #'forge-plugins-github-subissues-set-parent)))

;;;###autoload
(defun forge-plugins-github-subissues-disable ()
  "Disable GitHub sub-issue support."
  (interactive)
  (setq forge-plugins-github-subissues-enable nil)
  (advice-remove 'forge--list-topics #'forge-plugins-github-subissues--list-advice)
  (advice-remove 'forge--insert-topic #'forge-plugins-github-subissues--insert-advice)
  (advice-remove 'forge--submit-create-issue
                 #'forge-plugins-github-subissues--submit-create-issue))

(when forge-plugins-github-subissues-enable
  (forge-plugins-github-subissues-enable))

(provide 'forge-plugins-github-subissues)
;;; forge-plugins-github-subissues.el ends here
