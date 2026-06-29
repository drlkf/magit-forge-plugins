;;; forge-plugins-pullreq-approvals.el --- Pull request approvals integration  -*- lexical-binding: t; -*-

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

;; Display pull request approvals on pull request lines and in the topic
;; view, formatted as `<x/y>' where X is the current number of approvals
;; and Y is the number of required approvals for the target branch.
;;
;; The current approvals count is derived from the pull request's reviews
;; (`GET /repos/:owner/:repo/pulls/:number/reviews'): per reviewer, only
;; their latest meaningful review state is considered, and an approval is
;; counted when that state is `APPROVED'.  The required count comes from
;; the target branch's active rulesets
;; (`GET /repos/:owner/:repo/rules/branches/:base-ref'), taking the
;; largest `required_approving_review_count' across all `pull_request'
;; rules.  When the target branch has no such rule, the indicator is
;; hidden.

;;; Code:

(require 'forge nil t)
(require 'forge-topic nil t)
(require 'forge-pullreq nil t)
(require 'magit-status nil t)
(require 'magit-section nil t)
(require 'cl-lib)

(defconst forge-plugins-pullreq-approvals-tested-on-forge "0.6.6"
  "Forge version this plugin was tested against.")

;;;###autoload
(defcustom forge-plugins-pullreq-approvals-debug nil
  "Whether to enable debug logging for the pull request approvals plugin.
If non-nil, debug logs are written to the buffer
`*forge-plugins-pullreq-approvals-debug*`."
  :package-version '(forge-plugins-pullreq-approvals . "0.1.0")
  :group 'forge
  :type 'boolean)

;;;###autoload
(defcustom forge-plugins-pullreq-approvals-max-concurrent-requests 6
  "Maximum number of approvals fetches to run concurrently.
Pending fetches beyond this limit are queued and dispatched as
in-flight requests complete.  This bounds parallelism so the
GitHub API is not hammered while keeping fetches concurrent."
  :package-version '(forge-plugins-pullreq-approvals . "0.1.0")
  :group 'forge
  :type 'integer)

;;;###autoload
(defcustom forge-plugins-pullreq-approvals-refresh-delay 0.3
  "Delay in seconds before refreshing buffers after a fetch completes.
Multiple fetch completions within this window are coalesced into a
single buffer refresh to avoid blocking Emacs with a refresh storm."
  :package-version '(forge-plugins-pullreq-approvals . "0.1.0")
  :group 'forge
  :type 'number)

(defun forge-plugins-pullreq-approvals--debug (format-string &rest args)
  "Log a message to the debug buffer if debug logging is enabled.
FORMAT-STRING and ARGS are passed to `format'."
  (when forge-plugins-pullreq-approvals-debug
    (let ((buf (get-buffer-create "*forge-plugins-pullreq-approvals-debug*")))
      (with-current-buffer buf
        (save-excursion
          (goto-char (point-max))
          (let ((inhibit-read-only t))
            (insert (format-time-string "[%Y-%m-%d %H:%M:%S] "))
            (insert (apply #'format format-string args))
            (insert "\n")))))))

(defface forge-plugins-pullreq-approvals-met
  '((t :inherit success))
  "Face for pull requests whose required approvals are met."
  :group 'forge)

(defface forge-plugins-pullreq-approvals-pending
  '((t :inherit warning))
  "Face for pull requests still missing required approvals."
  :group 'forge)

(defvar forge-plugins-pullreq-approvals--cache (make-hash-table :test 'equal)
  "Cache of approval status for pull requests.
Keys are topic IDs.
Values are plists:
- `:head-rev': the head-rev for which this status was fetched.
- `:approved': number of current approvals.
- `:required': number of required approvals (or nil when unknown).
- `:reviews': alist of (LOGIN . STATE) for the latest review per user.
- `:fetching': boolean, whether a fetch is in progress.
- `:error': boolean, whether the last fetch failed.")

(defvar forge-plugins-pullreq-approvals--required-cache
  (make-hash-table :test 'equal)
  "Cache of required approval counts per branch.
Keys are strings of the form \"REPO-ID\\0BASE-REF\".
Values are integers, or the symbol `none' when the branch has no
required-approvals rule.")

(defun forge-plugins-pullreq-approvals--refresh-buffers ()
  "Refresh all visible or active Magit and Forge buffers."
  (dolist (buf (buffer-list))
    (with-current-buffer buf
      (when (or (derived-mode-p 'forge-topics-mode)
                (derived-mode-p 'magit-status-mode)
                (derived-mode-p 'forge-notifications-mode)
                (derived-mode-p 'forge-pullreq-mode))
        (magit-refresh-buffer)))))

(defvar forge-plugins-pullreq-approvals--refresh-timer nil
  "Pending timer used to coalesce buffer refreshes.")

(defun forge-plugins-pullreq-approvals--schedule-refresh ()
  "Schedule a debounced refresh of Magit and Forge buffers.
Multiple calls within
`forge-plugins-pullreq-approvals-refresh-delay' seconds are
coalesced into a single refresh so that a burst of fetch
completions does not trigger a refresh storm."
  (when (timerp forge-plugins-pullreq-approvals--refresh-timer)
    (cancel-timer forge-plugins-pullreq-approvals--refresh-timer))
  (setq forge-plugins-pullreq-approvals--refresh-timer
        (run-with-timer
         forge-plugins-pullreq-approvals-refresh-delay nil
         (lambda ()
           (setq forge-plugins-pullreq-approvals--refresh-timer nil)
           (forge-plugins-pullreq-approvals--refresh-buffers)))))

(defvar forge-plugins-pullreq-approvals--queue nil
  "FIFO list of topics pending an approvals fetch.")

(defvar forge-plugins-pullreq-approvals--inflight 0
  "Number of approvals fetches currently in flight.")

(defvar forge-plugins-pullreq-approvals--dispatch-timer nil
  "Pending timer used to drain the fetch queue off the redisplay path.")

(defun forge-plugins-pullreq-approvals--enqueue (topic)
  "Queue TOPIC for an approvals fetch and schedule the queue to drain.
The actual dispatch happens from a timer so that no network setup
work is performed during buffer redisplay."
  (setq forge-plugins-pullreq-approvals--queue
        (nconc forge-plugins-pullreq-approvals--queue (list topic)))
  (unless (timerp forge-plugins-pullreq-approvals--dispatch-timer)
    (setq forge-plugins-pullreq-approvals--dispatch-timer
          (run-with-timer
           0 nil
           (lambda ()
             (setq forge-plugins-pullreq-approvals--dispatch-timer nil)
             (forge-plugins-pullreq-approvals--dispatch))))))

(defun forge-plugins-pullreq-approvals--dispatch ()
  "Dispatch queued fetches up to the concurrency limit.
Pops topics off `forge-plugins-pullreq-approvals--queue' and fires
a fetch for each, as long as the number of in-flight requests
stays below
`forge-plugins-pullreq-approvals-max-concurrent-requests'."
  (while (and forge-plugins-pullreq-approvals--queue
              (< forge-plugins-pullreq-approvals--inflight
                 forge-plugins-pullreq-approvals-max-concurrent-requests))
    (let ((topic (pop forge-plugins-pullreq-approvals--queue)))
      (cl-incf forge-plugins-pullreq-approvals--inflight)
      (forge-plugins-pullreq-approvals--fetch topic))))

(defun forge-plugins-pullreq-approvals--fetch-done ()
  "Account for a completed fetch and dispatch any queued ones."
  (when (> forge-plugins-pullreq-approvals--inflight 0)
    (cl-decf forge-plugins-pullreq-approvals--inflight))
  (forge-plugins-pullreq-approvals--dispatch))

(defun forge-plugins-pullreq-approvals--required-key (topic)
  "Return the required-count cache key for TOPIC's target branch."
  (let ((repo (forge-get-repository topic)))
    (concat (format "%s" (oref repo id)) "\0" (or (oref topic base-ref) ""))))

(defun forge-plugins-pullreq-approvals--count-approved (reviews)
  "Return (COUNT . LATEST) for the GitHub REVIEWS list.
COUNT is the number of distinct users whose latest meaningful
review state is `APPROVED'.  LATEST is an alist of (LOGIN . STATE)
for each such user, in first-seen order.  Reviews with state
`COMMENTED' or `PENDING' do not change a user's state."
  (let ((latest nil))
    (dolist (review reviews)
      (let ((login (alist-get 'login (alist-get 'user review)))
            (state (alist-get 'state review)))
        (when (and login (member state '("APPROVED" "CHANGES_REQUESTED"
                                         "DISMISSED")))
          (if-let ((cell (assoc login latest)))
              (setcdr cell state)
            (setq latest (nconc latest (list (cons login state))))))))
    (cons (cl-count "APPROVED" latest :key #'cdr :test #'equal)
          latest)))

(defun forge-plugins-pullreq-approvals--rule-required (rules)
  "Return the required approving review count from RULES, or nil.
RULES is the array returned by the branch rules endpoint.  The
largest `required_approving_review_count' across all active
`pull_request' rules is returned; nil when there is no such rule."
  (let ((required nil))
    (dolist (rule (append rules nil))
      (when (equal (alist-get 'type rule) "pull_request")
        (let ((count (alist-get 'required_approving_review_count
                                (alist-get 'parameters rule))))
          (when (integerp count)
            (setq required (max (or required 0) count))))))
    required))

(defun forge-plugins-pullreq-approvals--store (topic head-rev required result)
  "Store the approvals RESULT for TOPIC into the cache.
HEAD-REV is the head-rev the fetch was performed against, REQUIRED
the required approval count, and RESULT the cons returned by
`forge-plugins-pullreq-approvals--count-approved'."
  (puthash (oref topic id)
           (list :head-rev head-rev
                 :approved (car result)
                 :required required
                 :reviews (cdr result)
                 :fetching nil)
           forge-plugins-pullreq-approvals--cache)
  (forge-plugins-pullreq-approvals--debug
   "Stored approvals for topic %s: approved=%s required=%s"
   (oref topic id) (car result) required)
  (forge-plugins-pullreq-approvals--fetch-done)
  (forge-plugins-pullreq-approvals--schedule-refresh))

(defun forge-plugins-pullreq-approvals--store-error (topic head-rev)
  "Record a failed approvals fetch for TOPIC against HEAD-REV."
  (puthash (oref topic id)
           (list :head-rev head-rev :fetching nil :error t)
           forge-plugins-pullreq-approvals--cache)
  (forge-plugins-pullreq-approvals--fetch-done)
  (forge-plugins-pullreq-approvals--schedule-refresh))

(defun forge-plugins-pullreq-approvals--fetch-reviews (topic head-rev required)
  "Fetch reviews for TOPIC and store the resulting approvals.
HEAD-REV is the head-rev the fetch is performed against and
REQUIRED the required approval count for the target branch."
  (forge-plugins-pullreq-approvals--debug
   "Fetching reviews for topic %s (head-rev: %s)" (oref topic id) head-rev)
  (forge-rest topic "GET" "/repos/:owner/:repo/pulls/:number/reviews" nil
    :unpaginate t
    :callback
    (lambda (value &rest _)
      (forge-plugins-pullreq-approvals--store
       topic head-rev required
       (forge-plugins-pullreq-approvals--count-approved value)))
    :errorback
    (lambda (err &rest _)
      (forge-plugins-pullreq-approvals--debug
       "Failed to fetch reviews for topic %s: %S" (oref topic id) err)
      (forge-plugins-pullreq-approvals--store-error topic head-rev))))

(defun forge-plugins-pullreq-approvals--fetch (topic)
  "Fetch approvals status for TOPIC asynchronously.
The required approval count for the target branch is resolved
first (from cache or the branch rules endpoint), then the reviews
are fetched and the approvals are stored."
  (let* ((head-rev (oref topic head-rev))
         (key (forge-plugins-pullreq-approvals--required-key topic))
         (cached-required (gethash key
                                   forge-plugins-pullreq-approvals--required-cache)))
    (if cached-required
        (forge-plugins-pullreq-approvals--fetch-reviews
         topic head-rev (and (integerp cached-required) cached-required))
      (forge-plugins-pullreq-approvals--debug
       "Fetching branch rules for topic %s (base-ref: %s)"
       (oref topic id) (oref topic base-ref))
      (forge-rest topic "GET" "/repos/:owner/:repo/rules/branches/:base-ref" nil
        :callback
        (lambda (value &rest _)
          (let ((required (forge-plugins-pullreq-approvals--rule-required value)))
            (puthash key (or required 'none)
                     forge-plugins-pullreq-approvals--required-cache)
            (forge-plugins-pullreq-approvals--fetch-reviews
             topic head-rev required)))
        :errorback
        (lambda (err &rest _)
          (forge-plugins-pullreq-approvals--debug
           "Failed to fetch branch rules for topic %s: %S" (oref topic id) err)
          (forge-plugins-pullreq-approvals--store-error topic head-rev))))))

(defun forge-plugins-pullreq-approvals--insert-faced (text face)
  "Insert TEXT and overlay it with FACE so it renders above highlight.
The overlay uses `priority' 2, matching `forge--insert-topic-labels',
so the status faces win over the `magit-section-highlight' overlay
\(which has no explicit priority) when the section is current."
  (let ((beg (point)))
    (insert text)
    (let ((o (make-overlay beg (point))))
      (overlay-put o 'priority 2)
      (overlay-put o 'evaporate t)
      (overlay-put o 'font-lock-face face))))

(defun forge-plugins-pullreq-approvals--promote-status-overlay (beg end)
  "Overlay status spans marked between BEG and END so they survive highlight.
The topic-line indicator appended by
`forge-plugins-pullreq-approvals--format-topic-line' carries the
`forge-plugins-pullreq-approvals-status' text property.  Promoting it to
a `priority' 2 overlay matches `forge--insert-topic-labels' so the status
face wins over the `magit-section-highlight' overlay (a plain
`font-lock-face' text property is otherwise shadowed by that overlay)."
  (let ((pos beg))
    (while (and pos (< pos end))
      (let ((next (next-single-property-change
                   pos 'forge-plugins-pullreq-approvals-status nil end)))
        (when (get-text-property pos 'forge-plugins-pullreq-approvals-status)
          (let ((o (make-overlay pos next)))
            (overlay-put o 'priority 2)
            (overlay-put o 'evaporate t)
            (overlay-put o 'font-lock-face
                         (get-text-property pos 'font-lock-face))))
        (setq pos next)))))

(defun forge-plugins-pullreq-approvals--summary (topic)
  "Return the approvals summary for TOPIC, triggering a fetch if needed.
The return value is a cons cell (STR . FACE), or nil when there is
nothing to display (no required-approvals rule, an in-progress
fetch, or an error)."
  (let* ((id (oref topic id))
         (head-rev (oref topic head-rev))
         (cached (gethash id forge-plugins-pullreq-approvals--cache)))
    (cond
     ((not head-rev) nil)
     ((and cached (equal (plist-get cached :head-rev) head-rev))
      (cond
       ((plist-get cached :fetching) nil)
       ((plist-get cached :error) nil)
       (t
        (let ((approved (plist-get cached :approved))
              (required (plist-get cached :required)))
          (if (and (integerp required) (> required 0))
              (cons (format "<%d/%d>" approved required)
                    (if (>= approved required)
                        'forge-plugins-pullreq-approvals-met
                      'forge-plugins-pullreq-approvals-pending))
            nil)))))
     (t
      (puthash id (list :head-rev head-rev :fetching t)
               forge-plugins-pullreq-approvals--cache)
      (forge-plugins-pullreq-approvals--enqueue topic)
      nil))))

(defun forge-plugins-pullreq-approvals--target-p (topic)
  "Return non-nil when TOPIC is a GitHub pull request to annotate."
  (and (forge-pullreq-p topic)
       (cl-typep (forge-get-repository topic) 'forge-github-repository)))

(defun forge-plugins-pullreq-approvals--format-topic-line (orig-fun topic
                                                                    &optional width)
  "Around advice to append the approvals indicator to the topic line.
ORIG-FUN is the advised function, called with TOPIC and WIDTH; its
result has the `<x/y>' indicator appended for GitHub pull requests."
  (let ((line (funcall orig-fun topic width)))
    (if (and forge-plugins-pullreq-approvals-enable
             (forge-plugins-pullreq-approvals--target-p topic))
        (if-let ((summary (forge-plugins-pullreq-approvals--summary topic)))
            (concat line " "
                    (propertize
                     (magit--propertize-face (car summary) (cdr summary))
                     'forge-plugins-pullreq-approvals-status t))
          line)
      line)))

(defun forge-plugins-pullreq-approvals--insert-topic (orig-fun topic
                                                              &optional width)
  "Around advice to promote the approvals badge to a highlight-proof overlay.
ORIG-FUN is `forge--insert-topic', called with TOPIC and WIDTH; the
indicator appended by `forge-plugins-pullreq-approvals--format-topic-line'
is then re-rendered as a `priority' 2 overlay over the inserted line."
  (let ((beg (point)))
    (funcall orig-fun topic width)
    (forge-plugins-pullreq-approvals--promote-status-overlay beg (point))))

(defun forge-plugins-pullreq-approvals--insert-section (post &optional topic)
  "Insert an Approvals section as a sibling after the description post.
This is `:before' advice for `forge-insert-post'.  POST and TOPIC
are the advised function's arguments; the section is only inserted
before the topic's own description post, i.e. when TOPIC is nil and
POST is a GitHub pull request."
  (when (and (null topic)
             forge-plugins-pullreq-approvals-enable
             (forge-plugins-pullreq-approvals--target-p post))
    (let* ((topic post)
           (id (oref topic id))
           (head-rev (oref topic head-rev))
           (cached (gethash id forge-plugins-pullreq-approvals--cache)))
      (magit-insert-section (pullreq-approvals)
        (let ((summary (forge-plugins-pullreq-approvals--summary topic)))
          (insert (magit--propertize-face "Approvals" 'magit-section-heading))
          (when summary
            (insert " ")
            (forge-plugins-pullreq-approvals--insert-faced
             (car summary) (cdr summary)))
          (magit-insert-heading))
        (magit-insert-section-body
          (cond
           ((and cached (equal (plist-get cached :head-rev) head-rev)
                 (not (plist-get cached :fetching)))
            (cond
             ((plist-get cached :error)
              (forge-plugins-pullreq-approvals--insert-faced
               "error" 'forge-plugins-pullreq-approvals-pending)
              (insert "\n"))
             ((plist-get cached :reviews)
              (dolist (review (plist-get cached :reviews))
                (let* ((login (car review))
                       (state (cdr review))
                       (label (downcase (string-replace "_" " " state)))
                       (face (if (equal state "APPROVED")
                                 'forge-plugins-pullreq-approvals-met
                               'forge-plugins-pullreq-approvals-pending)))
                  (insert "  ")
                  (forge-plugins-pullreq-approvals--insert-faced label face)
                  (insert (make-string (max 0 (- 18 (string-width label))) ?\s))
                  (insert " " login "\n"))))
             (t (insert (magit--propertize-face "none" 'magit-dimmed) "\n"))))
           (t
            (insert (magit--propertize-face "fetching..." 'magit-dimmed) "\n")))
          (insert "\n"))))))

(defun forge-plugins-pullreq-approvals--invalidate (topic)
  "Drop the cached approvals status for TOPIC, forcing a refetch.
The branch's required-count cache is also dropped so a fresh value
is read on the next fetch."
  (remhash (oref topic id) forge-plugins-pullreq-approvals--cache)
  (remhash (forge-plugins-pullreq-approvals--required-key topic)
           forge-plugins-pullreq-approvals--required-cache))

(defun forge-plugins-pullreq-approvals--invalidate-displayed ()
  "Invalidate the cached approvals of every GitHub pull request displayed.
Walk the current buffer's Magit section tree and invalidate the
cache for each section whose value is a GitHub pull request.
Return the number of pull requests invalidated."
  (let ((count 0))
    (when (bound-and-true-p magit-root-section)
      (letrec ((walk
                (lambda (section)
                  (let ((value (oref section value)))
                    (when (and (forge-pullreq-p value)
                               (forge-plugins-pullreq-approvals--target-p value))
                      (forge-plugins-pullreq-approvals--invalidate value)
                      (cl-incf count)))
                  (dolist (child (oref section children))
                    (funcall walk child)))))
        (funcall walk magit-root-section)))
    count))

(defun forge-plugins-pullreq-approvals-refresh ()
  "Refresh the pull request approvals in the current buffer.
Invalidate the cached approvals for the relevant pull request(s)
and refresh the buffer, which re-fetches them from the forge.
Approvals can change without a new push, so unlike `magit-refresh'
\(\\[magit-refresh]), which keeps the cached status as long as the
head revision is unchanged, this forces a fresh fetch.

In a pull request topic buffer this refreshes the buffer's own
topic; in a Magit status buffer it refreshes every GitHub pull
request currently displayed."
  (interactive)
  (let ((invalidated
         (cond
          ((and (derived-mode-p 'forge-pullreq-mode)
                (bound-and-true-p forge-buffer-topic)
                (forge-plugins-pullreq-approvals--target-p forge-buffer-topic))
           (forge-plugins-pullreq-approvals--invalidate forge-buffer-topic)
           1)
          ((derived-mode-p 'magit-status-mode)
           (forge-plugins-pullreq-approvals--invalidate-displayed))
          (t 0))))
    (if (and invalidated (> invalidated 0))
        (progn
          (forge-plugins-pullreq-approvals--debug
           "Manual refresh invalidated %d pull request(s)" invalidated)
          (magit-refresh-buffer))
      (user-error "No GitHub pull requests to refresh"))))

;;;###autoload
(defun forge-plugins-pullreq-approvals-enable ()
  "Enable pull request approvals integration."
  (interactive)
  (setq forge-plugins-pullreq-approvals-enable t)
  (advice-add 'forge--format-topic-line
              :around #'forge-plugins-pullreq-approvals--format-topic-line)
  (advice-add 'forge--insert-topic
              :around #'forge-plugins-pullreq-approvals--insert-topic)
  (advice-add 'forge-insert-post
              :before #'forge-plugins-pullreq-approvals--insert-section)
  (keymap-set forge-pullreq-mode-map "C-c C-v"
              #'forge-plugins-pullreq-approvals-refresh)
  (keymap-set magit-status-mode-map "C-c C-v"
              #'forge-plugins-pullreq-approvals-refresh))

;;;###autoload
(defun forge-plugins-pullreq-approvals-disable ()
  "Disable pull request approvals integration."
  (interactive)
  (setq forge-plugins-pullreq-approvals-enable nil)
  (advice-remove 'forge-insert-post
                 #'forge-plugins-pullreq-approvals--insert-section)
  (advice-remove 'forge--insert-topic
                 #'forge-plugins-pullreq-approvals--insert-topic)
  (advice-remove 'forge--format-topic-line
                 #'forge-plugins-pullreq-approvals--format-topic-line)
  (keymap-unset forge-pullreq-mode-map "C-c C-v" t)
  (keymap-unset magit-status-mode-map "C-c C-v" t))

;;;###autoload
(defcustom forge-plugins-pullreq-approvals-enable nil
  "Whether to enable pull request approvals integration."
  :package-version '(forge-plugins-pullreq-approvals . "0.1.0")
  :group 'forge
  :type 'boolean
  :set (lambda (sym val)
         (set-default sym val)
         (when (featurep 'forge-plugins-pullreq-approvals)
           (if val
               (forge-plugins-pullreq-approvals-enable)
             (forge-plugins-pullreq-approvals-disable)))))

(when forge-plugins-pullreq-approvals-enable
  (forge-plugins-pullreq-approvals-enable))

(provide 'forge-plugins-pullreq-approvals)
;;; forge-plugins-pullreq-approvals.el ends here
