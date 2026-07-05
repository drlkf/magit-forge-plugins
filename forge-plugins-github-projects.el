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
;; This plugin adds a board viewer and topic integration.
;; `forge-plugins-github-projects' lists the Projects v2 boards attached
;; to the current forge repository; selecting one opens a read-only
;; buffer that groups the board's items into columns by its
;; single-select "Status" field (the field that drives the board
;; columns) and renders each column as a collapsible `magit' section.
;; Cards show their type, number and title; `RET' or `b' on a card opens
;; it in the browser.
;;
;; In issue and pull request topic buffers, a "Projects" section lists
;; the boards the topic belongs to and its status on each, and a `p'
;; prefix keymap adds the topic to a board (`p a'), sets its status
;; (`p s') or removes it (`p r').
;;
;; All GraphQL is sent as raw query/mutation strings POSTed to
;; `/graphql' via `ghub-request' with `:auth 'forge', reusing the
;; repository's existing token and host.  Raw strings are required
;; because Projects v2 traverses unions and interfaces, which need
;; inline fragments that `ghub''s gsexp query builder cannot express.

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

(defvar-local forge-plugins-github-projects--project-id nil
  "The ProjectV2 node ID displayed in the current buffer.")

;; Projects v2 queries traverse GraphQL unions and interfaces
;; (`issueOrPullRequest', `fieldValueByName', single-select `field'),
;; which require inline fragments.  ghub's gsexp encoder cannot express
;; inline fragments, so these are raw GraphQL strings POSTed to
;; `/graphql' via `ghub-request' (the same primitive `forge' uses for
;; REST), rather than gsexp forms passed to `ghub-query'.

(defconst forge-plugins-github-projects--list-query
  "query($owner:String!,$name:String!){
     repository(owner:$owner,name:$name){
       projectsV2(first:50){ nodes{ id number title closed } }
     }
   }"
  "GraphQL query listing the repository's Projects v2 boards.")

(defconst forge-plugins-github-projects--items-query
  "query($id:ID!){
     node(id:$id){
       ... on ProjectV2{
         title url
         field(name:\"Status\"){
           ... on ProjectV2SingleSelectField{ options{ id name } }
         }
         items(first:100){
           nodes{
             fieldValueByName(name:\"Status\"){
               ... on ProjectV2ItemFieldSingleSelectValue{ optionId name }
             }
             content{
               ... on Issue{ __typename number title url state }
               ... on PullRequest{ __typename number title url state }
               ... on DraftIssue{ __typename title }
             }
           }
         }
       }
     }
   }"
  "GraphQL query fetching one board's items grouped data.
The board is resolved by its ProjectV2 node ID via the `node' root
field: a project's number is scoped to its owning org or user, so a
repo-linked org project does not resolve under `repository.projectV2'.")

(defun forge-plugins-github-projects--errors (body)
  "Return a joined message string for BODY's GraphQL `errors', or nil."
  (when-let ((errors (alist-get 'errors body)))
    (mapconcat (lambda (e) (or (alist-get 'message e) "unknown error"))
               errors "; ")))

(cl-defun forge-plugins-github-projects--graphql
    (repo query variables &key callback errorback)
  "POST GraphQL QUERY string with VARIABLES to REPO's GraphQL endpoint.
VARIABLES is an alist encoded as the JSON variables object.  With no
CALLBACK, run synchronously and return the response `data', signalling
a `user-error' on transport or GraphQL errors.  With CALLBACK, run
asynchronously: CALLBACK gets the `data' object, ERRORBACK a message
string.  Authentication and host come from REPO, as `forge' does its
own requests."
  (let ((payload `((query . ,query) (variables . ,variables))))
    (if callback
        (ghub-request "POST" "/graphql" nil
          :payload payload :auth 'forge :host (oref repo apihost) :forge 'github
          :callback
          (lambda (body _headers _status _req)
            (if-let ((msg (forge-plugins-github-projects--errors body)))
                (when errorback (funcall errorback msg))
              (funcall callback (alist-get 'data body))))
          :errorback
          (lambda (err _headers _status _req)
            (when errorback (funcall errorback (format "%S" err)))))
      (let* ((body (ghub-request "POST" "/graphql" nil
                     :payload payload :auth 'forge
                     :host (oref repo apihost) :forge 'github))
             (msg (forge-plugins-github-projects--errors body)))
        (when msg
          (user-error "GitHub GraphQL error: %s" msg))
        (alist-get 'data body)))))

(defun forge-plugins-github-projects--query (query repo &rest variables)
  "Run GraphQL QUERY string for REPO synchronously, returning the data.
VARIABLES are extra `:key value' pairs merged with the repository's
owner and name into the GraphQL variables object."
  (forge-plugins-github-projects--graphql
   repo query
   (append (list (cons 'owner (oref repo owner))
                 (cons 'name (oref repo name)))
           (cl-loop for (k v) on variables by #'cddr
                    collect (cons (intern (substring (symbol-name k) 1)) v)))))

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
   forge-plugins-github-projects--project-id))

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

(defun forge-plugins-github-projects--render (repo project-id)
  "Render the Projects v2 board PROJECT-ID (a node ID) of REPO.
Draws into the current buffer."
  (let* ((data (forge-plugins-github-projects--graphql
                repo forge-plugins-github-projects--items-query
                (list (cons 'id project-id))))
         (project (let-alist data .node))
         ;; `options' on a single-select field is a plain list, not a
         ;; Relay connection, so it has no `nodes' wrapper.
         (options (alist-get 'options (alist-get 'field project)))
         (items (alist-get 'nodes (alist-get 'items project)))
         (inhibit-read-only t))
    (erase-buffer)
    (setq forge-plugins-github-projects--repo repo
          forge-plugins-github-projects--project-id project-id)
    (magit-insert-section (forge-plugins-github-projects-board)
      (insert (magit--propertize-face (or (alist-get 'title project) "Project")
                                      'magit-section-heading))
      (magit-insert-heading)
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
- `:error': the error message string when the last fetch failed.")

(defconst forge-plugins-github-projects--membership-query-template
  "query($owner:String!,$name:String!,$number:Int!){
     repository(owner:$owner,name:$name){
       topic: %s(number:$number){
         id
         projectItems(first:20){
           nodes{
             id
             project{ id number title url }
             fieldValueByName(name:\"Status\"){
               ... on ProjectV2ItemFieldSingleSelectValue{ name }
             }
           }
         }
       }
     }
   }"
  "GraphQL query template for a topic's Projects v2 membership.
The single `%s' is the content field, `issue' or `pullRequest'; it is
aliased to `topic' so the response shape is uniform.")

(defun forge-plugins-github-projects--membership-query (topic)
  "Return the membership query string specialized for TOPIC's type."
  (format forge-plugins-github-projects--membership-query-template
          (if (forge-issue-p topic) "issue" "pullRequest")))

(defun forge-plugins-github-projects--parse-items (nodes)
  "Turn membership-query NODES into the cached item plists."
  (mapcar
   (lambda (node)
     (list :id (alist-get 'id node)
           :project (alist-get 'project node)
           :status (alist-get 'name (alist-get 'fieldValueByName node))))
   nodes))

(defun forge-plugins-github-projects--content (data)
  "Return the aliased `topic' object from membership response DATA."
  (let-alist data .repository.topic))

(defun forge-plugins-github-projects--refresh-topic-buffers ()
  "Refresh open issue and pull request topic buffers."
  (dolist (buf (buffer-list))
    (with-current-buffer buf
      (when (derived-mode-p 'forge-topic-mode)
        (magit-refresh-buffer)))))

(defun forge-plugins-github-projects--membership-plist (data)
  "Build a cache plist from a membership response DATA object."
  (let ((content (forge-plugins-github-projects--content data)))
    (list :content-id (alist-get 'id content)
          :items (forge-plugins-github-projects--parse-items
                  (alist-get 'nodes (alist-get 'projectItems content)))
          :fetching nil)))

(defun forge-plugins-github-projects--fetch-membership (topic)
  "Fetch TOPIC's Projects v2 membership asynchronously and cache it."
  (let ((id (oref topic id))
        (repo (forge-get-repository topic)))
    (puthash id (list :fetching t) forge-plugins-github-projects--items-cache)
    (forge-plugins-github-projects--graphql
     repo
     (forge-plugins-github-projects--membership-query topic)
     (list (cons 'owner (oref repo owner))
           (cons 'name (oref repo name))
           (cons 'number (oref topic number)))
     :callback
     (lambda (data)
       (puthash id (forge-plugins-github-projects--membership-plist data)
                forge-plugins-github-projects--items-cache)
       (forge-plugins-github-projects--refresh-topic-buffers))
     :errorback
     (lambda (msg)
       (puthash id (list :error msg :fetching nil)
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
        (insert (magit--propertize-face "Projects" 'magit-section-heading))
        (magit-insert-heading)
        (magit-insert-section-body
          (cond
           ((plist-get cached :fetching)
            (insert (propertize "  fetching...\n" 'face 'magit-dimmed)))
           ((plist-get cached :error)
            (insert (propertize
                     (format "  error: %s\n" (plist-get cached :error))
                     'face 'error)))
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
  "Run GraphQL MUTATION string for REPO with VARIABLES, synchronously.
Signals a `user-error' on a GraphQL error."
  (forge-plugins-github-projects--graphql repo mutation variables))

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
    ;; (so a transient failure does not poison the cache).  The
    ;; synchronous `--graphql' path signals a `user-error' on a GraphQL
    ;; error, so a permission failure propagates to the interactive
    ;; command with its real message rather than caching as "no projects".
    (when (or (null cached)
              (plist-get cached :fetching)
              (plist-get cached :error))
      (let* ((repo (forge-get-repository topic))
             (data (forge-plugins-github-projects--query
                    (forge-plugins-github-projects--membership-query topic)
                    repo :number (oref topic number))))
        (setq cached (forge-plugins-github-projects--membership-plist data))
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
          (let ((table (mapcar
                        (lambda (it)
                          (let ((project (plist-get it :project)))
                            (cons (format "#%s  %s"
                                          (alist-get 'number project)
                                          (alist-get 'title project))
                                  it)))
                        items)))
            (cdr (assoc (completing-read prompt table nil t) table)))))))

(defun forge-plugins-github-projects--status-field (repo project-id)
  "Return (FIELD-ID . OPTIONS) for the Status field of project PROJECT-ID.
The query is issued against REPO's GraphQL endpoint.  PROJECT-ID is the
ProjectV2 GraphQL node ID.  OPTIONS is an alist of
option name to option ID.  Returns nil when the project has no
single-select Status field.  The project is resolved by node ID via
the `node' root field, not by number under the repository: a project's
number is scoped to its owning organization or user, so a repo-linked
org project does not resolve under `repository.projectV2'."
  (let* ((data (forge-plugins-github-projects--graphql
                repo
                "query($id:ID!){
                   node(id:$id){
                     ... on ProjectV2{
                       field(name:\"Status\"){
                         ... on ProjectV2SingleSelectField{
                           id options{ id name }
                         }
                       }
                     }
                   }
                 }"
                (list (cons 'id project-id))))
         (field (let-alist data .node.field))
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
    (unless content-id
      (user-error "Topic has no GraphQL node id; run `forge-pull' first"))
    (unless projects
      (user-error "No open Projects v2 boards on %s/%s"
                  (oref repo owner) (oref repo name)))
    (let* ((table (mapcar (lambda (p)
                            (cons (format "#%s  %s"
                                          (alist-get 'number p)
                                          (alist-get 'title p))
                                  p))
                          projects))
           (choice (cdr (assoc (completing-read "Add to project: " table nil t)
                               table))))
      (forge-plugins-github-projects--mutate
       "mutation($input:AddProjectV2ItemByIdInput!){
          addProjectV2ItemById(input:$input){ item{ id } }
        }"
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
                 repo (alist-get 'id project))))
    (unless field
      (user-error "Project %s has no Status field" (alist-get 'title project)))
    (let* ((options (cdr field))
           (option-id (cdr (assoc (completing-read
                                   "Status: " options nil t)
                                  options))))
      (forge-plugins-github-projects--mutate
       "mutation($input:UpdateProjectV2ItemFieldValueInput!){
          updateProjectV2ItemFieldValue(input:$input){ projectV2Item{ id } }
        }"
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
       "mutation($input:DeleteProjectV2ItemInput!){
          deleteProjectV2Item(input:$input){ deletedItemId }
        }"
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
           (buffer (get-buffer-create
                    (format "*forge-project: %s/%s #%s*"
                            (oref repo owner) (oref repo name)
                            (alist-get 'number choice)))))
      (with-current-buffer buffer
        (forge-plugins-github-projects-mode)
        (forge-plugins-github-projects--render repo (alist-get 'id choice)))
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
