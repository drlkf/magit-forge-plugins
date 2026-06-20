;;; forge-plugins-pullreq-commits.el --- Show only canonical pull request commits  -*- lexical-binding: t; -*-

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

;; In the pull request buffer, `forge' populates the "Commits" section
;; by unioning several refs (the canonical `refs/pullreqs/N' ref, the
;; active local pull request branch, and a local branch matching the
;; head ref) so the listing stays useful when those refs are out of
;; sync.  A side effect is that, after a force-push or rebase, a local
;; pull request branch that still points at the old commits causes
;; those stale commits to reappear in the section.
;;
;; This plugin restricts the section to `forge''s canonical range,
;; `<remote>/<base-ref>..refs/pullreqs/N', so that only the commits
;; actually present in the (re-fetched) pull request are shown.  It
;; advises `forge--insert-pullreq-commits' to drop its ALL argument.

;;; Code:

(require 'forge nil t)

(defconst forge-plugins-pullreq-commits-tested-on-forge "0.6.6"
  "Forge version this plugin was tested against.")

(defun forge-plugins--pullreq-commits-canonical-range (args)
  "Drop the ALL argument from `forge--insert-pullreq-commits' ARGS.
With ALL removed, `forge' lists the canonical pull request range
\(`<remote>/<base-ref>..refs/pullreqs/N') instead of unioning the
possibly stale local pull request branches, so commits left behind
by a force-push or rebase no longer appear.  When the plugin is
disabled, ARGS is returned unchanged."
  (if forge-plugins-pullreq-commits-enable
      (list (car args))
    args))

;;;###autoload
(defun forge-plugins-pullreq-commits-enable ()
  "Enable restricting pull request commits to the canonical range."
  (interactive)
  (setq forge-plugins-pullreq-commits-enable t)
  (advice-add 'forge--insert-pullreq-commits :filter-args
              #'forge-plugins--pullreq-commits-canonical-range))

;;;###autoload
(defun forge-plugins-pullreq-commits-disable ()
  "Disable restricting pull request commits to the canonical range."
  (interactive)
  (setq forge-plugins-pullreq-commits-enable nil)
  (advice-remove 'forge--insert-pullreq-commits
                 #'forge-plugins--pullreq-commits-canonical-range))

;;;###autoload
(defcustom forge-plugins-pullreq-commits-enable nil
  "Whether to restrict pull request commits to the canonical range."
  :package-version '(forge-plugins-pullreq-commits . "0.1.0")
  :group 'forge
  :type 'boolean
  :set (lambda (sym val)
         (set-default sym val)
         (when (featurep 'forge-plugins-pullreq-commits)
           (if val
               (forge-plugins-pullreq-commits-enable)
             (forge-plugins-pullreq-commits-disable)))))

(when forge-plugins-pullreq-commits-enable
  (forge-plugins-pullreq-commits-enable))

(provide 'forge-plugins-pullreq-commits)
;;; forge-plugins-pullreq-commits.el ends here
