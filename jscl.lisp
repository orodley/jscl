;;; jscl.lisp ---

;; Copyright (C) 2012, 2013 David Vazquez
;; Copyright (C) 2012 Raimon Grau

;; JSCL is free software: you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation, either version 3 of the
;; License, or (at your option) any later version.
;;
;; JSCL is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with JSCL.  If not, see <http://www.gnu.org/licenses/>.

(defpackage :jscl
  (:use :cl)
  (:export #:bootstrap #:run-tests-in-host))

(in-package :jscl)

(defvar *source*
  '(("boot"             :target)
    ("compat"           :host)
    ("utils"            :both)
    ("numbers"          :target)
    ("char"             :target)
    ("list"             :target)
    ("array"            :target)
    ("string"           :target)
    ("sequence"         :target)
    ("print"            :target)
    ("package"          :target)
    ("misc"             :target)
    ("ffi"              :both)
    ("read"             :both)
    ("defstruct"        :both)
    ("lambda-list"      :both)
    ("backquote"        :both)
    ("compiler"         :both)
    ("toplevel"         :target)))

(defun source-pathname
    (filename &key (directory '(:relative "src")) (type nil) (defaults filename))
  (if type
      (make-pathname :type type :directory directory :defaults defaults)
      (make-pathname            :directory directory :defaults defaults)))

;;; Compile jscl into the host
(with-compilation-unit ()
  (dolist (input *source*)
    (when (member (cadr input) '(:host :both))
      (let ((fname (source-pathname (car input))))
        (multiple-value-bind (fasl warn fail) (compile-file fname)
          (declare (ignore fasl warn))
          (when fail
            (error "Compilation of ~A failed." fname)))))))

;;; Load jscl into the host
(dolist (input *source*)
  (when (member (cadr input) '(:host :both))
    (load (source-pathname (car input)))))

(defun read-whole-file (filename)
  (with-open-file (in filename)
    (let ((seq (make-array (file-length in) :element-type 'character)))
      (read-sequence seq in)
      seq)))

(defconstant +obj-file-extension+ "jso")

(defun replace-extension (filename new-extension)
  (do* ((filename (namestring filename))
        (len (length filename))
        (i (1- len) (1- i))
        (ch (char filename i) (char filename i)))
    ((or (zerop i) (char= ch #\.))
     (if (zerop i)
       (return-from replace-extension filename)
       (concatenate 'string (subseq filename 0 (1+ i)) new-extension)))))

(defun ls-compile-file (filename &key print)
  (let ((*compiling-file* t)
        (*compile-print-toplevels* print)
        (obj (replace-extension filename +obj-file-extension+)))
    (cond
      ((and (probe-file obj)
            (< (file-write-date filename) (file-write-date obj)))
       (format t "Loading environment from ~A...~%" obj)
       (with-open-file (o obj)
         ;; Read bindings and literals from the object file
         (macrolet ((push-list (list place)
                      `(setf ,place (append ,list ,place))))
           (push-list (read o) *literal-table*)
           (push-list (read o) (lexenv-variable *environment*))
           (push-list (read o) (lexenv-function *environment*)))))
      (t
       (let* ((source (read-whole-file filename))
              (in (make-string-stream source))
              ;; Keep track of what bindings and literals are currently at the
              ;; front of the environment and literal table, so that we can
              ;; detect which ones are new when writing to the object file.
              ;; Ignore blocks and gotags, as they cannot persist across files
              (front-literal (car *literal-table*))
              (front-var     (car (lexenv-variable *environment*)))
              (front-func    (car (lexenv-function *environment*))))
         (format t "Compiling ~a...~%" filename)
         (let ((compilations
                 (loop with eof-mark = (gensym)
                       for x = (ls-read in nil eof-mark)
                       until (eql x eof-mark)
                       for compilation = (ls-compile-toplevel x)
                       when (plusp (length compilation))
                         collect compilation)))
           (with-open-file (out obj :direction :output :if-exists :supersede
                                :if-does-not-exist :create)
             (flet ((collect-new (source old-head)
                      (loop for thing in source
                            until (eql thing old-head)
                            collect thing)))
               (format out "~S~&~S~&~S~&~{~A~}"
                       (collect-new *literal-table* front-literal)
                       (collect-new (lexenv-variable *environment*) front-var)
                       (collect-new (lexenv-function *environment*) front-func)
                       compilations)))))))))

(defun dump-global-environment (stream)
  (flet ((late-compile (form)
           (write-string (ls-compile-toplevel form) stream)))
    ;; We assume that environments have a friendly list representation
    ;; for the compiler and it can be dumped.
    (dolist (b (lexenv-function *environment*))
      (when (eq (binding-type b) 'macro)
        (setf (binding-value b) `(,*magic-unquote-marker* ,(binding-value b)))))
    (late-compile `(setq *environment* ',*environment*))
    ;; Set some counter variable properly, so user compiled code will
    ;; not collide with the compiler itself.
    (late-compile
     `(progn
        ,@(mapcar (lambda (s) `(%intern-symbol (%js-vref ,(cdr s))))
                  (remove-if-not #'symbolp *literal-table* :key #'car))
        (setq *literal-table* ',*literal-table*)
        (setq *variable-counter* ,*variable-counter*)
        (setq *gensym-counter* ,*gensym-counter*)))
    (late-compile `(setq *literal-counter* ,*literal-counter*))))

(defun append-object (source-name out)
  (let ((name (replace-extension source-name +obj-file-extension+)))
    (with-open-file (in name)
      (loop repeat 3 do (read in)) ; Skip literals and bindings
      (loop with eof = (gensym)
            for char = (read-char in nil eof)
            until (eql char eof)
            do (write-char char out)))))

(defvar *verbosity* nil) ; Set by make.sh when `verbose' is passed

(defun bootstrap ()
  (let ((*features* (cons :jscl *features*))
        (*package* (find-package "JSCL")))
    (setq *environment* (make-lexenv))
    (setq *literal-table* nil)
    (setq *variable-counter* 0
          *gensym-counter* 0
          *literal-counter* 0)
    (with-open-file (out "jscl.js" :direction :output :if-exists :supersede)
      (write-string (read-whole-file (source-pathname "prelude.js")) out)
      (dolist (input *source*)
        (when (member (cadr input) '(:target :both))
          (let ((file (source-pathname (car input) :type "lisp")))
            (ls-compile-file file :print *verbosity*)
            (append-object file out))))
      (dump-global-environment out))
    ;; Tests
    (with-open-file (out "tests.js" :direction :output :if-exists :supersede)
      (dolist (file (append (list "tests.lisp")
                            (directory "tests/*.lisp")
                            (list "tests-report.lisp")))
        (ls-compile-file file :print *verbosity*)
        (append-object file out)))))


;;; Run the tests in the host Lisp implementation. It is a quick way
;;; to improve the level of trust of the tests.
(defun run-tests-in-host ()
  (let ((*package* (find-package "JSCL")))
    (load "tests.lisp")
    (let ((*use-html-output-p* nil))
      (declare (special *use-html-output-p*))
      (dolist (input (directory "tests/*.lisp"))
        (load input)))
    (load "tests-report.lisp")))
