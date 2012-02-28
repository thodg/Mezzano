(eval-when (:compile-toplevel)
  (defpackage #:sys.eval
    (:use #:cl)))

(in-package #:sys.eval)

(defparameter *special-forms* (make-hash-table))

(defmacro defspecial (name lambda-list &body body)
  (let ((form-sym (gensym))
        (env-sym nil))
    (if (eql (first lambda-list) '&environment)
        (setf env-sym (second lambda-list)
              lambda-list (cddr lambda-list))
        (setf env-sym (gensym)))
  `(setf (gethash ',name *special-forms*)
         (lambda (,form-sym ,env-sym)
           (declare (ignorable ,form-sym ,env-sym)
                    (system:lambda-name (special-form ,name)))
           (block ,name
             (destructuring-bind ,lambda-list (cdr ,form-sym)
               ,@body))))))

(defun find-variable (symbol env)
  "Locate SYMBOL in ENV. Returns a binding list or the symbol if there was no lexical binding."
  (dolist (e env symbol)
    (when (and (eql (first e) :special) (member symbol (rest e)))
      (return symbol))
    (when (and (eql (first e) :binding) (eql (second e) symbol))
      (return e))))

(defun find-function (name env)
  (dolist (e env (fdefinition name))
    (when (eql (first e) :functions)
      (let ((fn (assoc name (rest e))))
	(when fn
	  (return (cdr fn)))))))

(defun eval-lambda (lambda outer-env)
  (let ((lambda-list (second lambda))
        (forms (cddr lambda)))
    (multiple-value-bind (body declares docstring)
	(sys.int::parse-declares forms :permit-docstring t)
      (declare (ignore docstring))
      (multiple-value-bind (required optional rest enable-keys keys allow-other-keys aux)
	  (sys.int::parse-ordinary-lambda-list lambda-list)
	(lambda (&rest args)
          (declare (system:lambda-name interpreted-function))
          (let ((env outer-env))
            (dolist (arg required)
              (when (null args)
                (error "Too few arguments to function ~S lambda-list ~S" name lambda-list))
              (push (list :binding arg (car args)) env)
              (setf args (cdr args)))
            (dolist (arg optional)
              (if args
                  (progn (push (list :binding (first arg) (car args)) env)
                         (setf args (cdr args))
                         (when (third arg)
                           (push (list :binding (third arg) t) env)))
                  (progn (push (list :binding (first arg) (eval-in-lexenv (second arg) env)) env)
                         (when (third arg)
                           (push (list :binding (third arg) nil) env)))))
            (if rest
                (push (list :binding rest args) env)
                (when (and (not enable-keys) args)
                  (error "Too many arguments to function ~S lambda-list ~S" name lambda-list)))
            (when enable-keys
              (when (oddp (length args))
                (error "Odd number of &KEY arguments."))
              (unless allow-other-keys
                (do ((i args (cddr i)))
                    ((null i))
                  (unless (member (car i) keys)
                    (error "Unknown &KEY argument ~S." (car i)))))
              (dolist (key keys)
                (let ((arg (getf args (caar key) args)))
                  (if (eql arg args)
                      (progn (push (list :binding (cadar key) (eval-in-lexenv (second key) env)) env)
                             (when (third key)
                               (push (list :binding (third key) nil) env)))
                      (progn (push (list :binding (cadar key) arg) env)
                             (when (third key)
                               (push (list :binding (third key) t) env)))))))
            (dolist (arg aux)
              (push (list :binding (first arg) (eval-in-lexenv (second arg) env)) env))
            (eval-locally-body declares body env)))))))

(defun eval-progn-body (forms env)
  (do ((itr forms (cdr itr)))
      ((null (cdr itr))
       (eval-in-lexenv (car itr) env))
    (eval-in-lexenv (car itr) env)))

(defun eval-locally-body (declares body env)
  "Collect all special declarations and add them to the environment."
  (dolist (dec declares)
    (when (eql (car dec) 'special)
      (dolist (v (cdr dec))
	(push (list :special v) env))))
  (eval-progn-body body env))

(defun frob-flet-function (definition env)
  (destructuring-bind (name lambda-list &body body) definition
    (values name
            ;; FIXME: create a named block.
            (eval-lambda `(lambda ,lambda-list
                            ,@body)
                         env))))

(defspecial block (&environment env name &body body)
  (let ((env (cons (list :block name #+nil(lambda (values)
                                       (return-from block (values-list values))))
                   env)))
    (eval-progn-body body env)))

(defspecial flet (&environment env definitions &body forms)
  (let ((functions (mapcar (lambda (def)
                             (multiple-value-bind (name fn)
                                 (frob-flet-function def env)
                               (cons name fn)))
                           definitions)))
    (multiple-value-bind (body declares)
        (sys.int::parse-declares forms)
      (eval-locally-body declares body (cons (list* :functions functions) env)))))

(defspecial function (&environment env name)
  (if (sys.int::lambda-expression-p name)
      (eval-lambda name env)
      (fdefinition name)))

(defspecial labels (&environment env definitions &body forms)
  (let* ((env (cons (list :functions) env))
         (functions (mapcar (lambda (def)
                              (multiple-value-bind (name fn)
                                  (frob-flet-function def env)
                                (cons name fn)))
                            definitions)))
    (setf (rest (first env)) functions)
    (multiple-value-bind (body declares)
        (sys.int::parse-declares forms)
      (eval-locally-body declares body env))))

(defspecial let (&environment env bindings &body forms)
  (multiple-value-bind (body declares)
      (sys.int::parse-declares forms)
    (let ((special-variables '())
          (special-values '())
          (special-declares (apply 'append
                                   (mapcar #'rest
                                           (remove-if-not (lambda (dec) (eql (first dec) 'special))
                                                          declares))))
          (new-env env))
      (dolist (b bindings)
        (multiple-value-bind (name init-form)
            (sys.int::parse-let-binding b)
          (let ((value (eval-in-lexenv init-form env)))
            (ecase (sys.int::symbol-mode name)
              ((nil :symbol-macro)
               (cond ((member name special-declares)
                      (push name special-variables)
                      (push value special-values))
                     (t (push (list :binding name value) new-env))))
              (:special
               (push name special-variables)
               (push value special-values))
              (:constant (error "Cannot bind over constant ~S." name))))))
      (when special-variables
        (error "TODO: special-variables"))
      #+nil(progv special-variables special-values
             (eval-locally-body declares body new-env))
      (eval-locally-body declares body new-env))))

(defspecial progn (&environment env &body forms)
  (eval-progn-body forms env))

(defspecial quote (object)
  object)

(defspecial return-from (&environment env name &optional value)
  (dolist (e env (error "No block named ~S." name))
    (when (and (eql (first e) :block)
               (eql (second e) name))
      (funcall (third e) (multiple-value-list (eval-in-lexenv value env))))))

(defspecial setq (&environment env symbol value)
  (setf (symbol-value symbol) (eval-in-lexenv value env)))

(defun eval-symbol (form env)
  "3.1.2.1.1  Symbols as forms"
  (let ((var (find-variable form env)))
    (if (symbolp var)
        (restart-case (symbol-value var)
          (use-value (v)
            :interactive (lambda ()
                           (format t "Enter a new value (evaluated): ")
                           (list (eval (read))))
            :report (lambda (s) (format s "Input a value to be used in place of ~S." var))
            v)
          (store-value (v)
            :interactive (lambda ()
                           (format t "Enter a new value (evaluated): ")
                           (list (eval (read))))
            :report (lambda (s) (format s "Input a new value for ~S." var))
            (setf (symbol-value var) v)))
        (third var))))

(defun eval-cons (form env)
  "3.1.2.1.2  Conses as forms"
  (let ((fn (gethash (first form) *special-forms*)))
    (cond (fn (funcall fn form env))
          ((macro-function (first form))
           ;; TODO: env.
           (eval-in-lexenv (macroexpand-1 form) env))
          (t (apply (find-function (first form) env)
                    (mapcar (lambda (f) (eval-in-lexenv f env))
                            (rest form)))))))

(defun eval-in-lexenv (form &optional env)
  "3.1.2.1  Form evaluation"
  (cond ((symbolp form)
	 (eval-symbol form env))
	((consp form)
	 (eval-cons form env))
	;; 3.1.2.1.3  Self evaluating objects
	(t form)))

(defun eval (form)
  (eval-in-lexenv form nil))
