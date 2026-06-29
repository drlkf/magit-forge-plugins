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
(require 'ghub)
(require 'magit-section)

(declare-function forge-get-repository "forge-core")

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
         (options (alist-get 'nodes
                             (alist-get 'options (alist-get 'field project))))
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
  "Enable the read-only GitHub Projects v2 board viewer."
  (interactive)
  (setq forge-plugins-github-projects-enable t))

;;;###autoload
(defun forge-plugins-github-projects-disable ()
  "Disable the read-only GitHub Projects v2 board viewer."
  (interactive)
  (setq forge-plugins-github-projects-enable nil))

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
