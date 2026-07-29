;;; forge-plugins-github-reviews.el --- GitHub pull request review threads  -*- lexical-binding: t; -*-

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

;; `forge' has no support for GitHub pull request review threads — the
;; resolvable, inline code-comment conversations.  This plugin adds
;; them.
;;
;; Pull request topic lines (in topic/notification lists and the Magit
;; status buffer) and the pull request topic view gain a `{x}' badge,
;; where X is the number of unresolved review threads.  The badge is
;; hidden when everything is resolved or there are no threads.
;;
;; In `forge-pullreq-mode' a collapsible `Reviews' section lists review
;; submissions with bodies, review threads, and their comments.  A `v'
;; prefix keymap acts on the thread or comment at point: reply to a
;; thread (`v c'), edit your own comment (`v e'), add a reaction
;; (`v @'), resolve/unresolve the thread (`v r') and refresh (`v g').
;;
;; All GitHub review-thread data is fetched and mutated through the
;; GraphQL API (`/graphql'), as `forge' models none of it, reusing the
;; repository's existing token and host via `ghub-request' with
;; `:auth 'forge'.  Reads for the badge are asynchronous, queued and
;; cached like the approvals plugin, so opening a topic never blocks on
;; the network; the mutation commands run synchronously in response to
;; a keypress, then invalidate the cache and refresh.

;;; Code:

(require 'forge nil t)
(require 'forge-topic nil t)
(require 'forge-pullreq nil t)
(require 'forge-post nil t)
(require 'ghub)
(require 'magit-status nil t)
(require 'magit-section nil t)
(require 'transient)
(require 'cl-lib)

(declare-function forge-get-repository "forge-core")
(declare-function forge-get-worktree "forge-repo")
(declare-function forge-pullreq-p "forge-pullreq")
(declare-function forge--setup-post-buffer "forge-post")
(declare-function forge--maybe-restore-winconf "forge-post")

(defconst forge-plugins-github-reviews-tested-on-forge "0.6.6"
  "Forge version this plugin was tested against.")

;;;###autoload
(defcustom forge-plugins-github-reviews-debug nil
  "Whether to enable debug logging for the GitHub reviews plugin.
If non-nil, debug logs are written to the buffer
`*forge-plugins-github-reviews-debug*`."
  :package-version '(forge-plugins-github-reviews . "0.1.0")
  :group 'forge
  :type 'boolean)

;;;###autoload
(defcustom forge-plugins-github-reviews-max-concurrent-requests 6
  "Maximum number of review-thread fetches to run concurrently.
Pending fetches beyond this limit are queued and dispatched as
in-flight requests complete.  This bounds parallelism so the
GitHub API is not hammered while keeping fetches concurrent."
  :package-version '(forge-plugins-github-reviews . "0.1.0")
  :group 'forge
  :type 'integer)

;;;###autoload
(defcustom forge-plugins-github-reviews-refresh-delay 0.3
  "Throttle window, in seconds, for applying fetched reviews to buffers.
Topic-list buffers (Magit status, forge topics and notifications) have
their per-topic review badges patched in place; all completions within
one window are applied in a single section-tree walk and redisplay, so
a burst of fetches on a large topic list does not stutter Emacs.  Pull
request topic buffers, which carry the full Reviews section, are
refreshed via `magit-refresh-buffer', coalesced the same way.  Lower
values update more eagerly; higher values coalesce more aggressively."
  :package-version '(forge-plugins-github-reviews . "0.1.0")
  :group 'forge
  :type 'number)

(defun forge-plugins-github-reviews--debug (format-string &rest args)
  "Log a message to the debug buffer if debug logging is enabled.
FORMAT-STRING and ARGS are passed to `format'."
  (when forge-plugins-github-reviews-debug
    (let ((buf (get-buffer-create "*forge-plugins-github-reviews-debug*")))
      (with-current-buffer buf
        (save-excursion
          (goto-char (point-max))
          (let ((inhibit-read-only t))
            (insert (format-time-string "[%Y-%m-%d %H:%M:%S] "))
            (insert (apply #'format format-string args))
            (insert "\n")))))))

(defface forge-plugins-github-reviews-unresolved
  '((t :inherit warning))
  "Face for the badge and for unresolved review threads."
  :group 'forge)

(defface forge-plugins-github-reviews-resolved
  '((t :inherit success))
  "Face for resolved review threads."
  :group 'forge)

(defvar forge-plugins-github-reviews--cache (make-hash-table :test 'equal)
  "Cache of review-thread status for pull requests.
Keys are topic IDs.
Values are plists:
- `:head-rev': the head-rev for which this status was fetched.
- `:threads': list of thread plists (see
  `forge-plugins-github-reviews--parse').
- `:reviews': review submissions with non-empty bodies.
- `:unresolved': number of unresolved review threads.
- `:fetching': boolean, whether a fetch is in progress.
- `:error': boolean, whether the last fetch failed.")

;;;; GraphQL

(defconst forge-plugins-github-reviews--query
  "query($owner:String!,$name:String!,$number:Int!){
     repository(owner:$owner,name:$name){
       pullRequest(number:$number){
          reviewThreads(first:100){
           nodes{
             id isResolved isOutdated path line
             comments(first:100){
               nodes{ id author{ login } body url viewerDidAuthor }
            }
          }
          reviews(first:100){
            nodes{ id author{ login } body state url }
          }
         }
       }
     }
   }"
  "GraphQL query fetching a pull request's review threads and comments.")

(defun forge-plugins-github-reviews--errors (body)
  "Return a joined message string for BODY's GraphQL `errors', or nil."
  (when-let ((errors (alist-get 'errors body)))
    (mapconcat (lambda (e) (or (alist-get 'message e) "unknown error"))
               errors "; ")))

(cl-defun forge-plugins-github-reviews--graphql
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
            (if-let ((msg (forge-plugins-github-reviews--errors body)))
                (when errorback (funcall errorback msg))
              (funcall callback (alist-get 'data body))))
          :errorback
          (lambda (err _headers _status _req)
            (when errorback (funcall errorback (format "%S" err)))))
      (let* ((body (ghub-request "POST" "/graphql" nil
                     :payload payload :auth 'forge
                     :host (oref repo apihost) :forge 'github))
             (msg (forge-plugins-github-reviews--errors body)))
        (when msg
          (user-error "GitHub GraphQL error: %s" msg))
        (alist-get 'data body)))))

(defun forge-plugins-github-reviews--variables (topic)
  "Return the GraphQL variables alist locating TOPIC's pull request."
  (let ((repo (forge-get-repository topic)))
    (list (cons 'owner (oref repo owner))
          (cons 'name (oref repo name))
          (cons 'number (oref topic number)))))

(defun forge-plugins-github-reviews--parse (data)
  "Parse review response DATA into a plist.
THREADS is a list of plists, each with `:id', `:resolved',
`:outdated', `:path', `:line' and `:comments' (a list of plists with
`:id', `:login', `:body', `:url' and `:viewer').  UNRESOLVED is the
number of threads whose `:resolved' is nil.  Reviews contains only
review submissions with non-empty bodies."
  (let* ((nodes (let-alist data .repository.pullRequest.reviewThreads.nodes))
         (review-nodes (let-alist data .repository.pullRequest.reviews.nodes))
         (threads
          (mapcar
           (lambda (tn)
             (list :id (alist-get 'id tn)
                   :resolved (eq (alist-get 'isResolved tn) t)
                   :outdated (eq (alist-get 'isOutdated tn) t)
                   :path (alist-get 'path tn)
                   :line (alist-get 'line tn)
                   :comments
                   (mapcar
                    (lambda (cn)
                      (list :id (alist-get 'id cn)
                            :login (alist-get 'login (alist-get 'author cn))
                            :body (alist-get 'body cn)
                            :url (alist-get 'url cn)
                            :viewer (eq (alist-get 'viewerDidAuthor cn) t)))
                    (alist-get 'nodes (alist-get 'comments tn)))))
           nodes)))
    (list :threads threads
          :unresolved (cl-count-if-not
                       (lambda (th) (plist-get th :resolved)) threads)
          :reviews
          (cl-loop for review in review-nodes
                   for body = (alist-get 'body review)
                   when (and body (not (string-empty-p body)))
                   collect (list :id (alist-get 'id review)
                                 :login (alist-get 'login (alist-get 'author review))
                                 :body body
                                 :state (alist-get 'state review)
                                 :url (alist-get 'url review))))))

;;;; Refresh and in-place badge patching (mirrors the approvals plugin)

(defun forge-plugins-github-reviews--refresh-buffers ()
  "Refresh open pull request topic buffers.
Only `forge-pullreq-mode' buffers are fully refreshed, because that is
the only mode carrying the Reviews section.  Topic-list buffers have
their per-topic badge patched in place instead."
  (dolist (buf (buffer-list))
    (with-current-buffer buf
      (when (derived-mode-p 'forge-pullreq-mode)
        (magit-refresh-buffer)))))

(defvar forge-plugins-github-reviews--refresh-timer nil
  "Pending timer used to coalesce pull request buffer refreshes.")

(defun forge-plugins-github-reviews--schedule-refresh ()
  "Schedule a debounced refresh of open pull request buffers.
Multiple calls within `forge-plugins-github-reviews-refresh-delay'
seconds are coalesced into a single refresh."
  (when (timerp forge-plugins-github-reviews--refresh-timer)
    (cancel-timer forge-plugins-github-reviews--refresh-timer))
  (setq forge-plugins-github-reviews--refresh-timer
        (run-with-timer
         forge-plugins-github-reviews-refresh-delay nil
         (lambda ()
           (setq forge-plugins-github-reviews--refresh-timer nil)
           (forge-plugins-github-reviews--refresh-buffers)))))

(defun forge-plugins-github-reviews--patch-line-badge (section topic)
  "Replace the review badge on SECTION's topic line for TOPIC in place.
The badge text (carrying the `forge-plugins-github-reviews-status'
property) and its promoted overlays are removed, then the current
badge from the cache is re-inserted and re-promoted."
  (save-excursion
    (let* ((start (oref section start))
           (eol (progn (goto-char start) (line-end-position)))
           (badge (text-property-any start eol
                                     'forge-plugins-github-reviews-status t)))
      (with-silent-modifications
        (let ((inhibit-read-only t))
          (when badge
            (dolist (o (overlays-in badge eol))
              (when (overlay-get o 'forge-plugins-github-reviews-badge)
                (delete-overlay o)))
            (delete-region (if (eq (char-before badge) ?\s) (1- badge) badge)
                           eol)
            (setq eol (line-end-position)))
          (when-let ((status-str
                      (forge-plugins-github-reviews--get-status-string topic)))
            (goto-char eol)
            (let ((beg (point)))
              (insert " " status-str)
              (forge-plugins-github-reviews--promote-status-overlay
               beg (point)))))))))

(defvar forge-plugins-github-reviews--pending (make-hash-table :test 'equal)
  "Topics whose review badge awaits an in-place patch.
Keys are topic IDs, values the topics.")

(defvar forge-plugins-github-reviews--flush-timer nil
  "Pending timer used to throttle in-place badge patching.")

(defun forge-plugins-github-reviews--flush ()
  "Patch every pending topic's badge in one pass per list buffer."
  (setq forge-plugins-github-reviews--flush-timer nil)
  (let ((batch forge-plugins-github-reviews--pending))
    (setq forge-plugins-github-reviews--pending (make-hash-table :test 'equal))
    (dolist (buf (buffer-list))
      (with-current-buffer buf
        (when (and (or (derived-mode-p 'forge-topics-mode)
                       (derived-mode-p 'magit-status-mode)
                       (derived-mode-p 'forge-notifications-mode))
                   (bound-and-true-p magit-root-section))
          (letrec ((walk
                    (lambda (section)
                      (let ((value (oref section value)))
                        (when (forge-pullreq-p value)
                          (when-let ((topic (gethash (oref value id) batch)))
                            (forge-plugins-github-reviews--patch-line-badge
                             section topic))))
                      (dolist (child (oref section children))
                        (funcall walk child)))))
            (funcall walk magit-root-section)))))))

(defun forge-plugins-github-reviews--note-pending (topic)
  "Queue TOPIC for a throttled in-place badge patch, then a refresh."
  (puthash (oref topic id) topic forge-plugins-github-reviews--pending)
  (unless (timerp forge-plugins-github-reviews--flush-timer)
    (setq forge-plugins-github-reviews--flush-timer
          (run-with-timer
           forge-plugins-github-reviews-refresh-delay nil
           #'forge-plugins-github-reviews--flush)))
  (forge-plugins-github-reviews--schedule-refresh))

;;;; Fetch queue

(defvar forge-plugins-github-reviews--queue nil
  "FIFO list of topics pending a review-thread fetch.")

(defvar forge-plugins-github-reviews--queue-tail nil
  "Last cons of `forge-plugins-github-reviews--queue'.
Tracked so enqueuing appends in constant time.")

(defvar forge-plugins-github-reviews--inflight 0
  "Number of review-thread fetches currently in flight.")

(defvar forge-plugins-github-reviews--dispatch-timer nil
  "Pending timer used to drain the fetch queue off the redisplay path.")

(defun forge-plugins-github-reviews--enqueue (topic)
  "Queue TOPIC for a review fetch and schedule the queue to drain."
  (let ((cell (list topic)))
    (if forge-plugins-github-reviews--queue-tail
        (setcdr forge-plugins-github-reviews--queue-tail cell)
      (setq forge-plugins-github-reviews--queue cell))
    (setq forge-plugins-github-reviews--queue-tail cell))
  (unless (timerp forge-plugins-github-reviews--dispatch-timer)
    (setq forge-plugins-github-reviews--dispatch-timer
          (run-with-timer
           0 nil
           (lambda ()
             (setq forge-plugins-github-reviews--dispatch-timer nil)
             (forge-plugins-github-reviews--dispatch))))))

(defun forge-plugins-github-reviews--dispatch ()
  "Dispatch queued fetches up to the concurrency limit."
  (while (and forge-plugins-github-reviews--queue
              (< forge-plugins-github-reviews--inflight
                 forge-plugins-github-reviews-max-concurrent-requests))
    (let ((topic (pop forge-plugins-github-reviews--queue)))
      (unless forge-plugins-github-reviews--queue
        (setq forge-plugins-github-reviews--queue-tail nil))
      (cl-incf forge-plugins-github-reviews--inflight)
      (forge-plugins-github-reviews--fetch topic))))

(defun forge-plugins-github-reviews--fetch-done ()
  "Account for a completed fetch and dispatch any queued ones."
  (when (> forge-plugins-github-reviews--inflight 0)
    (cl-decf forge-plugins-github-reviews--inflight))
  (forge-plugins-github-reviews--dispatch))

(defun forge-plugins-github-reviews--store (topic head-rev data)
  "Store the parsed review-thread DATA for TOPIC into the cache.
HEAD-REV is the head-rev the fetch was performed against."
  (let ((parsed (forge-plugins-github-reviews--parse data)))
    (puthash (oref topic id)
             (list :head-rev head-rev
                   :threads (plist-get parsed :threads)
                   :unresolved (plist-get parsed :unresolved)
                   :reviews (plist-get parsed :reviews)
                   :fetching nil)
             forge-plugins-github-reviews--cache)
    (forge-plugins-github-reviews--debug
     "Stored reviews for topic %s: unresolved=%s" (oref topic id) (cdr parsed)))
  (forge-plugins-github-reviews--fetch-done)
  (forge-plugins-github-reviews--note-pending topic))

(defun forge-plugins-github-reviews--store-error (topic head-rev)
  "Record a failed review fetch for TOPIC against HEAD-REV."
  (puthash (oref topic id)
           (list :head-rev head-rev :fetching nil :error t)
           forge-plugins-github-reviews--cache)
  (forge-plugins-github-reviews--fetch-done)
  (forge-plugins-github-reviews--note-pending topic))

(defun forge-plugins-github-reviews--fetch (topic)
  "Fetch review-thread status for TOPIC asynchronously."
  (let ((repo (forge-get-repository topic))
        (head-rev (oref topic head-rev)))
    (forge-plugins-github-reviews--debug
     "Fetching reviews for topic %s (head-rev: %s)" (oref topic id) head-rev)
    (forge-plugins-github-reviews--graphql
     repo forge-plugins-github-reviews--query
     (forge-plugins-github-reviews--variables topic)
     :callback
     (lambda (data)
       (forge-plugins-github-reviews--store topic head-rev data))
     :errorback
     (lambda (msg)
       (forge-plugins-github-reviews--debug
        "Failed to fetch reviews for topic %s: %s" (oref topic id) msg)
       (forge-plugins-github-reviews--store-error topic head-rev)))))

;;;; Badge rendering

(defun forge-plugins-github-reviews--insert-faced (text face)
  "Insert TEXT and overlay it with FACE so it renders above highlight."
  (let ((beg (point)))
    (insert text)
    (let ((o (make-overlay beg (point))))
      (overlay-put o 'priority 2)
      (overlay-put o 'evaporate t)
      (overlay-put o 'font-lock-face face))))

(defun forge-plugins-github-reviews--promote-status-overlay (beg end)
  "Overlay status spans marked between BEG and END so they survive highlight."
  (let ((pos beg))
    (while (and pos (< pos end))
      (let ((next (next-single-property-change
                   pos 'forge-plugins-github-reviews-status nil end)))
        (when (get-text-property pos 'forge-plugins-github-reviews-status)
          (let ((o (make-overlay pos next)))
            (overlay-put o 'priority 2)
            (overlay-put o 'evaporate t)
            (overlay-put o 'forge-plugins-github-reviews-badge t)
            (overlay-put o 'font-lock-face
                         (get-text-property pos 'font-lock-face))))
        (setq pos next)))))

(defun forge-plugins-github-reviews--summary (topic)
  "Return the review-thread summary for TOPIC, triggering a fetch if needed.
The return value is a cons cell (STR . FACE), or nil when there is
nothing to display (no unresolved threads, an in-progress fetch, or an
error)."
  (let* ((id (oref topic id))
         (head-rev (oref topic head-rev))
         (cached (gethash id forge-plugins-github-reviews--cache)))
    (cond
     ((not head-rev) nil)
     ((and cached (equal (plist-get cached :head-rev) head-rev))
      (cond
       ((plist-get cached :fetching) nil)
       ((plist-get cached :error) nil)
       (t (let ((n (plist-get cached :unresolved)))
            (when (and (integerp n) (> n 0))
              (cons (format "{%d}" n)
                    'forge-plugins-github-reviews-unresolved))))))
     (t
      (puthash id (list :head-rev head-rev :fetching t)
               forge-plugins-github-reviews--cache)
      (forge-plugins-github-reviews--enqueue topic)
      nil))))

(defun forge-plugins-github-reviews--get-status-string (topic)
  "Return the formatted review badge for TOPIC, or nil."
  (when-let ((summary (forge-plugins-github-reviews--summary topic)))
    (propertize
     (magit--propertize-face (car summary) (cdr summary))
     'forge-plugins-github-reviews-status t)))

(defun forge-plugins-github-reviews--target-p (topic)
  "Return non-nil when TOPIC is a GitHub pull request to annotate."
  (and (forge-pullreq-p topic)
       (cl-typep (forge-get-repository topic) 'forge-github-repository)))

(defun forge-plugins-github-reviews--format-topic-line (orig-fun topic
                                                                 &optional width)
  "Around advice to append the review badge to the topic line.
ORIG-FUN is the advised function, called with TOPIC and WIDTH."
  (let ((line (funcall orig-fun topic width)))
    (if (and forge-plugins-github-reviews-enable
             (forge-plugins-github-reviews--target-p topic))
        (if-let ((status-str
                  (forge-plugins-github-reviews--get-status-string topic)))
            (concat line " " status-str)
          line)
      line)))

(defun forge-plugins-github-reviews--insert-topic (orig-fun topic
                                                            &optional width)
  "Around advice to promote the review badge to a highlight-proof overlay.
ORIG-FUN is `forge--insert-topic', called with TOPIC and WIDTH."
  (let ((beg (point)))
    (funcall orig-fun topic width)
    (forge-plugins-github-reviews--promote-status-overlay beg (point))))

;;;; Reviews section

(defvar-keymap forge-plugins-github-reviews-line-map
  :doc "Keymap on a review comment line in a topic buffer."
  "RET" #'forge-plugins-github-reviews-visit-file
  "b"   #'forge-plugins-github-reviews-browse)

(defvar-keymap forge-plugins-github-reviews-review-map
  :doc "Keymap on a review submission body."
  "b" #'forge-plugins-github-reviews-browse)

(defun forge-plugins-github-reviews-browse ()
  "Open the review comment at point in the browser."
  (interactive)
  (if-let ((url (get-text-property (point) 'forge-plugins-github-reviews-url)))
      (browse-url url)
    (user-error "No URL for this comment")))

(defun forge-plugins-github-reviews-visit-file ()
  "Visit the file the review thread at point comments on, at its line.
The file is opened from the current pull request's local worktree.
When the thread has no line (an outdated or file-level comment), the
file is opened at its beginning."
  (interactive)
  (let ((thread (get-text-property (point)
                                   'forge-plugins-github-reviews-thread)))
    (unless thread
      (user-error "Point is not on a review thread"))
    (let* ((path (plist-get thread :path))
           (line (plist-get thread :line))
           (topic (forge-plugins-github-reviews--current-topic))
           (worktree (forge-get-worktree (forge-get-repository topic))))
      (unless path
        (user-error "This review thread is not anchored to a file"))
      (unless worktree
        (user-error "No local worktree for this repository"))
      (let ((file (expand-file-name path worktree)))
        (unless (file-exists-p file)
          (user-error "File %s does not exist in the worktree" path))
        (find-file file)
        (when line
          (goto-char (point-min))
          (forward-line (1- line)))))))

(defun forge-plugins-github-reviews--insert-thread (thread)
  "Insert a collapsible section for review THREAD (a thread plist).
Resolved threads are collapsed by default.  The heading carries the
thread plist as a text property; each comment line additionally carries
its comment plist and URL, plus the comment keymap."
  (let* ((resolved (plist-get thread :resolved))
         (path (plist-get thread :path))
         (line (plist-get thread :line))
         (comments (plist-get thread :comments))
         (state (if resolved "resolved" "unresolved"))
         (state-face (if resolved
                         'forge-plugins-github-reviews-resolved
                       'forge-plugins-github-reviews-unresolved)))
    (magit-insert-section (forge-plugins-github-reviews-thread thread resolved)
      (let ((beg (point)))
        (insert "  ")
        (insert (magit--propertize-face
                 (format "%s:%s" (or path "?") (or line "?"))
                 'magit-section-secondary-heading))
        (insert " ")
        (forge-plugins-github-reviews--insert-faced (format "[%s]" state)
                                                    state-face)
        (insert (format " (%d)" (length comments)))
        (add-text-properties
         beg (point) (list 'forge-plugins-github-reviews-thread thread)))
      (magit-insert-heading)
      (dolist (c comments)
        (let ((beg (point))
              (body (car (split-string (or (plist-get c :body) "") "\n"))))
          (insert "    ")
          (insert (magit--propertize-face
                   (concat (or (plist-get c :login) "?") ": ")
                   'magit-section-heading))
          (insert body "\n")
          (add-text-properties
           beg (point)
           (list 'forge-plugins-github-reviews-thread thread
                 'forge-plugins-github-reviews-comment c
                 'forge-plugins-github-reviews-url (plist-get c :url)
                 'keymap forge-plugins-github-reviews-line-map)))))))

(defun forge-plugins-github-reviews--insert-review (review)
  "Insert a collapsible section for a body-bearing review submission."
  (let ((state (downcase (replace-regexp-in-string
                          "_" " " (or (plist-get review :state) "unknown")))))
    (magit-insert-section (forge-plugins-github-reviews-review review)
      (let ((beg (point)))
        (insert "  " (or (plist-get review :login) "?") " ")
        (forge-plugins-github-reviews--insert-faced
         (format "[%s]" state)
         (if (equal (plist-get review :state) "APPROVED")
             'forge-plugins-github-reviews-resolved
           'forge-plugins-github-reviews-unresolved))
        (add-text-properties
         beg (point)
         (list 'forge-plugins-github-reviews-url (plist-get review :url))))
      (magit-insert-heading)
      (dolist (line (split-string (plist-get review :body) "\n"))
        (let ((beg (point)))
          (insert "    " line "\n")
          (add-text-properties
           beg (point)
           (list 'forge-plugins-github-reviews-url (plist-get review :url)
                 'keymap forge-plugins-github-reviews-review-map))))
      (insert "\n"))))

(defun forge-plugins-github-reviews--insert-section (post &optional topic)
  "Insert a Reviews section as a sibling after the description post.
This is `:before' advice for `forge-insert-post'.  POST and TOPIC are
the advised function's arguments; the section is only inserted before
the topic's own description post, i.e. when TOPIC is nil and POST is a
GitHub pull request."
  (when (and (null topic)
             forge-plugins-github-reviews-enable
             (forge-plugins-github-reviews--target-p post))
    (let* ((tp post)
           (id (oref tp id))
           (head-rev (oref tp head-rev))
           (cached (gethash id forge-plugins-github-reviews--cache)))
      (magit-insert-section (forge-plugins-github-reviews)
        (let ((summary (forge-plugins-github-reviews--summary tp)))
          (insert (magit--propertize-face "Reviews" 'magit-section-heading))
          (when summary
            (insert " ")
            (forge-plugins-github-reviews--insert-faced
             (car summary) (cdr summary)))
          (magit-insert-heading))
        (magit-insert-section-body
          (cond
           ((and cached (equal (plist-get cached :head-rev) head-rev)
                 (not (plist-get cached :fetching)))
            (cond
             ((plist-get cached :error)
              (insert (magit--propertize-face "error" 'error) "\n"))
             ((or (plist-get cached :reviews)
                  (plist-get cached :threads))
              (dolist (review (plist-get cached :reviews))
                (forge-plugins-github-reviews--insert-review review))
              (dolist (thread (plist-get cached :threads))
                (forge-plugins-github-reviews--insert-thread thread)))
             (t (insert (magit--propertize-face "none" 'magit-dimmed) "\n"))))
           (t (insert (magit--propertize-face "fetching..." 'magit-dimmed)
                      "\n")))
          (insert "\n"))))))

;;;; Cache invalidation

(defun forge-plugins-github-reviews--invalidate (topic)
  "Drop the cached review status for TOPIC, forcing a refetch."
  (remhash (oref topic id) forge-plugins-github-reviews--cache))

;;;; Interaction

(defun forge-plugins-github-reviews--current-topic ()
  "Return the current GitHub pull request topic or signal a `user-error'."
  (or (and (boundp 'forge-buffer-topic)
           forge-buffer-topic
           (forge-plugins-github-reviews--target-p forge-buffer-topic)
           forge-buffer-topic)
      (user-error "Not in a GitHub pull request buffer")))

(defun forge-plugins-github-reviews--topic-status (topic)
  "Return TOPIC's cached review status, fetching synchronously if stale.
Unlike the section render, this blocks: the caller is an interactive
command reacting to a keypress, so a short wait is acceptable."
  (let ((cached (gethash (oref topic id)
                         forge-plugins-github-reviews--cache)))
    (when (or (null cached)
              (plist-get cached :fetching)
              (plist-get cached :error)
              (not (equal (plist-get cached :head-rev) (oref topic head-rev))))
      (let* ((repo (forge-get-repository topic))
             (data (forge-plugins-github-reviews--graphql
                    repo forge-plugins-github-reviews--query
                    (forge-plugins-github-reviews--variables topic)))
             (parsed (forge-plugins-github-reviews--parse data)))
        (setq cached (list :head-rev (oref topic head-rev)
                           :threads (plist-get parsed :threads)
                           :unresolved (plist-get parsed :unresolved)
                           :reviews (plist-get parsed :reviews)
                           :fetching nil))
        (puthash (oref topic id) cached
                 forge-plugins-github-reviews--cache)))
    cached))

(defun forge-plugins-github-reviews--thread-at-point (topic prompt)
  "Return a review thread of TOPIC, chosen with PROMPT.
When point is on a thread or comment line, that thread is returned
directly; otherwise the topic's threads are offered for completion.
Signals a `user-error' when the pull request has no review threads."
  (or (get-text-property (point) 'forge-plugins-github-reviews-thread)
      (let ((threads (plist-get (forge-plugins-github-reviews--topic-status topic)
                                :threads)))
        (unless threads
          (user-error "This pull request has no review threads"))
        (if (length= threads 1)
            (car threads)
          (let ((table (mapcar
                        (lambda (th)
                          (cons (format "%s:%s [%s] %s"
                                        (plist-get th :path)
                                        (plist-get th :line)
                                        (if (plist-get th :resolved)
                                            "resolved" "unresolved")
                                        (or (plist-get (car (plist-get th :comments))
                                                       :login)
                                            (plist-get th :id)))
                                th))
                        threads)))
            (cdr (assoc (completing-read prompt table nil t) table)))))))

(defun forge-plugins-github-reviews--comment-at-point ()
  "Return the review comment at point or signal a `user-error'."
  (or (get-text-property (point) 'forge-plugins-github-reviews-comment)
      (user-error "Point is not on a review comment")))

(defun forge-plugins-github-reviews--mutate (repo mutation variables)
  "Run GraphQL MUTATION string for REPO with VARIABLES, synchronously.
Signals a `user-error' on a GraphQL error."
  (forge-plugins-github-reviews--graphql repo mutation variables))

(defun forge-plugins-github-reviews--finish-compose (topic)
  "Tear down the current compose buffer and refresh TOPIC's buffer.
Deletes the draft file, buries the compose buffer, restores the window
configuration, invalidates TOPIC's cache and refreshes the buffer the
compose was launched from.  Run only after a mutation succeeds."
  (let ((file buffer-file-name)
        (prevbuf forge--pre-post-buffer)
        (winconf forge--pre-post-winconf))
    (when (and file (file-exists-p file))
      (delete-file file t)
      (let ((dir (file-name-directory file)))
        (unless (directory-files dir nil directory-files-no-dot-files-regexp t)
          (delete-directory dir nil t))))
    (magit-mode-bury-buffer 'kill)
    (forge--maybe-restore-winconf winconf)
    (forge-plugins-github-reviews--invalidate topic)
    (when (buffer-live-p prevbuf)
      (with-current-buffer prevbuf (magit-refresh)))))

(defun forge-plugins-github-reviews--compose (topic header initial submit)
  "Open a forge compose buffer for a review comment on TOPIC.
HEADER is the header line; INITIAL, when non-nil, prefills the body.
SUBMIT is called with the trimmed body when the post is submitted; on
success the compose buffer is torn down and TOPIC's buffer refreshed."
  (forge--setup-post-buffer
    'review-comment
    (lambda (_repo _obj)
      (funcall submit (string-trim (buffer-string)))
      (forge-plugins-github-reviews--finish-compose topic))
    "review-comment"
    header
    nil
    (and initial (lambda () (insert initial)))))

;;;###autoload
(defun forge-plugins-github-reviews-reply ()
  "Reply to the review thread at point (or one chosen by completion).
Bound to \\`v c' in pull request buffers (GraphQL
`addPullRequestReviewThreadReply')."
  (interactive)
  (let* ((topic (forge-plugins-github-reviews--current-topic))
         (thread (forge-plugins-github-reviews--thread-at-point
                  topic "Reply to thread: ")))
    (forge-plugins-github-reviews--compose
     topic "Reply to review thread" nil
     (lambda (body)
       (when (string-empty-p body)
         (user-error "Empty reply"))
       (forge-plugins-github-reviews--mutate
        (forge-get-repository topic)
        "mutation($id:ID!,$body:String!){
           addPullRequestReviewThreadReply(input:{pullRequestReviewThreadId:$id,body:$body}){ comment{ id } }
         }"
        (list (cons 'id (plist-get thread :id)) (cons 'body body)))))))

;;;###autoload
(defun forge-plugins-github-reviews-edit ()
  "Edit your own review comment at point.
Bound to \\`v e' in pull request buffers (GraphQL
`updatePullRequestReviewComment')."
  (interactive)
  (let* ((topic (forge-plugins-github-reviews--current-topic))
         (comment (forge-plugins-github-reviews--comment-at-point)))
    (unless (plist-get comment :viewer)
      (user-error "You can only edit your own comments"))
    (forge-plugins-github-reviews--compose
     topic "Edit review comment" (plist-get comment :body)
     (lambda (body)
       (when (string-empty-p body)
         (user-error "Empty comment"))
       (forge-plugins-github-reviews--mutate
        (forge-get-repository topic)
        "mutation($id:ID!,$body:String!){
           updatePullRequestReviewComment(input:{pullRequestReviewCommentId:$id,body:$body}){ pullRequestReviewComment{ id } }
         }"
        (list (cons 'id (plist-get comment :id)) (cons 'body body)))))))

(defconst forge-plugins-github-reviews--reactions
  '(("+1"      . "THUMBS_UP")
    ("-1"      . "THUMBS_DOWN")
    ("laugh"   . "LAUGH")
    ("hooray"  . "HOORAY")
    ("confused" . "CONFUSED")
    ("heart"   . "HEART")
    ("rocket"  . "ROCKET")
    ("eyes"    . "EYES"))
  "Alist mapping reaction names to GitHub `ReactionContent' enum values.")

;;;###autoload
(defun forge-plugins-github-reviews-react ()
  "Add a reaction to the review comment at point.
Bound to \\`v @' in pull request buffers (GraphQL `addReaction')."
  (interactive)
  (let* ((topic (forge-plugins-github-reviews--current-topic))
         (comment (forge-plugins-github-reviews--comment-at-point))
         (content (cdr (assoc (completing-read
                               "Reaction: "
                               forge-plugins-github-reviews--reactions nil t)
                              forge-plugins-github-reviews--reactions))))
    (forge-plugins-github-reviews--mutate
     (forge-get-repository topic)
     "mutation($id:ID!,$c:ReactionContent!){
        addReaction(input:{subjectId:$id,content:$c}){ reaction{ content } }
      }"
     (list (cons 'id (plist-get comment :id)) (cons 'c content)))
    (message "Reacted %s" content)))

;;;###autoload
(defun forge-plugins-github-reviews-resolve ()
  "Resolve or unresolve the review thread at point.
Toggles based on the thread's current state.  Bound to \\`v r' in pull
request buffers (GraphQL `resolveReviewThread' /
`unresolveReviewThread')."
  (interactive)
  (let* ((topic (forge-plugins-github-reviews--current-topic))
         (thread (forge-plugins-github-reviews--thread-at-point
                  topic "Resolve/unresolve thread: "))
         (resolved (plist-get thread :resolved))
         (mutation
          (if resolved
              "mutation($id:ID!){ unresolveReviewThread(input:{threadId:$id}){ thread{ id } } }"
            "mutation($id:ID!){ resolveReviewThread(input:{threadId:$id}){ thread{ id } } }")))
    (forge-plugins-github-reviews--mutate
     (forge-get-repository topic) mutation
     (list (cons 'id (plist-get thread :id))))
    (forge-plugins-github-reviews--invalidate topic)
    (magit-refresh)
    (message (if resolved "Unresolved thread" "Resolved thread"))))

;;;###autoload
(defun forge-plugins-github-reviews-refresh ()
  "Refresh the review threads of the current pull request.
Invalidates the cache and refreshes the buffer, forcing a fresh fetch.
Reviews change without a new push (the head revision is unchanged), so
unlike \\[magit-refresh] this bypasses the cache.  Bound to \\`v g'."
  (interactive)
  (let ((topic (forge-plugins-github-reviews--current-topic)))
    (forge-plugins-github-reviews--invalidate topic)
    (magit-refresh-buffer)))

(defun forge-plugins-github-reviews-clear-queue ()
  "Clear the pending review fetch queue and reset dispatch state.
Cancel any scheduled dispatch timer, empty the queue and reset the
in-flight counter.  Use this to recover if fetches ever get stuck."
  (interactive)
  (when (timerp forge-plugins-github-reviews--dispatch-timer)
    (cancel-timer forge-plugins-github-reviews--dispatch-timer))
  (let ((n (length forge-plugins-github-reviews--queue)))
    (setq forge-plugins-github-reviews--dispatch-timer nil
          forge-plugins-github-reviews--queue nil
          forge-plugins-github-reviews--queue-tail nil
          forge-plugins-github-reviews--inflight 0)
    (forge-plugins-github-reviews--debug "Cleared fetch queue (%d pending)" n)
    (when (called-interactively-p 'interactive)
      (message "Cleared %d pending review fetch(es)" n))))

(transient-define-prefix forge-plugins-github-reviews-help ()
  "Show available keys for the GitHub reviews plugin."
  ["Review threads"
   ("c" "Reply to thread" forge-plugins-github-reviews-reply)
   ("e" "Edit your comment" forge-plugins-github-reviews-edit)
   ("@" "Add reaction" forge-plugins-github-reviews-react)
   ("r" "Resolve/unresolve" forge-plugins-github-reviews-resolve)
   ("g" "Refresh" forge-plugins-github-reviews-refresh)])

;; ponytail: `v' shadows `magit-reverse' in pull request buffers.  This
;; is the prefix the feature was specified with; rebind
;; `forge-plugins-github-reviews-prefix-map' elsewhere to free `v'.
(defvar-keymap forge-plugins-github-reviews-prefix-map
  :doc "Prefix keymap for review commands in pull request buffers."
  "c" #'forge-plugins-github-reviews-reply
  "e" #'forge-plugins-github-reviews-edit
  "@" #'forge-plugins-github-reviews-react
  "r" #'forge-plugins-github-reviews-resolve
  "g" #'forge-plugins-github-reviews-refresh
  "?" #'forge-plugins-github-reviews-help)

;;;###autoload
(defun forge-plugins-github-reviews-enable ()
  "Enable GitHub pull request review-thread integration."
  (interactive)
  (setq forge-plugins-github-reviews-enable t)
  (advice-add 'forge--format-topic-line
              :around #'forge-plugins-github-reviews--format-topic-line)
  (advice-add 'forge--insert-topic
              :around #'forge-plugins-github-reviews--insert-topic)
  (advice-add 'forge-insert-post
              :before #'forge-plugins-github-reviews--insert-section)
  (when (boundp 'forge-pullreq-mode-map)
    (keymap-set forge-pullreq-mode-map "v"
                forge-plugins-github-reviews-prefix-map)))

;;;###autoload
(defun forge-plugins-github-reviews-disable ()
  "Disable GitHub pull request review-thread integration."
  (interactive)
  (setq forge-plugins-github-reviews-enable nil)
  (forge-plugins-github-reviews-clear-queue)
  (advice-remove 'forge-insert-post
                 #'forge-plugins-github-reviews--insert-section)
  (advice-remove 'forge--insert-topic
                 #'forge-plugins-github-reviews--insert-topic)
  (advice-remove 'forge--format-topic-line
                 #'forge-plugins-github-reviews--format-topic-line)
  (when (boundp 'forge-pullreq-mode-map)
    (keymap-unset forge-pullreq-mode-map "v" t)))

;;;###autoload
(defcustom forge-plugins-github-reviews-enable nil
  "Whether to enable GitHub pull request review-thread integration."
  :package-version '(forge-plugins-github-reviews . "0.1.0")
  :group 'forge
  :type 'boolean
  :set (lambda (sym val)
         (set-default sym val)
         (when (featurep 'forge-plugins-github-reviews)
           (if val
               (forge-plugins-github-reviews-enable)
             (forge-plugins-github-reviews-disable)))))

(when forge-plugins-github-reviews-enable
  (forge-plugins-github-reviews-enable))

(provide 'forge-plugins-github-reviews)
;;; forge-plugins-github-reviews.el ends here
