(in-package #:vacietis)
(in-readtable vacietis)

;;(declaim (optimize (debug 3)))
(declaim (optimize (speed 3) (debug 0) (safety 1)))

;;; unary operators

(defmacro def-unary-op (c lisp)
  (let ((x (gensym)))
   `(defmacro ,c (,x)
      `(,',lisp ,,x))))

;;; binary arithmetic

(defmacro define-binary-op-mapping-definer (name &body body)
  `(defmacro ,name (&rest map)
     `(progn ,@(loop for (vacietis cl) on map by #'cddr collect
                    (let ((op (find-symbol (symbol-name vacietis) '#:vacietis.c)))
                      ,@body)))))

(define-binary-op-mapping-definer define-binary-ops
  `(progn (declaim (inline ,op))
          (defun ,op (x y)
            (,cl x y))))

(define-binary-ops
  |\|| logior
  ^    logxor
  &    logand
  *    *
  /    /
  integer/    (lambda (x y)
                (if (and (integerp x) (integerp y))
                    (truncate x y)
                    (/ x y)))
  ptr+ %ptr+
  ptr- %ptr-
  ptr< %ptr<
  ptr<= %ptr<=
  ptr> %ptr>
  ptr>= %ptr>=
  ptr== %ptr==
  ptr!= %ptr!=
         
  %    rem
  <<   ash
  >>   (lambda (int count) (ash int (- count))))

(def-unary-op vacietis.c:~ lognot)

;;; pointers, storage units and allocation

(defstruct c-pointer
  (sap (sb-sys:int-sap 0) :type (or null sb-sys:system-area-pointer))
  (offset 0 :type fixnum)
  (id 0 :type fixnum))

(defmethod make-load-form ((self c-pointer) &optional environment)
  (make-load-form-saving-slots self
                               :slot-names '(offset id)
                               :environment environment))

(declaim (inline sap-ref-c-pointer))
(defun sap-ref-c-pointer (sap offset)
  (declare (optimize (speed 3) (debug 0) (safety 0))
           (type sb-sys:system-area-pointer sap)
           (type fixnum offset))
  (let* ((r-sap    (sb-sys:sap-ref-word sap offset))
         (r-offset (sb-sys:sap-ref-word sap (+ offset sb-vm:n-word-bytes)))
         (r-id     (sb-sys:sap-ref-word sap (+ offset (* 2 sb-vm:n-word-bytes)))))
    (make-c-pointer :sap (sb-sys:int-sap r-sap)
                    :offset r-offset
                    :id r-id)))

(declaim (inline (setf sap-ref-c-pointer)))
(defun (setf sap-ref-c-pointer) (new-value sap offset)
  (declare (optimize (speed 3) (debug 0) (safety 0))
           (type sb-sys:system-area-pointer sap)
           (type fixnum offset))
  (let* ((w-sap    (c-pointer-sap new-value))
         (w-offset (c-pointer-offset new-value))
         (w-id     (c-pointer-id new-value)))
    (sb-kernel:%set-sap-ref-word sap offset (sb-sys:sap-int w-sap))
    (sb-kernel:%set-sap-ref-word sap (+ offset sb-vm:n-word-bytes) w-offset)
    (sb-kernel:%set-sap-ref-word sap (+ offset (* 2 sb-vm:n-word-bytes)) w-id)))

(defmacro define-c-pointer-ref-functions (options &rest types)
  (declare (ignore options))
  (let (forms)
    (dolist (type types)
      (let ((fname (intern (format nil "C-POINTER-REF-~A" (symbol-name type)))))
        (push
         `(declaim (inline ,fname))
         forms)
        (push
         `(defun ,fname (ptr offset)
            (declare (optimize (speed 3) (debug 0) (safety 0))
                     (type c-pointer ptr)
                     (type fixnum offset))
            (,(sap-get-ref-for type) (c-pointer-sap ptr) (+ (c-pointer-offset ptr) offset)))
         forms)))
    `(progn ,@forms)))

(define-c-pointer-ref-functions ()
    vacietis.c:double vacietis.c:float
    vacietis.c:long vacietis.c:int vacietis.c:short vacietis.c:char
    vacietis.c:unsigned-long vacietis.c:unsigned-int vacietis.c:unsigned-short vacietis.c:unsigned-char)

(defvar *c-pointers* (make-hash-table :weakness :key))
(defvar *interned-c-pointers* (make-hash-table :weakness :value))

(defvar *c-pointer-id-counter* 1)
(defvar *gen-c-pointer-id-mutex* (sb-thread:make-mutex :name "GEN-C-POINTER-ID-MUTEX"))
(defun gen-c-pointer-id ()
  (sb-thread:with-mutex (*gen-c-pointer-id-mutex*)
    (prog1 *c-pointer-id-counter*
      (incf *c-pointer-id-counter*))))

(defun print-c-pointers ()
  (maphash (lambda (k buffer)
             (let* ((dimensions (array-dimensions buffer))
                    (size (car dimensions))
                    (print-size (min 16 size))
                    (data (apply #'concatenate
                                 'string
                                 (loop for i from 0 upto (1- print-size)
                                    collect (format nil "~2,'0X" (aref buffer i))))))
               (format t "~S ~S ~10D ~A~%"
                       (c-pointer-id k)
                       (c-pointer-sap k)
                       size
                       data)))
           *c-pointers*))

(defun print-c-pointer-ids ()
  (maphash (lambda (id c-pointer)
             (let* ((buffer (gethash c-pointer *c-pointers*))
                    (dimensions (array-dimensions buffer))
                    (size (car dimensions)))
               (format t "~S : ~S ~S ~10D~%"
                       id
                       (c-pointer-id c-pointer)
                       (c-pointer-sap c-pointer)
                       size)))
           *interned-c-pointers*))

(defun dump-c-pointer (c-pointer bytes)
  (let ((sap (c-pointer-sap c-pointer)))
    (format t "~A"
            (apply #'concatenate 'string
                   (loop for i from 0 upto (1- bytes)
                      collect (format nil "~2,'0X" (sb-sys:sap-ref-8 sap i)))))))

(defmacro with-all-c-pointers-pinned (&body body)
  (let ((c-pointers))
    (maphash (lambda (k v)
               (declare (ignore v))
               (push k c-pointers))
             *c-pointers*)
    `(with-array-backed-c-pointer-ids (,@(mapcar #'c-pointer-id c-pointers))
       ,@body)
    #+nil
    `(with-array-backed-c-pointers (,@keys)
       ,@body)))

(defpackage #:vacietis.runtime
  (:use #:cl)
  (:export
   #:with-c
   ))

(defmacro vacietis.runtime:with-c (options &body body)
  `(vacietis::with-all-c-pointers-pinned
     ,@body))


(defun array-backed-c-pointer (size)
  ;; XXX pointers are 3 x word size
  (setq size (* size 3))
  (let* ((buffer (make-array size :element-type '(unsigned-byte 8))))
    (sb-sys:with-pinned-objects (buffer)
      (let* ((obj-address (sb-kernel:get-lisp-obj-address buffer))
             (address (logandc2 obj-address sb-vm:lowtag-mask))
             (data-address (+ (* 2 sb-vm:n-word-bytes) address))
             (sap (sb-sys:int-sap data-address)))
        (let ((c-pointer (make-c-pointer :sap sap)))
          (setf (gethash c-pointer *c-pointers*) buffer)
          (setf (c-pointer-id c-pointer) (gen-c-pointer-id))
          (setf (gethash (c-pointer-id c-pointer) *interned-c-pointers*) c-pointer)
          c-pointer)))))

(defun array-backed-c-pointer-of (buffer)
  (sb-sys:with-pinned-objects (buffer)
    (let* ((obj-address (sb-kernel:get-lisp-obj-address buffer))
           (address (logandc2 obj-address sb-vm:lowtag-mask))
           (data-address (+ (* 2 sb-vm:n-word-bytes) address))
           (sap (sb-sys:int-sap data-address)))
      (let ((c-pointer (make-c-pointer :sap sap)))
        (setf (gethash c-pointer *c-pointers*) buffer)
        (setf (c-pointer-id c-pointer) (gen-c-pointer-id))
        (setf (gethash (c-pointer-id c-pointer) *interned-c-pointers*) c-pointer)
        c-pointer))))

(defun c-pointer-of (obj)
  (let* ((obj-address (sb-kernel:get-lisp-obj-address obj))
         (address (logandc2 obj-address sb-vm:lowtag-mask))
         (data-address (+ (* 0 sb-vm:n-word-bytes) address))
         (sap (sb-sys:int-sap data-address)))
    (format t " obj-address: ~X~%" obj-address)
    (format t "     address: ~X~%" address)
    (format t "data-address: ~X~%" data-address)
    (let ((c-pointer (make-c-pointer :sap sap)))
      ;;(setf (gethash c-pointer *c-pointers*) obj)
      ;;(setf (c-pointer-id c-pointer) (gen-c-pointer-id))
      ;;(setf (gethash (c-pointer-id c-pointer) *interned-c-pointers*) c-pointer)
      c-pointer)))

(defmacro with-array-backed-c-pointers ((&rest saps) &body body)
  (let ((n (length saps))
        (pointer-syms (map 'list (lambda (x) (declare (ignore x)) (gensym)) saps))
        (buffer-syms (map 'list (lambda (x) (declare (ignore x)) (gensym)) saps))
        (obj-address (gensym))
        (address (gensym))
        (data-address (gensym)))
    `(let* (,@(loop for i from 0 upto (1- n)
                 collect
                   (let ((pointer-sym (nth i pointer-syms))
                         (c-pointer (nth i saps)))
                     `(,pointer-sym ,c-pointer)))
            ,@(loop for i from 0 upto (1- n)
                 collect
                   (let ((pointer-sym (nth i pointer-syms))
                         (buffer-sym (nth i buffer-syms)))
                     `(,buffer-sym (gethash ,pointer-sym *c-pointers*)))))
       (sb-sys:with-pinned-objects (,@buffer-syms)
         ,@(loop for i from 0 upto (1- n)
              collect
                (let ((pointer-sym (nth i pointer-syms))
                      (buffer-sym (nth i buffer-syms)))
                  `(let* ((,obj-address (sb-kernel:get-lisp-obj-address ,buffer-sym))
                          (,address (logandc2 ,obj-address sb-vm:lowtag-mask))
                          (,data-address (the fixnum (+ (* 2 sb-vm:n-word-bytes) ,address))))
                     (setf (c-pointer-sap ,pointer-sym) (sb-sys:int-sap ,data-address)))))
         ,@body))))

(defmacro with-array-backed-c-pointer-ids ((&rest sap-ids) &body body)
  (let ((n (length sap-ids))
        (pointer-syms (map 'list (lambda (x) (declare (ignore x)) (gensym)) sap-ids))
        (buffer-syms (map 'list (lambda (x) (declare (ignore x)) (gensym)) sap-ids))
        (obj-address (gensym))
        (address (gensym))
        (data-address (gensym)))
    `(let* (,@(loop for i from 0 upto (1- n)
                 collect
                   (let ((pointer-sym (nth i pointer-syms))
                         (id (nth i sap-ids)))
                     `(,pointer-sym (gethash ,id *interned-c-pointers*))))
            ,@(loop for i from 0 upto (1- n)
                 collect
                   (let ((pointer-sym (nth i pointer-syms))
                         (buffer-sym (nth i buffer-syms)))
                     `(,buffer-sym (gethash ,pointer-sym *c-pointers*)))))
       (sb-sys:with-pinned-objects (,@buffer-syms)
         ,@(loop for i from 0 upto (1- n)
              collect
                (let ((pointer-sym (nth i pointer-syms))
                      (buffer-sym (nth i buffer-syms)))
                  `(let* ((,obj-address (sb-kernel:get-lisp-obj-address ,buffer-sym))
                          (,address (logandc2 ,obj-address sb-vm:lowtag-mask))
                          (,data-address (the fixnum (+ (* 2 sb-vm:n-word-bytes) ,address))))
                     (setf (c-pointer-sap ,pointer-sym) (sb-sys:int-sap ,data-address)))))
         ,@body))))

(defun string-to-char* (string)
  (let ((unicode (babel:string-to-octets string :encoding :utf-8)))
    (if *use-alien-types*
        (let* ((size (1+ (length unicode)))
               (c-pointer (array-backed-c-pointer size)))
          (with-array-backed-c-pointers (c-pointer)
            (sb-kernel:copy-ub8-to-system-area unicode 0 (c-pointer-sap c-pointer) 0 size))
          c-pointer)
        (make-array (1+ (length unicode))
                    :element-type '(signed-byte 8)
                    :initial-contents (concatenate '(simple-array (signed-byte 8) (*))
                                                   (map 'vector
                                                        (lambda (c)
                                                          (if (> c 127)
                                                              (- (- c 127))
                                                              c))
                                                        unicode)
                                                   #(0))))))

(defun string-to-unsigned-char* (string)
  (let ((unicode (babel:string-to-octets string :encoding :utf-8)))
    (if *use-alien-types*
        (let* ((size (1+ (length unicode)))
               (c-pointer (array-backed-c-pointer size)))
          (with-array-backed-c-pointers (c-pointer)
            (sb-kernel:copy-ub8-to-system-area unicode 0 (c-pointer-sap c-pointer) 0 size))
          c-pointer)
        (make-array (1+ (length unicode))
                    :element-type '(unsigned-byte 8)
                    :initial-contents (concatenate '(simple-array (unsigned-byte 8) (*))
                                                   unicode
                                                   #(0))))))

(defun char*-to-string (char*)
  (if *use-alien-types*
      (with-array-backed-c-pointers (char*)
        (let* ((sap (c-pointer-sap char*))
               (length (loop for offset from 0
                          for c = (sb-kernel::sap-ref-8 sap offset)
                          when (= 0 c)
                          return offset))
               (byte-array (make-array length :element-type '(unsigned-byte 8))))
          (sb-kernel:copy-ub8-from-system-area sap 0 byte-array 0 length)
          (babel:octets-to-string byte-array :encoding :utf-8)))
      (let* ((char*      (ensure-memptr char*))
             (mem        (memptr-mem char*))
             (start      (memptr-ptr char*))
             (end        (or (position 0 mem :start start) (length mem)))
             (byte-array (make-array (- end start) :element-type '(unsigned-byte 8))))
        (replace byte-array mem :start2 start :end2 end)
        (babel:octets-to-string byte-array :encoding :utf-8))))

(defun make-memptr (&key mem)
  (make-place-ptr :variable mem
                  :offset 0))
(defun ensure-memptr (ptr)
  (typecase ptr
    (place-ptr ptr)
    (t (make-memptr :mem ptr))))
(defun ensure-unsigned-sequence (ptr)
  (let ((seq
         (typecase ptr
           (place-ptr
            (let ((mem (place-ptr-variable ptr))
                  (offset (place-ptr-offset ptr)))
              (if (= 0 offset)
                  mem
                  (subseq mem offset))))
           (string (string-to-unsigned-char* ptr))
           (t ptr))))
    (let ((element-type (array-element-type seq)))
      (if (equal element-type '(unsigned-byte 8))
          seq
          (make-array (length seq)
                      :element-type '(unsigned-byte 8)
                      :initial-contents (map 'vector
                                             (lambda (c)
                                               (if (< c 0)
                                                   (+ 127 (- c))
                                                   c))
                                             seq))))))

(defun allocate-memory (size)
  (make-memptr :mem (make-array size :adjustable t :initial-element 0)))

(defstruct place-ptr
  offset
  variable
  %closure)
(defun place-ptr-closure (ptr)
  (aif (place-ptr-variable ptr)
       (aref it (place-ptr-offset ptr))
       (funcall (place-ptr-%closure ptr))))
(defun (setf place-ptr-closure) (new-value ptr)
  (aif (place-ptr-variable ptr)
       (setf (aref it (place-ptr-offset ptr)) new-value)
       (funcall (place-ptr-%closure ptr) new-value)))
(defun memptr-mem (ptr)
  (typecase ptr
    (place-ptr (place-ptr-variable ptr))
    (t ptr)))
(defun memptr-ptr (ptr)
  (typecase ptr
    (place-ptr (place-ptr-offset ptr))
    (t 0)))
(defun memptr-type (ptr)
  ;;(format t "memptr-type: ~S~%" ptr)
  (let ((mem (ensure-memptr ptr)))
    (array-element-type (memptr-mem ptr))))

(defmacro vacietis.c:mkptr& (place) ;; need to deal w/function pointers
  (let ((new-value   (gensym))
        (place       (macroexpand place)))
    (dbg "mkptr& place: ~S~%" place)
    (cond
      ((null place)
       nil)
      ((and *use-alien-types*
            (listp place)
            (member (car place) '(aref vacietis.c:alien[])))
       (multiple-value-bind (parsed-place offsets)
           (parse-alien-accessor place)
         (dbg "  -> PARSED: ~S  ~S~%" parsed-place offsets)
         (let ((value (gensym))
               (ptr (gensym)))
           `(let* ((,value ,parsed-place)
                   (,ptr (make-c-pointer :sap (c-pointer-sap ,value)
                                         :offset (+ (c-pointer-offset ,value) ,@offsets)
                                         :id (c-pointer-id ,value))))
              ,ptr))))
      ((and *use-alien-types*
            ;; XXX
            (or
             (eq 'vacietis.c:|...| place)
             (symbolp place)))
       (let ((varsym (gensym)))
         `(progn
            (let ((,varsym ,place))
              (dbg "%closure making place ptr to ~S(~S)~%" ',place ,varsym)
              (make-place-ptr
               :offset nil
               :variable nil
               :%closure (lambda (&optional ,new-value)
                           (if ,new-value
                               (setf ,place ,new-value)
                               ,place)))))))
      ((and *use-alien-types*
            t)
       (let ((pointer-sym (cadr (cadr place))))
         `(copy-c-pointer ,pointer-sym)))
      ((and (listp place)
            (member (car place) '(aref vacietis.c:[])))
       (let* ((variable (second place))
              (initial-offset (third place))
              (varsym (gensym)))
         (if (and (integerp initial-offset) (= 0 initial-offset))
             variable
             `(progn
                (let ((,varsym ,variable))
                  (dbg "making place ptr to ~S(~S) ~S~%" ',variable ,varsym (place-ptr-p ,varsym))
                  (typecase ,varsym
                    (place-ptr
                     (dbg "  -> is already a place-ptr...~%")
                     ,varsym)
                    (t (make-place-ptr
                        :offset ,initial-offset
                        :variable ,varsym))))))))
      (t
       (let ((varsym (gensym)))
         `(progn
            (let ((,varsym ,place))
              (dbg "%closure making place ptr to ~S(~S)~%" ',place ,varsym)
              (make-place-ptr
               :offset nil
               :variable nil
               :%closure (lambda (&optional ,new-value)
                           (if ,new-value
                               (setf ,place ,new-value)
                               ,place))))))))))

(defun ensure-place-ptr-offset (x)
  (typecase x
    (place-ptr (place-ptr-offset x))
    (integer x)
    (c-pointer 0)
    (t 0)))

(defun %ptr+ (ptr x)
  (dbg "%ptr+: ~S ~S~%" ptr x)
  (cond
    ;; addition of pointers is not actually valid C
    ((and (place-ptr-p ptr) (place-ptr-p x))
     (+ (place-ptr-offset ptr)
        (place-ptr-offset x)))
    ((place-ptr-p ptr)
     (let* ((additional-offset x)
            (var (place-ptr-variable ptr))
            (offset (+ additional-offset (place-ptr-offset ptr))))
       (if (= 0 offset)
           var
           (make-place-ptr :offset offset
                           :variable var))))
    ((and (place-ptr-p x) (not (place-ptr-p ptr)))
     (let ((offset (+ ptr (place-ptr-offset x))))
       (if (= 0 offset)
           (place-ptr-variable x)
           (make-place-ptr :offset offset
                           :variable (place-ptr-variable x)))))
    ((place-ptr-p x)
     (%ptr+ ptr (place-ptr-offset x)))
    ((typep x 'simple-array)
     (let ((offset (ensure-place-ptr-offset ptr)))
       (if (= 0 offset)
           x
           (make-place-ptr :offset offset
                           :variable x))))
    ((c-pointer-p ptr)
     (let ((offset (ensure-place-ptr-offset x)))
       (if (= 0 offset)
           x
           (make-place-ptr :offset offset
                           :variable ptr))))
    (t
     (let ((offset (ensure-place-ptr-offset x)))
       (if (= 0 offset)
           ptr
           (make-place-ptr :offset offset
                           :variable ptr))))))

(defun %ptr- (x y)
  (cond
    ((and (or (place-ptr-p x) (typep x 'simple-array))
          (or (place-ptr-p y) (typep y 'simple-array)))
     (- (ensure-place-ptr-offset x) (ensure-place-ptr-offset y)))
    (t
     (typecase y
       (place-ptr
        (let ((ptr-offset (typecase x
                            (place-ptr (place-ptr-offset x))
                            (t 0))))
          (- ptr-offset (place-ptr-offset y))))
       (t (%ptr+ x (- y)))))))

(defun %ptr< (x y)
  (dbg "%ptr< ~S ~S~%" x y)
  (< (ensure-place-ptr-offset x) (ensure-place-ptr-offset y)))
(defun %ptr<= (x y)
  (<= (ensure-place-ptr-offset x) (ensure-place-ptr-offset y)))
(defun %ptr> (x y)
  (> (ensure-place-ptr-offset x) (ensure-place-ptr-offset y)))
(defun %ptr>= (x y)
  (>= (ensure-place-ptr-offset x) (ensure-place-ptr-offset y)))
(defun %ptr== (x y)
  (cond
    ((or (null x) (eql 0 x))
     (not (and y (not (eql 0 y)))))
    ((or (null y) (eql 0 y))
     (not (and x (not (eql 0 x)))))
    ((or (not (place-ptr-p x)) (not (place-ptr-p y)))
     (eq x y))
    (t
     (and (eq (place-ptr-variable x) (place-ptr-variable y))
          (= (place-ptr-offset x) (place-ptr-offset y))))))
(defun %ptr!= (x y)
  (not (%ptr== x y)))

(defun vacietis.c:deref* (ptr)
  ;;(dbg "deref*: ~S~%" ptr)
  (etypecase ptr
    (place-ptr (let ((value (place-ptr-closure ptr)))
                 ;;(dbg "  -> ~S~%" value)
                 value))
    (simple-array (aref ptr 0))
    (function ptr)))

(defun (setf vacietis.c:deref*) (new-value ptr)
  (etypecase ptr
    (place-ptr (setf (place-ptr-closure ptr) new-value))
    (simple-array (setf (aref ptr 0) new-value))))

(defun vacietis.c::orig-deref* (ptr)
  (vacietis.c:deref* ptr))
(defun (setf vacietis.c::orig-deref*) (new-value ptr)
  (funcall #'(setf vacietis.c:deref*) new-value ptr))

(defmacro vacietis.c:[] (a i)
  (make-aref a i)
  #+nil
  `(vacietis.c:deref* (vacietis.c:+ ,a ,i)))

(defmacro vacietis.c:|.| (x i)
  (if (and (consp x) (eq 'vacietis.c:|.| (elt x 0)))
      `(vacietis.c:|.| ,(elt x 1) ,(+ (elt x 2) i))
      `(aref ,x ,i)))

;;; arithmetic

;; things that operate on pointers: + - < > <= >= == != ++ -- !

;; may want to make these methods into cases in inlineable functions

(defmethod vacietis.c:+ ((x number) (y number))
  (+ x y))

;;(defmethod vacietis.c:+ ((ptr memptr) (x integer))
;;  (make-memptr :mem (memptr-mem ptr) :ptr (+ x (memptr-ptr ptr))))

(defmethod vacietis.c:+ ((ptr place-ptr) (x integer))
  (%ptr+ ptr x))
(defmethod vacietis.c:- ((ptr place-ptr) (x integer))
  (%ptr- ptr x))

;;(defmethod vacietis.c:+ ((x integer) (ptr memptr))
;;  (vacietis.c:+ ptr x))

(defmethod vacietis.c:- ((x number) (y number))
  (- x y))

;;(defmethod vacietis.c:- ((ptr memptr) (x integer))
;;  (make-memptr :mem (memptr-mem ptr) :ptr (- (memptr-ptr ptr) x)))

;;(defmethod vacietis.c:- ((ptr1 memptr) (ptr2 memptr))
;;  (assert (eq (memptr-mem ptr1) (memptr-mem ptr2)) ()
;;          "Trying to subtract pointers from two different memory segments")
;;  (- (memptr-ptr ptr1) (memptr-ptr ptr2)))

;;; comparison operators

(define-binary-op-mapping-definer define-comparison-ops
  `(progn (defmethod ,op ((x place-ptr) (y place-ptr))
            (and (eq  (place-ptr-variable x) (place-ptr-variable y))
                     (,cl (place-ptr-offset x) (place-ptr-offset y))))
          (defmethod ,op ((x number) (y number))
            (,cl x y))))

#+nil
(define-binary-op-mapping-definer define-comparison-ops
  `(progn (defmethod ,op ((x memptr) (y memptr))
            (if (and (eq  (memptr-mem x) (memptr-mem y))
                     (,cl (memptr-ptr x) (memptr-ptr y)))
                1
                0))
          (defmethod ,op ((x number) (y number))
            (if (,cl x y) 1 0))))

(define-comparison-ops
  == =
  <  <
  >  >
  <= <=
  >= >=)

(defmethod vacietis.c:== (x y)
  (declare (ignore x y))
  0)

;;; boolean algebra

(declaim (inline vacietis.c:!))
(defun vacietis.c:! (x)
  (if (eql x 0) 1 0))

(declaim (inline vacietis.c:!=))
(defun vacietis.c:!= (x y)
  (vacietis.c:! (vacietis.c:== x y)))

(defmacro vacietis.c:&& (a b)
  `(if (or (eql ,a 0) (eql ,b 0)) 0 1))

(defmacro vacietis.c:|\|\|| (a b)
  `(if (or (not (eql ,a 0)) (not (eql ,b 0))) 1 0))

;;; assignment

(defmacro vacietis.c:= (lvalue rvalue)
  (dbg "vacietis.c:=: ~S ~S~%" lvalue rvalue)
  `(setf ,lvalue ,rvalue))

(defmacro unroll-assignment-ops (&rest ops)
  `(progn
     ,@(loop for op in ops collect
            `(defmacro ,(find-symbol (symbol-name op) '#:vacietis.c)
                 (lvalue rvalue)
               `(setf ,lvalue
                      (,',(find-symbol
                           (reverse (subseq (reverse (symbol-name op)) 1))
                           '#:vacietis.c)
                          ,lvalue
                          ,rvalue))))))

(unroll-assignment-ops += -= *= integer/= ptr+= ptr-= %= <<= >>= &= ^= |\|=|)

;;; iteration

(defmacro vacietis.c:for ((bindings initialization test increment) body)
  `(let ,bindings
     (vacietis::do-tagbody ,@(awhen initialization (list it))
       for-loop-label
        (when (eql 0 ,test)
          (go vacietis.c:break))
        ,body
      vacietis.c:continue
        ,@(awhen increment (list it))
        (go for-loop-label)
      vacietis.c:break)))

(defmacro vacietis.c:do (body test)
  `(vacietis::do-tagbody do-loop-label
      ,body
    vacietis.c:continue
    (if ,test
        (go do-loop-label)
        (go vacietis.c:break))
    vacietis.c:break))

;;; switch

(defmacro vacietis.c:switch (exp cases body)
  `(vacietis::do-tagbody
      (case ,exp
        ,@(mapcar (lambda (x) `(,x (go ,x))) cases)
        (t (go ,(if (find 'vacietis.c:default body)
                    'vacietis.c:default
                    'vacietis.c:break))))
      ,@body
      vacietis.c:break))
