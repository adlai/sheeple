;; clone.lisp
;;
;; Contains the clone macro and utility functions
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
(in-package :sheeple)

(defun canonize-sheeple (sheeple)
  `(list ,@(mapcar #'canonize-sheep sheeple)))

(defun canonize-sheep (sheep)
  `(confirm-sheep ,sheep))

(defun confirm-sheep (sheep)
  sheep)

(defun canonize-properties (properties)
  `(list ,@(mapcar #'canonize-property properties)))

(defun canonize-property (property)
  (if (symbolp property)
      `(list :name ',property)
      (let ((name (car property))
	    (value (cadr property))
            (readers nil)
            (writers nil)
	    (cloneform *secret-unbound-value*)
            (other-options nil))
        (do ((olist (cddr property) (cddr olist)))
            ((null olist))
	  (case (car olist)
	    (:value
	     (setf value (cadr olist)))
	    (:val
	     (setf value (cadr olist)))
            (:reader 
             (pushnew (cadr olist) readers))
            (:writer 
             (pushnew (cadr olist) writers))
            (:manipulator
             (pushnew (cadr olist) readers)
             (pushnew `(setf ,(cadr olist)) writers))
	    (:cloneform
	     (setf cloneform (cadr olist)))
	    (otherwise 
             (pushnew (cadr olist) other-options)
             (pushnew (car olist) other-options))))
	(if other-options
	    (error "Invalid property option(s)")
	    `(list
	      :name ',name
	      :value ,value
	      ,@(when (not (eql cloneform *secret-unbound-value*))
		      `(:cloneform ',cloneform :clonefunction (lambda () ,cloneform)))
	      ,@(when readers `(:readers ',readers))
	      ,@(when writers `(:writers ',writers)))))))

(defun canonize-clone-options (options)
  (mapappend #'canonize-clone-option options))

(defun canonize-clone-option (option)
  (list `',(car option) (cadr option)))

(defmacro clone (sheeple properties &rest options)
  "Standard sheep-generation macro"
  `(spawn-sheep
    ,(canonize-sheeple sheeple)
    ,(canonize-properties properties)
    ,@(canonize-clone-options options)))