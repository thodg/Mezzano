;;;; A hash-table specialized on classes.
;;;; This efficiently maps from classes to arbitrary values.

;;;; Warning:
;;;; Concurrent reads are thread-safe, but updates must be protected by a lock.
;;;; These functions are unsafe and must be called with the proper arguments,
;;;; ie the table must be a fast-class-hash-table and the class must be a class.

(in-package :mezzano.clos)

;; Must be a power of two.
(sys.int::defglobal *default-fast-class-hash-table-size* 16)

(defstruct (fast-class-hash-table
             (:constructor make-fast-class-hash-table ()))
  ;; Table can use one of three possible representation:
  ;; NIL - There are no entries.
  ;; A cons - There is a single entry. The CAR is the class and the CDR is the value.
  ;; A simple-vector - There are many entries.
  (table nil)
  (count 0))

(defun fast-class-hash-table-entry (table class)
  (declare (optimize speed (safety 0) (debug 1))
           (type fast-class-hash-table table))
  (let ((storage (fast-class-hash-table-table table)))
    (cond ((consp storage)
           ;; Single entry.
           (if (eq (the cons (car storage)) class)
               (the cons (cdr storage))
               nil))
          ((not storage)
           ;; No entries.
           nil)
          (t
           (locally
               (declare (type simple-vector storage))
             ;; Full hash table.
             (do* ((hash (safe-class-hash class))
                   (size (length storage))
                   (mask (1- size))
                   ;; This hash implementation is inspired by the Python dict implementation.
                   (slot (logand hash #xFFFFFFFF)
                         (logand #xFFFFFFFF
                                 (the fixnum
                                      (+ (the fixnum
                                              (+ (the fixnum
                                                      (* slot 5))
                                                 perturb))
                                         1))))
                   (perturb hash (ash perturb -5)))
                  (nil)
               (declare (type fixnum hash size mask slot perturb))
               (let* ((offset (logand slot mask))
                      (slot (aref storage offset)))
                 (declare (type fixnum offset))
                 (when (eq slot nil)
                   ;; Unbound value marks the end of this run.
                   (return nil))
                 (when (and (not (eq slot t))
                            (eq class (car (the cons slot))))
                   (return (cdr (the cons slot)))))))))))

(defun get-fast-class-hash-table-slot-offset (storage class)
  (do* ((hash (safe-class-hash class))
        (size (sys.int::simple-vector-length storage))
        (free-slot nil)
        ;; This hash implementation is inspired by the Python dict implementation.
        (slot (logand hash #xFFFFFFFF) (logand #xFFFFFFFF (+ (* slot 5) perturb 1)))
        (perturb hash (ash perturb -5)))
       (nil)
    (let* ((offset (rem slot size))
           (slot (svref storage offset)))
      (when (and (not free-slot)
                 (or (eq slot nil)
                     (eq slot t)))
        (setf free-slot offset))
      (when (eq slot nil)
        ;; Unbound value marks the end of this run.
        (return (values nil free-slot)))
      (when (and (not (eq slot t))
                 (eq class (car slot)))
        (return (values slot offset))))))

(defun (setf fast-class-hash-table-entry) (value table class)
  (cond ((null (fast-class-hash-table-table table))
         (when (not (eql value nil))
           (setf (fast-class-hash-table-table table) (cons class value))
           (setf (fast-class-hash-table-count table) 1)))
        ((consp (fast-class-hash-table-table table))
         (cond ((eql (car (fast-class-hash-table-table table)) class)
                (cond (value
                       (setf (cdr (fast-class-hash-table-table table)) value))
                      (t
                       (setf (fast-class-hash-table-table table) nil)
                       (setf (fast-class-hash-table-count table) 0))))
               (value
                ;; Promote to full hash-table
                (let* ((storage (make-array *default-fast-class-hash-table-size* :initial-element nil))
                       (existing-entry (fast-class-hash-table-table table))
                       (existing-class (car existing-entry)))
                  (multiple-value-bind (existing-slot slot-offset)
                      (get-fast-class-hash-table-slot-offset storage existing-class)
                    (declare (ignore existing-slot))
                    (setf (svref storage slot-offset) existing-entry))
                  (multiple-value-bind (existing-slot slot-offset)
                      (get-fast-class-hash-table-slot-offset storage class)
                    (declare (ignore existing-slot))
                    (setf (svref storage slot-offset) (cons class value)))
                  (setf (fast-class-hash-table-table table) storage)
                  (incf (fast-class-hash-table-count table))))))
        (t
         (multiple-value-bind (existing-slot slot-offset)
             (get-fast-class-hash-table-slot-offset (fast-class-hash-table-table table) class)
           (cond
             ((eql value nil)
              ;; Removing a value.
              (when existing-slot
                (decf (fast-class-hash-table-count table))
                ;; Replace with a tombstone marker
                (setf (svref (fast-class-hash-table-table table) slot-offset) t)))
             (existing-slot
              ;; Updating an existing slot.
              (setf (cdr existing-slot) value))
             ((eql (1+ (fast-class-hash-table-count table))
                   (length (fast-class-hash-table-table table)))
              ;; This would fill the table. Expand it.
              (let* ((old-table (fast-class-hash-table-table table))
                     (new-table (make-array (* (length old-table) 2) :initial-element nil)))
                (dotimes (i (length old-table))
                  (let ((slot (svref old-table i)))
                    (when (consp slot)
                      (multiple-value-bind (existing-slot slot-offset)
                          (get-fast-class-hash-table-slot-offset new-table (car slot))
                        (assert (not existing-slot))
                        (setf (svref new-table slot-offset) slot)))))
                ;; And the new entry.
                (multiple-value-bind (existing-slot slot-offset)
                    (get-fast-class-hash-table-slot-offset new-table class)
                  (assert (not existing-slot))
                  (setf (svref new-table slot-offset) (cons class value)))
                (incf (fast-class-hash-table-count table))
                ;; Switch to new table.
                (setf (fast-class-hash-table-table table) new-table)))
             (t ;; Adding a new entry.
              (setf (svref (fast-class-hash-table-table table) slot-offset) (cons class value))
              (incf (fast-class-hash-table-count table)))))))
  value)

(defun map-fast-class-hash-table (fn table)
  (let ((table (fast-class-hash-table-table table)))
    (cond ((not table)
           nil)
          ((consp table)
           (funcall fn (car table) (cdr table)))
          (t
           (dotimes (i (length table))
             (let ((slot (svref table i)))
               (when (consp slot)
                 (funcall fn (car slot) (cdr slot)))))))))

(defun clear-fast-class-hash-table (table)
  (setf (fast-class-hash-table-table table) nil
        (fast-class-hash-table-count table) 0))
