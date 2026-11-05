;;; forge-plugins-topic-kill.el --- Kill topic buffers on quit  -*- lexical-binding: t; -*-

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

;; Make `magit-mode-bury-buffer' kill `forge-topic-mode' buffers
;; instead of burying them.

;;; Code:

(require 'magit-mode)

(defconst forge-plugins-topic-kill-tested-on-forge "0.6.6"
  "Forge version this plugin was tested against.")

(defun forge-plugins--topic-kill-args (args)
  "Force the kill argument in ARGS when in a topic buffer."
  (if (and forge-plugins-topic-kill-enable
           (derived-mode-p 'forge-topic-mode))
      (list t)
    args))

;;;###autoload
(defun forge-plugins-topic-kill-enable ()
  "Kill topic buffers when quitting them."
  (interactive)
  (setq forge-plugins-topic-kill-enable t)
  (advice-add 'magit-mode-bury-buffer :filter-args
              #'forge-plugins--topic-kill-args))

;;;###autoload
(defun forge-plugins-topic-kill-disable ()
  "Bury topic buffers when quitting them."
  (interactive)
  (setq forge-plugins-topic-kill-enable nil)
  (advice-remove 'magit-mode-bury-buffer #'forge-plugins--topic-kill-args))

;;;###autoload
(defcustom forge-plugins-topic-kill-enable nil
  "Whether quitting a topic buffer kills it."
  :package-version '(forge-plugins-topic-kill . "0.1.0")
  :group 'forge
  :type 'boolean
  :set (lambda (sym val)
         (set-default sym val)
         (when (featurep 'forge-plugins-topic-kill)
           (if val
               (forge-plugins-topic-kill-enable)
             (forge-plugins-topic-kill-disable)))))

(when forge-plugins-topic-kill-enable
  (forge-plugins-topic-kill-enable))

(provide 'forge-plugins-topic-kill)
;;; forge-plugins-topic-kill.el ends here
