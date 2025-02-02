;;; org-node.el --- Link org-id entries into a network -*- lexical-binding: t; -*-

;; Copyright (C) 2024 Martin Edström
;;
;; This file is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; For a full copy of the GNU General Public License
;; see <http://www.gnu.org/licenses/>.

;; Author:           Martin Edström <meedstrom91@gmail.com>
;; Created:          2024-04-13
;; Keywords:         org, hypermedia
;; Package-Requires: ((emacs "28.1") (compat "30") (llama))
;; URL:              https://github.com/meedstrom/org-node

;;; Commentary:

;; What is Org-node?

;; If you were the sort of person to prefer "id:" links over "file:"
;; links or any other type of link, you're in the right place!

;; Now you can rely on IDs and worry less about mentally tracking your
;; subtree hierarchies and directory structures.  As long as you've
;; assigned an ID to something, you can find it later.

;; The philosophy is the same as org-roam: if you assign an ID every
;; time you make an entry that you know you might want to link to from
;; elsewhere, then it tends to work out that the `org-node-find' command
;; can jump to more or less every entry you'd ever want to jump to.
;; Pretty soon you've forgot that your files have names.

;; Anyway, that's just the core of it as described to someone not
;; familiar with zettelkasten-ish packages.  In fact, out of the
;; simplicity arises something powerful, more to be experienced than
;; explained.

;; Compared to org-roam:

;;   - Same idea, compatible disk format
;;   - Faster
;;   - Does not need SQLite
;;   - Does not support "roam:" links
;;   - Lets you opt out of those file-level property drawers
;;   - Ships extra commands to e.g. auto-rename files and links
;;   - Tries to rely in a bare-metal way on upstream org-id and org-capture

;;   As a drawback of relying on org-id-locations, if a heading in some
;;   vendor README.org or whatever has an ID, it's considered part of
;;   your collection -- simply because if it's known to org-id, it's
;;   known to org-node.
;;   These headings can be filtered after-the-fact.

;; Compared to denote:

;;   - Org only, no Markdown nor other file types
;;   - Does not support "denote:" links
;;   - Filenames have no meaning (can match the Denote format if you like)
;;   - You can have as many "notes" as you want inside one file.  You
;;     could possibly use Denote to search files and org-node
;;     as a more granular search.

;;; Code:

;; Built-in
(require 'seq)
(require 'cl-lib)
(require 'subr-x)
(require 'bytecomp)
(require 'transient)
(require 'ucs-normalize)
(require 'org)
(require 'org-id)
(require 'org-macs)
(require 'org-element)

;; External
(require 'llama)
(require 'compat)
(require 'org-node-parser)
(require 'org-node-changes)

;; Satisfy compiler
(defvar $i)
(defvar org-roam-directory)
(defvar org-roam-dailies-directory)
(defvar consult-ripgrep-args)
(defvar org-node-backlink-mode)
(declare-function org-node-backlink--fix-entry-here "org-node-backlink")
(declare-function profiler-report "profiler")
(declare-function profiler-stop "profiler")
(declare-function tramp-tramp-file-p "tramp")
(declare-function org-lint "org-lint")
(declare-function consult--grep "consult")
(declare-function consult--grep-make-builder "consult")
(declare-function consult--ripgrep-make-builder "consult")


;;;; Options

(defgroup org-node nil
  "Support a zettelkasten of org-id files and subtrees."
  :group 'org)

(defcustom org-node-rescan-functions nil
  "Hook run after scanning specific files.
Not run after a full cache reset, only after e.g. a file is
saved or renamed causing an incremental update to the cache.

Called with one argument: the list of files re-scanned.  It may
include deleted files."
  :type 'hook)

(defcustom org-node-prefer-with-heading nil
  "Make a heading even when creating isolated file nodes.
If nil, write a #+TITLE and a file-level property-drawer instead.

In other words:

- if nil, make file with no heading (outline level 0)
- if t, make file with heading (outline level 1)

This affects the behavior of `org-node-new-file',
`org-node-extract-subtree', and `org-node-capture-target'.

If you change your mind about this setting, you can
transition the files you already have with the Org-roam commands
`org-roam-promote-entire-buffer' and `org-roam-demote-entire-buffer'."
  :type 'boolean)

(defcustom org-node-inject-variables (list)
  "Alist of variable-value pairs that child processes should set.

May be useful for injecting your authinfo and EasyPG settings so
that org-node can scan for ID nodes inside .org.gpg files.  Also,
`org-node-perf-keep-file-name-handlers' should include the EPG
handler.

I do not use EPG, so that is probably not enough to make it work.
Report an issue on https://github.com/meedstrom/org-node/issues
or drop me a line on Mastodon: @meedstrom@hachyderm.io"
  :type 'alist)

(defcustom org-node-link-types
  '("http" "https" "id")
  "Link types that may count as backlinks.
Types other than \"id\" only result in a backlink when there is
some node with the same link in its ROAM_REFS property.

Having fewer types results in a faster \\[org-node-reset].
Tip: eval `(org-link-types)' to see all possible types.

There is no need to add the \"cite\" type."
  :type '(repeat string))

(defcustom org-node-perf-assume-coding-system nil
  "Coding system to assume while scanning ID nodes.

Picking a specific coding system can speed up `org-node-reset'.
Set nil to let Emacs figure it out anew on every file.

For now, this setting is likely only impactful if
`org-node-perf-max-jobs' is very low.  Otherwise overhead is a much
larger component of the execute time.

On MS Windows this probably should be nil.  Same if you access
your files from multiple platforms.

Modern GNU/Linux, BSD and MacOS systems almost always encode new
files as `utf-8-unix'.  You can verify with a helper command
\\[org-node-list-file-coding-systems].

Note that if your Org collection is old and has survived several
system migrations, or some of it was generated via Pandoc
conversion or downloaded, it\\='s very possible that there\\='s a mix
of coding systems among them.  In that case, setting this
variable may cause org-node to fail to scan some of them, or
display strange-looking data."
  :type '(choice coding-system (const nil)))

(defcustom org-node-perf-keep-file-name-handlers nil
  "Which file handlers to respect while scanning for ID nodes.

Normally, `file-name-handler-alist' changes the behavior of many Emacs
functions when passed some file names: TRAMP paths, compressed files or
.org.gpg files.

It slows down the access of very many files, since it is a series of
regexps applied to every file name passed.  The fewer items in this
list, the faster `org-node-reset'.

There is probably no point adding items for now, as org-node will
need other changes to support TRAMP and encryption."
  :type '(set
          (function-item jka-compr-handler)
          (function-item epa-file-handler)
          ;; REVIEW: Chesterton's Fence.  I don't understand why
          ;; `tramp-archive-autoload-file-name-handler' exists
          ;; (check emacs -Q), when these two already have autoloads?
          (function-item tramp-file-name-handler)
          (function-item tramp-archive-file-name-handler)
          (function-item file-name-non-special)))

;; To compare perf with and without the setting, eval this in a large file.
;; (progn (add-hook 'org-node--temp-extra-fns
;;                  (lambda ()
;;                    (print (float-time (time-since org-node--time-at-begin-launch)))))
;;        (org-node--scan-targeted buffer-file-truename))
(defcustom org-node-perf-eagerly-update-link-tables t
  "Update backlink tables on every save.

A setting of t MAY slow down saving a big file containing
thousands of links on constrained devices.

Fortunately it is rarely needed, since the insert-link advices of
`org-node-cache-mode' will already record links added during
normal usage!

Other issues are corrected after `org-node--idle-timer' fires.
These temporary issues are:

1. deleted links remain in the table, leading to undead backlinks
2. link positions can desync, which can affect the org-roam buffer

A user of `org-node-backlink-mode' is recommended to enable this as
well as `org-node-backlink-aggressive'."
  :group 'org-node
  :type 'boolean)

(defun org-node--set-and-remind-reset (sym val)
  "Set SYM to VAL."
  (let ((caller (cadr (backtrace-frame 5))))
    (when (and (boundp 'org-node--first-init)
               (not org-node--first-init)
               ;; TIL: loading a theme calls ALL custom-setters?!
               (not (memq caller '(custom-theme-recalc-variable load-theme))))
      (lwarn 'org-node :debug
             "org-node--set-and-remind-reset called by %s" caller)
      (run-with-timer
       .1 nil #'message
       "Remember to run M-x org-node-reset after configuring %S" sym)))
  (custom-set-default sym val))

(defcustom org-node-filter-fn
  (lambda (node)
    (not (assoc "ROAM_EXCLUDE" (org-node-get-properties node))))
  "Predicate returning t to include a node, or nil to exclude it.

The filtering only has an impact on the table
`org-node--candidate<>node', which forms the basis for
completions in the minibuffer, and `org-node--title<>id', used
by `org-node-complete-at-point-mode'.

In other words, passing nil means the user cannot autocomplete to the
node, but Lisp code can still find it in the \"main\" table
`org-node--id<>node', and backlinks are discovered normally.

This function is applied once for every org-id node found, and
receives the node data as a single argument: an object which form
you can observe in examples from \\[org-node-peek] and specified
in the type `org-node' (C-h o org-node RET).

See the following example for a way to filter out nodes with a
ROAM_EXCLUDE property, or that have any kind of TODO state, or
are tagged :drill:, or where the full file path contains a
directory named \"archive\".

\(setq org-node-filter-fn
      (lambda (node)
        (not (or (assoc \"ROAM_EXCLUDE\" (org-node-get-properties node))
                 (org-node-get-todo node)
                 (string-search \"/archive/\" (org-node-get-file-path node))
                 (member \"drill\" (org-node-get-tags-local node))))))"
  :type 'function
  :set #'org-node--set-and-remind-reset)

(defcustom org-node-insert-link-hook '()
  "Hook run after inserting a link to an Org-ID node.

Called with point in the new link."
  :type 'hook)

(defcustom org-node-creation-hook '(org-node-put-created)
  "Hook run with point in the newly created buffer or entry.

Applied by `org-node-new-file', `org-node-capture-target',
`org-node-insert-heading', `org-node-nodeify-entry' and
`org-node-extract-subtree'.

NOT applied by `org-node-fakeroam-new-via-roam-capture' -- see
org-roam\\='s `org-roam-capture-new-node-hook' instead.

A good function for this hook is `org-node-put-created', since
the default `org-node-datestamp-format' is empty.  In the
author\\='s experience, recording the creation-date somewhere may
prove useful later on, e.g. when publishing to a blog."
  :type 'hook)

(defcustom org-node-extra-id-dirs nil
  "Directories in which to search Org files for IDs.

Essentially like variable `org-id-extra-files', but take directories.

You could already do this by adding directories to `org-agenda-files',
but that only checks the directories once.  This variable causes the
directories to be checked again over time in order to find new files
that have appeared, e.g. files moved by terminal commands or created by
other instances of Emacs.

These directories are only checked as long as `org-node-cache-mode' is
active.  They are checked recursively (looking in subdirectories,
sub-subdirectories etc).

EXCEPTION: Subdirectories that start with a dot, such as \".emacs.d/\",
are not checked.  To check these, add them explicitly.

To avoid accidentally picking up duplicate files such as versioned
backups, causing org-id to complain about duplicate IDs, configure
`org-node-extra-id-dirs-exclude'."
  :type '(repeat directory)
  :set #'org-node--set-and-remind-reset)

;; TODO: Figure out how to permit .org.gpg and fail gracefully if
;;       the EPG settings are insufficient. easier to test with .org.gz first
(defcustom org-node-extra-id-dirs-exclude
  '("/logseq/bak/"
    "/logseq/version-files/"
    "/node_modules/"
    ".sync-conflict-")
  "Path substrings of files that should not be searched for IDs.

This option only influences which files under `org-node-extra-id-dirs'
should be scanned.  It is meant as a way to avoid collecting IDs inside
versioned backup files or other noise.

For all other \"excludey\" purposes, you probably mean to configure
`org-node-filter-fn' instead.

If you have accidentally let org-id add a directory of backup files, try
\\[org-node-forget-dir].

It is not necessary to exclude backups or autosaves that end in ~ or #
or .bak, since the workhorse `org-node-list-files' only considers files
that end in precisely \".org\" anyway.

You can eke out a performance boost by excluding directories with a
humongous amount of files, such as the infamous \"node_modules\", even
if they contain no Org files.  However, directories that start with a
period are always ignored, so no need to specify e.g. \"~/.local/\" or
\".git/\" for that reason."
  :type '(repeat string))


;;;; Pretty completion

(defcustom org-node-alter-candidates nil
  "Whether to alter completion candidates instead of affixating.

This means that org-node will concatenate the results of
`org-node-affixation-fn' into a single string, so what the user types in
the minibuffer can match against the prefix and suffix as well as
against the node title.

In other words: you can match against the node's outline path, at least
so long as `org-node-affixation-fn' is set to `org-node-prefix-with-olp'
\(default).

\(Tip: users of the orderless library from July 2024 do not need this
setting, they can match the prefix and suffix via
`orderless-annotation', bound to the character \& by default.)

Another consequence is it lifts the uniqueness constraint on note
titles: you\\='ll be able to have two headings with the same name so
long as their prefix or suffix differ.

After changing this setting, please run \\[org-node-reset]."
  :type 'boolean
  :set #'org-node--set-and-remind-reset)

(defcustom org-node-affixation-fn #'org-node-prefix-with-olp
  "Function to give prefix and suffix to completion candidates.

The results will style the appearance of completions during
\\[org-node-find], \\[org-node-insert-link] et al.

To read more about affixations, see docstring of
`completion-extra-properties', however this function operates on
one candidate at a time, not the whole collection.

It receives two arguments: NODE and TITLE, and it must return a
list of three strings: title, prefix and suffix.  The prefix and
suffix can be nil.  Title should be TITLE unmodified.

NODE is an object which form you can observe in examples from
\\[org-node-peek] and specified in type `org-node'
\(type \\[describe-symbol] org-node RET).

If a node has aliases, the same node is passed to this function
again for every alias, in which case TITLE is actually one of the
aliases."
  :type '(radio
          (function-item org-node-affix-bare)
          (function-item org-node-prefix-with-olp)
          (function-item org-node-prefix-with-tags)
          (function-item org-node-affix-with-olp-and-tags)
          (function :tag "Custom function"))
  :set #'org-node--set-and-remind-reset)

(defun org-node-affix-bare (_node title)
  "Use TITLE as-is.
For use as `org-node-affixation-fn'."
  (list title nil nil))

(defun org-node-prefix-with-tags (node title)
  "Prepend NODE's tags to TITLE.
For use as `org-node-affixation-fn'."
  (list title
        (when-let ((tags (if org-use-tag-inheritance
                             (org-node-get-tags-with-inheritance node)
                           (org-node-get-tags-local node))))
          (propertize (concat "(" (string-join tags ", ") ") ")
                      'face 'org-tag))
        nil))

(defun org-node-prefix-with-olp (node title)
  "Prepend NODE's outline path to TITLE.
For use as `org-node-affixation-fn'."
  (list title
        (when (org-node-get-is-subtree node)
          (let ((ancestors (cons (org-node-get-file-title-or-basename node)
                                 (org-node-get-olp node)))
                (result nil))
            (dolist (anc ancestors)
              (push (propertize anc 'face 'completions-annotations) result)
              (push " > " result))
            (apply #'concat (nreverse result))))
        nil))

(defun org-node-affix-with-olp-and-tags (node title)
  "Prepend NODE's outline path to TITLE, and append NODE's tags.
For use as `org-node-affixation-fn'."
  (let ((prefix-len 0))
    (list title
          (when (org-node-get-is-subtree node)
            (let ((ancestors (cons (org-node-get-file-title-or-basename node)
                                   (org-node-get-olp node)))
                  (result nil))
              (dolist (anc ancestors)
                (push (propertize anc 'face 'completions-annotations) result)
                (push " > " result))
              (prog1 (setq result (apply #'concat (nreverse result)))
                (setq prefix-len (length result)))))
          (when-let ((tags (org-node-get-tags-local node)))
            (setq tags (propertize (concat (string-join tags ":"))
                                   'face 'org-tag))
            (concat (make-string
                     (max 2 (- (default-value 'fill-column)
                               (+ prefix-len (length title) (length tags))))
                     ?\s)
                    tags)))))

(defvar org-node--title<>affixation-triplet (make-hash-table :test #'equal)
  "1:1 table mapping titles or aliases to affixation triplets.")

(defun org-node--affixate-collection (coll)
  "From list COLL, make an alist of affixated members."
  (cl-loop for title in coll
           collect (gethash title org-node--title<>affixation-triplet)))

;; TODO: Assign a category `org-node', then add an embark action to embark?
;; TODO: Bind a custom exporter to `embark-export'
(defun org-node-collection (str pred action)
  "Custom COLLECTION for `completing-read'.

Ahead of time, org-node takes titles and aliases from
`org-node--title<>id', runs `org-node-affixation-fn' on each, and
depending on the user option `org-node-alter-candidates' it
either saves the affixed thing directly into
`org-node--candidate<>node' or into a secondary table
`org-node--title<>affixation-triplet'.  Finally, this function
then either simply reads candidates off the candidates table or
attaches the affixations in realtime.

Regardless of which, all completions are guaranteed to be keys of
`org-node--candidate<>node', but remember that it is possible for
`completing-read' to exit with user-entered input that didn\\='t
match anything.

Arguments STR, PRED and ACTION are handled behind the scenes,
read more at Info node `(elisp)Programmed Completion'."
  (if (eq action 'metadata)
      (cons 'metadata (unless org-node-alter-candidates
                        (list (cons 'affixation-function
                                    #'org-node--affixate-collection))))
    (complete-with-action action org-node--candidate<>node str pred)))

(defvar org-node-hist nil
  "Minibuffer history.")

;; Boost this completion hist to at least 1000 elements, unless user has nerfed
;; the global `history-length'.
(and (>= history-length (car (get 'history-length 'standard-value)))
     (< history-length 1000)
     (put 'org-node-hist 'history-length 1000))


;;;; The metadata struct

(cl-defstruct (org-node (:constructor org-node--make-obj)
                        (:copier nil)
                        (:conc-name org-node-get-))
  "An org-node object holds information about an Org ID node.
By the term \"Org ID node\", we mean either a subtree with
an ID property, or a file with a file-level ID property.  The
information is stored in slots listed below.

For each slot, there exists a getter function
\"org-node-get-FIELD\".

For example, the field \"deadline\" has a getter
`org-node-get-deadline'.  So you would type
\"(org-node-get-deadline NODE)\", where NODE is one of the
elements of \"(hash-table-values org-node--id<>node)\".

For real-world usage of these getters, see examples in the
documentation of `org-node-filter-fn' or Info node `(org-node)'."
  (aliases    nil :read-only t :type list :documentation
              "Return list of ROAM_ALIASES registered on the node.")
  (deadline   nil :read-only t :type string :documentation
              "Return node's DEADLINE state.")
  (file-path  nil :read-only t :type string :documentation
              "Return node's full file path.")
  (file-title nil :read-only t :type string :documentation
              "Return the #+title of the file where this node is. May be nil.")
  (id         nil :read-only t :type string :documentation
              "Return node's ID property.")
  (level      nil :read-only t :type integer :documentation
              "Return number of stars in the node heading. File-level node always 0.")
  (olp        nil :read-only t :type list :documentation
              "Return list of ancestor headings to this node.")
  (pos        nil :read-only t :type integer :documentation
              "Return char position of the node. File-level node always 1.")
  (priority   nil :read-only t :type string :documentation
              "Return priority such as [#A], as a string.")
  (properties nil :read-only t :type alist :documentation
              "Return alist of properties from the :PROPERTIES: drawer.")
  (refs       nil :read-only t :type list :documentation
              "Return list of ROAM_REFS registered on the node.")
  (scheduled  nil :read-only t :type string :documentation
              "Return node's SCHEDULED state.")
  (tags-local nil :read-only t :type list :documentation
              "Return list of tags local to the node.")
  ;; REVIEW: Maybe this can be a function that combines tags with a new field
  ;;         called inherited-tags.  That might cause slowdowns
  ;;         though due to consing on every call.
  (tags-with-inheritance nil :read-only t :type list :documentation
                         "Return list of tags, including inherited tags.")
  (title      nil :read-only t :type string :documentation
              "Return the node's heading, or #+title if it is not a subtree.")
  (todo       nil :read-only t :type string :documentation
              "Return node's TODO state."))

;; Used to be part of the struct
(defun org-node-get-file-title-or-basename (node)
  "Return either the #+title of file where NODE is, or bare file name."
  (or (org-node-get-file-title node)
      (file-name-nondirectory (org-node-get-file-path node))))

(defun org-node-get-is-subtree (node)
  "Return t if NODE is a subtree instead of a file."
  (> (org-node-get-level node) 0))

;; It's safe to alias an accessor, because they are all read only
(defalias 'org-node-get-props #'org-node-get-properties)
;; (defalias 'org-node-get-prio #'org-node-get-priority)
;; (defalias 'org-node-get-sched #'org-node-get-scheduled)
;; (defalias 'org-node-get-file #'org-node-get-file-path)
;; (defalias 'org-node-get-lvl #'org-node-get-level)

;; API transition underway: get-tags will include inherited tags in future
(define-obsolete-function-alias 'org-node-get-tags #'org-node-get-tags-local
  "2024-10-22")

(cl-defstruct (org-node-link (:constructor org-node-link--make-obj)
                             (:copier nil))
  "Please see docstring of `org-node-get-id-links-to'."
  origin
  pos
  type
  dest)


;;;; Tables

(defvaralias 'org-nodes 'org-node--id<>node)

(defvar org-node--id<>node (make-hash-table :test #'equal)
  "1:1 table mapping IDs to nodes.
To peek on the contents, try \\[org-node-peek] a few times, which
can demonstrate the data format.  See also the type `org-node'.")

(defvar org-node--candidate<>node (make-hash-table :test #'equal)
  "1:1 table mapping completion candidates to nodes.")

(defvar org-node--title<>id (make-hash-table :test #'equal)
  "1:1 table mapping raw titles (and ROAM_ALIASES) to IDs.")

(defvar org-node--ref<>id (make-hash-table :test #'equal)
  "1:1 table mapping ROAM_REFS members to the ID property near.")

(defvar org-node--ref-path<>ref-type (make-hash-table :test #'equal)
  "1:1 table mapping //paths to types:.

While the same path can be found with multiple types \(e.g. http and
https), this table will in that case store a random one of these, since
that is good enough to make completions look less outlandish.

This is a smaller table than you might think, since it only contains
entries for links found in a :ROAM_REFS: field, instead of all links
found anywhere.

To see all links found, try \\[org-node-list-reflinks].")

(defvar org-node--dest<>links (make-hash-table :test #'equal)
  "1:N table of links.

The table keys are destinations (org-ids, URI paths or citekeys),
and the corresponding table value is a list of `org-node-link'
records describing each link to that destination, with info such
as from which ID-node the link originates.  See
`org-node-get-id-links-to' for more info.")

;; As of 2024-10-06, the MTIME is not used for anything except supporting
;; `org-node-fakeroam-db-feed-mode'.  However, it has many conceivable
;; downstream or future applications.
(defvar org-node--file<>mtime.elapsed (make-hash-table :test #'equal)
  "1:1 table mapping file paths to values (MTIME . ELAPSED).

MTIME is the file\\='s last-modification time \(as an integer Unix
epoch) and ELAPSED how long it took to scan the file last time \(as a
float, usually a tiny fraction of a second).")

(defun org-node-get-id-links-to (node)
  "Get list of ID-link objects pointing to NODE.
Each object is of type `org-node-link' with these fields:

origin - ID of origin node (where the link was found)
pos - buffer position where the link was found
dest - ID of destination node, or a ref that belongs to it
type - link type, such as \"https\", \"ftp\", \"info\" or
       \"man\".  For ID-links this is always \"id\".  For a
       citation this is always nil.

This function only returns ID-links, so you can expect the :dest
to always equal the ID of NODE.  To see other link types, use
`org-node-get-reflinks-to'."
  (gethash (org-node-get-id node) org-node--dest<>links))

(defun org-node-get-reflinks-to (node)
  "Get list of reflink objects pointing to NODE.
Typical reflinks are URLs or @citekeys occurring in any document,
and they are considered to point to NODE when NODE has a
:ROAM_REFS: property that includes that same string.

The reflink object has the same shape as an ID-link object (see
`org-node-get-id-links-to'), but instead of an ID in the DEST field,
you have a ref string such an URL.  Common gotcha: for a web
address such as \"http://gnu.org\", the DEST field holds only
\"//gnu.org\", and the \"http\" part goes into the TYPE
field.  Colon is not stored anywhere.

Citations such as \"@gelman2001\" have TYPE nil, so you can
distinguish citations from other links this way."
  (cl-loop for ref in (org-node-get-refs node)
           append (gethash ref org-node--dest<>links)))

(defun org-node-peek (&optional ht)
  "Print some random rows of table `org-nodes'.
For reference, see type `org-node'.
When called from Lisp, peek on any hash table HT."
  (interactive)
  (let ((rows (hash-table-values (or ht org-nodes)))
        (print-length nil))
    (dotimes (_ 3)
      (print '----------------------------)
      (cl-prin1 (nth (random (length rows)) rows)))))


;;;; The mode

;;;###autoload
(define-minor-mode org-node-cache-mode
  "Instruct various hooks to keep the cache updated.

-----"
  :global t
  (remove-hook 'org-mode-hook #'org-node-cache-mode) ;; Old install instruction
  (if org-node-cache-mode
      (progn
        ;; FIXME: A dirty-added node eventually disappears if its buffer is
        ;;        never saved, and then the series stops working
        (add-hook 'org-node-creation-hook         #'org-node--add-series-item 90)
        (add-hook 'org-node-creation-hook         #'org-node--dirty-ensure-node-known -50)
        (add-hook 'org-node-insert-link-hook      #'org-node--dirty-ensure-link-known -50)
        (add-hook 'org-roam-post-node-insert-hook #'org-node--dirty-ensure-link-known -50)
        (advice-add 'org-insert-link :after       #'org-node--dirty-ensure-link-known)
        (add-hook 'calendar-today-invisible-hook  #'org-node--mark-days 5)
        (add-hook 'calendar-today-visible-hook    #'org-node--mark-days 5)
        (add-hook 'window-buffer-change-functions #'org-node--kill-blank-unsaved-buffers)
        (add-hook 'after-save-hook                #'org-node--handle-save)
        (advice-add 'rename-file :after           #'org-node--handle-rename)
        (advice-add 'delete-file :after           #'org-node--handle-delete)
        (org-node-cache-ensure 'must-async t)
        (org-node--maybe-adjust-idle-timer))
    (cancel-timer org-node--idle-timer)
    (remove-hook 'org-node-creation-hook          #'org-node--add-series-item)
    (remove-hook 'org-node-creation-hook          #'org-node--dirty-ensure-node-known)
    (remove-hook 'org-node-insert-link-hook       #'org-node--dirty-ensure-link-known)
    (remove-hook 'org-roam-post-node-insert-hook  #'org-node--dirty-ensure-link-known)
    (advice-remove 'org-insert-link               #'org-node--dirty-ensure-link-known)
    (remove-hook 'calendar-today-invisible-hook   #'org-node--mark-days)
    (remove-hook 'calendar-today-visible-hook     #'org-node--mark-days)
    (remove-hook 'window-buffer-change-functions  #'org-node--kill-blank-unsaved-buffers)
    (remove-hook 'after-save-hook                 #'org-node--handle-save)
    (advice-remove 'rename-file                   #'org-node--handle-rename)
    (advice-remove 'delete-file                   #'org-node--handle-delete)))

(defun org-node--tramp-file-p (file)
  "Pass FILE to `tramp-tramp-file-p' if Tramp is loaded."
  (when (featurep 'tramp)
    (tramp-tramp-file-p file)))

(defun org-node--handle-rename (file newname &rest _)
  "Arrange to scan NEWNAME for nodes and links, and forget FILE."
  (org-node--scan-targeted
   (thread-last (list file newname)
                (seq-filter (##string-suffix-p ".org" %))
                (seq-remove #'backup-file-name-p)
                (seq-remove #'org-node--tramp-file-p)
                (mapcar #'file-truename)
                (org-node-abbrev-file-names))))

(defun org-node--handle-delete (file &rest _)
  "Arrange to forget nodes and links in FILE."
  (when (string-suffix-p ".org" file)
    (unless (org-node--tramp-file-p file)
      (org-node--scan-targeted file))))

(defun org-node--handle-save ()
  "Arrange to re-scan nodes and links in current buffer."
  (when (and (string-suffix-p ".org" buffer-file-truename)
             (not (backup-file-name-p buffer-file-truename))
             (not (org-node--tramp-file-p buffer-file-truename)))
    (org-node--scan-targeted buffer-file-truename)))

(defvar org-node--idle-timer (timer-create)
  "Timer for intermittently checking `org-node-extra-id-dirs'.
for new, changed or deleted files, then resetting the cache.

This redundant behavior helps detect changes made by something
other than the current instance of Emacs, such as an user typing
rm on the command line instead of using \\[delete-file].

This timer is set by `org-node--maybe-adjust-idle-timer'.
Override that function to configure timer behavior.")

(defun org-node--maybe-adjust-idle-timer ()
  "Adjust `org-node--idle-timer' based on duration of last scan.
If not running, start it."
  (let ((new-delay (* 25 (1+ org-node--time-elapsed))))
    (when (or (not (member org-node--idle-timer timer-idle-list))
              ;; Don't enter an infinite loop (idle timers are footguns)
              (not (> (float-time (or (current-idle-time) 0))
                      new-delay)))
      (cancel-timer org-node--idle-timer)
      (setq org-node--idle-timer
            (run-with-idle-timer new-delay t #'org-node--scan-all)))))

;; FIXME: The idle timer will detect new files appearing, created by other
;;        emacsen, but won't run the hook `org-node-rescan-functions' on them,
;;        which would be good to do.  So check for new files and then try to
;;        use `org-node--scan-targeted', since that runs the hook, but it is
;;        easy to imagine a pitfall where the list of new files is just all
;;        files, and then we do NOT want to run the hook.  So use a heuristic
;;        cutoff like 10 files.
;; (defun org-node--catch-unknown-modifications ()
;;   (let ((new (-difference (org-node-list-files) (org-node-list-files t)))))
;;   (if (> 10 )
;;       (org-node--scan-all)
;;     (org-node--scan-targeted))
;;   )

(defvar org-node--not-yet-saved nil
  "List of buffers created to hold a new node.")

(defun org-node--kill-blank-unsaved-buffers (&rest _)
  "Kill buffers created by org-node that have become blank.

This exists to allow you to create a node, especially a journal
note for today, change your mind, do an undo to empty the buffer,
then browse to the previous day\\='s note.  When later you want
to create today\\='s note after all, the series :creator function
should be made to run again, but will only do so if the buffer
has been properly deleted since, thus this hook."
  (unless (minibufferp)
    (dolist (buf org-node--not-yet-saved)
      (if (or (not (buffer-live-p buf))
              (file-exists-p (buffer-file-name buf)))
          (setq org-node--not-yet-saved (delq buf org-node--not-yet-saved))
        (and (not (get-buffer-window buf t)) ;; buffer not visible
             (string-blank-p (with-current-buffer buf (buffer-string)))
             (kill-buffer buf))))))

(defun org-node-cache-ensure (&optional synchronous force)
  "Ensure that org-node is ready for use.
Specifically, do the following:

- Run `org-node--init-ids'.
- \(Re-)build the cache if it is empty, or if FORCE is t.

The primary use case is at the start of autoloaded commands.

Optional argument SYNCHRONOUS t means that if a cache build is
needed or already ongoing, block Emacs until it is done.

When SYNCHRONOUS is nil, return immediately and let the caching
proceed in the background.  As that may take a few seconds, that
would mean that the `org-node--id<>node' table could be still outdated
by the time you query it, but that is acceptable in many
situations such as in an user command since the table is mostly
correct - and fully correct by the time of the next invocation.

If the `org-node--id<>node' table is currently empty, behave as if
SYNCHRONOUS t, unless SYNCHRONOUS is the symbol `must-async'."
  (unless (eq synchronous 'must-async)
    ;; The warn-function becomes a no-op after the first run, so gotta
    ;; run it as late as possible in case of late variable settings.  By
    ;; running it here, we've waited until the user runs a command.
    (org-node-changes--warn-and-copy))
  (org-node--init-ids)
  (when (hash-table-empty-p org-nodes)
    (setq synchronous (if (eq synchronous 'must-async) nil t))
    (setq force t))
  (when force
    ;; Launch the async processes
    (org-node--scan-all))
  (when (eq t synchronous)
    ;; Block until all processes finish
    (when (seq-some #'process-live-p org-node--processes)
      (if org-node-cache-mode
          (message "org-node first-time caching...")
        (message "org-node caching... (Hint: Avoid this hang by enabling org-node-cache-mode at some point before use)")))
    (mapc #'accept-process-output org-node--processes)
    ;; Just in case... see docstring of `org-node-create'.
    ;; Not super happy about this edge-case, it's a wart of the current design
    ;; of `org-node--try-launch-scan'.
    (while (member org-node--retry-timer timer-list)
      (cancel-timer org-node--retry-timer)
      (funcall (timer--function org-node--retry-timer))
      (mapc #'accept-process-output org-node--processes))))

;; BUG: A heisenbug lurks inside (or is revealed by) org-id.
;; https://emacs.stackexchange.com/questions/81794/
;; When it appears, backtrace will show this, which makes no sense -- it's
;; clearly called on a list:
;;     Debugger entered--Lisp error: (wrong-type-argument listp #<hash-table equal 3142/5277) 0x190d581ba129>
;;       org-id-alist-to-hash((("/home/kept/roam/semantic-tabs-in-2024.org" "f21c984c-13f3-428c-8223-0dc1a2a694df") ("/home/kept/roam/semicolons-make-javascript-h..." "b40a0757-bff4-4188-b212-e17e3fc54e13") ...))
;;       org-node--init-ids()
;;       ...
(defun org-node--init-ids ()
  "Ensure that org-id is ready for use.

In broad strokes:
- Run `org-id-locations-load' if needed.
- Ensure `org-id-locations' is a hash table and not an alist.
- Throw error if `org-id-locations' is still empty after this,
  unless `org-node-extra-id-dirs' has members.
- Wipe `org-id-locations' if it appears afflicted by a known bug that
  makes the symbol value an indeterminate superposition of one of two
  possible values \(a hash table or an alist) depending on which code
  accesses it -- like Schrödinger\\='s cat -- and tell the user to
  rebuild the value, since even org-id\\='s internal functions are
  unable to fix it."
  (require 'org-id)
  (when (not org-id-track-globally)
    (user-error "Org-node requires `org-id-track-globally'"))
  (when (null org-id-locations)
    (when (file-exists-p org-id-locations-file)
      (ignore-errors (org-id-locations-load))))
  (when (listp org-id-locations)
    (ignore-errors
      (setq org-id-locations (org-id-alist-to-hash org-id-locations))))
  (when (listp org-id-locations)
    (setq org-id-locations nil)
    (org-node--die
     "Found org-id heisenbug!  Wiped org-id-locations, repair with `org-node-reset' or `org-roam-update-org-id-locations'"))
  (when (hash-table-p org-id-locations)
    (when (hash-table-empty-p org-id-locations)
      (org-id-locations-load)
      (when (and (hash-table-empty-p org-id-locations)
                 (null org-node-extra-id-dirs))
        (org-node--die
         (concat
          "No org-ids found.  If this was unexpected, try M-x `org-id-update-id-locations' or M-x `org-roam-update-org-id-locations'.
\tIf this is your first time using org-id, first assign an ID to some
\trandom heading with M-x `org-id-get-create', so that at least one exists
\ton disk, then do M-x `org-node-reset' and it should work from then on."))))))

(define-advice org-id-locations-load
    (:after () org-node--abbrev-org-id-locations)
  "Maybe abbreviate all filenames in `org-id-locations'.

Due to an oversight, org-id does not abbreviate after reconstructing
filenames if `org-id-locations-file-relative' is t.

https://lists.gnu.org/archive/html/emacs-orgmode/2024-09/msg00305.html"
  (when org-id-locations-file-relative
    (maphash (lambda (id file)
               (puthash id (org-node-abbrev-file-names file) org-id-locations))
             org-id-locations)))


;;;; Scanning

(defun org-node--scan-all ()
  "Arrange a full scan."
  (org-node--try-launch-scan t))

(defun org-node--scan-targeted (files)
  "Arrange to scan FILES."
  (when files
    (org-node--try-launch-scan (ensure-list files))))

(defvar org-node--retry-timer (timer-create))
(defvar org-node--file-queue nil)
(defvar org-node--wait-start nil)
(defvar org-node--full-scan-requested nil)

;; I'd like to remove this code, but complexity arises elsewhere if I do.
;; This makes things easy to reason about.
(defun org-node--try-launch-scan (&optional files)
  "Launch processes to scan FILES, or reschedule if processes active.
The rescheduling tries again every second, until the active processes
have finished, and then launches the new processes.

This ensures that multiple calls occurring in a short time \(like when
multiple files are being renamed in Dired) will be handled eventually
and not dropped, letting you trust that `org-node-rescan-functions' will
in fact run for all affected files.

If FILES is t, do a full reset, scanning all files discovered by
`org-node-list-files'."
  (if (eq t files)
      (setq org-node--full-scan-requested t)
    (setq org-node--file-queue
          (seq-union org-node--file-queue
                     (org-node-abbrev-file-names files))))
  (let (must-retry)
    (if (seq-some #'process-live-p org-node--processes)
        (progn
          (unless org-node--wait-start
            (setq org-node--wait-start (current-time)))
          (if (> (float-time (time-since org-node--wait-start)) 30)
              ;; Timeout subprocess stuck in some infinite loop
              (progn
                (setq org-node--wait-start nil)
                (message "org-node: Worked longer than 30 sec, killing")
                (mapc #'delete-process org-node--processes)
                (setq org-node--processes nil))
            (setq must-retry t)))
      ;; All clear, scan now
      (setq org-node--wait-start nil)
      (setq org-node--time-at-begin-launch (current-time))
      (setq org-node--gc-at-begin-launch gc-elapsed)
      (if org-node--full-scan-requested
          (progn
            (setq org-node--full-scan-requested nil)
            (org-node--scan (org-node-list-files) #'org-node--finalize-full)
            (when org-node--file-queue
              (setq must-retry t)))
        ;; Targeted scan of specific files
        (if org-node--file-queue
            (org-node--scan org-node--file-queue #'org-node--finalize-modified)
          (message "`org-node-try-launch-scan' launched with no input"))
        (setq org-node--file-queue nil)))
    (when must-retry
      (cancel-timer org-node--retry-timer)
      (setq org-node--retry-timer
            (run-with-timer 1 nil #'org-node--try-launch-scan)))))

(defvar org-node--processes nil
  "List of subprocesses.")

(defvar org-node--stderr-name " *org-node*"
  "Name of buffer for the subprocesses shared stderr.")

(defcustom org-node-perf-max-jobs 0
  "Number of subprocesses to run.
If left at 0, will be set at runtime to the result of
`org-node--count-logical-cores'.

Affects the speed of \\[org-node-reset], which mainly matters at
first-time init, since it may block Emacs while populating tables for
the first time."
  :type 'natnum)

(defun org-node--count-logical-cores ()
  "Return sum of available processor cores, minus 1."
  (max (1- (string-to-number
            (pcase system-type
              ((or 'gnu 'gnu/linux 'gnu/kfreebsd 'berkeley-unix)
               (if (executable-find "nproc")
                   (shell-command-to-string "nproc --all")
                 (shell-command-to-string "lscpu -p | egrep -v '^#' | wc -l")))
              ((or 'darwin)
               (shell-command-to-string "sysctl -n hw.logicalcpu_max"))
              ;; No idea if this works
              ((or 'cygwin 'windows-nt 'ms-dos)
               (ignore-errors
                 (with-temp-buffer
                   (call-process "echo" nil t nil "%NUMBER_OF_PROCESSORS%")
                   (buffer-string)))))))
       1))

(defun org-node--ensure-compiled-lib (feature)
  "Look for .eln, .elc or .el file corresponding to FEATURE.
FEATURE is a symbol as it shows up in `features'.

Guess which one was in fact loaded by the current Emacs,
and return it if it is .elc or .eln.

If it is .el, then opportunistically compile it and return the newly
compiled file instead.  This returns an .elc on the first call, then an
.eln on future calls.

Note: if you are currently editing the source code for FEATURE, use
`eval-buffer' and save to ensure this finds the correct file."
  (let* ((hit (cl-loop
               for (file . elems) in load-history
               when (eq feature (cdr (assq 'provide elems)))
               return
               ;; Want two pieces of info: the file path according to
               ;; `load-history', and some function supposedly defined
               ;; there.  The function is a better source of info, for
               ;; discovering an .eln.
               (cons file (cl-loop
                           for elem in elems
                           when (and (consp elem)
                                     (eq 'defun (car elem))
                                     (not (consp (symbol-function (cdr elem))))
                                     (not (function-alias-p (cdr elem))))
                           return (cdr elem)))))
         (file-name-handler-alist '(("\\.gz\\'" . jka-compr-handler))) ;; perf
         (loaded (or (and (native-comp-available-p)
                          (ignore-errors
                            ;; REVIEW: `symbol-file' uses expand-file-name,
                            ;;         but I'm not convinced it is needed
                            (expand-file-name
                             (native-comp-unit-file
                              (subr-native-comp-unit
                               (symbol-function (cdr hit)))))))
                     (car hit))))
    (unless loaded
      (error "Current Lisp definitions need to come from a file %S[.el/.elc/.eln]"
             feature))
    ;; HACK: Sometimes comp.el makes freefn- temp files; pretend we found .el.
    ;;       Not a good hack, because load-path is NOT as trustworthy as
    ;;       load-history.
    (when (string-search "freefn-" loaded)
      (setq loaded
            (locate-file (symbol-name feature) load-path '(".el" ".el.gz"))))
    (if (or (string-suffix-p ".el" loaded)
            (string-suffix-p ".el.gz" loaded))
        (or (when (native-comp-available-p)
              ;; If we built an .eln last time, return it now even though
              ;; the current Emacs process is still running interpreted .el.
              (comp-lookup-eln loaded))
            (let* ((elc (file-name-concat temporary-file-directory
                                          (concat (symbol-name feature)
                                                  ".elc")))
                   (byte-compile-dest-file-function
                    `(lambda (&rest _) ,elc)))
              (when (native-comp-available-p)
                (native-compile-async (list loaded)))
              ;; Native comp may take a while, so return .elc this time.
              ;; We should not pick an .elc from load path if Emacs is now
              ;; running interpreted code, since the code's likely newer.
              (if (or (file-newer-than-file-p elc loaded)
                      (byte-compile-file loaded))
                  ;; NOTE: On Guix we should never end up here, but if we
                  ;;       did, that'd be a problem as Guix will probably
                  ;;       reuse the first .elc we ever made forever, even
                  ;;       after upgrades to .el, due to 1970 timestamps.
                  elc
                loaded)))
      ;; Either .eln or .elc was loaded, so use the same for the
      ;; subprocesses.  We should not opportunistically build an .eln if
      ;; Emacs had loaded an .elc for the current process, because we
      ;; cannot assume the source .el is equivalent code.
      ;; The .el could be in-development, newer than .elc, so subprocesses
      ;; should use the same .elc for compatibility right up until the point
      ;; the developer actually evals the .el buffer.
      loaded)))

(defun org-node-kill ()
  "Kill any stuck subprocesses."
  (interactive)
  (while-let ((proc (pop org-node--processes)))
    (delete-process proc)))

;; Copied from part of `org-link-make-regexps'
(defun org-node--make-plain-re (link-types)
  "Build a moral equivalent to `org-link-plain-re'.
Make it target only LINK-TYPES instead of all the cars of
`org-link-parameters'."
  (let* ((non-space-bracket "[^][ \t\n()<>]")
         (parenthesis
	  `(seq (any "<([")
		(0+ (or (regex ,non-space-bracket)
			(seq (any "<([")
			     (0+ (regex ,non-space-bracket))
			     (any "])>"))))
		(any "])>"))))
    (rx-to-string
     `(seq word-start
	   (regexp ,(regexp-opt link-types t))
	   ":"
           (group
	    (1+ (or (regex ,non-space-bracket)
		    ,parenthesis))
	    (or (regexp "[^[:punct:][:space:]\n]")
                ?- ?/ ,parenthesis))))))

(defun org-node--mk-work-variables ()
  "Return an alist of symbols and values to set in subprocesses."
  (let ((reduced-plain-re (org-node--make-plain-re org-node-link-types)))
    (list
     ;; NOTE: The $sigil-prefixed names visually distinguish these
     ;; variables in the body of `org-node-parser--collect-dangerously'.
     (cons '$plain-re reduced-plain-re)
     (cons '$merged-re (concat org-link-bracket-re "\\|" reduced-plain-re))
     (cons '$assume-coding-system org-node-perf-assume-coding-system)
     (cons '$inlinetask-min-level (bound-and-true-p org-inlinetask-min-level))
     (cons '$file-todo-option-re
           (rx bol (* space) (or "#+todo: " "#+seq_todo: " "#+typ_todo: ")))
     (cons '$global-todo-re
           (let ((default (default-value 'org-todo-keywords)))
             (org-node-parser--make-todo-regexp
              (string-join (if (stringp (car default))
                               default
                             (apply #'append (mapcar #'cdr default)))
                           " "))))
     (cons '$file-name-handler-alist
           (cl-remove-if-not
            (##memq % org-node-perf-keep-file-name-handlers)
            file-name-handler-alist :key #'cdr))
     (cons '$backlink-drawer-re
           (concat "^[\t\s]*:"
                   (or (and (require 'org-super-links nil t)
                            (boundp 'org-super-links-backlink-into-drawer)
                            (stringp org-super-links-backlink-into-drawer)
                            org-super-links-backlink-into-drawer)
                       "backlinks")
                   ":")))))

(defvar org-node--first-init t
  "Non-nil until org-node has been initialized, then nil.
Mainly for muffling some messages.")

(defvar org-node--results nil)
(defvar org-node--debug nil)
(defun org-node--scan (files finalizer)
  "Begin async scanning FILES for id-nodes and links.
Other functions have similar docstrings, but this function
actually launches the processes - the rubber hits the road.

When finished, pass a list of scan results to the FINALIZER
function to update current tables."
  (when (= 0 org-node-perf-max-jobs)
    (setq org-node-perf-max-jobs (org-node--count-logical-cores)))
  (mkdir (org-node--tmpfile) t)
  (let ((compiled-lib (org-node--ensure-compiled-lib 'org-node-parser))
        (file-name-handler-alist nil)
        (coding-system-for-read org-node-perf-assume-coding-system)
        (vars (append org-node-inject-variables
                      (org-node--mk-work-variables))))
    (when (seq-some #'process-live-p org-node--processes)
      ;; We should never end up here
      (mapc #'delete-process org-node--processes)
      (message "org-node subprocesses alive, a bug report would be welcome"))
    (setq org-node--processes nil)
    (with-current-buffer (get-buffer-create org-node--stderr-name)
      (erase-buffer))

    (if org-node--debug
        ;; Special case for debugging; run inside main process so we can step
        ;; through the org-node-parser.el functions with edebug.
        (let ((write-region-inhibit-fsync nil))
          (setq org-node-parser--found-links nil)
          (setq org-node-parser--paths-types nil)
          (setq org-node--first-init nil)
          (setq org-node--time-at-after-launch (current-time))
          (dolist (var vars)
            (set (car var) (cdr var)))
          (setq $files files)
          (with-current-buffer (get-buffer-create "*org-node debug*")
            (setq buffer-read-only nil)
            (when (eq 'show org-node--debug)
              (pop-to-buffer (current-buffer)))
            (erase-buffer)
            (if (eq 'profile org-node--debug)
                (progn
                  (require 'profiler)
                  (profiler-stop)
                  (profiler-start 'cpu)
                  (org-node-parser--collect-dangerously)
                  (profiler-stop)
                  (profiler-report))
              (org-node-parser--collect-dangerously))
            (org-node--handle-finished-job 1 finalizer)))

      ;; If not debugging, split the work over many child processes
      (let* ((file-lists
              (org-node--split-file-list files org-node-perf-max-jobs))
             (n-jobs (length file-lists))
             ;; Ensure working directory is not remote (messes things up)
             (default-directory invocation-directory))
        (setq org-node--results nil)
        (dotimes (i n-jobs)
          (push
           (make-process
            :name (format "org-node-%d" i)
            :noquery t
            :stderr (get-buffer-create " *org-node-stderr*" t)
            :buffer (with-current-buffer
                        (get-buffer-create (format " *org-node-%d*" i) t)
                      (erase-buffer)
                      (current-buffer))
            :connection-type 'pipe
            :command
            ;; TODO: Maybe prepend a "timeout 30"
            ;; Ensure the children run the same binary executable as
            ;; current Emacs, so the `compiled-lib' bytecode fits
            (list (file-name-concat invocation-directory invocation-name)
                  "--quick"
                  "--batch"
                  "--eval" (prin1-to-string
                            `(progn
                               (setq gc-cons-threshold (* 1000 1000 1000))
                               (dolist (var ',vars)
                                 (set (car var) (cdr var)))
                               (setq $files ',(pop file-lists)))
                            nil '((length) (level)))
                  "--load" compiled-lib
                  "--funcall" "org-node-parser--collect-dangerously")
            :sentinel (lambda (proc _event)
                        (org-node--handle-finished-job
                         proc n-jobs finalizer)))
           org-node--processes))
        (setq org-node--time-at-after-launch (current-time))))))

(defun org-node--handle-finished-job (proc n-jobs finalizer)
  "Read output of process PROC.
Add that to `org-node--results'.

Count each call up to N-JOBS, then on the last call, pass the merged
results to function FINALIZER."
  (when (eq 'exit (process-status proc))
    (with-current-buffer (process-buffer proc)
      (push (read (buffer-string)) org-node--results))
    (when (= (length org-node--results) n-jobs)
      (setq org-node--time-at-finalize (current-time))
      (let ((merged-result (pop org-node--results)))
        ;; First result is last done.  Did test this.
        (setq org-node--time-at-last-child-done (pop merged-result))
        ;; Absorb the rest of the results
        (dolist (result org-node--results)
          (pop result) ;; Remove its timestamp
          (let (new-merged-result)
            ;; Zip lists pairwise. Like (-zip-with #'nconc list1 list2).
            (while result
              (push (nconc (pop result) (pop merged-result))
                    new-merged-result))
            (setq merged-result (nreverse new-merged-result))))
        (funcall finalizer merged-result)))))


;;;; Scan-finalizers

(defvar org-node-before-update-tables-hook nil
  "Hook run just before processing results from scan.")

(defun org-node--finalize-full (results)
  "Wipe tables and repopulate from data in RESULTS."
  (run-hooks 'org-node-before-update-tables-hook)
  (clrhash org-node--id<>node)
  (clrhash org-node--dest<>links)
  (clrhash org-node--candidate<>node)
  (clrhash org-node--title<>id)
  (clrhash org-node--ref<>id)
  (clrhash org-node--file<>mtime.elapsed)
  (setq org-node--collisions nil) ;; To be populated by `org-node--record-nodes'
  (seq-let (missing-files file-info nodes path.type links problems) results
    (org-node--forget-id-locations missing-files)
    (dolist (link links)
      (push link (gethash (org-node-link-dest link) org-node--dest<>links)))
    (cl-loop for (path . type) in path.type
             do (puthash path type org-node--ref-path<>ref-type))
    (cl-loop for (file . mtime.elapsed) in file-info
             do (puthash file mtime.elapsed org-node--file<>mtime.elapsed))
    ;; HACK: Don't manage `org-id-files' at all.  Reduces GC, but could
    ;; affect downstream uses of org-id which assume the variable to be
    ;; correct.  Uncomment to improve.
    ;; (setq org-id-files (mapcar #'car file-info))
    (org-node--record-nodes nodes)
    ;; (org-id-locations-save) ;; A nicety, but sometimes slow
    (setq org-node-built-series nil)
    (dolist (def org-node-series-defs)
      (setf (alist-get (car def) org-node-built-series nil nil #'equal)
            (org-node--build-series def))
      (org-node--add-series-to-dispatch (car def)
                                        (plist-get (cdr def) :name)))
    (setq org-node--time-elapsed
          ;; For more reproducible profiling: don't count time spent on
          ;; other sentinels, timers or I/O in between these periods
          (+ (float-time
              (time-subtract (current-time)
                             org-node--time-at-finalize))
             (float-time
              (time-subtract org-node--time-at-last-child-done
                             org-node--time-at-begin-launch))))
    (org-node--maybe-adjust-idle-timer)
    (while-let ((fn (pop org-node--temp-extra-fns)))
      (funcall fn))
    (when (and org-node--collisions org-node-warn-title-collisions)
      (message "Some nodes share title, see M-x org-node-list-collisions"))
    (when (setq org-node--problems problems)
      (message "Scan had problems, see M-x org-node-list-scan-problems"))
    (setq org-node--first-init nil)))

(defvar org-node--old-link-sets nil
  "For use by `org-node-backlink-aggressive'.

Alist of ((DEST . LINKS) (DEST . LINKS) ...), where LINKS is are sets of
links with destination DEST.  These reflect a past state of
`org-node--dest<>links', allowing for a diff operation against the
up-to-date set.")

(defun org-node--finalize-modified (results)
  "Use RESULTS to update tables."
  (run-hooks 'org-node-before-update-tables-hook)
  (seq-let (missing-files file-info nodes path.type links problems) results
    (let ((found-files (mapcar #'car file-info)))
      (org-node--forget-id-locations missing-files)
      (dolist (file missing-files)
        (remhash file org-node--file<>mtime.elapsed))
      (org-node--dirty-forget-files missing-files)
      (org-node--dirty-forget-completions-in missing-files)
      ;; In case a title was edited: don't persist old revisions of the title
      (org-node--dirty-forget-completions-in found-files)
      (setq org-node--old-link-sets nil)
      (when org-node-perf-eagerly-update-link-tables
        (cl-loop with ids-of-nodes-scanned = (cl-loop
                                              for node in nodes
                                              collect (org-node-get-id node))
                 with reduced-link-sets = nil
                 for dest being each hash-key of org-node--dest<>links
                 using (hash-values link-set)
                 do (cl-loop
                     with update-this-dest = nil
                     for link in link-set
                     if (member (org-node-link-origin link)
                                ids-of-nodes-scanned)
                     do (setq update-this-dest t)
                     else collect link into reduced-link-set
                     finally do
                     (when update-this-dest
                       (push (cons dest reduced-link-set) reduced-link-sets)))
                 finally do
                 (cl-loop
                  for (dest . links) in reduced-link-sets do
                  (when (bound-and-true-p org-node-backlink-aggressive)
                    (push (cons dest (gethash dest org-node--dest<>links))
                          org-node--old-link-sets))
                  (puthash dest links org-node--dest<>links))))
      ;; Having discarded the links that were known to originate in the
      ;; re-scanned nodes, it's safe to record them (again).
      (dolist (link links)
        (push link (gethash (org-node-link-dest link) org-node--dest<>links)))
      (cl-loop for (path . type) in path.type
               do (puthash path type org-node--ref-path<>ref-type))
      (cl-loop for (file . mtime.elapsed) in file-info
               do (puthash file mtime.elapsed org-node--file<>mtime.elapsed))
      (org-node--record-nodes nodes)
      (while-let ((fn (pop org-node--temp-extra-fns)))
        (funcall fn))
      (dolist (prob problems)
        (push prob org-node--problems))
      (when problems
        (message "Scan had problems, see M-x org-node-list-scan-problems"))
      (run-hook-with-args 'org-node-rescan-functions
                          (append missing-files found-files)))))

(defun org-node--record-nodes (nodes)
  "Add NODES to `org-nodes' and related info to other tables."
  (let ((affixator (org-node--ensure-compiled org-node-affixation-fn))
        (filterer (org-node--ensure-compiled org-node-filter-fn)))
    (dolist (node nodes)
      (let* ((id (org-node-get-id node))
             (path (org-node-get-file-path node))
             (refs (org-node-get-refs node)))
        ;; Share location with org-id & do so with manual `puthash'
        ;; because `org-id-add-location' would run logic we've already run
        (puthash id path org-id-locations)
        ;; Register the node
        (puthash id node org-node--id<>node)
        (dolist (ref refs)
          (puthash ref id org-node--ref<>id))
        ;; Setup completion candidates
        (when (funcall filterer node)
          ;; Let refs work as aliases
          (dolist (ref refs)
            (puthash ref node org-node--candidate<>node)
            (puthash ref
                     (let ((type (gethash ref org-node--ref-path<>ref-type)))
                       (list (propertize ref 'face 'org-cite)
                             (when type
                               (propertize (concat type ":")
                                           'face 'completions-annotations))
                             nil))
                     org-node--title<>affixation-triplet))
          (dolist (title (cons (org-node-get-title node)
                               (org-node-get-aliases node)))
            (let ((collision (gethash title org-node--title<>id)))
              (when (and collision (not (equal id collision)))
                (push (list title id collision) org-node--collisions)))
            (puthash title id org-node--title<>id)
            (let ((affx (funcall affixator node title)))
              (if org-node-alter-candidates
                  ;; Absorb the affixations into one candidate string
                  (puthash (concat (nth 1 affx) (nth 0 affx) (nth 2 affx))
                           node
                           org-node--candidate<>node)
                ;; Bare title as candidate, to be affixated in realtime by
                ;; `org-node-collection'
                (puthash title affx org-node--title<>affixation-triplet)
                (puthash title node org-node--candidate<>node)))))))))

(defvar org-node--compile-timers nil)
(defvar org-node--compiled-lambdas (make-hash-table :test #'equal)
  "1:1 table mapping lambda expressions to compiled bytecode.")

(defun org-node--ensure-compiled (fn)
  "Try to return FN as a compiled function.

- If FN is a symbol with uncompiled function definition, return
  the same symbol and arrange to natively compile it after some
  idle time.

- If FN is an anonymous lambda, compile it, cache the resulting
  bytecode, and return that bytecode.  Then arrange to replace
  the cached value with native bytecode after some idle time."
  (cond ((compiled-function-p fn) fn)
        ((symbolp fn)
         (if (compiled-function-p (symbol-function fn))
             fn
           (if (native-comp-available-p)
               (unless (alist-get fn org-node--compile-timers)
                 (setf (alist-get fn org-node--compile-timers)
                       (run-with-idle-timer
                        (+ 5 (random 10)) nil #'native-compile fn)))
             (byte-compile fn))
           ;; May actually use entirely uncompiled until native is available
           fn))
        ((gethash fn org-node--compiled-lambdas))
        ((prog1 (puthash fn (byte-compile fn) org-node--compiled-lambdas)
           (when (and (native-comp-available-p)
                      (not (eq 'closure (car-safe fn))))
             (run-with-idle-timer (+ 5 (random 10))
                                  nil
                                  `(lambda ()
                                     (puthash ,fn (native-compile ,fn)
                                              org-node--compiled-lambdas))))))))


;;;; "Dirty" functions
;; Help keep the cache reasonably in sync without having to do a full reset

;; See `org-node--finalize-modified' for forgetting links
(defun org-node--dirty-forget-files (files)
  "Remove from cache info about nodes/refs in FILES.
You should also run `org-node--dirty-forget-completions-in' for a
thorough cleanup."
  (when files
    (cl-loop
     for node being each hash-value of org-node--id<>node
     when (member (org-node-get-file-path node) files)
     collect (org-node-get-id node) into ids
     and append (org-node-get-refs node) into refs
     and append (cons (org-node-get-title node)
                      (org-node-get-aliases node)) into titles
     finally do
     (dolist (id ids)
       (remhash id org-node--id<>node))
     (dolist (ref refs)
       (remhash ref org-node--ref<>id)
       (remhash ref org-node--title<>id))
     (dolist (title titles)
       (remhash title org-node--title<>id)))))

(defun org-node--dirty-forget-completions-in (files)
  "Remove the completion candidates for all nodes in FILES."
  (when files
    (cl-loop
     for candidate being each hash-key of org-node--candidate<>node
     using (hash-values node)
     when (member (org-node-get-file-path node) files)
     do (remhash candidate org-node--candidate<>node))))

(defun org-node--dirty-ensure-link-known (&optional id &rest _)
  "Record the ID-link at point.
If optional argument ID is non-nil, do not check the link at
point but assume it is a link to ID."
  (when (derived-mode-p 'org-mode)
    (org-node--init-ids)
    (when-let ((origin (org-node-id-at-point))
               (dest (if (gethash id org-id-locations)
                         id
                       (let ((elm (org-element-context)))
                         (when (equal "id" (org-element-property :type elm))
                           (org-element-property :path elm))))))
      (push (org-node-link--make-obj
             :origin origin
             :pos (point)
             :type "id"
             :dest dest)
            (gethash dest org-node--dest<>links)))))

(defun org-node--dirty-ensure-node-known ()
  "Record the node at point.

Not meant to be perfect, but good enough to:

1. ensure that the node at point will show up among completion
candidates right away, without having to save the buffer.

2. ensure that `org-node-backlink-mode' won\\='t autoclean backlinks
to this node on account of it \"not existing yet\".  Actually,
also necessary is `org-node--dirty-ensure-link-known' elsewhere."
  (let ((id (org-node-id-at-point))
        (case-fold-search t))
    (unless (gethash id org-node--id<>node)
      (unless (gethash buffer-file-truename org-node--file<>mtime.elapsed)
        (when (file-exists-p buffer-file-truename)
          (puthash buffer-file-truename (cons 0 0) org-node--file<>mtime.elapsed)))
      (save-excursion
        (without-restriction
          (goto-char (point-min))
          (re-search-forward (concat "^[\t\s]*:id: +" id))
          (let ((props (org-entry-properties))
                (heading (org-get-heading t t t t))
                (fpath buffer-file-truename) ;; Abbreviated
                (ftitle (cadar (org-collect-keywords '("TITLE")))))
            (when heading
              (setq heading (substring-no-properties heading)))
            (org-node--record-nodes
             (list
              (org-node--make-obj
               :title (or heading ftitle)
               :id id
               :file-path fpath
               :file-title ftitle
               :aliases (split-string-and-unquote
                         (or (cdr (assoc "ROAM_ALIASES" props)) ""))
               :refs (org-node-parser--split-refs-field
                      (cdr (assoc "ROAM_REFS" props)))
               :pos (if heading (org-entry-beginning-position) 1)
               ;; NOTE: Don't use `org-reduced-level' since org-node-parser.el
               ;;       also does not correct for that
               :level (or (org-current-level) 0)
               :olp (org-get-outline-path)
               ;; Less important
               :properties props
               :tags-local (org-get-tags nil t)
               :tags-with-inheritance (org-get-tags)
               :todo (if heading (org-get-todo-state))
               :deadline (cdr (assoc "DEADLINE" props))
               :scheduled (cdr (assoc "SCHEDULED" props)))))))))))


;;;; Scanning: Etc

(defvar org-node--time-elapsed 1.0
  "Duration of the last cache reset.")

(defvar org-node--gc-at-begin-launch 0)
(defvar org-node--time-at-begin-launch nil)
(defvar org-node--time-at-scan-begin nil)
(defvar org-node--time-at-after-launch nil)
(defvar org-node--time-at-last-child-done nil)
(defvar org-node--time-at-finalize nil)

(defun org-node--print-elapsed ()
  "Print time elapsed since `org-node--time-at-scan-begin'.
Also report statistics about the nodes and links found.

Currently, the printed message implies that all of org-node\\='s
data were collected within the time elapsed, so you should not
run this function after only a partial scan, as the message would
be misleading."
  (if (not org-node-cache-mode)
      (message "Scan complete (Hint: Turn on org-node-cache-mode)")
    (let ((n-subtrees (cl-loop
                       for node being the hash-values of org-node--id<>node
                       count (org-node-get-is-subtree node)))
          (n-backlinks (cl-loop
                        for id being the hash-keys of org-node--id<>node
                        sum (length (gethash id org-node--dest<>links))))
          (n-reflinks (cl-loop
                       for ref being the hash-keys of org-node--ref<>id
                       sum (length (gethash ref org-node--dest<>links)))))
      (message "Saw %d file-nodes, %d subtree-nodes, %d ID-links, %d reflinks in %.2fs (wall-time %.2fs)"
               (- (hash-table-count org-node--id<>node) n-subtrees)
               n-subtrees
               n-backlinks
               n-reflinks
               org-node--time-elapsed
               (float-time (time-since org-node--time-at-begin-launch))))))

(defun org-node--split-file-list (files n)
  "Split FILES into N lists of files.

Take into account how long it took to scan each file last time, to
return balanced lists that should each take around the same amount of
wall-time to process.

This reduces the risk that one subprocess takes noticably longer due to
being saddled with a mega-file in addition to the average workload."
  (if (<= (length files) n)
      (org-node--split-into-n-sublists files n)
    (let ((total-time 0))
      ;; NOTE: In the rare case of running `org-node--scan-targeted' with >n
      ;;       items, the end result will probably be just 1 sublist, but it's
      ;;       so rare it's not worth optimizing
      (maphash (lambda (_k v) (setq total-time (+ total-time (cdr v))))
               org-node--file<>mtime.elapsed)
      ;; Special case for first time
      (if (= total-time 0)
          (org-node--split-into-n-sublists files n)
        (let ((max-per-core (/ total-time n))
              (this-sublist-sum 0)
              sublists
              this-sublist
              untimed
              time)
          (catch 'filled
            (while-let ((file (pop files)))
              (setq time (cdr (gethash file org-node--file<>mtime.elapsed)))
              (if (or (null time) (= 0 time))
                  (push file untimed)
                (if (> time max-per-core)
                    ;; Dedicate huge files to their own cores
                    (push (list file) sublists)
                  (if (< time (- max-per-core this-sublist-sum))
                      (progn
                        (push file this-sublist)
                        (setq this-sublist-sum (+ this-sublist-sum time)))
                    (push this-sublist sublists)
                    (setq this-sublist-sum 0)
                    (setq this-sublist nil)
                    (push file files)
                    (when (= (length sublists) n)
                      (throw 'filled t)))))))
          ;; Let last sublist absorb all untimed
          (if this-sublist
              (progn
                (push (nconc untimed this-sublist) sublists)
                (when files
                  (message "org-node: FILES surprisingly not empty: %s" files)))
            ;; Last sublist already hit time limit, spread leftovers equally
            (let ((ctr 0)
                  (len (length sublists)))
              (if (= len 0)
                  ;; All files are untimed
                  ;; REVIEW: Code never ends up here, right?
                  (progn
                    (setq sublists (org-node--split-into-n-sublists untimed n))
                    (message "org-node: Unexpected code path. Not fatal, but report appreciated"))
                (dolist (file (nconc untimed files))
                  (push file (nth (% (cl-incf ctr) len) sublists))))))
          sublists)))))

(defun org-node--split-into-n-sublists (big-list n)
  "Split BIG-LIST equally into a list of N sublists.

In the unlikely case where BIG-LIST contains N or fewer elements,
that results in a value just like BIG-LIST except that
each element is wrapped in its own list."
  (let ((sublist-length (max 1 (/ (length big-list) n)))
        result)
    (dotimes (i n)
      (if (= i (1- n))
          ;; Let the last iteration just take what's left
          (push big-list result)
        (push (take sublist-length big-list) result)
        (setq big-list (nthcdr sublist-length big-list))))
    (delq nil result)))


;;;; Etc

(defun org-node--die (format-string &rest args)
  "Like `error' but make sure the user sees it.
Useful because not everyone has `debug-on-error' t, and then
errors are very easy to miss.

Arguments FORMAT-STRING and ARGS as in `format-message'."
  (let ((err-string (apply #'format-message format-string args)))
    (unless debug-on-error
      (display-warning 'org-node err-string :error))
    (error "%s" err-string)))

(defun org-node--consent-to-bothersome-modes-for-mass-edit ()
  "Confirm about certain modes being enabled.
These are modes such as `auto-save-visited-mode' that can
interfere with user experience during an incremental mass editing
operation."
  (cl-loop for mode in '(auto-save-visited-mode
                         git-auto-commit-mode)
           when (and (boundp mode)
                     (symbol-value mode)
                     (not (y-or-n-p
                           (format "%S is active - proceed anyway?" mode))))
           return nil
           finally return t))

;; (benchmark-call #'org-node-list-files)
;; => (0.009714744 0 0.0)
;; (benchmark-call #'org-roam-list-files)
;; => (1.488666741 1 0.23508516499999388)
(defun org-node-list-files (&optional instant interactive)
  "List files in `org-id-locations' or `org-node-extra-id-dirs'.

With optional argument INSTANT t, return already known files
instead of checking the filesystem again.

When called interactively \(automatically making INTERACTIVE
non-nil), list the files in a new buffer."
  (interactive "i\np")
  (if interactive
      ;; TODO: Make something like a find-dired buffer
      (org-node--pop-to-tabulated-list
       :buffer "*org-node files*"
       :format [("File" 0 t)]
       :entries (cl-loop
                 for file in (org-node-list-files)
                 collect (list file (vector
                                     (list file
                                           'action `(lambda (_button)
                                                      (find-file ,file))
                                           'face 'link
                                           'follow-link t)))))
    (when (stringp org-node-extra-id-dirs)
      (setq org-node-extra-id-dirs (list org-node-extra-id-dirs))
      (message
       "Option `org-node-extra-id-dirs' must be a list, changed it for you"))

    (when (or (not instant)
              (hash-table-empty-p org-node--file<>mtime.elapsed))
      (let* ((file-name-handler-alist nil)
             (dirs-to-scan (delete-dups
                            (mapcar #'file-truename org-node-extra-id-dirs))))
        (cl-loop for file in (org-node-abbrev-file-names
                              (cl-loop for dir in dirs-to-scan
                                       nconc (org-node--dir-files-recursively
                                              dir
                                              ".org"
                                              org-node-extra-id-dirs-exclude)))
                 do (or (gethash file org-node--file<>mtime.elapsed)
                        (puthash file (cons 0 0) org-node--file<>mtime.elapsed))))
      (cl-loop for file being each hash-value of org-id-locations
               do (or (gethash file org-node--file<>mtime.elapsed)
                      (puthash file (cons 0 0) org-node--file<>mtime.elapsed))))
    (hash-table-keys org-node--file<>mtime.elapsed)))

;; (progn (ignore-errors (native-compile #'org-node--dir-files-recursively)) (benchmark-run 100 (org-node--dir-files-recursively org-roam-directory "org" '("logseq/"))))
(defun org-node--dir-files-recursively (dir suffix excludes)
  "Faster, purpose-made variant of `directory-files-recursively'.
Return a list of all files under directory DIR, its
sub-directories, sub-sub-directories and so on, with provisos:

- Don\\='t follow symlinks to other directories.
- Don\\='t enter directories whose name start with a dot.
- Don\\='t enter directories where some substring of the path
  matches one of strings EXCLUDES literally.
- Don\\='t collect any file where some substring of the name
  matches one of strings EXCLUDES literally.
- Collect only files that end in SUFFIX literally.
- Don\\='t sort final results in any particular order."
  (let (result)
    (dolist (file (file-name-all-completions "" dir))
      (if (directory-name-p file)
          (unless (string-prefix-p "." file)
            (setq file (file-name-concat dir file))
            (unless (or (cl-loop for substr in excludes
                                 thereis (string-search substr file))
                        (file-symlink-p (directory-file-name file)))
              (setq result (nconc result (org-node--dir-files-recursively
        		                  file suffix excludes)))))
        (when (string-suffix-p suffix file)
          (unless (cl-loop for substr in excludes
                           thereis (string-search substr file))
            (push (file-name-concat dir file) result)))))
    result))

(defvar org-node--userhome nil)
(defun org-node-abbrev-file-names (paths)
  "Abbreviate all file paths in PATHS.
Faster than `abbreviate-file-name', especially if you have to run
it for many paths.

May in some corner-cases give different results.  For instance, it
disregards file name handlers, affecting TRAMP.

PATHS can be a single path or a list, and are presumed to be absolute.

It is a good idea to abbreviate a path when you don\\='t know where it
came from.  That helps ensure that it is comparable to a path provided
in either `org-id-locations' or an `org-node' object.

If the wild path may be a symlink or not an absolute path, it would be
safer to process it first with `file-truename', then pass the result to
this function.

Tip: the inexactly named buffer-local variable `buffer-file-truename'
already contains an abbreviated truename."
  (unless org-node--userhome
    (setq org-node--userhome (file-name-as-directory (expand-file-name "~"))))
  ;; Assume a case-sensitive filesystem.
  ;; REVIEW: Not sure if it fails gracefully on NTFS/FAT/HFS+/APFS.
  (let ((case-fold-search nil))
    (if (listp paths)
        (cl-loop
         for path in paths
         do (setq path (directory-abbrev-apply path))
         if (string-prefix-p org-node--userhome path)
         ;; REVIEW: Sane in single-user mode Linux?
         collect (concat "~" (substring path (1- (length org-node--userhome))))
         else collect path)
      (setq paths (directory-abbrev-apply paths))
      (if (string-prefix-p org-node--userhome paths)
          (concat "~" (substring paths (1- (length org-node--userhome))))
        paths))))

(defun org-node--forget-id-locations (files)
  "Remove references to FILES in `org-id-locations'.
You might consider committing the effect to disk afterwards by calling
`org-id-locations-save', which this function will not do for you.

FILES are assumed to be abbreviated truenames."
  (when files
    (if (listp org-id-locations)
        (message "org-node--forget-id-locations: Surprised that `org-id-locations' is an alist at this time")
      (maphash (lambda (id file)
                 (when (member file files)
                   (remhash id org-id-locations)))
               org-id-locations))))


;;;; Filename functions

(defun org-node--tmpfile (&optional basename &rest args)
  "Return a path that puts BASENAME in a temporary directory.
As a nicety, `format' BASENAME with ARGS too.

On most systems, the resulting string will be
/tmp/org-node/BASENAME, but it depends on
OS and variable `temporary-file-directory'."
  (file-name-concat temporary-file-directory
                    "org-node"
                    (when basename (apply #'format basename args))))

;; (progn (byte-compile #'org-node--root-dirs) (benchmark-run 10 (org-node--root-dirs (hash-table-values org-id-locations))))
(defun org-node--root-dirs (file-list)
  "Infer root directories of FILE-LIST.

If FILE-LIST is the `hash-table-values' of `org-id-locations',
this function will in many cases spit out a list of one item
because many people keep their Org files in one root
directory \(with various subdirectories).

By \"root\", we mean the longest directory path common to a set
of files.

If it finds more than one root, it sorts by count of files they
contain recursively, so that the most populous root directory
will be the first element.

Note also that the only directories that may qualify are those
that directly contain some member of FILE-LIST, so that if you
have the 3 members

- \"/home/me/Syncthing/foo.org\"
- \"/home/kept/bar.org\"
- \"/home/kept/archive/baz.org\"

the return value will not be \(\"/home/\"), but
\(\"/home/kept/\" \"/home/me/Syncthing/\"), because \"/home\"
itself contains no direct members of FILE-LIST.

FILE-LIST must be a list of full paths; this function does not
consult the filesystem, just compares substrings to each other."
  (let* ((files (seq-uniq file-list))
         (dirs (sort (delete-consecutive-dups
                      (sort (mapcar #'file-name-directory files) #'string<))
                     (##length< %1 (length %2))))
         roots)
    ;; Example: if there is /home/roam/courses/Math1A/, but ancestor dir
    ;; /home/roam/ is also a member of the set, throw out the child
    (while-let ((dir (car (last dirs))))
      (cl-loop for other-dir in (setq dirs (nbutlast dirs))
               when (string-prefix-p other-dir dir)
               return (delete dir dirs)
               finally return (push dir roots)))
    ;; Now sort by count of items inside if we found 2 or more roots
    (if (= (length roots) 1)
        roots
      (cl-loop
       with dir-counters = (cl-loop for dir in roots collect (cons dir 0))
       for file in files
       do (cl-loop for dir in roots
                   when (string-prefix-p dir file)
                   return (cl-incf (cdr (assoc dir dir-counters))))
       finally return (mapcar #'car (cl-sort dir-counters #'> :key #'cdr))))))

(defcustom org-node-ask-directory nil
  "Whether to ask the user where to save a new file node.

- Symbol nil: put file in the most populous root directory in
              `org-id-locations' without asking
- String: a directory path in which to put the file
- Symbol t: ask every time

This variable controls the directory component, but the file
basename is controlled by `org-node-slug-fn' and
`org-node-datestamp-format'."
  :group 'org-node
  :type '(choice boolean string))

(defun org-node-guess-or-ask-dir (prompt)
  "Maybe prompt for a directory, and if so, show string PROMPT.
Behavior depends on the user option `org-node-ask-directory'."
  (if (eq t org-node-ask-directory)
      (read-directory-name prompt)
    (if (stringp org-node-ask-directory)
        org-node-ask-directory
      (car (org-node--root-dirs (org-node-list-files t))))))

(defcustom org-node-datestamp-format ""
  "Passed to `format-time-string' to prepend to filenames.

Example from Org-roam: %Y%m%d%H%M%S-
Example from Denote: %Y%m%dT%H%M%S--"
  :type 'string)

(defcustom org-node-slug-fn #'org-node-slugify-for-web
  "Function taking a node title and returning a filename component.
Receives one argument: the value of an Org #+TITLE keyword, or
the first heading in a file that has no #+TITLE.

Built-in choices:
- `org-node-slugify-for-web'
- `org-node-slugify-like-roam-default'
- `org-node-fakeroam-slugify-via-roam'

It is popular to also prefix filenames with a datestamp.  To do
that, configure `org-node-datestamp-format'."
  :type '(radio
          (function-item org-node-slugify-for-web)
          (function-item org-node-slugify-like-roam-default)
          (function-item org-node-fakeroam-slugify-via-roam)
          (function :tag "Custom function")))

(defun org-node-slugify-like-roam-default (title)
  "From TITLE, make a filename slug in default org-roam style.
Does not require org-roam installed.

A title like \"Löb\\='s Theorem\" becomes \"lob_s_theorem\".

Diacritical marks U+0300 to U+0331 are stripped \(mostly used with Latin
alphabets).  Also stripped are all glyphs not categorized in Unicode as
belonging to some alphabet or number system.

If you seek to emulate org-roam filenames, you may also want to
configure `org-node-datestamp-format'."
  (thread-last title
               (ucs-normalize-NFD-string)
               (seq-remove (lambda (char) (<= #x300 char #x331)))
               (concat)
               (ucs-normalize-NFC-string)
               (downcase)
               (string-trim)
               (replace-regexp-in-string "[^[:alnum:]]" "_")
               (replace-regexp-in-string "__*" "_")
               (replace-regexp-in-string "^_" "")
               (replace-regexp-in-string "_$" "")))

(defun org-node-slugify-for-web (title)
  "From TITLE, make a filename slug meant to look nice as URL component.

A title like \"Löb\\='s Theorem\" becomes \"lobs-theorem\".

Diacritical marks U+0300 to U+0331 are stripped \(mostly used with Latin
alphabets).  Also stripped are all glyphs not categorized in Unicode as
belonging to some alphabet or number system."
  (thread-last title
               (ucs-normalize-NFD-string)
               (seq-remove (lambda (char) (<= #x300 char #x331)))
               (concat)
               (ucs-normalize-NFC-string)
               (downcase)
               (string-trim)
               (replace-regexp-in-string "[[:space:]]+" "-")
               (replace-regexp-in-string "[^[:alnum:]\\/-]" "")
               (replace-regexp-in-string "\\/" "-")
               (replace-regexp-in-string "--*" "-")
               (replace-regexp-in-string "^-" "")
               (replace-regexp-in-string "-$" "")))

;; Useful test cases if you want to hack on this!

;; (org-node-slugify-for-web "A/B testing")
;; (org-node-slugify-for-web "\"But there's still a chance, right?\"")
;; (org-node-slugify-for-web "Löb's Theorem")
;; (org-node-slugify-for-web "Mañana Çedilla")
;; (org-node-slugify-for-web "How to convince me that 2 + 2 = 3")
;; (org-node-slugify-for-web "E. T. Jaynes")
;; (org-node-slugify-for-web "Amnesic recentf? Solution: Foo.")
;; (org-node-slugify-for-web "Slimline/\"pizza box\" computer chassis")
;; (org-node-slugify-for-web "#emacs")
;; (org-node-slugify-for-web "칹え🐛")


;;;; How to create new nodes

(defvar org-node-proposed-title nil
  "For use by `org-node-creation-fn'.")

(defvar org-node-proposed-id nil
  "For use by `org-node-creation-fn'.")

(defun org-node--purge-backup-file-names ()
  "Clean backup names accidentally added to org-id database."
  (setq org-id-files (seq-remove #'backup-file-name-p org-id-files))
  (setq org-id-locations
        (org-id-alist-to-hash
         (cl-loop for entry in (org-id-hash-to-alist org-id-locations)
                  unless (backup-file-name-p (car entry))
                  collect entry))))

(defun org-node--goto (node)
  "Visit NODE."
  (if node
      (let ((file (org-node-get-file-path node)))
        (if (backup-file-name-p file)
            ;; Transitional; handle-save doesn't record backup files anymore
            (progn
              (message "org-node: Somehow recorded backup file, resetting...")
              (org-node--purge-backup-file-names)
              (push (lambda ()
                      (message "org-node: Somehow recorded backup file, resetting... done"))
                    org-node--temp-extra-fns)
              (org-node--scan-all))
          (if (file-exists-p file)
              (progn
                (when (not (file-readable-p file))
                  (error "org-node: Couldn't visit unreadable file %s" file))
                (let ((pos (org-node-get-pos node)))
                  (find-file file)
                  (widen)
                  ;; Now `save-place-find-file-hook' has potentially already
                  ;; moved point, and that could be good enough.  So: move
                  ;; point to node heading, unless heading is already inside
                  ;; visible part of buffer and point is at or under it
                  (if (org-node-get-is-subtree node)
                      (progn
                        (unless (and (pos-visible-in-window-p pos)
                                     (not (org-invisible-p pos))
                                     (equal (org-node-get-title node)
                                            (org-get-heading t t t t)))

                          (goto-char pos)
                          (if (org-at-heading-p)
                              (org-show-entry)
                            (org-show-context))
                          (recenter 0)))
                    (unless (pos-visible-in-window-p pos)
                      (goto-char pos)))))
            (message "org-node: Didn't find file, resetting...")
            (push (lambda ()
                    (message "org-node: Didn't find file, resetting... done"))
                  org-node--temp-extra-fns)
            (org-node--scan-all))))
    (error "`org-node--goto' received a nil argument")))

;; TODO: "Create" sounds unspecific, rename to "New node"?
(defun org-node-create (title id &optional series-key)
  "Call `org-node-creation-fn' with necessary variables set.

TITLE will be title of node, ID will be id of node \(use
`org-id-new' if you don\\='t know\).

Optional argument SERIES-KEY means use the resulting node to
maybe grow the corresponding series.

When calling from Lisp, you should not assume anything about
which buffer will be current afterwards, since it depends on
`org-node-creation-fn', whether TITLE or ID had existed, and
whether the user carried through with the creation.

To operate on a node after creating it, either let-bind
`org-node-creation-fn' so you know what you get, or hook
`org-node-creation-hook' temporarily, or write:

    (org-node-create TITLE ID)
    (org-node-cache-ensure t)
    (let ((node (gethash ID org-node--id<>node)))
      (if node (org-node--goto node)))"
  (setq org-node-proposed-title title)
  (setq org-node-proposed-id id)
  (setq org-node-proposed-series-key series-key)
  (unwind-protect
      (funcall org-node-creation-fn)
    (setq org-node-proposed-title nil)
    (setq org-node-proposed-id nil)
    (setq org-node-proposed-series-key nil)))

(defcustom org-node-creation-fn #'org-node-new-file
  "Function called to create a node that does not yet exist.
Used by commands such as `org-node-find'.

Some choices:
- `org-node-new-file'
- `org-node-fakeroam-new-via-roam-capture'
- `org-capture'

It is pointless to choose `org-capture' here unless you configure
`org-capture-templates' such that some capture templates use
`org-node-capture-target' as their target.

If you wish to write a custom function instead of any of the
above three choices, know that two variables are set at the time
the function is called: `org-node-proposed-title' and
`org-node-proposed-id', which it is expected to obey."
  :group 'org-node
  :type '(radio
          (function-item org-node-new-file)
          (function-item org-node-fakeroam-new-via-roam-capture)
          (function-item org-capture)
          (function :tag "Custom function")))

(defun org-node-new-file ()
  "Create a file-level node.
Meant to be called indirectly as `org-node-creation-fn', so that some
necessary variables are set."
  (if (or (null org-node-proposed-title)
          (null org-node-proposed-id))
      (message "org-node-new-file is meant to be called indirectly")
    (let* ((dir (org-node-guess-or-ask-dir "New file in which directory? "))
           (path-to-write
            (file-name-concat
             dir (concat (format-time-string org-node-datestamp-format)
                         (funcall org-node-slug-fn org-node-proposed-title)
                         ".org"))))
      (when (file-exists-p path-to-write)
        (user-error "File already exists: %s" path-to-write))
      (when (find-buffer-visiting path-to-write)
        (user-error "A buffer already exists for filename %s" path-to-write))
      (mkdir dir t)
      (find-file path-to-write)
      (if org-node-prefer-with-heading
          (insert "* " org-node-proposed-title
                  "\n:PROPERTIES:"
                  "\n:ID:       " org-node-proposed-id
                  "\n:END:"
                  "\n")
        (insert ":PROPERTIES:"
                "\n:ID:       " org-node-proposed-id
                "\n:END:"
                "\n#+title: " org-node-proposed-title
                "\n"))
      (goto-char (point-max))
      (push (current-buffer) org-node--not-yet-saved)
      (run-hooks 'org-node-creation-hook))))

(defun org-node-capture-target ()
  "Can be used as target in a capture template.
See `org-capture-templates' for more info about targets.

In simple terms, let\\='s say you have configured
`org-capture-templates' so it has a template that
targets `(function org-node-capture-target)'.  Now here\\='s a
possible workflow:

1. Run `org-capture'
2. Select your template
3. Type name of known or unknown node
4a. If it was known, it will capture into that node.
4b. If it was unknown, it will create a file-level node and then
    capture into there.

Additionally, with (setq org-node-creation-fn #\\='org-capture),
commands like `org-node-find' will outsource to `org-capture' when you
type the name of a node that does not exist.  That enables this
\"inverted\" workflow:

1. Run `org-node-find'
2. Type name of an unknown node
3. Select your template
4. Same as 4b earlier."
  (org-node-cache-ensure)
  (let (title node id)
    (if org-node-proposed-title
        ;; Was called from `org-node-create', so the user had typed the
        ;; title and no such node exists yet
        (progn
          (setq title org-node-proposed-title)
          (setq id org-node-proposed-id))
      ;; Was called from `org-capture', which means the user has not yet typed
      ;; the title; let them type it now
      (let ((input (completing-read "Node: " #'org-node-collection
                                    () () () 'org-node-hist)))
        (setq node (gethash input org-node--candidate<>node))
        (if node
            (progn
              (setq title (org-node-get-title node))
              (setq id (org-node-get-id node)))
          (setq title input)
          (setq id (org-id-new)))))
    (if node
        ;; Node exists; capture into it
        (progn
          (find-file (org-node-get-file-path node))
          (widen)
          (goto-char (org-node-get-pos node))
          (org-reveal)
          ;; TODO: Figure out how to play well with :prepend vs not :prepend.
          ;; Now it's just like it always prepends, I think?
          (unless (and (= 1 (point)) (org-at-heading-p))
            ;; Go to just before next heading, or end of buffer if there are no
            ;; more headings.  This allows the template to insert subtrees
            ;; without swallowing content that was already there.
            (when (outline-next-heading)
              (backward-char 1))))
      ;; Node does not exist; capture into new file
      (let* ((dir (org-node-guess-or-ask-dir "New file in which directory? "))
             (path-to-write
              (file-name-concat
               dir (concat (format-time-string org-node-datestamp-format)
                           (funcall org-node-slug-fn title)
                           ".org"))))
        (when (file-exists-p path-to-write)
          (error "File already exists: %s" path-to-write))
        (when (find-buffer-visiting path-to-write)
          (error "A buffer already has the filename %s" path-to-write))
        (mkdir (file-name-directory path-to-write) t)
        (find-file path-to-write)
        (if org-node-prefer-with-heading
            (insert "* " title
                    "\n:PROPERTIES:"
                    "\n:ID:       " id
                    "\n:END:"
                    "\n")
          (insert ":PROPERTIES:"
                  "\n:ID:       " id
                  "\n:END:"
                  "\n#+title: " title
                  "\n"))
        (push (current-buffer) org-node--not-yet-saved)
        (run-hooks 'org-node-creation-hook)))))


;;;; Examples and helpers for user to define series

(defun org-node-extract-file-name-datestamp (path)
  "From filename PATH, get the datestamp prefix if it has one.
Do so by comparing with `org-node-datestamp-format'.  Not immune
to false positives, if you have been changing formats over time."
  (when (and org-node-datestamp-format
             (not (string-blank-p org-node-datestamp-format)))
    (let ((name (file-name-nondirectory path)))
      (when (string-match
             (org-node--make-regexp-for-time-format org-node-datestamp-format)
             name)
        (match-string 0 name)))))

(defun org-node-mk-series-sorted-by-property
    (key name prop &optional capture)
  "Define a series of ID-nodes sorted by property PROP.
If an ID-node does not have property PROP, it is excluded.
KEY, NAME and CAPTURE explained in `org-node-series-defs'."
  `(,key
    :name ,name
    :version 2
    :capture ,capture
    :classifier (lambda (node)
                  (let ((sortstr (cdr (assoc ,prop (org-node-get-props node)))))
                    (when (and sortstr (not (string-blank-p sortstr)))
                      (cons (concat sortstr " " (org-node-get-title node))
                            (org-node-get-id node)))))
    :whereami (lambda ()
                (when-let* ((sortstr (org-entry-get nil ,prop t))
                            (node (gethash (org-node-id-at-point) org-nodes)))
                  (concat sortstr " " (org-node-get-title node))))
    :prompter (lambda (key)
                (let ((series (cdr (assoc key org-node-built-series))))
                  (completing-read "Go to: " (plist-get series :sorted-items))))
    :try-goto (lambda (item)
                (org-node-helper-try-goto-id (cdr item)))
    :creator (lambda (sortstr key)
               (let ((adder (lambda () (org-entry-put nil ,prop sortstr))))
                 (add-hook 'org-node-creation-hook adder)
                 (unwind-protect (org-node-create sortstr (org-id-new) key)
                   (remove-hook 'org-node-creation-hook adder))))))

(defun org-node-mk-series-on-tags-sorted-by-property
    (key name tags prop &optional capture)
  "Define a series filtered by TAGS sorted by property PROP.
TAGS is a string of tags separated by colons.
KEY, NAME and CAPTURE explained in `org-node-series-defs'."
  `(,key
    :name ,name
    :version 2
    :capture ,capture
    :classifier (lambda (node)
                  (let ((sortstr (cdr (assoc ,prop (org-node-get-props node))))
                        (tagged (seq-intersection (split-string ,tags ":" t)
                                                  (org-node-get-tags-local node))))
                    (when (and sortstr tagged (not (string-blank-p sortstr)))
                      (cons (concat sortstr " " (org-node-get-title node))
                            (org-node-get-id node)))))
    :whereami (lambda ()
                (when (seq-intersection (split-string ,tags ":" t)
                                        (org-get-tags))
                  (let ((sortstr (org-entry-get nil ,prop t))
                        (node (gethash (org-node-id-at-point) org-nodes)))
                    (when (and sortstr node)
                      (concat sortstr " " (org-node-get-title node))))))
    :prompter (lambda (key)
                (let ((series (cdr (assoc key org-node-built-series))))
                  (completing-read "Go to: " (plist-get series :sorted-items))))
    :try-goto (lambda (item)
                (org-node-helper-try-goto-id (cdr item)))
    ;; NOTE: The sortstr should not necessarily become the title, but we make
    ;;       it so anyway, and the user can edit afterwards.
    ;; REVIEW: This should probably change, better to prompt for title.  But
    ;;         how?
    :creator (lambda (sortstr key)
               (let ((adder (lambda ()
                              (org-entry-put nil ,prop sortstr)
                              (dolist (tag (split-string ,tags ":" t))
                                (org-node-tag-add tag)))))
                 (add-hook 'org-node-creation-hook adder)
                 (unwind-protect (org-node-create sortstr (org-id-new) key)
                   (remove-hook 'org-node-creation-hook adder))))))

(defun org-node-mk-series-on-filepath-sorted-by-basename
    (key name dir &optional capture date-picker)
  "Define a series of files located under DIR.
KEY, NAME and CAPTURE explained in `org-node-series-defs'.

When optional argument DATE-PICKER is non-nil, let the prompter use the
Org date picker.  This needs file basenames in YYYY-MM-DD format."
  (setq dir (abbreviate-file-name (file-truename dir)))
  `(,key
    :name ,name
    :version 2
    :capture ,capture
    :classifier (lambda (node)
                  (when (string-prefix-p ,dir (org-node-get-file-path node))
                    (let* ((path (org-node-get-file-path node))
                           (sortstr (file-name-base path)))
                      (cons sortstr path))))
    :whereami (lambda ()
                (when (string-prefix-p ,dir buffer-file-truename)
                  (file-name-base buffer-file-truename)))
    :prompter (lambda (key)
                ;; Tip: Consider `org-read-date-prefer-future' nil
                (if ,date-picker
                    (let ((org-node-series-that-marks-calendar key))
                      (org-read-date))
                  (let ((series (cdr (assoc key org-node-built-series))))
                    (completing-read "Go to: " (plist-get series :sorted-items)))))
    :try-goto (lambda (item)
                (org-node-helper-try-visit-file (cdr item)))
    :creator (lambda (sortstr key)
               (let ((org-node-creation-fn #'org-node-new-file)
                     (org-node-ask-directory ,dir))
                 (org-node-create sortstr (org-id-new) key)))))

(defvar org-node--guess-daily-dir nil)
(defun org-node--guess-daily-dir ()
  "Do not rely on this.
Better insert a hardcoded string in your series definition
instead of calling this function."
  (with-memoization org-node--guess-daily-dir
    (or (bound-and-true-p org-node-fakeroam-daily-dir)
        (bound-and-true-p org-journal-dir)
        (and (bound-and-true-p org-roam-directory)
             (seq-find #'file-exists-p
                       (list (file-name-concat org-roam-directory "daily/")
                             (file-name-concat org-roam-directory "dailies/"))))
        (seq-find #'file-exists-p
                  (list (file-name-concat org-directory "daily/")
                        (file-name-concat org-directory "dailies/"))))))

(defun org-node-helper-try-goto-id (id)
  "Try to visit org-id ID, returning non-nil on success."
  (let ((node (gethash id org-node--id<>node)))
    (when node
      (org-node--goto node)
      t)))

(defun org-node-helper-try-visit-file (file)
  "If FILE exists or a buffer has it as filename, visit that.
On success, return non-nil; otherwise nil.  Never create FILE."
  (let ((buf (find-buffer-visiting file)))
    (if buf
        (switch-to-buffer buf)
      (when (file-readable-p file)
        (find-file file)))))

(defun org-node-helper-filename->ymd (path)
  "Check the filename PATH for a date and return it.
On failing to coerce a date, return nil."
  (when path
    (let ((clipped-name (file-name-base path)))
      (if (string-match
           (rx bol (= 4 digit) "-" (= 2 digit) "-" (= 2 digit))
           clipped-name)
          (match-string 0 clipped-name)
        ;; Even in a non-daily file, pretend it is a daily if possible,
        ;; to allow entering the series at a more relevant date
        (when-let ((stamp (org-node-extract-file-name-datestamp path)))
          (org-node-extract-ymd stamp org-node-datestamp-format))))))

;; TODO: Handle %s, %V, %y...  is there a library?
(defun org-node-extract-ymd (instance time-format)
  "Try to extract a YYYY-MM-DD date out of string INSTANCE.
Assume INSTANCE is a string produced by TIME-FORMAT, e.g. if
TIME-FORMAT is %Y%m%dT%H%M%SZ then a possible INSTANCE is
20240814T123307Z.  In that case, return 2024-08-14.

Will throw an error if TIME-FORMAT does not include either %F or
all three of %Y, %m and %d.  May return odd results if other
format-constructs occur before these."
  (let ((verify-re (org-node--make-regexp-for-time-format time-format)))
    (when (string-match-p verify-re instance)
      (let ((case-fold-search nil))
        (let ((pos-year (string-search "%Y" time-format))
              (pos-month (string-search "%m" time-format))
              (pos-day (string-search "%d" time-format))
              (pos-ymd (string-search "%F" time-format)))
          (if (seq-some #'null (list pos-year pos-month pos-day))
              (progn (cl-assert pos-ymd)
                     (substring instance pos-ymd (+ pos-ymd 10)))
            (when (> pos-month pos-year) (cl-incf pos-month 2))
            (when (> pos-day pos-year) (cl-incf pos-day 2))
            (concat (substring instance pos-year (+ pos-year 4))
                    "-"
                    (substring instance pos-month (+ pos-month 2))
                    "-"
                    (substring instance pos-day (+ pos-day 2)))))))))


;;;; Series plumbing

(defcustom org-node-series-defs nil
  "Alist defining each node series.

This functionality is still experimental, and likely to have
higher-level wrappers in the future.

Each item looks like

\(KEY :name NAME
     :classifier CLASSIFIER
     :whereami WHEREAMI
     :prompter PROMPTER
     :try-goto TRY-GOTO
     :creator CREATOR
     :capture CAPTURE
     :version VERSION)

KEY uniquely identifies the series, and is the key to type after
\\[org-node-series-dispatch] to select it.  It may not be \"j\",
\"n\", \"p\" or \"c\", these keys are reserved for
Jump/Next/Previous/Capture actions.

NAME describes the series, in one or a few words.

CLASSIFIER is a single-argument function taking an `org-node'
object and should return a cons cell or list if a series-item was
found, otherwise nil.

The list may contain anything, but the first element must be a
sort-string, i.e. a string suitable for sorting on.  An example
is a date in the format YYYY-MM-DD, but not in the format MM/DD/YY.

This is what determines the order of items in the series: after
all nodes have been processed by CLASSIFIER, the non-nil return
values are sorted by the sort-string, using `string>'.

Aside from returning a single item, CLASSIFIER may also return a list of
such items.  This can be useful if e.g. you have a special type of node
that \"defines\" a series by simply containing links to each item that
should go into it.

Function PROMPTER may be used during jump/capture/refile to
interactively prompt for a sort-string.  This highlights the
other use of the sort-string: finding our way back from scant
context.

For example, in a series of daily-notes sorted on YYYY-MM-DD, a
prompter could use `org-read-date'.

PROMPTER receives one argument, the series plist, which has the
same form as one of the values in `org-node-series-defs' but
includes two extra members :key, corresponding to KEY, and
:sorted-items, which may be useful for interactive completion.

Function WHEREAMI is like PROMPTER in that it should return a
sort-string.  However, it should do this without user
interaction, and may return nil.  For example, if the user is not
currently in a daily-note, the daily-notes\\=' WHEREAMI should
return nil.  It receives no arguments.

Function TRY-GOTO takes a single argument: one of the items
originally created by CLASSIFIER.  That is, a list of not only a
sort-string but any associated data you put in.  If TRY-GOTO
succeeds in using this information to visit a place of interest,
it should return non-nil, otherwise nil.  It should not create or
write anything on failure - reserve that for the CREATOR
function.

Function CREATOR creates a place that did not exist.  For
example, if the user picked a date from `org-read-date' but no
daily-note exists for that date, CREATOR is called to create that
daily-note.  It receives a would-be sort-string as argument.

Optional string CAPTURE indicates the keys to a capture template
to autoselect, when you choose the capture option in the
`org-node-series-dispatch' menu.

Integer VERSION indicates the series definition language.  New
series should use version 2, as of 2024-09-05.  When org-node
updates the series definition language, old versions may still
work, but this is not heavily tested, so it will start printing a
message to remind you to check out the wiki on GitHub and port
your definitions."
  :type 'alist
  :package-version '(org-node . "1.0.10")
  :set #'org-node--set-and-remind-reset)

(defvar org-node-built-series nil
  "Alist describing each node series, internal use.")

(defvar org-node-proposed-series-key nil
  "Key that identifies the series about to be added to.
Automatically set, should be nil most of the time.  For a
variable that need not stay nil, see
`org-node-current-series-key'.")

(defun org-node--add-series-item (&optional key)
  "Look at node near point to maybe add an item to a series.
Only do something if `org-node-proposed-series-key' is non-nil
currently."
  (when (or key org-node-proposed-series-key)
    (let* ((series (cdr (assoc (or key org-node-proposed-series-key)
                               org-node-built-series)))
           (node-here (gethash (org-node-id-at-point) org-nodes))
           (new-item (when node-here
                       (funcall (plist-get series :classifier) node-here))))
      (when new-item
        (unless (member new-item (plist-get series :sorted-items))
          (push new-item (plist-get series :sorted-items))
          (sort (plist-get series :sorted-items)
                (lambda (item1 item2)
                  (string> (car item1) (car item2)))))))))

(defun org-node--series-jump (key)
  "Prompt for and jump to an entry in series identified by KEY."
  (let* ((series (cdr (assoc key org-node-built-series)))
         (sortstr (if (eq 2 (plist-get series :version))
                      (funcall (plist-get series :prompter) key)
                    (funcall (plist-get series :prompter) series)))
         (item (assoc sortstr (plist-get series :sorted-items))))
    (if item
        (unless (funcall (plist-get series :try-goto) item)
          (delete item (plist-get series :sorted-items))
          (if (eq 2 (plist-get series :version))
              (funcall (plist-get series :creator) sortstr key)
            (funcall (plist-get series :creator) sortstr)))
      (if (eq 2 (plist-get series :version))
          (funcall (plist-get series :creator) sortstr key)
        (funcall (plist-get series :creator) sortstr)))))

(defun org-node--series-goto-next (key)
  "Visit the next entry in series identified by KEY."
  (org-node--series-goto-previous key t))

(defun org-node--series-goto-previous (key &optional next)
  "Visit the previous entry in series identified by KEY.
If argument NEXT is non-nil, visit the next entry instead."
  (let* ((series (cdr (assoc key org-node-built-series)))
         (tail (plist-get series :sorted-items))
         head
         here)
    (unless tail
      (error "No items in series \"%s\"" (plist-get series :name)))
    ;; Depending on the design of the :whereami lambda, being in a sub-heading
    ;; may block discovering that a parent heading is a member of the series,
    ;; so re-try until the top level
    (when (derived-mode-p 'org-mode)
      (save-excursion
        (without-restriction
          (while (and (not (setq here (funcall (plist-get series :whereami))))
                      (org-up-heading-or-point-min))))))
    (when (or (when here
                ;; Find our location in the series
                (cl-loop for item in tail
                         while (string> (car item) here)
                         do (push (pop tail) head))
                (when (equal here (caar tail))
                  (pop tail)
                  ;; Opportunistically clean up duplicate keys
                  (while (equal here (caar tail))
                    (setcar tail (cadr tail))
                    (setcdr tail (cddr tail))))
                t)
              (when (y-or-n-p
                     (format "Not in series \"%s\".  Jump to latest item in that series?"
                             (plist-get series :name)))
                (setq head (take 1 tail))
                t))
      ;; Usually this should return on the first try, but sometimes stale
      ;; items refer to something that has been erased from disk, so
      ;; deregister each item that TRY-GOTO failed to visit and try again.
      (cl-loop for item in (if next head tail)
               if (funcall (plist-get series :try-goto) item)
               return t
               else do (delete item (plist-get series :sorted-items))
               finally do (message "No %s item in series \"%s\""
                                   (if next "next" "previous")
                                   (plist-get series :name))))))

(defun org-node-series-capture-target ()
  "Experimental."
  (org-node-cache-ensure)
  (let ((key (or org-node-current-series-key
                 (let* ((valid-keys (mapcar #'car org-node-series-defs))
                        (elaborations
                         (cl-loop for series in org-node-series-defs
                                  concat
                                  (format " %s(%s)"
                                          (car series)
                                          (plist-get (cdr series) :name))))
                        (input (read-char-from-minibuffer
                                (format "Press any of [%s] to capture into series: %s "
                                        (string-join valid-keys ",")
                                        elaborations)
                                (mapcar #'string-to-char valid-keys))))
                   (char-to-string input)))))
    ;; Almost identical to `org-node--series-jump'
    (let* ((series (cdr (assoc key org-node-built-series)))
           (sortstr (or org-node-proposed-title
                        (if (eq 2 (plist-get series :version))
                            (funcall (plist-get series :prompter) key)
                          (funcall (plist-get series :prompter) series))))
           (item (assoc sortstr (plist-get series :sorted-items))))
      (when (or (null item)
                (not (funcall (plist-get series :try-goto) item)))
        ;; TODO: Move point after creation to most appropriate place
        (if (eq 2 (plist-get series :version))
            (funcall (plist-get series :creator) sortstr key)
          (funcall (plist-get series :creator) sortstr))))))

(defun org-node--build-series (def)
  "From DEF, make a plist for `org-node-built-series'.
DEF is a series-definition from `org-node-series-defs'."
  (let ((classifier (org-node--ensure-compiled
                     (plist-get (cdr def) :classifier))))
    (nconc
     (cl-loop for elt in (cdr def)
              if (functionp elt)
              collect (org-node--ensure-compiled elt)
              else collect elt)
     (cl-loop for node being the hash-values of org-node--id<>node
              as result = (funcall classifier node)
              if (listp (car result))
              nconc result into items
              else collect result into items
              finally return
              ;; Sort `string>' due to most recent dailies probably being most
              ;; relevant, thus cycling recent dailies will have the best perf
              (list :key (car def)
                    :sorted-items (delete-consecutive-dups
                                   (if (< emacs-major-version 30)
                                       ;; Faster than compat's sort
                                       (cl-sort items #'string> :key #'car)
                                     (compat-call sort items
                                                  :key #'car :lessp #'string<
                                                  :reverse t :in-place t))))))))

(defvar org-node-current-series-key nil
  "Key of the series currently being browsed with the menu.")

(defun org-node--add-series-to-dispatch (key name)
  "Use KEY and NAME to add a series to the Transient menu."
  (when (ignore-errors (transient-get-suffix 'org-node-series-dispatch key))
    (transient-remove-suffix 'org-node-series-dispatch key))
  (transient-append-suffix 'org-node-series-dispatch '(0 -1)
    (list key name key))
  ;; Make the series switches mutually exclusive
  (let ((old (car (slot-value (get 'org-node-series-dispatch 'transient--prefix)
                              'incompatible))))
    (setf (slot-value (get 'org-node-series-dispatch 'transient--prefix)
                      'incompatible)
          (list (seq-uniq (cons key old))))))

;; These suffixes just exist due to a linter complaint, could
;; have been lambdas

(transient-define-suffix org-node--series-goto-previous* (args)
  (interactive (list (transient-args 'org-node-series-dispatch)))
  (if args
      (org-node--series-goto-previous (car args))
    (message "Choose series before navigating")))

(transient-define-suffix org-node--series-goto-next* (args)
  (interactive (list (transient-args 'org-node-series-dispatch)))
  (if args
      (org-node--series-goto-next (car args))
    (message "Choose series before navigating")))

(transient-define-suffix org-node--series-jump* (args)
  (interactive (list (transient-args 'org-node-series-dispatch)))
  (if args
      (org-node--series-jump (car args))
    (message "Choose series before navigating")))

(transient-define-suffix org-node--series-capture (args)
  (interactive (list (transient-args 'org-node-series-dispatch)))
  (if args
      (progn (setq org-node-current-series-key (car args))
             (unwind-protect
                 (let* ((series (cdr (assoc (car args) org-node-built-series)))
                        (capture-keys (plist-get series :capture)))
                   (if capture-keys
                       (org-capture nil capture-keys)
                     (message "No capture template for series %s"
                              (plist-get series :name))))
               (setq org-node-current-series-key nil)))
    (message "Choose series before navigating")))

;;;###autoload (autoload 'org-node-series-dispatch "org-node" nil t)
(transient-define-prefix org-node-series-dispatch ()
  ["Series"
   ("|" "Invisible" "Placeholder" :if-nil t)]
  ["Navigation"
   ("p" "Previous in series" org-node--series-goto-previous* :transient t)
   ("n" "Next in series" org-node--series-goto-next* :transient t)
   ("j" "Jump (or create)" org-node--series-jump*)
   ("c" "Capture into" org-node--series-capture)])

(defcustom org-node-series-that-marks-calendar nil
  "Key for the series that should mark days in the calendar.

This affects the appearance of the `org-read-date' calendar
popup.  For example, you can use it to indicate which days have a
daily-journal entry.

This need usually not be customized!  When you use
`org-node-series-dispatch' to jump to a daily-note or some
other date-based series, that series may be designed to
temporarily set this variable.

Customize this mainly if you want a given series to always be
indicated, any time Org pops up a calendar for you.

The sort-strings in the series that corresponds to this key
should be correctly parseable by `parse-time-string'."
  :type '(choice key (const nil)))

;; (defface org-node-calendar-marked
;;   '((t :inherit 'org-link))
;;   "Face used by `org-node--mark-days'.")

;; TODO: How to cooperate with preexisting marks?
(defun org-node--mark-days ()
  "Mark days in the calendar popup.
The user option `org-node-series-that-marks-calendar' controls
which dates to mark.

Meant to sit on these hooks:
- `calendar-today-invisible-hook'
- `calendar-today-visible-hook'"
  (calendar-unmark)
  (when org-node-series-that-marks-calendar
    (let* ((series (cdr (assoc org-node-series-that-marks-calendar
                               org-node-built-series)))
           (sortstrs (mapcar #'car (plist-get series :sorted-items)))
           mdy)
      (dolist (date sortstrs)
        ;; Use `parse-time-string' rather than `iso8601-parse' to fail quietly
        (setq date (parse-time-string date))
        (when (seq-some #'natnump date) ;; Basic check that it could be parsed
          (setq mdy (seq-let (_ _ _ d m y _ _ _) date
                      (list m d y)))
          (when (calendar-date-is-visible-p mdy)
            (calendar-mark-visible-date mdy)))))))


;;;; Commands

;;;###autoload
(defun org-node-find ()
  "Select and visit one of your ID nodes.

To behave like `org-roam-node-find' when creating new nodes, set
`org-node-creation-fn' to `org-node-fakeroam-new-via-roam-capture'."
  (interactive)
  (org-node-cache-ensure)
  (let* ((input (completing-read "Go to ID-node: " #'org-node-collection
                                 () () () 'org-node-hist))
         (node (gethash input org-node--candidate<>node)))
    (if node
        (org-node--goto node)
      (if (string-blank-p input)
          (message "Won't create untitled node")
        (org-node-create input (org-id-new))))))

;;;###autoload
(defun org-node-visit-random ()
  "Visit a random node."
  (interactive)
  (org-node-cache-ensure)
  (org-node--goto (nth (random (hash-table-count org-node--candidate<>node))
                       (hash-table-values org-node--candidate<>node))))

;;;###autoload
(defun org-node-insert-link (&optional region-as-initial-input)
  "Insert a link to one of your ID nodes.

To behave exactly like org-roam\\='s `org-roam-node-insert',
see `org-node-insert-link*' and its docstring.

Optional argument REGION-AS-INITIAL-INPUT t means behave as
`org-node-insert-link*'."
  (interactive nil org-mode)
  (unless (derived-mode-p 'org-mode)
    (user-error "Only works in org-mode buffers"))
  (org-node-cache-ensure)
  (let* ((beg nil)
         (end nil)
         (region-text (when (region-active-p)
                        (setq end (region-end))
                        (goto-char (region-beginning))
                        (skip-chars-forward "\n[:space:]")
                        (setq beg (point))
                        (goto-char end)
                        (skip-chars-backward "\n[:space:]")
                        (setq end (point))
                        (org-link-display-format
                         (buffer-substring-no-properties beg end))))
         (initial (if (or region-as-initial-input
                          (when region-text
                            (try-completion region-text org-node--title<>id)))
                      region-text
                    nil))
         (input (completing-read "Node: " #'org-node-collection
                                 () () initial 'org-node-hist))
         (node (gethash input org-node--candidate<>node))
         (id (if node (org-node-get-id node) (org-id-new)))
         (link-desc (or region-text
                        (when (not org-node-alter-candidates) input)
                        (and node (seq-find (##string-search % input)
                                            (org-node-get-aliases node)))
                        (and node (org-node-get-title node))
                        input)))
    (atomic-change-group
      (when region-text
        (delete-region beg end))
      ;; TODO: When inserting a citation, insert a [cite:] instead of a normal
      ;;       link
      ;; (if (string-prefix-p "@" input))
      (insert (org-link-make-string (concat "id:" id) link-desc)))
    (run-hooks 'org-node-insert-link-hook)
    ;; TODO: Delete the link if a node was not created
    (unless node
      (if (string-blank-p input)
          (message "Won't create untitled node")
        (org-node-create input id)))))

;;;###autoload
(defun org-node-insert-link* ()
  "Insert a link to one of your ID nodes.

Unlike `org-node-insert-link', emulate `org-roam-node-insert' by
always copying any active region as initial input.

That behavior can be convenient if you often want to use the
selected region as a new node title, or you already know it
matches a node title.

On the other hand if you always find yourself erasing the
minibuffer before selecting some other node you had in mind, to
which the region should be linkified, you\\='ll prefer
`org-node-insert-link'.

The commands are the same, it is just a difference in
initial input."
  (interactive nil org-mode)
  (org-node-insert-link t))

;;;###autoload
(defun org-node-insert-transclusion ()
  "Insert a #+transclude: referring to a node."
  (interactive nil org-mode)
  (unless (derived-mode-p 'org-mode)
    (user-error "Only works in org-mode buffers"))
  (org-node-cache-ensure)
  (let ((node (gethash (completing-read "Node: " #'org-node-collection
                                        () () () 'org-node-hist)
                       org-node--candidate<>node)))
    (let ((id (org-node-get-id node))
          (title (org-node-get-title node))
          (level (or (org-current-level) 0)))
      (insert (org-link-make-string (concat "id:" id) title))
      (goto-char (pos-bol))
      (insert "#+transclude: ")
      (goto-char (pos-eol))
      (insert " :level " (number-to-string (+ 1 level))))))

;;;###autoload
(defun org-node-insert-transclusion-as-subtree ()
  "Insert a link and a transclusion.

Result will basically look like:

** [[Note]]
#+transclude: [[Note]] :level 3

but adapt to the surrounding outline level.  I recommend
adding keywords to the things to exclude:

\(setq org-transclusion-exclude-elements
      \\='(property-drawer comment keyword))"
  (interactive nil org-mode)
  (unless (derived-mode-p 'org-mode)
    (error "Only works in org-mode buffers"))
  (org-node-cache-ensure)
  (let ((node (gethash (completing-read "Node: " #'org-node-collection
                                        () () () 'org-node-hist)
                       org-node--candidate<>node)))
    (let ((id (org-node-get-id node))
          (title (org-node-get-title node))
          (level (or (org-current-level) 0))
          (m1 (make-marker)))
      (insert (org-link-make-string (concat "id:" id) title))
      (set-marker m1 (1- (point)))
      (duplicate-line)
      (goto-char (pos-bol))
      (insert (make-string (+ 1 level) ?\*) " ")
      (forward-line 1)
      (insert "#+transclude: ")
      (goto-char (pos-eol))
      (insert " :level " (number-to-string (+ 2 level)))
      ;; If the target is a subtree rather than file-level node, I'd like to
      ;; cut out the initial heading because we already made an outer heading.
      ;; (We made the outer heading so that this transclusion will count as a
      ;; backlink, plus it makes more sense to me on export to HTML).
      ;;
      ;; Unfortunately cutting it out with the :lines trick would prevent
      ;; `org-transclusion-exclude-elements' from having an effect, and the
      ;; subtree's property drawer shows up!
      ;; TODO: Patch `org-transclusion-content-range-of-lines' to respect
      ;; `org-transclusion-exclude-elements', or (better) don't use :lines but
      ;; make a different argument like ":no-initial-heading"
      ;;
      ;; For now, just let it nest an extra heading. Looks odd, but doesn't
      ;; break things.
      (goto-char (marker-position m1))
      (set-marker m1 nil)
      (run-hooks 'org-node-insert-link-hook))))

;;;###autoload
(defun org-node-refile ()
  "Experimental."
  (interactive nil org-mode)
  (unless (derived-mode-p 'org-mode)
    (user-error "This command expects an org-mode buffer"))
  (org-node-cache-ensure)
  (when (org-invisible-p)
    (user-error "Better not run this command in an invisible region"))
  (let* ((input (completing-read "Refile into ID-node: " #'org-node-collection
                                 () () () 'org-node-hist))
         (node (gethash input org-node--candidate<>node)))
    (unless node
      (error "Node not found %s" input))
    (org-back-to-heading t)
    (when (org-invisible-p) ;; IDK...
      (user-error "Better not run this command in an invisible region"))
    (org-cut-subtree)
    (org-node--goto node)
    (widen)
    (when (outline-next-heading)
      (backward-char 1))
    (org-paste-subtree)
    (org-node--dirty-ensure-node-known)))

;;;###autoload
(defun org-node-extract-subtree ()
  "Extract subtree at point into a file of its own.
Leave a link in the source file, and show the newly created file
as current buffer.

You may find it a common situation that the subtree had not yet
been assigned an ID nor any other property that you normally
assign to your nodes.  Thus, this creates an ID if there was
no ID, copies over all inherited tags \(making them explicit),
and runs `org-node-creation-hook'.

Adding to that, see below for an example advice that copies any
inherited \"CREATED\" property, if an ancestor had such a
property.  It is subjective whether you\\='d want this behavior,
but it can be desirable if you know the subtree had been part of
the source file for ages so that you regard the ancestor\\='s
creation-date as more \"truthful\" than today\\='s date.

\(advice-add \\='org-node-extract-subtree :around
            (defun my-inherit-creation-date (orig-fn &rest args)
                   (let ((parent-creation
                          (org-entry-get-with-inheritance \"CREATED\")))
                     (apply orig-fn args)
                     ;; Now in the new buffer
                     (org-entry-put nil \"CREATED\"
                                    (or parent-creation
                                        (format-time-string
                                         (org-time-stamp-format t t)))))))"
  (interactive nil org-mode)
  (unless (derived-mode-p 'org-mode)
    (user-error "This command expects an org-mode buffer"))
  (org-node-cache-ensure)
  (let ((dir (org-node-guess-or-ask-dir "Extract to new file in directory: ")))
    (when (org-invisible-p)
      (user-error "Better not run this command in an invisible region"))
    (org-back-to-heading t)
    (save-buffer)
    (when (org-invisible-p)
      (user-error "Better not run this command in an invisible region"))
    (let* ((tags (org-get-tags))
           (title (org-get-heading t t t t))
           (id (org-id-get-create))
           (boundary (save-excursion
                       (org-end-of-meta-data t)
                       (point)))
           (case-fold-search t)
           ;; Why is CATEGORY autocreated by `org-entry-properties'...  It's
           ;; an invisible property that's always present and usually not
           ;; interesting, unless user has entered some explicit value
           (explicit-category (save-excursion
                                (when (search-forward ":category:" boundary t)
                                  (org-entry-get nil "CATEGORY"))))
           (properties (seq-remove
                        (##string-equal-ignore-case "CATEGORY" (car %))
                        (org-entry-properties nil 'standard)))
           (path-to-write
            (file-name-concat
             dir (concat (format-time-string org-node-datestamp-format)
                         (funcall org-node-slug-fn title)
                         ".org")))
           (parent-pos (save-excursion
                         (without-restriction
                           (org-up-heading-or-point-min)
                           (point)))))
      (if (file-exists-p path-to-write)
          (message "A file already exists named %s" path-to-write)
        (org-cut-subtree)
        ;; Try to leave a link at the end of parent entry, pointing to the
        ;; ID of subheading that was extracted.
        (unless (bound-and-true-p org-capture-mode)
          (widen)
          (goto-char parent-pos)
          (goto-char (org-entry-end-position))
          (if (org-invisible-p)
              (message "Invisible area, not inserting link to extracted")
            (open-line 1)
            (insert "\n"
                    (format-time-string
                     (format "%s Created " (org-time-stamp-format t t)))
                    (org-link-make-string (concat "id:" id) title)
                    "\n")
            (org-node--dirty-ensure-link-known id)))
        (find-file path-to-write)
        (org-paste-subtree)
        (unless org-node-prefer-with-heading
          ;; Replace the root heading and its properties with file-level
          ;; keywords &c.
          (goto-char (point-min))
          (org-end-of-meta-data t)
          (kill-region (point-min) (point))
          (org-map-region #'org-promote (point-min) (point-max))
          (insert
           ":PROPERTIES:\n"
           (string-join (mapcar (##concat ":" (car %) ": " (cdr %))
                                properties)
                        "\n")
           "\n:END:"
           (if explicit-category
               (concat "\n#+category: " explicit-category)
             "")
           (if tags
               (concat "\n#+filetags: :" (string-join tags ":") ":")
             "")
           "\n#+title: " title
           "\n"))
        (org-node--dirty-ensure-node-known)
        (push (current-buffer) org-node--not-yet-saved)
        (run-hooks 'org-node-creation-hook)
        (when (bound-and-true-p org-node-backlink-mode)
          (org-node-backlink--fix-entry-here))))))

;; "Some people, when confronted with a problem, think
;; 'I know, I'll use regular expressions.'
;; Now they have two problems." —Jamie Zawinski
(defvar org-node--make-regexp-for-time-format nil)
(defun org-node--make-regexp-for-time-format (format)
  "Make regexp to match a result of (format-time-string FORMAT).

In other words, if e.g. FORMAT is %Y-%m-%d, which can be
instantiated in many ways such as 2024-08-10, then this should
return a regexp that can match any of those ways it might turn
out, with any year, month or day.

Memoize the value, so consecutive calls with the same FORMAT only
need to compute once."
  (if (equal format (car org-node--make-regexp-for-time-format))
      ;; Reuse memoized value on consecutive calls with same input
      (cdr org-node--make-regexp-for-time-format)
    (cdr (setq org-node--make-regexp-for-time-format
               (cons format
                     (let ((example (format-time-string format)))
                       (if (string-match-p (rx (any "^*+([\\")) example)
                           (error "org-node: Unable to safely rename with current `org-node-datestamp-format'.  This is not inherent in your choice of format, I am just not smart enough")
                         (concat "^"
                                 (string-replace
                                  "." "\\."
                                  (replace-regexp-in-string
                                   "[[:digit:]]+" "[[:digit:]]+"
                                   (replace-regexp-in-string
                                    "[[:alpha:]]+" "[[:alpha:]]+"
                                    example t)))))))))))

;; This function can be removed if one day we drop support for file-level
;; nodes, because then just (org-entry-get-with-inheritance "ID") will suffice.
;; That demonstrates the maintenance burden of supporting file-level nodes:
;; org-entry-get /can/ get the file-level ID but only sometimes.  Don't know
;; where's the bug in that case, but it's not a bug to prioritize in Org IMHO;
;; file-level property drawers were a mistake, they create the need for
;; special-case code all over the place, which leads to new bugs, and bring
;; very little to the table.  Even this workaround had a bug earlier, but we
;; shouldn't need to write workarounds in the first place.  Thanks for
;; listening.
(defun org-node-id-at-point ()
  "Get ID for current entry or up the outline tree."
  (save-excursion
    (without-restriction
      (or (org-entry-get-with-inheritance "ID")
          (progn (goto-char (point-min))
                 (org-entry-get-with-inheritance "ID"))))))

(defcustom org-node-renames-allowed-dirs nil
  "Dirs in which files may be auto-renamed.
Used by `org-node-rename-file-by-title'.

To add exceptions, see `org-node-renames-exclude'."
  :type '(repeat string))

(defcustom org-node-renames-exclude "\\(?:daily\\|dailies\\|journal\\)/"
  "Regexp matching paths of files not to auto-rename.
For use by `org-node-rename-file-by-title'.

Only applied to files under `org-node-renames-allowed-dirs'.  If
a file is not there, it is not considered in any case."
  :type 'string)

;;;###autoload
(defun org-node-rename-file-by-title (&optional interactive)
  "Rename the current file according to `org-node-slug-fn'.

Also attempt to check for a prefix in the style of
`org-node-datestamp-format', and avoid overwriting it.

Suitable at the end of `after-save-hook'.  If called from a hook
\(or from Lisp in general), only operate on files in
`org-node-renames-allowed-dirs'.  When called interactively as a
command, always prompt for confirmation.

Argument INTERACTIVE automatically set."
  (interactive "p" org-mode)
  ;; Apparently the variable `buffer-file-truename' returns an abbreviated path
  (let ((path (file-truename buffer-file-name))
        (buf (current-buffer))
        (title nil))
    (cond
     ((or (not (derived-mode-p 'org-mode))
          (not (equal "org" (file-name-extension path))))
      (when interactive
        (message "Will only rename Org files")))
     ((and (not interactive)
           (null org-node-renames-allowed-dirs))
      (message "User option `org-node-renames-allowed-dirs' should be configured"))
     ((or interactive
          (cl-loop
           for dir in (mapcar #'file-truename org-node-renames-allowed-dirs)
           if (string-match-p org-node-renames-exclude dir)
           do (user-error "Regexp `org-node-renames-exclude' would directly match a directory from `org-node-renames-allowed-dirs'")
           else if (and (string-prefix-p dir path)
                        (not (string-match-p org-node-renames-exclude path)))
           return t))
      (if (not (setq title (or (cadar (org-collect-keywords '("TITLE")))
                               ;; No #+title, so take first heading as title
                               ;; for this purpose
                               (save-excursion
                                 (without-restriction
                                   (goto-char 1)
                                   (or (org-at-heading-p)
                                       (outline-next-heading))
                                   (org-get-heading t t t t))))))
          (message "File has no title nor heading")

        (let* ((name (file-name-nondirectory path))
               (date-prefix (or (org-node-extract-file-name-datestamp path)
                                ;; Couldn't find date prefix, give a new one
                                (format-time-string org-node-datestamp-format)))
               (new-name
                (concat date-prefix (funcall org-node-slug-fn title) ".org"))
               (new-path
                (file-name-concat (file-name-directory path) new-name)))
          (cond
           ((equal path new-path)
            (when interactive
              (message "Filename already correct: %s" path)))
           ((or (buffer-modified-p buf)
                (buffer-modified-p (buffer-base-buffer buf)))
            (when interactive
              (message "Unsaved file, letting it be: %s" path)))
           ((find-buffer-visiting new-path)
            (user-error "Wanted to rename, but a buffer already visits target: %s"
                        new-path))
           ((not (file-writable-p path))
            (user-error "No permissions to rename file: %s"
                        path))
           ((not (file-writable-p new-path))
            (user-error "No permissions to write a new file at: %s"
                        new-path))
           ;; A bit unnecessary bc `rename-file' would error too,
           ;; but at least we didn't kill buffer yet
           ((file-exists-p new-path)
            (user-error "Canceled because a file exists at: %s"
                        new-path))
           ((or (not interactive)
                (y-or-n-p (format "Rename file %s to %s?" name new-name)))
            (let* ((pt (point))
                   (visible-window (get-buffer-window buf))
                   (window-start (window-start visible-window)))
              ;; Kill buffer before renaming, because it will not
              ;; follow the rename
              (kill-buffer buf)
              (rename-file path new-path)
              ;; REVIEW: Use `find-file'?
              (let ((new-buf (find-file-noselect new-path)))
                ;; Don't let remaining hooks operate on some random buffer
                ;; (we are possibly being called in the middle of a hook)
                (set-buffer new-buf)
                ;; Helpfully go back to where point was
                (when visible-window
                  (set-window-buffer-start-and-point
                   visible-window new-buf window-start pt))
                (with-current-buffer new-buf
                  (goto-char pt)
                  (if (org-at-heading-p) (org-show-entry) (org-show-context)))))
            (message "File %s renamed to %s" name new-name)))))))))

;; FIXME: Kill opened buffers.  First make sure it can pick up where it left
;;        off.  Maybe use `org-node--in-files-do'.
;;;###autoload
(defun org-node-rewrite-links-ask (&optional files)
  "Update desynced link descriptions, interactively.

Search all files, or just FILES if non-nil, for ID-links where
the link description has gotten out of sync from the
destination\\='s current title.

At each link, prompt for user consent, then auto-update the link
so it matches the destination\\='s current title."
  (interactive)
  (require 'ol)
  (require 'org-faces)
  (defface org-node--rewrite-face
    `((t :inherit 'org-link
         :inverse-video ,(not (face-inverse-video-p 'org-link))))
    "Face for use in `org-node-rewrite-links-ask'.")
  (org-node-cache-ensure)
  (when (org-node--consent-to-bothersome-modes-for-mass-edit)
    (let ((n-links 0)
          (n-files 0))
      (dolist (file (or files (org-node-list-files t)))
        (cl-incf n-files)
        (with-current-buffer (delay-mode-hooks (find-file-noselect file))
          (save-excursion
            (without-restriction
              (goto-char (point-min))
              (while-let ((end (re-search-forward org-link-bracket-re nil t)))
                (message "Checking... link %d (file #%d)"
                         (cl-incf n-links) n-files)
                (let* ((beg (match-beginning 0))
                       (link (substring-no-properties (match-string 0)))
                       (exact-link (rx (literal link)))
                       (parts (split-string link "]\\["))
                       (target (substring (car parts) 2))
                       (desc (when (cadr parts)
                               (substring (cadr parts) 0 -2)))
                       (id (when (string-prefix-p "id:" target)
                             (substring target 3)))
                       (node (gethash id org-node--id<>node))
                       (true-title (when node
                                     (org-node-get-title node)))
                       (answered-yes nil))
                  (when (and id node desc
                             (not (string-equal-ignore-case desc true-title))
                             (not (member-ignore-case
                                   desc (org-node-get-aliases node))))
                    (switch-to-buffer (current-buffer))
                    (goto-char end)
                    (if (org-at-heading-p)
                        (org-show-entry)
                      (org-show-context))
                    (recenter)
                    (highlight-regexp exact-link 'org-node--rewrite-face)
                    (unwind-protect
                        (setq answered-yes
                              (y-or-n-p
                               (format "Rewrite link? Will become:  \"%s\""
                                       true-title)))
                      (unhighlight-regexp exact-link))
                    (when answered-yes
                      (goto-char beg)
                      (atomic-change-group
                        (delete-region beg end)
                        (insert (org-link-make-string target true-title)))
                      ;; Give user a moment to glimpse the result before hopping
                      ;; to the next link in case of a replacement gone wrong
                      (redisplay)
                      (sleep-for .15))
                    (goto-char end)))))))))))

;;;###autoload
(defun org-node-rename-asset-and-rewrite-links ()
  "Helper for renaming images and all links that point to them.

Prompt for an asset such as an image file to be renamed, then search
recursively for Org files containing a link to that asset, open a wgrep
buffer of the search hits, and start an interactive search-replace that
updates the links.  After the user consents or doesn\\='t consent to
replacing all the links, finally rename the asset file itself.  If the
user quits, do not apply any modifications."
  (interactive)
  (unless (require 'wgrep nil t)
    (user-error "This command requires the wgrep package"))
  (when (and (fboundp 'wgrep-change-to-wgrep-mode)
             (fboundp 'wgrep-finish-edit))
    (let ((root (car (org-node--root-dirs (org-node-list-files))))
          (default-directory default-directory))
      (or (equal default-directory root)
          (if (y-or-n-p (format "Go to folder \"%s\"?" root))
              (setq default-directory root)
            (setq default-directory
                  (read-directory-name
                   "Directory with Org notes to operate on: "))))
      (when-let ((bufs (seq-filter (##string-search "*grep*" (buffer-name %))
                                   (buffer-list))))
        (when (yes-or-no-p "Kill other *grep* buffers to be sure this works?")
          (mapc #'kill-buffer bufs)))
      (let* ((filename (file-relative-name (read-file-name "File to rename: ")))
             (new (read-string "New name: " filename)))
        (mkdir (file-name-directory new) t)
        (unless (file-writable-p new)
          (error "New path wouldn't be writable"))
        (rgrep (regexp-quote filename) "*.org")
        ;; HACK Doesn't work right away, so wait a sec, then it works
        (run-with-timer
         1 nil
         (lambda ()
           (pop-to-buffer (seq-find (##string-search "*grep*" (buffer-name %))
                                    (buffer-list)))
           (wgrep-change-to-wgrep-mode)
           (goto-char (point-min))
           ;; Interactive replaces
           (query-replace filename new)
           ;; NOTE: If the user quits the replaces with C-g, the following code
           ;;       never runs, which is good.
           (when (buffer-modified-p)
             (wgrep-finish-edit)
             (rename-file filename new)
             (message "File renamed from %s to %s" filename new))))
        (message "Waiting for rgrep to populate buffer...")))))

;;;###autoload
(defun org-node-insert-heading ()
  "Insert a heading with ID and run `org-node-creation-hook'."
  (interactive nil org-mode)
  (org-insert-heading)
  (org-node-nodeify-entry))

;;;###autoload
(defun org-node-nodeify-entry ()
  "Add an ID to entry at point and run `org-node-creation-hook'."
  (interactive nil org-mode)
  (org-node-cache-ensure)
  (org-id-get-create)
  (run-hooks 'org-node-creation-hook))

;;;###autoload
(defun org-node-put-created ()
  "Add a CREATED property to entry at point, if none already."
  (interactive nil org-mode)
  (unless (org-entry-get nil "CREATED")
    (org-entry-put nil "CREATED"
                   (format-time-string (org-time-stamp-format t t)))))

(defvar org-node--temp-extra-fns nil
  "Extra functions to run at the end of a full scan.
The list is emptied on each use.  Primarily exists to give the
interactive command `org-node-reset' a way to print the time
elapsed.")

;;;###autoload
(defun org-node-reset ()
  "Wipe and rebuild the cache."
  (interactive)
  (cl-pushnew #'org-node--print-elapsed org-node--temp-extra-fns)
  (org-node-cache-ensure nil t))

;;;###autoload
(defun org-node-forget-dir (dir)
  "Remove references in `org-id-locations' to files in DIR.

Note that if DIR can be found under `org-node-extra-id-dirs',
this action may make no practical impact unless you also add DIR
to `org-node-extra-id-dirs-exclude'.

In case of unsolvable problems, how to wipe org-id-locations:

\(progn
 (delete-file org-id-locations-file)
 (setq org-id-locations nil)
 (setq org-id--locations-checksum nil)
 (setq org-agenda-text-search-extra-files nil)
 (setq org-id-files nil)
 (setq org-id-extra-files nil))"
  (interactive "DForget all IDs in directory: ")
  (org-node-cache-ensure t)
  (let ((files
         (org-node-abbrev-file-names
          (nconc
           (org-node--dir-files-recursively (file-truename dir) ".org_exclude" nil)
           (org-node--dir-files-recursively (file-truename dir) ".org" nil)))))
    (when files
      (message "Forgetting all IDs in directory %s..." dir)
      (redisplay)
      (org-node--forget-id-locations files)
      (dolist (file files)
        (remhash file org-node--file<>mtime.elapsed))
      (org-id-locations-save)
      (org-node-reset))))

;;;###autoload
(defun org-node-grep ()
  "Grep across all files known to org-node."
  (interactive)
  (unless (require 'consult nil t)
    (user-error "This command requires the consult package"))
  (require 'consult)
  (org-node-cache-ensure)
  ;; Prevent consult from turning the names relative, with such enlightening
  ;; directory paths as ../../../../../../.
  (cl-letf (((symbol-function #'file-relative-name)
             (lambda (name &optional _dir) name)))
    (let ((consult-ripgrep-args (concat consult-ripgrep-args " --type=org")))
      (if (executable-find "rg")
          (consult--grep "Grep in all known Org files: "
                         #'consult--ripgrep-make-builder
                         (org-node--root-dirs (org-node-list-files t))
                         nil)
        ;; Much slower, no --type=org means must target thousands of files
        ;; and not a handful of dirs
        (consult--grep "Grep in all known Org files: "
                       #'consult--grep-make-builder
                       (org-node-list-files)
                       nil)))))

(defvar org-node--unlinted nil)
(defvar org-node--lint-warnings nil)
(defun org-node-lint-all ()
  "Run `org-lint' on all known Org files, and report results.

If last run was interrupted, resume working through the file list
from where it stopped.  With prefix argument, start over
from the beginning."
  (interactive)
  (require 'org-lint)
  (org-node--init-ids)
  (when (or (equal current-prefix-arg '(4))
            (and (null org-node--unlinted)
                 (y-or-n-p (format "Lint %d files?"
                                   (length (org-node-list-files t))))))
    (setq org-node--unlinted (org-node-list-files t))
    (setq org-node--lint-warnings nil))
  (setq org-node--unlinted
        (org-node--in-files-do
          :files org-node--unlinted
          :msg "Running org-lint (you may quit and resume anytime)"
          :about-to-do "About to visit a file to run org-lint"
          :call (lambda ()
                  (when-let ((warning (org-lint)))
                    (push (cons buffer-file-name (car warning))
                          org-node--lint-warnings)))))
  (when org-node--lint-warnings
    (org-node--pop-to-tabulated-list
     :buffer "*org lint results*"
     :format [("File" 30 t) ("Line" 5 t) ("Trust" 5 t) ("Explanation" 0 t)]
     :reverter #'org-node-lint-all
     :entries (cl-loop
               for (file . warning) in org-node--lint-warnings
               collect (let ((array (cadr warning)))
                         (list warning
                               (vector
                                (list (file-name-nondirectory file)
                                      'face 'link
                                      'action `(lambda (_button)
                                                 (find-file ,file)
                                                 (goto-line ,(string-to-number
                                                              (elt array 0))))
                                      'follow-link t)
                                (elt array 0)
                                (elt array 1)
                                (elt array 2))))))))

(defun org-node-list-feedback-arcs ()
  "Show a feedback-arc-set of forward id-links.

Requires GNU R installed, with R packages stringr, readr, igraph.

A feedback arc set is a set of links such that if they are all
cut (though sometimes it suffices to reverse the direction rather
than cut them), the remaining links in the network will
constitute a DAG (directed acyclic graph).

You may consider this as merely one of many ways to view your
network to quality-control it.  Rationale:

    https://edstrom.dev/zvjjm/slipbox-workflow#ttqyc"
  (interactive)
  (unless (executable-find "Rscript")
    (user-error
     "This command requires GNU R, with R packages: stringr, readr, igraph"))
  (let ((r-code "library(stringr)
library(readr)
library(igraph)

tsv <- commandArgs(TRUE)[1]
g <- graph_from_data_frame(read_tsv(tsv), directed = TRUE)
fas1 <- feedback_arc_set(g, algo = \"approx_eades\")

lisp_data <- str_c(\"(\\\"\", as_ids(fas1), \"\\\")\") |>
  str_replace(\"\\\\|\", \"\\\" . \\\"\") |>
  str_flatten(\"\n \") |>
  (function(x) {
    str_c(\"(\", x, \")\")
  })()

write_file(lisp_data, file.path(dirname(tsv), \"feedback-arcs.eld\"))")
        (script-file (org-node--tmpfile "analyze_feedback_arcs.R"))
        (input-tsv (org-node--tmpfile "id_node_digraph.tsv")))
    (write-region r-code () script-file () 'quiet)
    (write-region (org-node--make-digraph-tsv-string) () input-tsv () 'quiet)
    (with-temp-buffer
      (unless (= 0 (call-process "Rscript" () t () script-file input-tsv))
        (error "%s" (buffer-string))))
    (let ((feedbacks (with-temp-buffer
                       (insert-file-contents
                        (org-node--tmpfile "feedback-arcs.eld"))
                       (read (buffer-string)))))
      (when (listp feedbacks)
        (org-node--pop-to-tabulated-list
         :buffer "*org-node feedback arcs*"
         :format [("Node containing link" 39 t) ("Target of link" 0 t)]
         :entries (cl-loop
                   for (origin . dest) in feedbacks
                   as origin-node = (gethash origin org-node--id<>node)
                   as dest-node = (gethash dest org-node--id<>node)
                   collect
                   (list (cons origin dest)
                         (vector (list (org-node-get-title origin-node)
                                       'face 'link
                                       'action `(lambda (_button)
                                                  (org-node--goto ,origin-node))
                                       'follow-link t)
                                 (list (org-node-get-title dest-node)
                                       'face 'link
                                       'action `(lambda (_button)
                                                  (org-node--goto ,dest-node))
                                       'follow-link t)))))))))

;; TODO: Temp merge all refs into corresponding ID
(defun org-node--make-digraph-tsv-string ()
  "Generate a string in Tab-Separated Values form.
The string is a 2-column table of destination-origin pairs, made
from ID links found in `org-node--dest<>links'."
  (concat
   "src\tdest\n"
   (string-join
    (seq-uniq (cl-loop
               for dest being the hash-keys of org-node--dest<>links
               using (hash-values links)
               append (cl-loop
                       for link in links
                       when (equal "id" (org-node-link-type link))
                       collect (concat dest "\t" (org-node-link-origin link)))))
    "\n")))

(cl-defun org-node--pop-to-tabulated-list (&key buffer format entries reverter)
  "Boilerplate abstraction.
BUFFER is a buffer or buffer name where the list should be created.
FORMAT is the value to which `tabulated-list-format' should be set.
ENTRIES is the value to which `tabulated-list-entries' should be set.

Optional argument REVERTER is a function to add locally to
`tabulated-list-revert-hook'."
  (unless (and buffer format)
    (user-error
     "org-node--pop-to-tabulated-list: Mandatory arguments are buffer, format, entries"))
  (when (null entries)
    (message "No entries to tabulate"))
  (pop-to-buffer (get-buffer-create buffer))
  (tabulated-list-mode)
  (setq tabulated-list-format format)
  (tabulated-list-init-header)
  (setq tabulated-list-entries entries)
  (when reverter (add-hook 'tabulated-list-revert-hook reverter nil t))
  (tabulated-list-print t))

(defvar org-node--found-systems nil)
(defvar org-node--list-file-coding-systems-files nil)
(defun org-node-list-file-coding-systems ()
  "Check coding systems of files found by `org-node-list-files'.
This is done by temporarily visiting each file and checking what
Emacs decides to decode it as.  To start over, run the command
with \\[universal-argument] prefix."
  (interactive)
  (when (or (equal current-prefix-arg '(4))
            (and (null org-node--list-file-coding-systems-files)
                 (y-or-n-p (format "Check coding systems in %d files?  They will not be modified."
                                   (length (org-node-list-files t))))))
    (setq org-node--list-file-coding-systems-files (org-node-list-files t))
    (setq org-node--found-systems nil))
  (setq org-node--list-file-coding-systems-files
        (org-node--in-files-do
          :files org-node--list-file-coding-systems-files
          :fundamental-mode t
          :msg "Checking file coding systems (quit and resume anytime)"
          :about-to-do "About to check file coding system"
          :call (lambda ()
                  (push (cons buffer-file-name buffer-file-coding-system)
                        org-node--found-systems))))
  (org-node--pop-to-tabulated-list
   :buffer "*org file coding systems*"
   :format [("Coding system" 20 t) ("File" 40 t)]
   :entries (cl-loop for (file . sys) in org-node--found-systems
                     collect (list file (vector (symbol-name sys) file)))
   :reverter #'org-node-list-file-coding-systems))

(defun org-node-list-dead-links ()
  "List links that lead to no known ID."
  (interactive)
  (let ((dead-links
         (cl-loop for dest being the hash-keys of org-node--dest<>links
                  using (hash-values links)
                  unless (gethash dest org-node--id<>node)
                  append (cl-loop for link in links
                                  when (equal "id" (org-node-link-type link))
                                  collect (cons dest link)))))
    (message "%d dead links found" (length dead-links))
    (when dead-links
      (org-node--pop-to-tabulated-list
       :buffer "*dead links*"
       :format [("Location" 40 t) ("Unknown ID reference" 40 t)]
       :reverter #'org-node-list-dead-links
       :entries
       (cl-loop
        for (dest . link) in dead-links
        as origin-node = (gethash (org-node-link-origin link)
                                  org-node--id<>node)
        if (not (equal dest (org-node-link-dest link)))
        do (error "IDs not equal: %s, %s" dest (org-node-link-dest link))
        else if (not origin-node)
        do (error "Node not found for ID: %s" (org-node-link-origin link))
        else collect
        (list link
              (vector
               (list (org-node-get-title origin-node)
                     'face 'link
                     'action `(lambda (_button)
                                (org-node--goto ,origin-node)
                                (goto-char ,(org-node-link-pos link)))
                     'follow-link t)
               dest)))))))

(defun org-node-list-reflinks ()
  "List all reflinks and their locations.

Useful to see how many times you\\='ve inserted a link that is very
similar to another link, but not identical, so that likely only
one of them is associated with a ROAM_REFS property."
  (interactive)
  (let ((plain-links (cl-loop
                      for list being the hash-values of org-node--dest<>links
                      append (cl-loop
                              for link in list
                              unless (equal "id" (org-node-link-type link))
                              collect link))))
    ;; (cl-letf ((truncate-string-ellipsis " "))
    (if plain-links
        (org-node--pop-to-tabulated-list
         :buffer "*org-node reflinks*"
         :format [("Ref" 4 t) ("Inside node" 30 t) ("Link" 0 t)]
         :reverter #'org-node-list-reflinks
         :entries
         (cl-loop
          for link in plain-links
          collect (let ((type (org-node-link-type link))
                        (dest (org-node-link-dest link))
                        (origin (org-node-link-origin link))
                        (pos (org-node-link-pos link)))
                    (let ((node (gethash origin org-node--id<>node)))
                      (list link
                            (vector
                             (if (gethash dest org-node--ref<>id) "*" "")
                             (if node
                                 (list (org-node-get-title node)
                                       'action `(lambda (_button)
                                                  (org-id-goto ,origin)
                                                  (goto-char ,pos)
                                                  (if (org-at-heading-p)
                                                      (org-show-entry)
                                                    (org-show-context)))
                                       'face 'link
                                       'follow-link t)
                               origin)
                             (if type (concat type ":" dest) dest)))))))
      (message "No links found"))))

(defcustom org-node-warn-title-collisions t
  "Whether to print messages on finding duplicate node titles."
  :group 'org-node
  :type 'boolean)

(defvar org-node--collisions nil
  "Alist of node title collisions.")

(defun org-node-list-collisions ()
  "Pop up a buffer listing node title collisions."
  (interactive)
  (if org-node--collisions
      (org-node--pop-to-tabulated-list
       :buffer "*org-node title collisions*"
       :format [("Non-unique name" 30 t) ("ID" 37 t) ("Other ID" 0 t)]
       :reverter #'org-node-list-collisions
       :entries (cl-loop
                 for row in org-node--collisions
                 collect (seq-let (msg id1 id2) row
                           (list row
                                 (vector msg
                                         (list id1
                                               'action `(lambda (_button)
                                                          (org-id-goto ,id1))
                                               'face 'link
                                               'follow-link t)
                                         (list id2
                                               'action `(lambda (_button)
                                                          (org-id-goto ,id2))
                                               'face 'link
                                               'follow-link t))))))
    (message "Congratulations, no title collisions! (in %d filtered nodes)"
             (hash-table-count org-node--title<>id))))

(defvar org-node--problems nil
  "Alist of errors encountered by org-node-parser.")

(defun org-node-list-scan-problems ()
  "Pop up a buffer listing errors found by org-node-parser."
  (interactive)
  (if org-node--problems
      (org-node--pop-to-tabulated-list
       :buffer "*org-node scan problems*"
       :format [("Scan choked near position" 27 t) ("Issue (newest on top)" 0 t)]
       :reverter #'org-node-list-scan-problems
       :entries (cl-loop
                 for problem in org-node--problems
                 collect (seq-let (file pos signal) problem
                           (list problem
                                 (vector (list
                                          (format "%s:%d"
                                                  (file-name-nondirectory file) pos)
                                          'face 'link
                                          'action `(lambda (_button)
                                                     (find-file ,file)
                                                     (goto-char ,pos))
                                          'follow-link t)
                                         (format "%s" signal))))))
    (message "Congratulations, no problems scanning %d nodes!"
             (hash-table-count org-node--id<>node))))

;; Very important macro for the backlink mode, because backlink insertion opens
;; the target Org file in the background, and if doing that is laggy, then
;; every link insertion is laggy.
(defmacro org-node--with-quick-file-buffer (file &rest body)
  "Pseudo-backport of Emacs 29 `org-with-file-buffer'.
Also integrates `org-with-wide-buffer' behavior, and tries to
execute minimal hooks in order to open and close FILE as quickly
as possible.

In detail:

1. If a buffer was visiting FILE, reuse that buffer, else visit
   FILE in a new buffer, in which case ignore most of the Org
   startup checks and don\\='t ask about file-local variables.

2. Temporarily `widen' the buffer, execute BODY, then restore
   point.

3a. If a new buffer had to be opened: save and kill it.
    \(Mandatory because buffers opened in the quick way look
    \"wrong\", e.g. no indent-mode, no visual wrap etc.)  Also
    skip any save hooks and kill hooks.

3b. If a buffer had been open: leave it open and leave it
    unsaved.

Optional keyword argument ABOUT-TO-DO as in
`org-node--in-files-do'.

\(fn FILE [:about-to-do ABOUT-TO-DO] &rest BODY)"
  (declare (indent 1) (debug t))
  (let ((why (if (eq (car body) :about-to-do)
                 (progn (pop body) (pop body))
               "Org-node is about to look inside a file")))
    `(let ((enable-local-variables :safe)
           (org-inhibit-startup t) ;; Don't apply startup #+options
           (find-file-hook nil)
           (after-save-hook nil)
           (before-save-hook nil)
           (org-agenda-files nil)
           (kill-buffer-hook nil) ;; Inhibit save-place etc
           (kill-buffer-query-functions nil)
           (buffer-list-update-hook nil))
       ;; The cache is buggy, disable to be safe
       (org-element-with-disabled-cache
         (let* ((--was-open-- (find-buffer-visiting ,file))
                (--file-- (org-node-abbrev-file-names (file-truename ,file)))
                (_ (if (file-directory-p --file--)
                       (error "Is a directory: %s" --file--)))
                (--buf-- (or --was-open--
                             (delay-mode-hooks
                               (org-node--find-file-noselect --file-- ,why)))))
           (when (bufferp --buf--)
             (with-current-buffer --buf--
               (save-excursion
                 (without-restriction
                   ,@body))
               (if --was-open--
                   ;; Because the cache gets confused by changes
                   (org-element-cache-reset)
                 (when (buffer-modified-p)
                   (let ((save-silently t)
                         (inhibit-message t))
                     (save-buffer)))
                 (kill-buffer)))))))))

(define-error 'org-node-must-retry "Unexpected signal org-node-must-retry")

;; TODO: Maybe have it prompt to kill all buffers prior to start
(cl-defun org-node--in-files-do
    (&key files fundamental-mode msg about-to-do call too-many-files-hack)
  "Temporarily visit each file in FILES and call function CALL.

Take care!  This function presumes that FILES satisfy the assumptions
made by `org-node--find-file-noselect'.  This is safe if FILES is
the output of `org-node-list-files', but easily violated otherwise.

While the loop runs, print a message every now and then, composed
of MSG and a counter for the amount of files left to visit.

On running across a problem such as the auto-save being newer
than the original, prompt the user to recover it using
ABOUT-TO-DO to clarify why the file is about to be accessed, and
break the loop when the user declines.

If the user quits mid-way through the loop, or it is broken,
return the remainder of FILES that have not yet been visited.

In each file visited, the behavior is much like
`org-node--with-quick-file-buffer'.

The files need not be Org files, and if optional argument
FUNDAMENTAL-MODE is t, do not activate any major mode.

If a buffer had already been visiting FILE, reuse that buffer.
Naturally, FUNDAMENTAL-MODE has no effect in that case.

For explanation of TOO-MANY-FILES-HACK, see code comments."
  (declare (indent defun))
  (cl-assert (and msg files call about-to-do))
  (setq call (org-node--ensure-compiled call))
  (let ((enable-local-variables :safe)
        (org-inhibit-startup t) ;; Don't apply startup #+options
        (file-name-handler-alist nil)
        ;; (coding-system-for-read org-node-perf-assume-coding-system)
        (find-file-hook nil)
        (after-save-hook nil)
        (before-save-hook nil)
        (org-agenda-files nil)
        (kill-buffer-hook nil) ;; Inhibit save-place etc
        (kill-buffer-query-functions nil)
        (write-file-functions nil) ;; recentf-track-opened-file
        (buffer-list-update-hook nil))
    (let ((files* files)
          interval
          file
          was-open
          buf
          (start-time (current-time))
          (ctr 0))
      ;; The cache is buggy, disable to be safe
      (org-element-with-disabled-cache
        (condition-case err
            (while files*
              (cl-incf ctr)
              (when (zerop (% ctr 200))
                ;; Reap open file handles (max is 1024, and Emacs bug can keep
                ;; them open during the loop despite killed buffers)
                (garbage-collect)
                (when too-many-files-hack
                  ;; Sometimes necessary to drop the call stack to actually
                  ;; reap file handles, sometimes not.  Don't understand it.
                  ;; E.g. `org-node-lint-all' does not seem to need this hack,
                  ;; but `org-node-backlink-fix-all-files' does.
                  (signal 'org-node-must-retry nil)))
              (if interval
                  (when (zerop (% ctr interval))
                    (message "%s... %d files to go" msg (length files*)))
                ;; Set a reasonable interval between `message' calls, since they
                ;; can be surprisingly expensive.
                (when (> (float-time (time-since start-time)) 0.3)
                  (setq interval ctr)))
              (setq file (pop files*))
              (setq was-open (find-buffer-visiting file))
              (setq buf (or was-open
                            (if fundamental-mode
                                (let (auto-mode-alist)
                                  (org-node--find-file-noselect
                                   file about-to-do))
                              (delay-mode-hooks
                                (org-node--find-file-noselect
                                 file about-to-do)))))
              (when buf
                (with-current-buffer buf
                  (save-excursion
                    (without-restriction
                      (funcall call)))
                  (unless was-open
                    (when (buffer-modified-p)
                      (let ((save-silently t)
                            (inhibit-message t))
                        (save-buffer)))
                    (kill-buffer)))))
          (( org-node-must-retry )
           (run-with-timer .1 nil #'org-node--in-files-do
                           :msg msg
                           :about-to-do about-to-do
                           :fundamental-mode fundamental-mode
                           :files files*
                           :call call
                           :too-many-files-hack too-many-files-hack)
           ;; Because of the hack, the caller only receives `files*' once, and
           ;; each timer run after that won't modify
           ;; `org-node-backlink--files-to-fix', so try to modify as a nicety.
           ;; This works until the last iteration, because a cons cell cannot
           ;; be destructively reassigned to nil.
           (setcar files (car files*))
           (setcdr files (cdr files*))
           files*)
          (( quit )
           (unless (or was-open (not buf) (buffer-modified-p buf))
             (kill-buffer buf))
           (cons file files*))
          (( error )
           (lwarn 'org-node :warning "%s: Loop interrupted by signal %S\n\tBuffer: %s\n\tFile: %s\n\tNext file: %s\n\tValue of ctr: %d"
                  (format-time-string "%T") err buf file (car files*) ctr)
           (unless (or was-open (not buf) (buffer-modified-p buf))
             (kill-buffer buf))
           files*)
          (:success
           (when too-many-files-hack
             (message "%s... done" msg))
           nil))))))

;; Somewhat faster than `find-file-noselect', not benchmarked.
;; More importantly, the way it fails is better suited for loop usage, IMO.
;; Also better for silent background usage.  The argument ABOUT-TO-DO clarifies
;; what would otherwise be a mysterious error that's difficult for the user to
;; track down to this package.
(defun org-node--find-file-noselect (abbr-truename about-to-do)
  "Read file ABBR-TRUENAME into a buffer and return the buffer.
If there's a problem such as an auto-save file being newer, prompt the
user to proceed with a message based on string ABOUT-TO-DO, else do
nothing and return nil.

Very presumptive!  Like `find-file-noselect' but intended as a
subroutine for `org-node--in-files-do' or any program that has
already ensured that ABBR-TRUENAME:

- is an abbreviated file truename dissatisfying `backup-file-name-p'
- is not being visited by any other buffer
- is not a directory"
  (let ((attrs (file-attributes abbr-truename))
        (buf (create-file-buffer abbr-truename)))
    (when (null attrs)
      (kill-buffer buf)
      (error "File appears to be gone/renamed: %s" abbr-truename))
    (if (or (not (and large-file-warning-threshold
                      (> (file-attribute-size attrs)
                         large-file-warning-threshold)))
            (y-or-n-p
             (format "%s, but file %s is large (%s), open anyway? "
                     about-to-do
                     (file-name-nondirectory abbr-truename)
                     (funcall byte-count-to-string-function
                              large-file-warning-threshold))))
        (with-current-buffer buf
          (condition-case nil
              (progn (insert-file-contents abbr-truename t)
                     (set-buffer-multibyte t))
	    (( file-error )
             (kill-buffer buf)
             (error "Problems reading file: %s" abbr-truename)))
          (setq buffer-file-truename abbr-truename)
          (setq buffer-file-number (file-attribute-file-identifier attrs))
          (setq default-directory (file-name-directory buffer-file-name))
          (if (and (not (and buffer-file-name auto-save-visited-file-name))
                   (file-newer-than-file-p (or buffer-auto-save-file-name
				               (make-auto-save-file-name))
			                   buffer-file-name))
              ;; Could try to call `recover-file' here, but I'm not sure the
              ;; resulting behavior would be sane, so just bail
              (progn
                (message "%s, but skipped because it has an auto-save file: %s"
                         about-to-do buffer-file-name)
                nil)
            (normal-mode t)
            (current-buffer)))
      (message "%s, but skipped because file exceeds `large-file-warning-threshold': %s"
               about-to-do buffer-file-name)
      nil)))


;;;; Commands to add tags/refs/alias

;; REVIEW: Is this a sane logic for picking heading?  It does not mirror how
;;         org-set-tags-command picks heading to apply to, and maybe that is
;;         the behavior to model.
;;         Maybe simplify it for v2.
(defun org-node--call-at-nearest-node (function &rest args)
  "With point at the relevant heading, call FUNCTION with ARGS.

Prefer the closest ancestor heading that has an ID, else go to
the file-level property drawer if that contains an ID, else fall
back on the heading for the current entry.

Afterwards, maybe restore point to where it had been previously,
so long as the affected heading would still be visible in the
window."
  (let* ((where-i-was (point-marker))
         (id (org-node-id-at-point))
         (heading-pos
          (save-excursion
            (without-restriction
              (when id
                (goto-char (point-min))
                (re-search-forward
                 (rx bol (* space) ":ID:" (+ space) (literal id))))
              (org-back-to-heading-or-point-min)
              (point)))))
    (when (and heading-pos (< heading-pos (point-min)))
      (widen))
    (save-excursion
      (when heading-pos
        (goto-char heading-pos))
      (apply function args))
    (when heading-pos
      (unless (pos-visible-in-window-p heading-pos)
        (goto-char heading-pos)
        (recenter 0)
        (when (pos-visible-in-window-p where-i-was)
          (forward-char (- where-i-was (point))))))
    (set-marker where-i-was nil)))

(defun org-node--add-to-property-keep-space (property value)
  "Add VALUE to PROPERTY for node at point.

If the current entry has no ID, operate on the closest ancestor
with an ID.  If there\\='s no ID anywhere, operate on the current
entry.

Then behave like `org-entry-add-to-multivalued-property' but
preserve spaces: instead of percent-escaping each space character
as \"%20\", wrap the value in quotes if it has spaces."
  (org-node--call-at-nearest-node
   (lambda ()
     (let ((old (org-entry-get nil property)))
       (when old
         (setq old (split-string-and-unquote old)))
       (unless (member value old)
         (org-entry-put nil property (combine-and-quote-strings
                                      (cons value old))))))))

(defun org-node-alias-add ()
  "Add to ROAM_ALIASES in nearest relevant property drawer."
  (interactive nil org-mode)
  (org-node--add-to-property-keep-space
   "ROAM_ALIASES" (string-trim (read-string "Alias: "))))

;; FIXME: What if user yanks a [cite:... ... ...]?
(defun org-node-ref-add ()
  "Add to ROAM_REFS in nearest relevant property drawer.
Wrap the value in double-brackets if necessary."
  (interactive nil org-mode)
  (let ((ref (string-trim (read-string "Ref: "))))
    (when (and (string-match-p " " ref)
               (string-match-p org-link-plain-re ref))
      ;; If it is a link, it should be enclosed in brackets
      (setq ref (concat "[[" (string-trim ref (rx "[[") (rx "]]"))
                        "]]")))
    (org-node--add-to-property-keep-space "ROAM_REFS" ref)))

(defun org-node--read-tag ()
  "Prompt for an Org tag.
Pre-fill completions by collecting tags from all known ID-nodes, as well
as the members of `org-tag-persistent-alist' and `org-tag-alist'.

Also collect current buffer tags, but only if `org-element-use-cache' is
non-nil, because it can cause noticeable latency."
  (completing-read-multiple
   "Tag: "
   (delete-dups
    (nconc (thread-last (append org-tag-persistent-alist
                                org-tag-alist
                                (when org-element-use-cache
                                  (org-get-buffer-tags)))
                        (mapcar #'car)
                        (mapcar #'substring-no-properties)
                        (cl-remove-if #'keywordp))
           (cl-loop for node being each hash-value of org-node--id<>node
                    append (org-node-get-tags-with-inheritance node))))))

(defun org-node-tag-add (tag-or-tags)
  "Add TAG-OR-TAGS to the node at point.
To always operate on the local entry, try `org-node-tag-add*'."
  (interactive (list (org-node--read-tag)) org-mode)
  (org-node--call-at-nearest-node #'org-node-tag-add* tag-or-tags))

(defun org-node-tag-add* (tag-or-tags)
  "Add TAG-OR-TAGS to the entry at point."
  (interactive (list (org-node--read-tag)) org-mode)
  (if (= (org-outline-level) 0)
      ;; There's no Org builtin to set filetags yet
      (let* ((tags (cl-loop
                    for raw in (cdar (org-collect-keywords '("FILETAGS")))
                    append (split-string raw ":" t)))
             (new-tags (seq-uniq (append (ensure-list tag-or-tags) tags)))
             (case-fold-search t))
        (save-excursion
          (without-restriction
            (goto-char 1)
            (if (search-forward "\n#+filetags:" nil t)
                (progn
                  (skip-chars-forward " ")
                  (atomic-change-group
                    (delete-region (point) (pos-eol))
                    (insert ":" (string-join new-tags ":") ":")))
              (if (re-search-forward "^[^:#]" nil t)
                  (progn
                    (backward-char 1)
                    (skip-chars-backward "\n\t\s"))
                (goto-char (point-max)))
              (newline)
              (insert "#+filetags: :" (string-join new-tags ":") ":")))))
    (save-excursion
      (org-back-to-heading)
      (org-set-tags (seq-uniq (append (ensure-list tag-or-tags)
                                      (org-get-tags)))))))


;;;; CAPF (Completion-At-Point Function)

(defun org-node-complete-at-point ()
  "Complete word at point to a known node title, and linkify.
Designed for `completion-at-point-functions', which see."
  (when-let ((bounds (bounds-of-thing-at-point 'word)))
    (and (not (org-in-src-block-p))
         (not (save-match-data (org-in-regexp org-link-any-re)))
         (list (car bounds)
               (cdr bounds)
               org-node--title<>id
               :exclusive 'no
               :exit-function
               (lambda (text _)
                 (when-let ((id (gethash text org-node--title<>id)))
                   (atomic-change-group
                     (delete-char (- (length text)))
                     (insert (org-link-make-string (concat "id:" id) text)))
                   (run-hooks 'org-node-insert-link-hook)))))))

(define-minor-mode org-node-complete-at-point-local-mode
  "Let completion at point insert links to nodes.

-----"
  :require 'org-node
  (if org-node-complete-at-point-local-mode
      (add-hook 'completion-at-point-functions
                #'org-node-complete-at-point nil t)
    (remove-hook 'completion-at-point-functions
                 #'org-node-complete-at-point t)))

(defun org-node-complete-at-point--enable-if-org ()
  "Enable `org-node-complete-at-point-local-mode' in Org buffer."
  (and (derived-mode-p 'org-mode)
       buffer-file-name
       (org-node-complete-at-point-local-mode)))

(define-globalized-minor-mode org-node-complete-at-point-mode
  org-node-complete-at-point-local-mode
  org-node-complete-at-point--enable-if-org)


;;;; Misc

(defun org-node-convert-link-to-super (&rest _)
  "Drop input and call `org-super-links-convert-link-to-super'."
  (require 'org-super-links)
  (when (fboundp 'org-super-links-convert-link-to-super)
    (org-super-links-convert-link-to-super nil)))

(defun org-node-try-visit-ref-node ()
  "Designed for `org-open-at-point-functions'.

For the link at point, if there exists an org-ID node that has
the link in its ROAM_REFS property, visit that node rather than
following the link normally.

If already visiting that node, then follow the link normally."
  (when-let ((url (thing-at-point 'url)))
    ;; Rarely more than one car
    (let* ((dest (car (org-node-parser--split-refs-field url)))
           (found (cl-loop for node being the hash-values of org-nodes
                           when (member dest (org-node-get-refs node))
                           return node)))
      (if (and found
               ;; Check that point is not already in said ref node (if so,
               ;; better to fallback to default `org-open-at-point' logic)
               (not (and (derived-mode-p 'org-mode)
                         (equal (org-node-id-at-point)
                                (org-node-get-id found)))))
          (progn (org-node--goto found)
                 t)
        nil))))


;;;; API not used inside this package

(defun org-node-at-point ()
  "Return the ID-node near point.

This may refer to the current Org heading, else an ancestor
heading, else the file-level node, whichever has an ID first."
  (gethash (org-node-id-at-point) org-node--id<>node))

(defun org-node-read ()
  "Prompt for a known ID-node."
  (gethash (completing-read "Node: " #'org-node-collection
                            () () () 'org-node-hist)
           org-node--candidate<>node))

(defun org-node-series-goto (key sortstr)
  "Visit an entry in series identified by KEY.
The entry to visit has sort-string SORTSTR.  Create if it does
not exist."
  (let* ((series (cdr (assoc key org-node-built-series)))
         (item (assoc sortstr (plist-get series :sorted-items))))
    (when (or (null item)
              (if (funcall (plist-get series :try-goto) item)
                  nil
                (delete item (plist-get series :sorted-items))
                t))
      (funcall (plist-get series :creator) sortstr key))))

(provide 'org-node)

;;; org-node.el ends here
