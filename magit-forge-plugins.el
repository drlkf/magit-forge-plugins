;;; magit-forge-plugins.el --- Collection of plugins for forge  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  drlkf

;; Author: drlkf
;; Package-Requires: ((forge "0.5.0") (emacs "29.1"))
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

;; This package provides a collection of plugins that extend
;; `forge'.  Set each plugin's flag variable to `t' to enable it.
;; Each plugin installs its advice at load time and checks its flag
;; at runtime.

;;; Code:

(require 'forge-plugin-topic-format)
(require 'forge-plugin-github-actions)

;;;###autoload
(defun forge-plugins-enable ()
  "Enable all plugins according to their feature flag."
  (interactive)
  (when forge-plugin-topic-format-enable
    (forge-plugin-topic-format-enable))
  (when forge-plugin-github-actions-enable
    (forge-plugin-github-actions-enable)))

(provide 'magit-forge-plugins)
;;; magit-forge-plugins.el ends here
