;; This file is part of Sheeple

;; message-dispatch.lisp
;;
;; Message execution and dispatch
;;
;; TODO
;; * Figure out an optimization to make manipulators about as fast as calling property-value
;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
(in-package :sheeple)

(declaim (optimize (safety 1) (speed 3) (debug 1)))
(defun primary-message-p (message)
  (null (message-qualifiers message)))

(defun before-message-p (message)
  (when (member :before (message-qualifiers message))
    t))

(defun after-message-p (message)
  (when (member :after (message-qualifiers message))
    t))

(defun around-message-p (message)
  (when (member :around (message-qualifiers message))
    t))

(defun apply-buzzword (buzzword args)
  (let ((messages (find-applicable-messages buzzword args)))
    (apply-messages messages args)))

(defstruct (cache (:type vector))
  buzzword
  around
  primary
  before
  after
  messages)

(defun apply-messages (cache args)
  (funcall (compute-effective-message-function cache)
	   args))

(defun compute-effective-message-function (cache)
  (let ((messages (cache-messages cache))
	(around (car (cache-around cache)))
	(primaries (cache-primary cache)))
    (when (null primaries)
      (let ((name (buzzword-name (cache-buzzword cache))))
	(error 'no-primary-messages
	       :format-control 
	       "There are no primary messages for buzzword ~A."
	       :format-args (list name))))
    (if around
	(let ((next-emfun
	       (compute-effective-message-function (create-message-cache
						    (cache-buzzword cache)
						    (remove around messages)))))
	  (lambda (args)
	    (funcall (message-function around) args next-emfun)))
	(let ((next-emfun (compute-primary-emfun (cdr primaries)))
	      (befores (cache-before cache))
	      (afters (cache-after cache)))
	  (lambda (args)
	    (when befores
              (dolist (before befores)
                (funcall (message-function before) args nil)))
            (multiple-value-prog1
                (funcall (message-function (car primaries)) args next-emfun)
              (when afters
                (dolist (after afters)
                  (funcall (message-function after) args nil)))))))))

(defun compute-primary-emfun (messages)
  (if (null messages)
      nil
      (let ((next-emfun (compute-primary-emfun (cdr messages))))
	(lambda (args)
	  (funcall (message-function (car messages)) args next-emfun)))))

(defun create-message-cache (buzzword messages)
  (make-cache
   :buzzword buzzword
   :messages messages
   :primary (remove-if-not #'primary-message-p messages)
   :around (remove-if-not #'around-message-p messages)
   :before (remove-if-not #'before-message-p messages)
   :after (reverse (remove-if-not #'after-message-p messages))))

(defun find-applicable-messages (buzzword args &key (errorp t))
  (declare (buzzword buzzword))
  (let* (;; This doesn't seem to be expensive at all..
	 (relevant-args-length (the fixnum (arg-info-number-required (buzzword-arg-info buzzword))))
	 ;; If I can avoid calling fetch-memo-vector-entry for singly-dispatched readers, that
	 ;; would be -lovely-. Not sure how to do that yet, though.
	 (memo-entry (fetch-memo-entry args buzzword relevant-args-length)))
    (or memo-entry
	memo-entry
	(let* ((relevant-args (subseq args 0 relevant-args-length))
	       (new-msg-list (%find-applicable-messages buzzword 
							relevant-args
							:errorp errorp)))
	  (memoize-message-dispatch buzzword relevant-args new-msg-list)))))

(defun fetch-memo-entry (args buzzword relevant-args-length)
  (let* ((memo-table (buzzword-memo-table buzzword)))
    (gethash (subseq args 0 relevant-args-length) memo-table)))

(defun memoize-message-dispatch (buzzword args msg-list)
  (let ((msg-cache (create-message-cache buzzword msg-list)))
    (add-entry-to-buzzword msg-cache buzzword args)
    msg-cache))

(defun add-entry-to-buzzword (cache buzzword args)
  (setf (gethash args (buzzword-memo-table buzzword)) cache))

(defun %find-applicable-messages  (buzzword args &key (errorp t))
  "Returns the most specific message using BUZZWORD and ARGS."
  (if (null args)
      (buzzword-messages buzzword)
      (let ((selector (buzzword-name buzzword))
	    (n (length args))
	    (discovered-messages nil)
	    (contained-applicable-messages nil))
	(declare (list discovered-messages contained-applicable-messages))
	(loop 
	   for arg in args
	   for index upto (1- n)
	   do (let* ((arg (if (sheep-p arg)
			      arg
			      (or (find-fleeced-wolf arg)
				  (fleece-of arg))))
		     (curr-sheep-list (sheep-hierarchy-list arg)))
		(loop
		   for curr-sheep in curr-sheep-list
		   for hierarchy-position upto (1- (length curr-sheep-list))
		   do (dolist (role (sheep-direct-roles curr-sheep))
			(when (and (equal selector (role-name role)) ;(eql buzzword (role-buzzword role))
				   (= (the fixnum index) (the fixnum (role-position role))))
			  (let ((curr-message (role-message role)))
			    (when (= n (length (the list (message-specialized-portion curr-message))))
			      (when (not (member curr-message
						 discovered-messages
						 :key #'message-container-message))
				(pushnew (the vector (contain-message curr-message))
					 discovered-messages))
			      (let ((contained-message (find curr-message
							     discovered-messages
							     :key #'message-container-message)))
				(setf (elt (message-container-rank contained-message) index) 
				      hierarchy-position)
				(when (fully-specified-p (message-container-rank contained-message))
				  (pushnew contained-message contained-applicable-messages :test #'equalp))))))))))
	(if contained-applicable-messages
	    (unbox-messages (sort-applicable-messages contained-applicable-messages))
	    (when errorp
	      (error 'no-applicable-messages
		     :format-control
		     "There are no applicable messages for buzzword ~A when called with args:~%~S"
		     :format-args (list selector args)))))))

(defun unbox-messages (messages)
  (mapcar #'message-container-message messages))

(defun sort-applicable-messages (message-list &key (rank-key #'<))
  (sort message-list rank-key
	:key (lambda (contained-message)
	       (calculate-rank-score (message-container-rank contained-message)))))

(defun contain-message (message)
  (make-message-container
   :message message
   :rank (make-array (length (message-specialized-portion message))
		     :initial-element nil)))

(defstruct (message-container (:type vector))
  message
  rank)

(defun fully-specified-p (rank)
  (loop for item across rank
     do (when (eql item nil)
	  (return-from fully-specified-p nil)))
  t)

(defun calculate-rank-score (rank)
  (declare (simple-array rank))
  (let ((total 0))
    (declare (fixnum total))
    (loop for item across rank
       do (when (numberp item)
	    (incf total (the fixnum item))))
    total))

(defun message-specialized-portion (msg)
  (parse-lambda-list (message-lambda-list msg)))
