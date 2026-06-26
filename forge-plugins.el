;;; forge-plugins.el --- Collection of plugins for forge  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  drlkf

;; Author: drlkf <drlkf@drlkf.net>
;; Maintainer: drlkf <drlkf@drlkf.net>
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (forge "0.5.0") (magit "4.0.0") (ghub "4.0.0"))
;; Keywords: tools
;; URL: https://github.com/drlkf/magit-forge-plugins

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

;; This package provides a collection of plugins that extend
;; `forge'.  Set each plugin's flag variable to `t' to enable it.
;; Each plugin installs its advice at load time and checks its flag
;; at runtime.

;;; Code:

(require 'forge-plugins-topic-format)
(require 'forge-plugins-github-actions)
(require 'forge-plugins-pullreq-commits)
(require 'forge-plugins-pullreq-approvals)

;;;###autoload
(defun forge-plugins-enable ()
  "Enable all plugins according to their feature flag."
  (interactive)
  (when forge-plugins-topic-format-enable
    (forge-plugins-topic-format-enable))
  (when forge-plugins-github-actions-enable
    (forge-plugins-github-actions-enable))
  (when forge-plugins-pullreq-commits-enable
    (forge-plugins-pullreq-commits-enable))
  (when forge-plugins-pullreq-approvals-enable
    (forge-plugins-pullreq-approvals-enable)))

(provide 'forge-plugins)
;;; forge-plugins.el ends here
