;;; forge-plugins-prefetch.el --- Piggyback plugin data on forge pulls  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  drlkf

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; Forge's pull query has no extension point, but it reads
;; `forge--github-pullreqs-fragment' at call time.  While pulling, we
;; rebind it to include the pullRequest fields registered by enabled
;; plugins, then hand each pulled pull request's data to the plugins'
;; consumers so they can fill their caches instead of fetching per topic.

;;; Code:

(require 'cl-lib)
(require 'forge-github)

;; forge main splits its query into per-type fragments; released forge
;; (e.g. 20260623) has one `forge--github-repository-query'.
(defvar forge--github-pullreqs-fragment)
(defvar forge--github-repository-query)

(defconst forge-plugins-prefetch--query-vars
  '(forge--github-pullreqs-fragment forge--github-repository-query)
  "Forge query variables holding a `pullRequests' connection.")

(defvar forge-plugins-prefetch--providers nil
  "Alist of (NAME ENABLED FIELDS CONSUMER).
ENABLED is a symbol whose value toggles the provider.  FIELDS is a
list of gsexp pullRequest fields; nested connections must use a fixed
`first' instead of `:edges' so ghub doesn't paginate them per PR.
CONSUMER is called with REPO and the pullRequest DATA alist.")

(defun forge-plugins-prefetch-register (name enabled fields consumer)
  "Register or replace provider NAME, see `forge-plugins-prefetch--providers'."
  (setf (alist-get name forge-plugins-prefetch--providers)
        (list enabled fields consumer)))

(defun forge-plugins-prefetch--active ()
  (cl-remove-if-not (lambda (p) (symbol-value (nth 1 p)))
                    forge-plugins-prefetch--providers))

(defun forge-plugins-prefetch--fragment (query)
  "QUERY with active providers' fields appended to its `pullRequests' node."
  (let ((extra (cl-delete-duplicates
                (mapcan (lambda (p) (copy-sequence (nth 2 p)))
                        (forge-plugins-prefetch--active))
                :test #'equal)))
    (cl-labels ((walk (node)
                  (cond ((not (consp node)) node)
                        ((and (eq (car node) 'pullRequests) (vectorp (cadr node)))
                         (append node extra))
                        (t (mapcar #'walk node)))))
      (if extra (walk query) query))))

(defun forge-plugins-prefetch--pull-advice (orig &rest args)
  "Around advice extending forge's pull request query for ORIG with ARGS."
  (cl-progv
      (cl-remove-if-not #'boundp forge-plugins-prefetch--query-vars)
      (mapcar (lambda (v) (forge-plugins-prefetch--fragment (symbol-value v)))
              (cl-remove-if-not #'boundp forge-plugins-prefetch--query-vars))
    (apply orig args)))

(defun forge-plugins-prefetch--update-advice (orig repo data &rest args)
  "Around advice feeding DATA to active consumers after ORIG stores it.
ARGS covers released forge's extra optional arguments."
  (prog1 (apply orig repo data args)
    (dolist (p (forge-plugins-prefetch--active))
      (with-demoted-errors "forge-plugins-prefetch: %S"
        (funcall (nth 3 p) repo data)))))

(advice-add 'forge--pull :around #'forge-plugins-prefetch--pull-advice)
(advice-add 'forge--pull-topic :around #'forge-plugins-prefetch--pull-advice)
(advice-add 'forge--pull-notifications :around #'forge-plugins-prefetch--pull-advice)
(advice-add 'forge--update-pullreq :around #'forge-plugins-prefetch--update-advice)

(provide 'forge-plugins-prefetch)
;;; forge-plugins-prefetch.el ends here
