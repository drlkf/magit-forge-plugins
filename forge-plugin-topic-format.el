;;; forge-plugin-topic-format.el --- Topic line formatting customization  -*- lexical-binding: t; -*-

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

;; Customize the format of topic lines in `forge' topic and
;; notification lists.  Provides `forge-plugin-topic-line-format' and
;; `forge-plugin-topic-slug-symbols' to control display.

;;; Code:

(require 'forge nil t)

(defconst forge-plugin-topic-format-tested-on-forge "0.6.6"
  "Forge version this plugin was tested against.")

(defcustom forge-plugin-topic-line-format "%R%s %t"
  "Format for topic lines in topic and notification lists.

The following %-sequences are supported:

`%R' The slug of the repository, padded to
`forge-topic-repository-slug-width', followed by a space.
This is only non-empty in flat notification lists and in
ungrouped, global topic lists; elsewhere it expands to the
empty string.
`%s' The slug of the topic (e.g., \"#123\"), padded to the width
requested by the caller.
`%a' The login of the topic's author.
`%t' The title of the topic."
  :package-version '(forge-plugin-topic-format . "0.1.0")
  :group 'forge
  :type 'string)

(defcustom forge-plugin-topic-slug-symbols
  '((forge-issue . nil)
    (forge-pullreq . nil)
    (forge-discussion . nil))
  "Symbols used to prefix topic slugs, by topic type.

Each entry maps a topic class to the symbol displayed in front of
the topic's number. When the symbol is nil, the slug provided by
the forge is used as-is; otherwise the forge's leading symbol is
replaced with the configured one at display time.

Note that forges use their own conventions: e.g., GitLab uses
\"!\" for merge requests and \"#\" for issues, while GitHub uses
\"#\" for everything. By default these conventions are preserved.
For example, setting `forge-discussion' to \"@\" displays GitHub
discussions with an at-sign prefix."
  :package-version '(forge-plugin-topic-format . "0.1.0")
  :group 'forge
  :type '(alist :key-type (choice (const forge-issue)
                                  (const forge-pullreq)
                                  (const forge-discussion))
                :value-type (choice (const :tag "Use forge's slug" nil)
                                    string)))

(defun forge-plugin--apply-topic-slug-symbol (topic slug)
  "Return SLUG with its leading symbol replaced.
The replacement is chosen based on the type of TOPIC per
`forge-plugin-topic-slug-symbols'. If no symbol is configured
for that type, SLUG is returned unchanged."
  (let* ((sym (cdr (assq (cond ((forge-discussion-p topic) 'forge-discussion)
                               ((forge-pullreq-p topic) 'forge-pullreq)
                               ((forge-issue-p topic) 'forge-issue))
                         forge-plugin-topic-slug-symbols))))
    (if (not sym)
        slug
      (let* ((rest (string-remove-prefix
                    "@" (string-remove-prefix
                         "!" (string-remove-prefix "#" slug))))
             (props (text-properties-at 0 slug)))
        (apply #'propertize (concat sym rest) props)))))

(defun forge-plugin--format-topic-slug (orig-fun topic)
  (if forge-plugin-topic-format-enable
      (forge-plugin--apply-topic-slug-symbol topic (funcall orig-fun topic))
    (funcall orig-fun topic)))

(defun forge-plugin--format-topic-line (orig-fun topic &optional width)
  (if forge-plugin-topic-format-enable
      (format-spec
       forge-plugin-topic-line-format
       `((?R . ,(or (and (or (and (derived-mode-p 'forge-notifications-mode)
                                  (eq forge-notifications-display-style 'flat))
                             (and (derived-mode-p 'forge-topics-mode)
                                  (oref forge--buffer-topics-spec global)
                                  (not (oref forge--buffer-topics-spec grouped))))
                         (concat (truncate-string-to-width
                                  (oref (forge-get-repository topic) slug)
                                  forge-topic-repository-slug-width
                                  nil ?\s t)
                                 " "))
                    ""))
         (?s . ,(string-pad (forge--format-topic-slug topic) (or width 5)))
         (?a . ,(forge-plugin--format-topic-author topic))
         (?t . ,(forge--format-topic-title topic))))
    (funcall orig-fun topic width)))

(defun forge-plugin--format-topic-author (topic)
  (magit--propertize-face (or (oref topic author) "(ghost)")
                          'forge-post-author))

;;;###autoload
(defun forge-plugin-topic-format-enable ()
  "Enable topic line formatting customization."
  (interactive)
  (setq forge-plugin-topic-format-enable t)
  (advice-add 'forge--format-topic-slug :around #'forge-plugin--format-topic-slug)
  (advice-add 'forge--format-topic-line :around #'forge-plugin--format-topic-line))

;;;###autoload
(defun forge-plugin-topic-format-disable ()
  "Disable topic line formatting customization."
  (interactive)
  (setq forge-plugin-topic-format-enable nil)
  (advice-remove 'forge--format-topic-slug #'forge-plugin--format-topic-slug)
  (advice-remove 'forge--format-topic-line #'forge-plugin--format-topic-line))

;;;###autoload
(defcustom forge-plugin-topic-format-enable nil
  "Whether to enable topic line formatting customization."
  :package-version '(forge-plugin-topic-format . "0.1.0")
  :group 'forge
  :type 'boolean
  :set (lambda (sym val)
         (set-default sym val)
         (when (featurep 'forge-plugin-topic-format)
           (if val
               (forge-plugin-topic-format-enable)
             (forge-plugin-topic-format-disable)))))

(when forge-plugin-topic-format-enable
  (forge-plugin-topic-format-enable))

(provide 'forge-plugin-topic-format)
;;; forge-plugin-topic-format.el ends here
