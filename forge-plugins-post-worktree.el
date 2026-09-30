;;; forge-plugins-post-worktree.el --- Guard post drafts against stale worktrees  -*- lexical-binding: t; -*-

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

;; `forge--post-expand-file-name' trusts the raw `worktree' slot.  When
;; the recorded clone is gone, `magit-gitdir' returns nil and the draft
;; path is expanded against `default-directory', which is "/" in global
;; list buffers.  This plugin validates the worktree first and clears
;; the slot when it is stale, so drafts fall back to
;; `forge-post-fallback-directory'.

;;; Code:

(require 'forge nil t)

(defconst forge-plugins-post-worktree-tested-on-forge "0.6.6"
  "Forge version this plugin was tested against.")

(defun forge-plugins--post-worktree-expand-file-name (orig file repo)
  "Clear REPO's stale worktree before calling ORIG with FILE and REPO."
  (when (and forge-plugins-post-worktree-enable
             (not (and-let* ((tree (forge-get-worktree repo)))
                    (magit-gitdir tree))))
    (oset repo worktree nil))
  (funcall orig file repo))

;;;###autoload
(defun forge-plugins-post-worktree-enable ()
  "Enable worktree validation for post drafts."
  (interactive)
  (setq forge-plugins-post-worktree-enable t)
  (advice-add 'forge--post-expand-file-name :around
              #'forge-plugins--post-worktree-expand-file-name))

;;;###autoload
(defun forge-plugins-post-worktree-disable ()
  "Disable worktree validation for post drafts."
  (interactive)
  (setq forge-plugins-post-worktree-enable nil)
  (advice-remove 'forge--post-expand-file-name
                 #'forge-plugins--post-worktree-expand-file-name))

;;;###autoload
(defcustom forge-plugins-post-worktree-enable nil
  "Whether to validate the worktree before creating post drafts."
  :package-version '(forge-plugins-post-worktree . "0.1.0")
  :group 'forge
  :type 'boolean
  :set (lambda (sym val)
         (set-default sym val)
         (when (featurep 'forge-plugins-post-worktree)
           (if val
               (forge-plugins-post-worktree-enable)
             (forge-plugins-post-worktree-disable)))))

(when forge-plugins-post-worktree-enable
  (forge-plugins-post-worktree-enable))

(provide 'forge-plugins-post-worktree)
;;; forge-plugins-post-worktree.el ends here
