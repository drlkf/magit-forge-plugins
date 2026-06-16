;;; forge-plugins-github-actions.el --- GitHub Actions status integration  -*- lexical-binding: t; -*-

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

;; Display GitHub Actions status on pull request lines and in the topic view,
;; with the ability to view logs and trigger re-runs.

;;; Code:

(require 'forge nil t)
(require 'forge-topic nil t)
(require 'magit-section nil t)
(require 'ansi-color)
(require 'cl-lib)

(declare-function evil-define-key* "evil-core")

(defconst forge-plugins-github-actions-tested-on-forge "0.6.6"
  "Forge version this plugin was tested against.")

;;;###autoload
(defcustom forge-plugins-github-actions-debug nil
  "Whether to enable debug logging for the GitHub Actions plugin.
If non-nil, debug logs are written to the buffer
`*forge-plugins-github-actions-debug*`."
  :package-version '(forge-plugins-github-actions . "0.1.0")
  :group 'forge
  :type 'boolean)

;;;###autoload
(defcustom forge-plugins-github-actions-max-concurrent-requests 6
  "Maximum number of check-run fetches to run concurrently.
Pending fetches beyond this limit are queued and dispatched as
in-flight requests complete.  This bounds parallelism so the
GitHub API is not hammered while keeping fetches concurrent."
  :package-version '(forge-plugins-github-actions . "0.1.0")
  :group 'forge
  :type 'integer)

;;;###autoload
(defcustom forge-plugins-github-actions-refresh-delay 0.3
  "Delay in seconds before refreshing buffers after a fetch completes.
Multiple fetch completions within this window are coalesced into a
single buffer refresh to avoid blocking Emacs with a refresh storm."
  :package-version '(forge-plugins-github-actions . "0.1.0")
  :group 'forge
  :type 'number)

(defun forge-plugins-github-actions--debug (format-string &rest args)
  "Log a message to the debug buffer if debug logging is enabled.
FORMAT-STRING and ARGS are passed to `format'."
  (when forge-plugins-github-actions-debug
    (let ((buf (get-buffer-create "*forge-plugins-github-actions-debug*")))
      (with-current-buffer buf
        (save-excursion
          (goto-char (point-max))
          (let ((inhibit-read-only t))
            (insert (format-time-string "[%Y-%m-%d %H:%M:%S] "))
            (insert (apply #'format format-string args))
            (insert "\n")))))))

(defface forge-plugins-github-actions-success
  '((t :inherit success))
  "Face for successful GitHub Actions check runs."
  :group 'forge)

(defface forge-plugins-github-actions-warning
  '((t :inherit warning))
  "Face for pending or neutral GitHub Actions check runs."
  :group 'forge)

(defface forge-plugins-github-actions-failure
  '((t :inherit error))
  "Face for failed GitHub Actions check runs."
  :group 'forge)

(defface forge-plugins-github-actions-log-time
  '((t :inherit magit-dimmed))
  "Face for timestamps in GitHub Actions logs."
  :group 'forge)

(defface forge-plugins-github-actions-log-command
  '((t :inherit magit-section-heading))
  "Face for command lines in GitHub Actions logs."
  :group 'forge)

(defface forge-plugins-github-actions-log-section
  '((t :inherit magit-section-secondary-heading))
  "Face for section header lines in GitHub Actions logs."
  :group 'forge)

(defvar forge-plugins-github-actions--cache (make-hash-table :test 'equal)
  "Cache of GitHub Actions status for pull requests.
Keys are topic IDs.
Values are plists:
- `:head-rev': the head-rev for which this status was fetched.
- `:total': total number of check runs.
- `:success': number of successful check runs.
- `:runs': list of check run alists.
- `:fetching': boolean, whether a fetch is in progress.")

(defvar forge-plugins-github-actions--log-cache (make-hash-table :test 'equal)
  "Cache of GitHub Actions job logs.
Keys are job IDs (strings).
Values are log strings.")

(defvar forge-plugins-github-actions--steps-cache (make-hash-table :test 'equal)
  "Cache of GitHub Actions job step metadata.
Keys are job IDs (strings).
Values are the `steps' list returned by the jobs API (a list of
alists with at least `name', `number', `status', `conclusion',
`started_at' and `completed_at'), or the symbol `none' when the
job has no step metadata.")

(defvar-keymap forge-plugins-github-action-section-map
  :doc "Keymap for GitHub Action lines in a pull request topic view."
  :parent forge-common-map
  "<remap> <magit-visit-thing>"  #'forge-plugins-github-actions-view-logs
  "b"                            #'forge-plugins-github-actions-visit-run
  "R"                            #'forge-plugins-github-actions-rerun)

(defun forge-plugins-github-actions--run-at-point ()
  "Return the GitHub Action check run on the line at point.
Signal a `user-error' when point is not on an action line."
  (or (get-text-property (point) 'forge-plugins-github-actions-run)
      (user-error "No action under point")))

(defun forge-plugins-github-actions--refresh-buffers ()
  "Refresh all visible or active Magit and Forge buffers."
  (dolist (buf (buffer-list))
    (with-current-buffer buf
      (when (or (derived-mode-p 'forge-topics-mode)
                (derived-mode-p 'magit-status-mode)
                (derived-mode-p 'forge-notifications-mode)
                (derived-mode-p 'forge-pullreq-mode))
        (magit-refresh-buffer)))))

(defvar forge-plugins-github-actions--refresh-timer nil
  "Pending timer used to coalesce buffer refreshes.")

(defun forge-plugins-github-actions--schedule-refresh ()
  "Schedule a debounced refresh of Magit and Forge buffers.
Multiple calls within `forge-plugins-github-actions-refresh-delay'
seconds are coalesced into a single refresh so that a burst of
fetch completions does not trigger a refresh storm."
  (when (timerp forge-plugins-github-actions--refresh-timer)
    (cancel-timer forge-plugins-github-actions--refresh-timer))
  (setq forge-plugins-github-actions--refresh-timer
        (run-with-timer
         forge-plugins-github-actions-refresh-delay nil
         (lambda ()
           (setq forge-plugins-github-actions--refresh-timer nil)
           (forge-plugins-github-actions--refresh-buffers)))))

(defvar forge-plugins-github-actions--queue nil
  "FIFO list of topics pending a check-run fetch.")

(defvar forge-plugins-github-actions--inflight 0
  "Number of check-run fetches currently in flight.")

(defvar forge-plugins-github-actions--dispatch-timer nil
  "Pending timer used to drain the fetch queue off the redisplay path.")

(defun forge-plugins-github-actions--enqueue (topic)
  "Queue TOPIC for a check-run fetch and schedule the queue to drain.
The actual dispatch happens from a timer so that no network setup
work is performed during buffer redisplay."
  (setq forge-plugins-github-actions--queue
        (nconc forge-plugins-github-actions--queue (list topic)))
  (unless (timerp forge-plugins-github-actions--dispatch-timer)
    (setq forge-plugins-github-actions--dispatch-timer
          (run-with-timer
           0 nil
           (lambda ()
             (setq forge-plugins-github-actions--dispatch-timer nil)
             (forge-plugins-github-actions--dispatch))))))

(defun forge-plugins-github-actions--dispatch ()
  "Dispatch queued fetches up to the concurrency limit.
Pops topics off `forge-plugins-github-actions--queue' and fires a
fetch for each, as long as the number of in-flight requests stays
below `forge-plugins-github-actions-max-concurrent-requests'."
  (while (and forge-plugins-github-actions--queue
              (< forge-plugins-github-actions--inflight
                 forge-plugins-github-actions-max-concurrent-requests))
    (let ((topic (pop forge-plugins-github-actions--queue)))
      (cl-incf forge-plugins-github-actions--inflight)
      (forge-plugins-github-actions--fetch topic))))

(defun forge-plugins-github-actions--fetch-done ()
  "Account for a completed fetch and dispatch any queued ones."
  (when (> forge-plugins-github-actions--inflight 0)
    (cl-decf forge-plugins-github-actions--inflight))
  (forge-plugins-github-actions--dispatch))

(defun forge-plugins-github-actions--fetch (topic)
  "Fetch GitHub Actions check-run results for TOPIC asynchronously."
  (let ((id (oref topic id))
        (head-rev (oref topic head-rev)))
    (forge-plugins-github-actions--debug
     "Fetching check runs for topic %s (head-rev: %s)" id head-rev)
    (forge-rest topic "GET" "/repos/:owner/:repo/commits/:head-rev/check-runs" nil
      :callback
      (lambda (value _headers _status _req)
        (let* ((total (alist-get 'total_count value))
               (runs (alist-get 'check_runs value))
               (success 0)
               (failure 0)
               (skipped 0))
          (dolist (run runs)
            (let ((status (alist-get 'status run))
                  (conclusion (alist-get 'conclusion run)))
              (when (equal status "completed")
                (cond
                 ((equal conclusion "success") (cl-incf success))
                 ((member conclusion '("failure" "timed_out" "action_required"))
                  (cl-incf failure))
                 ((equal conclusion "skipped") (cl-incf skipped))))))
          (forge-plugins-github-actions--debug
           "Successfully fetched check runs for topic %s: total=%s, success=%s, failure=%s, skipped=%s"
           id total success failure skipped)
          (puthash id
                   (list :head-rev head-rev
                         :total total
                         :success success
                         :failure failure
                         :skipped skipped
                         :runs runs
                         :fetching nil)
                   forge-plugins-github-actions--cache)
          (forge-plugins-github-actions--fetch-done)
          (forge-plugins-github-actions--schedule-refresh)))
      :errorback
      (lambda (err _headers _status _req)
        (forge-plugins-github-actions--debug
         "Failed to fetch check runs for topic %s: %S" id err)
        (puthash id
                 (list :head-rev head-rev
                       :total nil
                       :success nil
                       :runs nil
                       :fetching nil
                       :error t)
                 forge-plugins-github-actions--cache)
        (forge-plugins-github-actions--fetch-done)
        (forge-plugins-github-actions--schedule-refresh)))))

(defun forge-plugins-github-actions--insert-faced (text face)
  "Insert TEXT and overlay it with FACE so it renders above section highlight.
The overlay uses `priority' 2, matching `forge--insert-topic-labels', so the
status faces win over the `magit-section-highlight' overlay (which has no
explicit priority) when the section is current."
  (let ((beg (point)))
    (insert text)
    (let ((o (make-overlay beg (point))))
      (overlay-put o 'priority 2)
      (overlay-put o 'evaporate t)
      (overlay-put o 'font-lock-face face))))

(defun forge-plugins-github-actions--status-summary (topic)
  "Return the status summary for TOPIC, triggering a fetch if needed.
The return value is a cons cell (STR . FACE) or nil."
  (let* ((id (oref topic id))
         (head-rev (oref topic head-rev))
         (cached (gethash id forge-plugins-github-actions--cache)))
    (cond
     ((not head-rev) nil)
     ((and cached (equal (plist-get cached :head-rev) head-rev))
      (cond
       ((plist-get cached :fetching) nil)
       ((plist-get cached :error) nil)
       (t
        (let* ((total (plist-get cached :total))
               (success (plist-get cached :success))
               (failure (or (plist-get cached :failure) 0))
               (skipped (or (plist-get cached :skipped) 0))
               (relevant (and total (- total skipped))))
          (forge-plugins-github-actions--debug
           "Cache hit for topic %s (head-rev: %s): total=%s, success=%s, failure=%s, skipped=%s"
           id head-rev total success failure skipped)
          (if (and relevant (> relevant 0))
              (let ((face (cond
                           ((> failure 0) 'forge-plugins-github-actions-failure)
                           ((= success relevant) 'forge-plugins-github-actions-success)
                           (t 'forge-plugins-github-actions-warning))))
                (cons (format "(%d/%d)" success relevant) face))
            nil)))))
     (t
      (if cached
          (forge-plugins-github-actions--debug
           "Cache outdated for topic %s (cached head-rev: %s, current head-rev: %s), triggering fetch"
           id (plist-get cached :head-rev) head-rev)
        (forge-plugins-github-actions--debug
         "Cache miss for topic %s (head-rev: %s), triggering fetch" id head-rev))
      (puthash id
               (list :head-rev head-rev :fetching t) forge-plugins-github-actions--cache)
      (forge-plugins-github-actions--enqueue topic)
      nil))))

(defun forge-plugins-github-actions--get-status-string (topic)
  "Return the formatted status string for TOPIC, triggering a fetch if needed."
  (when-let ((summary (forge-plugins-github-actions--status-summary topic)))
    (magit--propertize-face (car summary) (cdr summary))))

(defun forge-plugins-github-actions--format-topic-line (orig-fun topic &optional width)
  "Around advice to append GitHub Actions status to the topic line.
ORIG-FUN is the advised function, called with TOPIC and WIDTH; its
result has the status string appended for GitHub pull requests."
  (let ((line (funcall orig-fun topic width)))
    (if (and forge-plugins-github-actions-enable
             (forge-pullreq-p topic)
             (cl-typep (forge-get-repository topic) 'forge-github-repository))
        (let ((status-str (forge-plugins-github-actions--get-status-string topic)))
          (if status-str
              (concat line " " status-str)
            line))
      line)))

(defun forge-plugins-github-actions--insert-commits-actions (post &optional topic)
  "Insert a GitHub Actions section as a sibling after the Commits section.
This is `:before' advice for `forge-insert-post'.  POST and TOPIC are
the advised function's arguments; the section is only inserted before
the topic's own description post, i.e. when TOPIC is nil and POST is a
GitHub pull request."
  (when (and (null topic)
             forge-plugins-github-actions-enable
             (forge-pullreq-p post)
             (cl-typep (forge-get-repository post) 'forge-github-repository))
    (let* ((topic post)
           (id (oref topic id))
           (head-rev (oref topic head-rev))
           (cached (gethash id forge-plugins-github-actions--cache)))
      (magit-insert-section (github-actions)
        (let ((summary (forge-plugins-github-actions--status-summary topic)))
          (insert (magit--propertize-face "Actions" 'magit-section-heading))
          (when summary
            (insert " ")
            (forge-plugins-github-actions--insert-faced
             (car summary) (cdr summary)))
          (magit-insert-heading))
        (magit-insert-section-body
          (cond
           ((and cached (equal (plist-get cached :head-rev) head-rev))
            (cond
             ((plist-get cached :error)
              (forge-plugins-github-actions--insert-faced
               "error" 'forge-plugins-github-actions-failure)
              (insert "\n"))
             (t
              (if-let* ((runs (plist-get cached :runs)))
                  (dolist (run runs)
                    (let* ((name (alist-get 'name run))
                           (status (alist-get 'status run))
                           (conclusion (alist-get 'conclusion run))
                           (status-str (or (if (equal status "completed")
                                               conclusion
                                             status)
                                           "unknown"))
                           (face (cond
                                  ((equal conclusion "success")
                                   'forge-plugins-github-actions-success)
                                  ((member conclusion
                                           '("failure" "timed_out" "action_required"))
                                   'forge-plugins-github-actions-failure)
                                  (t 'forge-plugins-github-actions-warning)))
                           (beg (point)))
                      (insert "  ")
                      (forge-plugins-github-actions--insert-faced status-str face)
                      (insert (make-string
                               (max 0 (- 15 (string-width status-str))) ?\s))
                      (insert " ")
                      (insert name)
                      (insert "\n")
                      (add-text-properties
                       beg (point)
                       (list 'forge-plugins-github-actions-run run
                             'keymap forge-plugins-github-action-section-map))))
                (insert (magit--propertize-face "none" 'magit-dimmed) "\n")))))
           ((and cached (plist-get cached :fetching))
            (insert (magit--propertize-face "fetching..." 'magit-dimmed) "\n"))
           (t
            ;; The fetch was already enqueued by the heading's
            ;; `forge-plugins-github-actions--status-summary' call above.
            (insert (magit--propertize-face "fetching..." 'magit-dimmed) "\n")))
          (insert "\n"))))))

(cl-defun forge-plugins-github-actions--rest-raw
    (obj-or-host method resource
                 &optional params
                 &key callback errorback noerror unpaginate reader)
  "Like `forge--rest' but supports a custom READER.
OBJ-OR-HOST, METHOD, RESOURCE, PARAMS, CALLBACK, ERRORBACK, NOERROR
and UNPAGINATE are as in `forge--rest'."
  (pcase-let ((`(,host ,forge) (forge--host-arguments obj-or-host)))
    (ghub-request method
      (if (cl-typep obj-or-host 'forge-object)
          (forge--format-resource obj-or-host resource)
        resource)
      params
      :auth 'forge :host host :forge forge
      :callback callback :errorback errorback :noerror noerror
      :unpaginate unpaginate
      :reader reader)))

(defun forge-plugins-github-actions--extract-job-id (run)
  "Extract the job ID from the check run RUN."
  (let ((html-url (alist-get 'html_url run)))
    (if (and html-url (string-match "/actions/runs/[0-9]+/job/\\([0-9]+\\)" html-url))
        (match-string 1 html-url)
      (let ((id (alist-get 'id run)))
        (and id (number-to-string id))))))

(defvar-local forge-plugins-github-actions--log-topic nil
  "The topic associated with the current log buffer.")

(defvar-local forge-plugins-github-actions--log-run nil
  "The check run associated with the current log buffer.")

(defvar-local forge-plugins-github-actions--log-job-id nil
  "The job ID associated with the current log buffer.")

(defun forge-plugins-github-actions-log-browse-url ()
  "Browse the HTML URL of the current GitHub Action job."
  (interactive)
  (if-let ((url (alist-get 'html_url forge-plugins-github-actions--log-run)))
      (browse-url url)
    (user-error "No URL found for this action")))

(defun forge-plugins-github-actions--log-revert-function (_ignore-auto _noconfirm)
  "Revert function to refresh the GitHub Action logs."
  (forge-plugins-github-actions--log-fetch-and-display t))

(defvar-keymap forge-plugins-github-actions-log-mode-map
  :doc "Keymap for `forge-plugins-github-actions-log-mode'."
  :parent magit-section-mode-map
  "B" #'forge-plugins-github-actions-log-browse-url
  "r" #'revert-buffer)

;; Under `evil', the log buffer inherits `special-mode''s motion state, where
;; `B' and `r' would otherwise be shadowed by the global motion/normal maps.
;; Bind them in those states so they win.
(with-eval-after-load 'evil
  (evil-define-key* '(motion normal) forge-plugins-github-actions-log-mode-map
    "B" #'forge-plugins-github-actions-log-browse-url
    "r" #'revert-buffer
    "q" #'quit-window))

(define-derived-mode forge-plugins-github-actions-log-mode magit-section-mode "GH-Action-Log"
  "Major mode for viewing GitHub Action job logs.

Keybindings:
\\{forge-plugins-github-actions-log-mode-map}"
  (setq-local revert-buffer-function #'forge-plugins-github-actions--log-revert-function))

(defun forge-plugins-github-actions--parse-log-line (line)
  "Parse a single log LINE, extracting timestamp and formatting special markers."
  (let ((time-str nil)
        (rest line))
    (when (string-match "^\\([0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}T\\)\\([0-9]\\{2\\}:[0-9]\\{2\\}:[0-9]\\{2\\}\\)\\(\\.[0-9]+Z\\)? " line)
      (setq time-str (match-string 2 line))
      (setq rest (substring line (match-end 0))))
    ;; Workflow command markers are emitted with a leading "##" (by the runner
    ;; itself, e.g. "##[command]") or without it (by actions such as
    ;; actions/checkout, e.g. "[command]").  Allow up to two leading hashes,
    ;; match the marker generically and dispatch on its name, treating any
    ;; unknown marker as normal output.
    (if (not (string-match "^#\\{0,2\\}\\[\\([a-z]+\\)\\]\\(.*\\)" rest))
        (list :type 'normal :time time-str :text rest)
      (let ((marker (match-string 1 rest))
            (text (match-string 2 rest)))
        (pcase marker
          ("command" (list :type 'command :time time-str :text (concat "> " text)))
          ("error" (list :type 'error :time time-str :text (concat "error: " text)))
          ("warning" (list :type 'warning :time time-str :text (concat "warning: " text)))
          ("notice" (list :type 'notice :time time-str :text (concat "notice: " text)))
          ("debug" (list :type 'debug :time time-str :text (concat "debug: " text)))
          ("section" (list :type 'section :time time-str :text text))
          ("group" (list :type 'group-start :time time-str :text text))
          ("endgroup" (list :type 'group-end :time time-str :text nil))
          (_ (list :type 'normal :time time-str :text rest)))))))

(defun forge-plugins-github-actions--parse-log-groups (lines)
  "Parse LINES into a nested structure of groups and lines.
LINES is a list of raw log line strings.  Each `##[group]' opens a
collapsible section that nests under any currently open group and is
closed by its matching `##[endgroup]'; lines following an
`##[endgroup]' are attributed to the enclosing group (or the top
level when none remains open).  Returns a list whose items are
either `(line PARSED)' or `(group TITLE ITEMS)', where ITEMS may
itself contain nested `(group ...)' entries."
  (let ((root nil)
        (stack nil))
    (cl-labels
        ((append-item (item)
           (if stack
               (let ((frame (car stack)))
                 (setcdr frame (cons item (cdr frame))))
             (push item root)))
         (close-top ()
           (let* ((frame (pop stack))
                  (node (list 'group (car frame) (nreverse (cdr frame)))))
             (append-item node))))
      (dolist (line lines)
        (let* ((parsed (forge-plugins-github-actions--parse-log-line line))
               (type (plist-get parsed :type))
               (text (plist-get parsed :text)))
          (cond
           ((eq type 'group-start)
            (push (cons text nil) stack))
           ((eq type 'group-end)
            (when stack (close-top)))
           (t (append-item (list 'line parsed))))))
      (while stack (close-top))
      (nreverse root))))

(defun forge-plugins-github-actions--log-line-timestamp (line)
  "Return the `YYYY-MM-DDTHH:MM:SS' UTC prefix of LINE, or nil.
GitHub prefixes each raw log line with an ISO-8601 UTC timestamp.
The returned prefix is directly comparable lexicographically, which
matches chronological order, and is used to partition lines into the
job's steps by comparing against each step's `started_at'."
  (when (string-match "^\\([0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}T[0-9]\\{2\\}:[0-9]\\{2\\}:[0-9]\\{2\\}\\)"
                      line)
    (match-string 1 line)))

(defun forge-plugins-github-actions--partition-lines-by-steps (lines steps)
  "Partition raw LINES into the job's STEPS by timestamp.
STEPS is the `steps' list from the jobs API.  Returns a cons of
\(PREAMBLE . TABLE) where PREAMBLE is the list of lines emitted before
the first step started, and TABLE is a hash mapping a step `number'
to its list of lines.  Lines without their own timestamp inherit the
bucket of the preceding line.  Steps that never started (`started_at'
nil, e.g. skipped steps) are ignored for partitioning."
  (let* ((started (sort (cl-remove-if-not (lambda (s) (alist-get 'started_at s)) steps)
                        (lambda (a b)
                          (string-lessp (alist-get 'started_at a)
                                        (alist-get 'started_at b)))))
         (starts (mapcar (lambda (s) (substring (alist-get 'started_at s) 0 19)) started))
         (numbers (mapcar (lambda (s) (alist-get 'number s)) started))
         (nsteps (length started))
         (table (make-hash-table :test 'eq))
         (preamble nil)
         (idx -1))
    (dolist (line lines)
      (let ((ts (forge-plugins-github-actions--log-line-timestamp line)))
        (when ts
          (while (and (< (1+ idx) nsteps)
                      (not (string-lessp ts (nth (1+ idx) starts))))
            (cl-incf idx)))
        (if (< idx 0)
            (push line preamble)
          (let ((num (nth idx numbers)))
            (puthash num (cons line (gethash num table)) table)))))
    (maphash (lambda (k v) (puthash k (nreverse v) table)) table)
    (cons (nreverse preamble) table)))

(defun forge-plugins-github-actions--step-face (step)
  "Return the face to use for the heading of STEP."
  (let ((conclusion (alist-get 'conclusion step))
        (status (alist-get 'status step)))
    (cond
     ((equal conclusion "success") 'forge-plugins-github-actions-success)
     ((member conclusion '("failure" "timed_out" "action_required" "cancelled"))
      'forge-plugins-github-actions-failure)
     ((equal conclusion "skipped") 'magit-dimmed)
     ((equal status "completed") 'forge-plugins-github-actions-success)
     (t 'forge-plugins-github-actions-warning))))

(defun forge-plugins-github-actions--insert-log-line (parsed-line)
  "Insert a single PARSED-LINE with proper faces and formatting.
ANSI color escapes in the line's text are resolved here, per line,
so that coloring is applied even for lines materialized lazily when a
collapsed step or group section is later expanded."
  (let ((type (plist-get parsed-line :type))
        (time-str (plist-get parsed-line :time))
        (text (plist-get parsed-line :text)))
    (when time-str
      (insert (magit--propertize-face
               time-str 'forge-plugins-github-actions-log-time)
              " "))
    (when text
      (let ((face (cond
                   ((eq type 'command) 'forge-plugins-github-actions-log-command)
                   ((eq type 'section) 'forge-plugins-github-actions-log-section)
                   ((eq type 'error) 'forge-plugins-github-actions-failure)
                   ((eq type 'warning) 'forge-plugins-github-actions-warning)
                   ((eq type 'notice) 'forge-plugins-github-actions-warning)
                   ((eq type 'debug) 'magit-dimmed)
                   (t nil)))
            (beg (point)))
        (if face
            (insert (magit--propertize-face text face))
          (insert text))
        (ansi-color-apply-on-region beg (point))))
    (insert "\n")))

(defun forge-plugins-github-actions--insert-parsed-log (parsed)
  "Insert PARSED log structure into the current buffer.
PARSED is a list of `(line ...)' and `(group TITLE ITEMS)' items as
returned by `forge-plugins-github-actions--parse-log-groups'.  Groups
are rendered as collapsible sections and may nest arbitrarily."
  (dolist (item parsed)
    (pcase item
      (`(line ,parsed-line)
       (forge-plugins-github-actions--insert-log-line parsed-line))
      (`(group ,title ,items)
       (magit-insert-section (github-action-log-group title t)
         (magit-insert-heading title)
         (magit-insert-section-body
           (forge-plugins-github-actions--insert-parsed-log items)))))))

(defun forge-plugins-github-actions--insert-step-section (step lines)
  "Insert a collapsible section for STEP containing LINES.
STEP is a step alist from the jobs API and LINES is the list of raw
log line strings belonging to it.  Successful steps are collapsed by
default while failed steps are expanded, mirroring the web UI."
  (let* ((name (alist-get 'name step))
         (conclusion (alist-get 'conclusion step))
         (failed (member conclusion
                         '("failure" "timed_out" "action_required" "cancelled")))
         (heading (magit--propertize-face
                   (or name "step")
                   (forge-plugins-github-actions--step-face step))))
    (magit-insert-section (github-action-log-step name (not failed))
      (magit-insert-heading heading)
      (magit-insert-section-body
        (forge-plugins-github-actions--insert-parsed-log
         (forge-plugins-github-actions--parse-log-groups lines))))))

(defun forge-plugins-github-actions--insert-log (value steps)
  "Insert the decoded log VALUE into the current buffer.
When STEPS (the job's step metadata) is available, the log is
partitioned by timestamp into one collapsible section per step,
named after the step and ordered as reported by the API, with nested
`##[group]' blocks rendered as nested sections.  Otherwise the whole
log is rendered with nested groups only.  ANSI colors are applied
per line by `forge-plugins-github-actions--insert-log-line', so that
lazily-materialized collapsed sections are colored on expansion."
  (magit-insert-section (logbuf)
    (let ((lines (split-string value "\r?\n")))
      (if (and steps (listp steps))
          (pcase-let* ((`(,preamble . ,table)
                        (forge-plugins-github-actions--partition-lines-by-steps
                         lines steps)))
            (when preamble
              (forge-plugins-github-actions--insert-parsed-log
               (forge-plugins-github-actions--parse-log-groups preamble)))
            (dolist (step (cl-sort (copy-sequence steps) #'<
                                   :key (lambda (s) (or (alist-get 'number s) 0))))
              (let ((step-lines (gethash (alist-get 'number step) table)))
                (when (or step-lines (alist-get 'started_at step))
                  (forge-plugins-github-actions--insert-step-section
                   step (or step-lines nil))))))
        (forge-plugins-github-actions--insert-parsed-log
         (forge-plugins-github-actions--parse-log-groups lines))))))

(defun forge-plugins-github-actions--log-insert-message (message)
  "Replace the current log buffer with MESSAGE inside a root section.
The log buffer uses `magit-section-mode', whose `post-command-hook'
requires a root section to exist; inserting bare text would make
`magit-current-section' return nil and signal a wrong-type error."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (magit-insert-section (logbuf)
      (insert message))
    (set-buffer-modified-p nil)))

(defun forge-plugins-github-actions--render-log (buf value steps)
  "Render the decoded log VALUE with STEPS metadata into BUF.
STEPS may be nil (render with nested groups only) or `none' (treated
as nil).  An empty VALUE shows a placeholder message."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (if (and value (not (equal value "")))
          (let ((inhibit-read-only t)
                (steps (and (listp steps) steps)))
            (erase-buffer)
            (forge-plugins-github-actions--insert-log value steps)
            (set-buffer-modified-p nil)
            (goto-char (point-min)))
        (forge-plugins-github-actions--log-insert-message
         "No logs found or log is empty.\n")))))

(defun forge-plugins-github-actions--log-fetch-logs (topic job-id buf)
  "Fetch the logs for JOB-ID of TOPIC and render them into BUF.
Step metadata is read from the steps cache, having been fetched
beforehand by `forge-plugins-github-actions--log-fetch-and-display'."
  (forge-plugins-github-actions--debug "Fetching logs for job %s" job-id)
  (let ((url (format "/repos/:owner/:repo/actions/jobs/%s/logs" job-id)))
    (forge-plugins-github-actions--rest-raw
     topic "GET" url nil
     :reader #'ghub--decode-payload
     :callback
     (lambda (value &rest _)
       (forge-plugins-github-actions--debug
        "Successfully fetched logs for job %s (length: %d)" job-id (length value))
       (puthash job-id value forge-plugins-github-actions--log-cache)
       (let ((steps (gethash job-id forge-plugins-github-actions--steps-cache)))
         (forge-plugins-github-actions--render-log buf value steps)))
     :errorback
     (lambda (err &rest _)
       (forge-plugins-github-actions--debug
        "Failed to fetch logs for job %s: %S" job-id err)
       (when (buffer-live-p buf)
         (with-current-buffer buf
           (let ((msg (or (and (listp err) (cdr (assq 'message err)))
                          (and (listp err) (cdr (assq 'error err)))
                          (and (stringp err) err))))
             (forge-plugins-github-actions--log-insert-message
              (if msg
                  (concat "Failed to fetch logs.\n" "Error: " msg "\n")
                "Failed to fetch logs.\n")))))))))

(defun forge-plugins-github-actions--log-fetch-steps (topic job-id buf then)
  "Fetch step metadata for JOB-ID of TOPIC, cache it, then call THEN.
THEN is called with no arguments once the metadata (or a `none'
marker on failure) has been cached.  BUF is only used to guard
against rendering into a dead buffer."
  (forge-plugins-github-actions--debug "Fetching step metadata for job %s" job-id)
  (let ((url (format "/repos/:owner/:repo/actions/jobs/%s" job-id)))
    (forge-rest topic "GET" url nil
      :callback
      (lambda (value &rest _)
        (let ((steps (alist-get 'steps value)))
          (forge-plugins-github-actions--debug
           "Fetched %d steps for job %s" (length steps) job-id)
          (puthash job-id (or steps 'none)
                   forge-plugins-github-actions--steps-cache)
          (when (buffer-live-p buf) (funcall then))))
      :errorback
      (lambda (err &rest _)
        (forge-plugins-github-actions--debug
         "Failed to fetch step metadata for job %s: %S" job-id err)
        (puthash job-id 'none forge-plugins-github-actions--steps-cache)
        (when (buffer-live-p buf) (funcall then))))))

(defun forge-plugins-github-actions--log-fetch-and-display (&optional force)
  "Fetch and display the logs in the current buffer.
If FORCE is nil and the logs are cached, use the cached logs.  The
job's step metadata is fetched first so the log can be partitioned
into one collapsible section per step, matching GitHub's web UI."
  (let ((topic forge-plugins-github-actions--log-topic)
        (job-id forge-plugins-github-actions--log-job-id)
        (buf (current-buffer)))
    (if (and (not force)
             (gethash job-id forge-plugins-github-actions--log-cache))
        (let ((value (gethash job-id forge-plugins-github-actions--log-cache))
              (steps (gethash job-id forge-plugins-github-actions--steps-cache)))
          (forge-plugins-github-actions--debug "Using cached logs for job %s" job-id)
          (forge-plugins-github-actions--render-log buf value steps))
      (with-current-buffer buf
        (forge-plugins-github-actions--log-insert-message
         (concat "Fetching logs for job " job-id "...\n")))
      (if (and (not force)
               (gethash job-id forge-plugins-github-actions--steps-cache))
          (forge-plugins-github-actions--log-fetch-logs topic job-id buf)
        (forge-plugins-github-actions--log-fetch-steps
         topic job-id buf
         (lambda ()
           (forge-plugins-github-actions--log-fetch-logs topic job-id buf)))))))

(defun forge-plugins-github-actions-view-logs ()
  "Fetch and display the logs of the GitHub Action under point."
  (interactive)
  (let* ((run (forge-plugins-github-actions--run-at-point))
         (topic forge-buffer-topic)
         (job-id (forge-plugins-github-actions--extract-job-id run))
         (name (alist-get 'name run))
         (buf-name (format "*forge-github-action-log: %s (%s)*" name job-id))
         (buf (get-buffer-create buf-name)))
    (with-current-buffer buf
      (forge-plugins-github-actions-log-mode)
      (setq forge-plugins-github-actions--log-topic topic)
      (setq forge-plugins-github-actions--log-run run)
      (setq forge-plugins-github-actions--log-job-id job-id))
    (pop-to-buffer buf)
    (with-current-buffer buf
      (forge-plugins-github-actions--log-fetch-and-display))))

(defun forge-plugins-github-actions-visit-run ()
  "Open the HTML URL of the GitHub Action under point."
  (interactive)
  (let* ((run (forge-plugins-github-actions--run-at-point))
         (url (alist-get 'html_url run)))
    (if url
        (browse-url url)
      (user-error "No URL found for this action"))))

(defun forge-plugins-github-actions-rerun ()
  "Re-run the GitHub Action under point."
  (interactive)
  (let* ((run (forge-plugins-github-actions--run-at-point))
         (topic forge-buffer-topic)
         (repo (forge-get-repository topic))
         (owner (oref repo owner))
         (name (oref repo name))
         (run-id (alist-get 'id run))
         (run-name (alist-get 'name run))
         (url (format "/repos/%s/%s/check-runs/%s/rerequest" owner name run-id)))
    (message "Requesting re-run of %s..." run-name)
    (forge-plugins-github-actions--debug
     "Requesting re-run of check run %s (ID: %s)" run-name run-id)
    (forge-rest topic "POST" url nil
      :callback
      (lambda (&rest _)
        (message "Re-run of %s requested successfully" run-name)
        (forge-plugins-github-actions--debug
         "Successfully requested re-run of check run %s" run-name)
        (let* ((id (oref topic id))
               (cached (gethash id forge-plugins-github-actions--cache)))
          (when cached
            (puthash id
                     (plist-put cached :fetching t)
                     forge-plugins-github-actions--cache)
            (forge-plugins-github-actions--schedule-refresh)))
        (run-with-timer
         2 nil #'forge-plugins-github-actions--enqueue topic))
      :errorback
      (lambda (err &rest _)
        (let ((msg (or (alist-get 'message err) "Unknown error")))
          (message "Failed to re-run %s: %s" run-name msg)
          (forge-plugins-github-actions--debug
           "Failed to request re-run of check run %s: %S" run-name err))))))

;;;###autoload
(defun forge-plugins-github-actions-enable ()
  "Enable GitHub Actions status integration."
  (interactive)
  (setq forge-plugins-github-actions-enable t)
  (advice-add 'forge--format-topic-line
              :around #'forge-plugins-github-actions--format-topic-line)
  (advice-add 'forge-insert-post
              :before #'forge-plugins-github-actions--insert-commits-actions))

;;;###autoload
(defun forge-plugins-github-actions-disable ()
  "Disable GitHub Actions status integration."
  (interactive)
  (setq forge-plugins-github-actions-enable nil)
  (advice-remove 'forge-insert-post
                 #'forge-plugins-github-actions--insert-commits-actions)
  (advice-remove 'forge--format-topic-line
                 #'forge-plugins-github-actions--format-topic-line))

;;;###autoload
(defcustom forge-plugins-github-actions-enable nil
  "Whether to enable GitHub Actions status integration."
  :package-version '(forge-plugins-github-actions . "0.1.0")
  :group 'forge
  :type 'boolean
  :set (lambda (sym val)
         (set-default sym val)
         (when (featurep 'forge-plugins-github-actions)
           (if val
               (forge-plugins-github-actions-enable)
             (forge-plugins-github-actions-disable)))))

(when forge-plugins-github-actions-enable
  (forge-plugins-github-actions-enable))

(provide 'forge-plugins-github-actions)
;;; forge-plugins-github-actions.el ends here
