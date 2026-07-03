;;; forge-plugins-github-projects.el --- Read-only GitHub Projects v2 boards  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  drlkf

;; Author: drlkf <drlkf@drlkf.net>
;; Keywords: tools

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; `forge' models GitHub issues, pull requests and discussions, but has
;; no support for Projects v2 — the Kanban-style project boards.  Those
;; boards are exposed exclusively through GitHub's GraphQL API (the
;; classic REST Projects API was sunset on 2025-04-01); see
;; https://docs.github.com/en/issues/planning-and-tracking-with-projects/automating-your-project/using-the-api-to-manage-projects.
;;
;; This plugin adds a read-only viewer.  `forge-plugins-github-projects'
;; lists the Projects v2 boards attached to the current forge
;; repository; selecting one opens a buffer that groups the board's
;; items into columns by its single-select "Status" field (the field
;; that drives the board columns) and renders each column as a
;; collapsible `magit' section.  Cards show their type, number and
;; title; `RET' or `b' on a card opens it in the browser.
;;
;; Queries go through `ghub-query' (the GraphQL entry point of `ghub',
;; the library `forge' itself uses) with `:auth 'forge', reusing the
;; repository's existing token and host.  Nothing is mutated.

;;; Code:

(require 'forge nil t)
(require 'forge-topic nil t)
(require 'ghub)
(require 'magit-section)
(require 'cl-lib)

(declare-function forge-get-repository "forge-core")
(declare-function forge-issue-p "forge-issue")
(declare-function forge-pullreq-p "forge-pullreq")

(defconst forge-plugins-github-projects-tested-on-forge "0.6.6"
  "Forge version this plugin was tested against.")

(defvar-local forge-plugins-github-projects--repo nil
  "The forge repository whose board the current buffer displays.")

(defvar-local forge-plugins-github-projects--number nil
  "The Projects v2 number displayed in the current buffer.")

(defconst forge-plugins-github-projects--list-query
  '(query
    (repository
     [(owner $owner String!) (name $name String!)]
     (projectsV2 [(first 50)]
                 (nodes number title closed (field [(name "Status")]
                                                   (... on ProjectV2SingleSelectField id))))))
  "GraphQL query listing the repository's Projects v2 boards.")

(defconst forge-plugins-github-projects--items-query
  '(query
    (repository
     [(owner $owner String!) (name $name String!)]
     (projectV2
      [(number $number Int!)]
      title url
      (field [(name "Status")]
             (... on ProjectV2SingleSelectField
                  (options id name)))
      (items
       [(first 100)]
       (nodes
        (fieldValueByName
         [(name "Status")]
         (... on ProjectV2ItemFieldSingleSelectValue optionId name))
        (content
         (... on Issue       __typename number title url state)
         (... on PullRequest __typename number title url state)
         (... on DraftIssue  __typename title)))))))
  "GraphQL query fetching one board's items grouped data.")

(defun forge-plugins-github-projects--query (query repo &rest variables)
  "Run GraphQL QUERY for REPO synchronously, returning the parsed data.
VARIABLES are extra `:key value' pairs merged with the repository's
owner and name.  Authentication and host are taken from REPO via
the forge auth source, exactly as `forge' issues its own requests."
  (let ((vars (append (list (cons 'owner (oref repo owner))
                            (cons 'name (oref repo name)))
                      (cl-loop for (k v) on variables by #'cddr
                               collect (cons (intern (substring (symbol-name k) 1))
                                             v)))))
    (ghub-query query vars
      :auth 'forge
      :host (oref repo apihost)
      :forge 'github)))

(defun forge-plugins-github-projects--read-repository ()
  "Return the current forge repository or signal a `user-error'."
  (or (and (fboundp 'forge-get-repository)
           (ignore-errors (forge-get-repository :tracked)))
      (user-error "No forge repository in this buffer")))

(defvar-keymap forge-plugins-github-projects-card-map
  :doc "Keymap on a Projects v2 card line."
  "RET" #'forge-plugins-github-projects-browse-card
  "b"   #'forge-plugins-github-projects-browse-card)

(defun forge-plugins-github-projects-browse-card ()
  "Open the project card at point in the browser."
  (interactive)
  (if-let ((url (get-text-property (point) 'forge-plugins-github-projects-url)))
      (browse-url url)
    (user-error "No URL for this card")))

(defvar-keymap forge-plugins-github-projects-mode-map
  :doc "Keymap for `forge-plugins-github-projects-mode'."
  :parent magit-section-mode-map
  "g" #'revert-buffer)

(define-derived-mode forge-plugins-github-projects-mode magit-section-mode
  "Forge-Project"
  "Major mode for viewing a read-only GitHub Projects v2 board.

\\{forge-plugins-github-projects-mode-map}"
  (setq-local revert-buffer-function
              #'forge-plugins-github-projects--revert))

(defun forge-plugins-github-projects--revert (&rest _)
  "Re-fetch and redraw the board in the current buffer."
  (forge-plugins-github-projects--render
   forge-plugins-github-projects--repo
   forge-plugins-github-projects--number))

(defun forge-plugins-github-projects--card-face (state)
  "Return the face for a card whose item STATE is given (may be nil)."
  (pcase state
    ("OPEN"   'magit-section-heading)
    ("MERGED" 'magit-dimmed)
    ("CLOSED" 'magit-dimmed)
    (_        'default)))

(defun forge-plugins-github-projects--insert-card (item)
  "Insert a single card line for ITEM (an alist from the items query)."
  (let* ((content (alist-get 'content item))
         (type (alist-get '__typename content))
         (number (alist-get 'number content))
         (title (or (alist-get 'title content) "(untitled)"))
         (url (alist-get 'url content))
         (state (alist-get 'state content))
         (beg (point)))
    (insert "  ")
    (when number
      (insert (propertize (format "#%s " number) 'face 'magit-dimmed)))
    (when type
      (insert (propertize (format "[%s] " type) 'face 'magit-dimmed)))
    (insert (propertize title 'face
                        (forge-plugins-github-projects--card-face state)))
    (insert "\n")
    (add-text-properties
     beg (point)
     (list 'forge-plugins-github-projects-url url
           'keymap forge-plugins-github-projects-card-map))))

(defun forge-plugins-github-projects--render (repo number)
  "Render the Projects v2 board NUMBER of REPO into the current buffer."
  (let* ((data (forge-plugins-github-projects--query
                forge-plugins-github-projects--items-query repo
                :number number))
         (project (let-alist data .repository.projectV2))
         ;; `options' on a single-select field is a plain list, not a
         ;; Relay connection, so it has no `nodes' wrapper.
         (options (alist-get 'options (alist-get 'field project)))
         (items (alist-get 'nodes (alist-get 'items project)))
         (inhibit-read-only t))
    (erase-buffer)
    (setq forge-plugins-github-projects--repo repo
          forge-plugins-github-projects--number number)
    (magit-insert-section (forge-plugins-github-projects-board)
      (magit-insert-heading
        (propertize (or (alist-get 'title project) "Project")
                    'face 'magit-section-heading))
      ;; One column per Status option, in the board's own order, plus a
      ;; trailing "No Status" bucket for items without a status value.
      (let ((buckets (make-hash-table :test 'equal)))
        (dolist (item items)
          (let ((opt (or (alist-get 'optionId
                                    (alist-get 'fieldValueByName item))
                         :none)))
            (push item (gethash opt buckets))))
        (dolist (opt (append options (list '((id . :none) (name . "No Status")))))
          (let* ((id (alist-get 'id opt))
                 (name (alist-get 'name opt))
                 (cards (nreverse (gethash id buckets))))
            (when (or cards (not (eq id :none)))
              (magit-insert-section (forge-plugins-github-projects-column)
                (magit-insert-heading
                  (format "%s (%d)" name (length cards)))
                (if cards
                    (dolist (card cards)
                      (forge-plugins-github-projects--insert-card card))
                  (insert (propertize "  (empty)\n" 'face 'magit-dimmed)))))))))
    (goto-char (point-min))))

;;;; Topic project membership

;; The rest of this file adds a "Projects" section to issue and pull
;; request topic buffers, listing the Projects v2 boards the topic
;; belongs to and its status on each, plus commands to add the topic to
;; a project, set its status, and remove it.  Reads are async+cached (so
;; opening a topic never blocks on the network); the mutation commands
;; are synchronous, since they run in response to an explicit keypress.

(defvar forge-plugins-github-projects--items-cache (make-hash-table :test 'equal)
  "Cache of a topic's Projects v2 membership.
Keys are forge topic IDs.  Values are plists:
- `:content-id': the topic's GraphQL node ID.
- `:items': list of item alists, each with `id' (ProjectV2Item ID),
  `project' (with `id', `number', `title', `url') and the current
  `status' name (or nil).
- `:fetching': non-nil while a fetch is in progress.
- `:error': non-nil when the last fetch failed.")

(defconst forge-plugins-github-projects--membership-query
  '(query
    (repository
     [(owner $owner String!) (name $name String!)]
     (issueOrPullRequest
      [(number $number Int!)]
      (... on Issue
           id
           (projectItems
            [(first 20)]
            (nodes id (project id number title url)
                   (fieldValueByName
                    [(name "Status")]
                    (... on ProjectV2ItemFieldSingleSelectValue name)))))
      (... on PullRequest
           id
           (projectItems
            [(first 20)]
            (nodes id (project id number title url)
                   (fieldValueByName
                    [(name "Status")]
                    (... on ProjectV2ItemFieldSingleSelectValue name))))))))
  "GraphQL query for a topic's Projects v2 membership.")

(defun forge-plugins-github-projects--parse-items (nodes)
  "Turn membership-query NODES into the cached item plists."
  (mapcar
   (lambda (node)
     (list :id (alist-get 'id node)
           :project (alist-get 'project node)
           :status (alist-get 'name (alist-get 'fieldValueByName node))))
   nodes))

(defun forge-plugins-github-projects--content (topic-data)
  "Return the `issueOrPullRequest' alist from membership TOPIC-DATA."
  (let-alist topic-data .repository.issueOrPullRequest))

(defun forge-plugins-github-projects--refresh-topic-buffers ()
  "Refresh open issue and pull request topic buffers."
  (dolist (buf (buffer-list))
    (with-current-buffer buf
      (when (derived-mode-p 'forge-topic-mode)
        (magit-refresh-buffer)))))

(defun forge-plugins-github-projects--fetch-membership (topic)
  "Fetch TOPIC's Projects v2 membership asynchronously and cache it."
  (let* ((id (oref topic id))
         (repo (forge-get-repository topic))
         (number (oref topic number)))
    (puthash id (list :fetching t) forge-plugins-github-projects--items-cache)
    (ghub-query forge-plugins-github-projects--membership-query
      (list (cons 'owner (oref repo owner))
            (cons 'name (oref repo name))
            (cons 'number number))
      :auth 'forge :host (oref repo apihost) :forge 'github
      :callback
      (lambda (data _headers _status _req)
        (let ((content (forge-plugins-github-projects--content data)))
          (puthash id
                   (list :content-id (alist-get 'id content)
                         :items (forge-plugins-github-projects--parse-items
                                 (alist-get 'nodes
                                            (alist-get 'projectItems content)))
                         :fetching nil)
                   forge-plugins-github-projects--items-cache))
        (forge-plugins-github-projects--refresh-topic-buffers))
      :errorback
      (lambda (_err _headers _status _req)
        (puthash id (list :error t :fetching nil)
                 forge-plugins-github-projects--items-cache)
        (forge-plugins-github-projects--refresh-topic-buffers)))))

(defun forge-plugins-github-projects--invalidate (topic)
  "Drop TOPIC's cached membership so the next render re-fetches it."
  (remhash (oref topic id) forge-plugins-github-projects--items-cache))

(defun forge-plugins-github-projects--topic-p (obj)
  "Return non-nil when OBJ is a GitHub issue or pull request topic."
  (and (or (forge-issue-p obj) (forge-pullreq-p obj))
       (cl-typep (forge-get-repository obj) 'forge-github-repository)))

(defvar-keymap forge-plugins-github-projects-item-map
  :doc "Keymap on a project membership line in a topic buffer."
  :parent forge-plugins-github-projects-card-map)

(defun forge-plugins-github-projects--insert-membership (post &optional topic)
  "Insert the Projects section for POST when it is a topic's own post.
This is `:before' advice for `forge-insert-post': the section is
inserted only for the description post (TOPIC nil) of a GitHub issue
or pull request.  Membership is rendered from the cache; a miss kicks
off an async fetch and shows a placeholder."
  (when (and (null topic)
             forge-plugins-github-projects-enable
             (forge-plugins-github-projects--topic-p post))
    (let* ((topic post)
           (cached (gethash (oref topic id)
                            forge-plugins-github-projects--items-cache)))
      (unless cached
        (forge-plugins-github-projects--fetch-membership topic)
        (setq cached (gethash (oref topic id)
                              forge-plugins-github-projects--items-cache)))
      (magit-insert-section (forge-plugins-github-projects-topic)
        (magit-insert-heading
          (propertize "Projects" 'face 'magit-section-heading))
        (magit-insert-section-body
          (cond
           ((plist-get cached :fetching)
            (insert (propertize "  fetching...\n" 'face 'magit-dimmed)))
           ((plist-get cached :error)
            (insert (propertize "  error fetching projects\n" 'face 'error)))
           ((plist-get cached :items)
            (dolist (item (plist-get cached :items))
              (let* ((project (plist-get item :project))
                     (status (plist-get item :status))
                     (beg (point)))
                (insert "  " (or (alist-get 'title project) "(project)"))
                (insert " ")
                (insert (propertize (format "[%s]" (or status "no status"))
                                    'face (if status 'magit-section-heading
                                            'magit-dimmed)))
                (insert "\n")
                (add-text-properties
                 beg (point)
                 (list 'forge-plugins-github-projects-item item
                       'forge-plugins-github-projects-url (alist-get 'url project)
                       'keymap forge-plugins-github-projects-item-map)))))
           (t (insert (propertize "  none\n" 'face 'magit-dimmed))))
          (insert "\n"))))))

;;;; Mutations

(defun forge-plugins-github-projects--mutate (mutation repo variables)
  "Run GraphQL MUTATION for REPO with VARIABLES (an alist), synchronously."
  (ghub-query mutation variables
    :auth 'forge :host (oref repo apihost) :forge 'github :synchronous t))

(defun forge-plugins-github-projects--current-topic ()
  "Return the current topic buffer's topic or signal a `user-error'."
  (or (and (boundp 'forge-buffer-topic) forge-buffer-topic)
      (user-error "Not in a forge topic buffer")))

(defun forge-plugins-github-projects--topic-items (topic)
  "Return TOPIC's cached membership items, fetching synchronously if needed.
Unlike the section render, this blocks: the caller is an interactive
command reacting to a keypress, so a short wait is acceptable."
  (let ((cached (gethash (oref topic id)
                         forge-plugins-github-projects--items-cache)))
    ;; Re-fetch on a miss, an in-flight async fetch, or a prior error
    ;; (so a transient failure does not poison the cache).  This
    ;; ghub-query is not `:noerror', so a permission error signals and
    ;; propagates to the interactive command with its real message.
    (when (or (null cached)
              (plist-get cached :fetching)
              (plist-get cached :error))
      (let* ((repo (forge-get-repository topic))
             (data (ghub-query forge-plugins-github-projects--membership-query
                     (list (cons 'owner (oref repo owner))
                           (cons 'name (oref repo name))
                           (cons 'number (oref topic number)))
                     :auth 'forge :host (oref repo apihost)
                     :forge 'github :synchronous t))
             (content (forge-plugins-github-projects--content data)))
        (setq cached (list :content-id (alist-get 'id content)
                           :items (forge-plugins-github-projects--parse-items
                                   (alist-get 'nodes
                                              (alist-get 'projectItems content)))
                           :fetching nil))
        (puthash (oref topic id) cached
                 forge-plugins-github-projects--items-cache)))
    cached))

(defun forge-plugins-github-projects--select-item (topic prompt)
  "Return a membership item of TOPIC, chosen with PROMPT.
When point is on a project line, that project's item is returned
directly; otherwise the topic's current projects are offered for
completion.  Signals a `user-error' when the topic is in no project."
  (or (get-text-property (point) 'forge-plugins-github-projects-item)
      (let ((items (plist-get (forge-plugins-github-projects--topic-items topic)
                              :items)))
        (unless items
          (user-error "This topic is in no project"))
        (if (length= items 1)
            (car items)
          (let ((table (mapcar (lambda (it)
                                 (cons (alist-get 'title (plist-get it :project))
                                       it))
                               items)))
            (cdr (assoc (completing-read prompt table nil t) table)))))))

(defun forge-plugins-github-projects--status-field (repo number)
  "Return (FIELD-ID . OPTIONS) for project NUMBER's Status field in REPO.
OPTIONS is an alist of option name to option ID.  Returns nil when the
project has no single-select Status field."
  (let* ((data (forge-plugins-github-projects--query
                '(query
                  (repository
                   [(owner $owner String!) (name $name String!)]
                   (projectV2
                    [(number $number Int!)]
                    (field [(name "Status")]
                           (... on ProjectV2SingleSelectField
                                id (options id name))))))
                repo :number number))
         (field (let-alist data .repository.projectV2.field))
         (id (alist-get 'id field)))
    (when id
      (cons id
            (mapcar (lambda (o) (cons (alist-get 'name o) (alist-get 'id o)))
                    (alist-get 'options field))))))

;;;###autoload
(defun forge-plugins-github-projects-add ()
  "Add the current topic to a Projects v2 board.
Lists the repository's open boards and adds the topic to the chosen
one.  Bound to \\`p a' in topic buffers."
  (interactive)
  (let* ((topic (forge-plugins-github-projects--current-topic))
         (repo (forge-get-repository topic))
         (content-id (or (plist-get (forge-plugins-github-projects--topic-items topic)
                                    :content-id)
                         (oref topic their-id)))
         (data (forge-plugins-github-projects--query
                forge-plugins-github-projects--list-query repo))
         (projects (seq-remove
                    (lambda (p) (eq (alist-get 'closed p) t))
                    (let-alist data .repository.projectsV2.nodes))))
    (unless projects
      (user-error "No open Projects v2 boards on %s/%s"
                  (oref repo owner) (oref repo name)))
    (let* ((table (mapcar (lambda (p) (cons (alist-get 'title p) p)) projects))
           (choice (cdr (assoc (completing-read "Add to project: " table nil t)
                               table))))
      (forge-plugins-github-projects--mutate
       '(mutation
         (addProjectV2ItemById
          [(input $input AddProjectV2ItemByIdInput!)]
          (item id)))
       repo
       (list (cons 'input (list (cons 'projectId (alist-get 'id choice))
                                (cons 'contentId content-id)))))
      (forge-plugins-github-projects--invalidate topic)
      (magit-refresh)
      (message "Added to project %s" (alist-get 'title choice)))))

;;;###autoload
(defun forge-plugins-github-projects-set-status ()
  "Set the current topic's status in one of its projects.
Uses the project on the line at point, or prompts among the topic's
projects.  Bound to \\`p s' in topic buffers."
  (interactive)
  (let* ((topic (forge-plugins-github-projects--current-topic))
         (repo (forge-get-repository topic))
         (item (forge-plugins-github-projects--select-item
                topic "Set status in project: "))
         (project (plist-get item :project))
         (field (forge-plugins-github-projects--status-field
                 repo (alist-get 'number project))))
    (unless field
      (user-error "Project %s has no Status field" (alist-get 'title project)))
    (let* ((options (cdr field))
           (option-id (cdr (assoc (completing-read
                                   "Status: " options nil t)
                                  options))))
      (forge-plugins-github-projects--mutate
       '(mutation
         (updateProjectV2ItemFieldValue
          [(input $input UpdateProjectV2ItemFieldValueInput!)]
          (projectV2Item id)))
       repo
       (list (cons 'input
                   (list (cons 'projectId (alist-get 'id project))
                         (cons 'itemId (plist-get item :id))
                         (cons 'fieldId (car field))
                         (cons 'value
                               (list (cons 'singleSelectOptionId option-id)))))))
      (forge-plugins-github-projects--invalidate topic)
      (magit-refresh)
      (message "Status updated in project %s" (alist-get 'title project)))))

;;;###autoload
(defun forge-plugins-github-projects-remove ()
  "Remove the current topic from one of its projects.
Uses the project on the line at point, or prompts among the topic's
projects.  Bound to \\`p r' in topic buffers."
  (interactive)
  (let* ((topic (forge-plugins-github-projects--current-topic))
         (repo (forge-get-repository topic))
         (item (forge-plugins-github-projects--select-item
                topic "Remove from project: "))
         (project (plist-get item :project)))
    (when (yes-or-no-p (format "Remove this topic from project %s? "
                               (alist-get 'title project)))
      (forge-plugins-github-projects--mutate
       '(mutation
         (deleteProjectV2Item
          [(input $input DeleteProjectV2ItemInput!)]
          (deletedItemId)))
       repo
       (list (cons 'input (list (cons 'projectId (alist-get 'id project))
                                (cons 'itemId (plist-get item :id))))))
      (forge-plugins-github-projects--invalidate topic)
      (magit-refresh)
      (message "Removed from project %s" (alist-get 'title project)))))

;; ponytail: `p' shadows `magit-section-backward' in topic buffers.
;; This is the prefix the feature was specified with; rebind
;; `forge-plugins-github-projects-prefix-map' elsewhere to free `p'.
(defvar-keymap forge-plugins-github-projects-prefix-map
  :doc "Prefix keymap for project commands in topic buffers."
  "a" #'forge-plugins-github-projects-add
  "s" #'forge-plugins-github-projects-set-status
  "r" #'forge-plugins-github-projects-remove)

;;;###autoload
(defun forge-plugins-github-projects ()
  "Open a read-only GitHub Projects v2 board for the current repository.
Lists the repository's boards; when there is more than one, prompts
for which to open.  Requires the plugin to be enabled."
  (interactive)
  (unless forge-plugins-github-projects-enable
    (user-error "The GitHub Projects plugin is disabled"))
  (let* ((repo (forge-plugins-github-projects--read-repository))
         (data (forge-plugins-github-projects--query
                forge-plugins-github-projects--list-query repo))
         (projects (seq-remove
                    (lambda (p) (eq (alist-get 'closed p) t))
                    (let-alist data .repository.projectsV2.nodes))))
    (unless projects
      (user-error "No open Projects v2 boards on %s/%s"
                  (oref repo owner) (oref repo name)))
    (let* ((choice
            (if (length= projects 1)
                (car projects)
              (let* ((table (mapcar (lambda (p)
                                      (cons (format "#%s  %s"
                                                    (alist-get 'number p)
                                                    (alist-get 'title p))
                                            p))
                                    projects))
                     (key (completing-read "Project: " table nil t)))
                (cdr (assoc key table)))))
           (number (alist-get 'number choice))
           (buffer (get-buffer-create
                    (format "*forge-project: %s/%s #%s*"
                            (oref repo owner) (oref repo name) number))))
      (with-current-buffer buffer
        (forge-plugins-github-projects-mode)
        (forge-plugins-github-projects--render repo number))
      (pop-to-buffer buffer))))

;;;###autoload
(defun forge-plugins-github-projects-enable ()
  "Enable the GitHub Projects v2 board viewer and topic integration.
Installs the topic Projects section and binds the \\`p' prefix
\(add/set-status/remove) in `forge-topic-mode-map'."
  (interactive)
  (setq forge-plugins-github-projects-enable t)
  (advice-add 'forge-insert-post :before
              #'forge-plugins-github-projects--insert-membership)
  (when (boundp 'forge-topic-mode-map)
    (keymap-set forge-topic-mode-map "p"
                forge-plugins-github-projects-prefix-map)))

;;;###autoload
(defun forge-plugins-github-projects-disable ()
  "Disable the GitHub Projects v2 viewer and topic integration."
  (interactive)
  (setq forge-plugins-github-projects-enable nil)
  (advice-remove 'forge-insert-post
                 #'forge-plugins-github-projects--insert-membership)
  (when (boundp 'forge-topic-mode-map)
    (keymap-unset forge-topic-mode-map "p" t)))

;;;###autoload
(defcustom forge-plugins-github-projects-enable nil
  "Whether to enable the read-only GitHub Projects v2 board viewer."
  :package-version '(forge-plugins-github-projects . "0.1.0")
  :group 'forge
  :type 'boolean
  :set (lambda (sym val)
         (set-default sym val)
         (when (featurep 'forge-plugins-github-projects)
           (if val
               (forge-plugins-github-projects-enable)
             (forge-plugins-github-projects-disable)))))

(when forge-plugins-github-projects-enable
  (forge-plugins-github-projects-enable))

(provide 'forge-plugins-github-projects)
;;; forge-plugins-github-projects.el ends here
