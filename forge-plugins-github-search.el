;;; forge-plugins-github-search.el --- Read-only GitHub search results  -*- lexical-binding: t; -*-

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

;; `forge' has no way to browse results of GitHub's search query syntax
;; (e.g. `review-requested:@me', `status:success', saved-search style
;; queries), since it only models topics already synced into its local
;; database.  This plugin runs an arbitrary GitHub search query string
;; directly against the GraphQL `search' root field and renders the
;; matching issues and pull requests in a flat, read-only list.
;;
;; `forge-plugins-github-search' prompts for a query string and opens
;; the results; `forge-plugins-github-search-browse-query' does the
;; same non-interactively, for callers that hardcode a query (e.g. a
;; saved search reproduced as a query string, since GitHub has no
;; public API to resolve saved searches by id).
;;
;; GraphQL is sent as a raw query string POSTed to `/graphql' via
;; `ghub-request' with `:auth 'forge', reusing the repository's
;; existing token and host, mirroring
;; `forge-plugins-github-projects''s approach.

;;; Code:

(require 'forge nil t)
(require 'ghub)
(require 'magit-section)
(require 'transient)
(require 'cl-lib)

(declare-function forge--ls-repos "forge-repo")

(defconst forge-plugins-github-search-tested-on-forge "0.6.6"
  "Forge version this plugin was tested against.")

(defvar-local forge-plugins-github-search--repo nil
  "The forge repository used to authenticate the current search buffer.")

(defvar-local forge-plugins-github-search--query nil
  "The GitHub search query string displayed in the current buffer.")

(defconst forge-plugins-github-search--query-string
  "query($q:String!){
     search(query:$q, type:ISSUE, first:100){
       issueCount
       nodes{
         ... on Issue{
           __typename number title url state
           repository{ nameWithOwner }
         }
         ... on PullRequest{
           __typename number title url state isDraft
           repository{ nameWithOwner }
         }
       }
     }
   }"
  "GraphQL query running a search string against issues and pull requests.")

(defun forge-plugins-github-search--errors (body)
  "Return a joined message string for BODY's GraphQL `errors', or nil."
  (when-let ((errors (alist-get 'errors body)))
    (mapconcat (lambda (e) (or (alist-get 'message e) "unknown error"))
               errors "; ")))

(defun forge-plugins-github-search--graphql (repo query-string)
  "Run the search GraphQL QUERY-STRING for REPO, returning the matching nodes.
Signals a `user-error' on transport or GraphQL errors."
  (let* ((payload `((query . ,forge-plugins-github-search--query-string)
                    (variables . ((q . ,query-string)))))
         (body (ghub-request "POST" "/graphql" nil
                 :payload payload :auth 'forge
                 :host (oref repo apihost) :forge 'github))
         (msg (forge-plugins-github-search--errors body)))
    (when msg
      (user-error "GitHub GraphQL error: %s" msg))
    (let-alist (alist-get 'data body) .search.nodes)))

(defun forge-plugins-github-search--any-repository ()
  "Return the first tracked forge-github-repository or signal `user-error'.
Used to borrow authentication credentials when there is no buffer-local
forge repository, e.g. the search buffer opened from an arbitrary buffer."
  (or (seq-find (lambda (r) (and (cl-typep r 'forge-github-repository)
                                 (eq (oref r condition) :tracked)))
                (forge--ls-repos))
      (user-error "No tracked GitHub repository to authenticate with")))

(defun forge-plugins-github-search--item-face (state)
  "Return the face for an item whose STATE is given (may be nil)."
  (pcase state
    ("MERGED" 'magit-dimmed)
    ("CLOSED" 'magit-dimmed)
    (_        'default)))

(defun forge-plugins-github-search--insert-item (item)
  "Insert a single result line for ITEM (an alist from the search query)."
  (let* ((number (alist-get 'number item))
         (title (or (alist-get 'title item) "(untitled)"))
         (url (alist-get 'url item))
         (state (alist-get 'state item))
         (draft (eq (alist-get 'isDraft item) t))
         (repo-name (let-alist item .repository.nameWithOwner))
         (beg (point)))
    (insert "  ")
    (when repo-name
      (insert (propertize (format "%s " repo-name) 'face 'magit-dimmed)))
    (when number
      (insert (propertize (format "#%s " number) 'face 'magit-dimmed)))
    (when draft
      (insert (propertize "[draft] " 'face 'magit-dimmed)))
    (insert (propertize title 'face
                        (forge-plugins-github-search--item-face state)))
    (insert "\n")
    (add-text-properties
     beg (point)
     (list 'forge-plugins-github-search-url url
           'keymap forge-plugins-github-search-item-map))))

(defun forge-plugins-github-search-browse-item ()
  "Open the search result item at point in the browser."
  (interactive)
  (if-let ((url (get-text-property (point) 'forge-plugins-github-search-url)))
      (browse-url url)
    (user-error "No URL for this item")))

(defvar-keymap forge-plugins-github-search-item-map
  :doc "Keymap on a search result item line."
  "RET" #'forge-plugins-github-search-browse-item
  "b"   #'forge-plugins-github-search-browse-item)

(transient-define-prefix forge-plugins-github-search-help ()
  "Show available keys in the GitHub search results buffer."
  ["Actions"
   ("g" "Refresh results" revert-buffer)])

(defvar-keymap forge-plugins-github-search-mode-map
  :doc "Keymap for `forge-plugins-github-search-mode'."
  :parent magit-section-mode-map
  "?" #'forge-plugins-github-search-help
  "g" #'revert-buffer)

(define-derived-mode forge-plugins-github-search-mode magit-section-mode
  "Forge-Search"
  "Major mode for viewing read-only GitHub search results.

\\{forge-plugins-github-search-mode-map}"
  (setq-local revert-buffer-function
              #'forge-plugins-github-search--revert))

(defun forge-plugins-github-search--render (repo query-string)
  "Render the results of QUERY-STRING run with REPO's credentials.
Draws into the current buffer."
  (let* ((items (forge-plugins-github-search--graphql repo query-string))
         (inhibit-read-only t))
    (erase-buffer)
    (setq forge-plugins-github-search--repo repo
          forge-plugins-github-search--query query-string)
    (magit-insert-section (forge-plugins-github-search-results)
      (insert (magit--propertize-face query-string 'magit-section-heading))
      (magit-insert-heading)
      (if items
          (dolist (item items)
            (forge-plugins-github-search--insert-item item))
        (insert (propertize "  (no results)\n" 'face 'magit-dimmed))))
    (goto-char (point-min))))

(defun forge-plugins-github-search--revert (&rest _)
  "Re-run the query and redraw the results in the current buffer."
  (forge-plugins-github-search--render
   forge-plugins-github-search--repo
   forge-plugins-github-search--query))

;;;###autoload
(defun forge-plugins-github-search-browse-query (query-string &optional title)
  "Open a read-only buffer listing GitHub search results for QUERY-STRING.
Optional TITLE names the buffer; defaults to QUERY-STRING truncated to
60 characters.  Requires the plugin to be enabled."
  (unless forge-plugins-github-search-enable
    (user-error "The GitHub Search plugin is disabled"))
  (let* ((repo (forge-plugins-github-search--any-repository))
         (buffer (get-buffer-create
                  (format "*forge-search: %s*"
                          (or title (truncate-string-to-width
                                     query-string 60 nil nil t))))))
    (with-current-buffer buffer
      (forge-plugins-github-search-mode)
      (forge-plugins-github-search--render repo query-string))
    (pop-to-buffer buffer)))

;;;###autoload
(defun forge-plugins-github-search (query-string)
  "Prompt for a GitHub search QUERY-STRING and open its results.
See `forge-plugins-github-search-browse-query'."
  (interactive "sGitHub search query: ")
  (forge-plugins-github-search-browse-query query-string))

;;;###autoload
(defun forge-plugins-github-search-enable ()
  "Enable the GitHub search results viewer."
  (interactive)
  (setq forge-plugins-github-search-enable t))

;;;###autoload
(defun forge-plugins-github-search-disable ()
  "Disable the GitHub search results viewer."
  (interactive)
  (setq forge-plugins-github-search-enable nil))

;;;###autoload
(defcustom forge-plugins-github-search-enable nil
  "Whether to enable the read-only GitHub search results viewer."
  :package-version '(forge-plugins-github-search . "0.1.0")
  :group 'forge
  :type 'boolean
  :set (lambda (sym val)
         (set-default sym val)
         (when (featurep 'forge-plugins-github-search)
           (if val
               (forge-plugins-github-search-enable)
             (forge-plugins-github-search-disable)))))

(when forge-plugins-github-search-enable
  (forge-plugins-github-search-enable))

(provide 'forge-plugins-github-search)
;;; forge-plugins-github-search.el ends here
