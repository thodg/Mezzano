(in-package :sys.int)

(fmakunbound 'funcallable-instance-lambda-expression)
(defgeneric funcallable-instance-lambda-expression (function)
  (:method ((function function))
    (declare (ignore function))
    (values nil t nil)))

(fmakunbound 'funcallable-instance-debug-info)
(defgeneric funcallable-instance-debug-info (function)
  (:method ((function function))
    (declare (ignore function))
    nil))

(defgeneric make-load-form (object &optional environment))

(defun raise-undefined-function (invoked-through &rest args)
  (setf invoked-through (function-reference-name invoked-through))
  ;; Allow restarting.
  (restart-case (error 'undefined-function :name invoked-through)
    (use-value (v)
      :interactive (lambda ()
                     (format t "Enter a new value (evaluated): ")
                     (list (eval (read))))
      :report (lambda (s) (format s "Input a value to be used in place of ~S." `(fdefinition ',invoked-through)))
      (apply v args))))
