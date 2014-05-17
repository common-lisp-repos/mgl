;;;; Code for the MNIST handwritten digit recognition challange.
;;;;
;;;; See papers by Geoffrey Hinton, for the DBN-to-BPN approach:
;;;;
;;;;   To Recognize Shapes, First Learn to Generate Images,
;;;;   http://www.cs.toronto.edu/~hinton/absps/montrealTR.pdf
;;;;
;;;;   http://www.cs.toronto.edu/~hinton/MatlabForSciencePaper.html
;;;;
;;;; and for the DBN-to-DBM-to-BPN one:
;;;;
;;;;   "Deep Boltzmann Machines",
;;;;   http://www.cs.toronto.edu/~hinton/absps/dbm.pdf
;;;;
;;;; Download the four files from http://yann.lecun.com/exdb/mnist and
;;;; gunzip them. Set *MNIST-DATA-DIR* to point to their directory and
;;;; call TRAIN-MNIST/1 or TRAIN-MNIST/2 for DBN-to-BPN and
;;;; DBN-to-DBM-to-BPN approaches, respectively.
;;;;
;;;;
;;;; DBN-to-BPN (see TRAIN-MNIST/1)
;;;;
;;;; A 784-500-500-2000 deep belief network is trained, then 10
;;;; softmax units are attached to the top layer of the
;;;; backpropagation network converted from the top half of the DBN.
;;;; The new, 2000->10 connections in the backprop network are trained
;;;; for a few batches and finally all weights are trained together.
;;;; Takes less than two days to train on a 2.16GHz Core Duo and
;;;; reaches ~98.86% accuracy.
;;;;
;;;; During DBN training the DBN TEST RMSE is the RMSE of the mean
;;;; field reconstruction of the test images while TRAINING RMSE is of
;;;; the stochastic reconstructions (that is, the hidden layer is
;;;; sampled) during training. Naturally, the stochastic one tends to
;;;; be higher but is cheap to compute.
;;;;
;;;; MGL is marginally faster (~10%) training the first RBM than the
;;;; original matlab code when both are using single-threaded BLAS.
;;;; Since 86% percent of the time is spent in BLAS this probably
;;;; means only that the two BLAS implementations perform similarly.
;;;; However, since the matlab code precomputes inputs for the stacked
;;;; RBMs, this code is a doing a lot more on them making it ~32%
;;;; slower on the 2nd. Probably due to the size of last layer, the
;;;; picture changes again in the 3rd rbm: they are roughly on par.
;;;;
;;;; CG training of the BPN is also of the same speed except for the
;;;; first phase where only the softmax weights are trained. Here,
;;;; this code is about 6 times slower due to the input being clamped
;;;; at the usual place and the BPN forwarded which is avoidable in
;;;; this case, but it's not very important as the vast majority of
;;;; time is spent training the whole BPN.
;;;;
;;;;
;;;; DBN-to-DBM-to-BPN (see TRAIN-MNIST/2)
;;;;
;;;; A 784-500-1000 DBM is pretrained as a DBN then the DBM is
;;;; translated to a BPN. It's pretty much the same training process
;;;; as before except that after the DBN the DBM is trained by PCD
;;;; before unrolling that into a BPN. Accuracy is ~99.09% a bit
;;;; higher than the reported 99.05%.

(in-package :mgl-example-mnist)

(defparameter *mnist-data-dir*
  (merge-pathnames "mnist-data/" *example-dir*)
  "Set this to the directory where the uncompressed mnist files reside.")

(defparameter *mnist-save-dir*
  (merge-pathnames "mnist-save/" *example-dir*)
  "Set this to the directory where the trained models are saved.")

(defstruct image
  (label nil :type (integer 0 10))
  (array nil :type mat))

(defmethod label ((image image))
  (image-label image))


;;;; Reading the files

(defun read-low-endian-ub32 (stream)
  (+ (ash (read-byte stream) 24)
     (ash (read-byte stream) 16)
     (ash (read-byte stream) 8)
     (read-byte stream)))

(defun read-magic-or-lose (stream magic)
  (unless (eql magic (read-low-endian-ub32 stream))
    (error "Bad magic.")))

(defun read-image-labels (stream)
  (read-magic-or-lose stream 2049)
  (let ((n (read-low-endian-ub32 stream)))
    (loop repeat n collect (read-byte stream))))

(defun read-image-array (stream)
  (let ((a (make-array (* 28 28) :element-type 'mgl-util:flt)))
    (loop for i below (* 28 28) do
      (let ((pixel (/ (read-byte stream) #.(flt 255))))
        (unless (<= 0 pixel 1)
          (error "~S" pixel))
        (setf (aref a i) pixel)))
    (array-to-mat a)))

(defun print-image-array (a)
  (with-facets ((a (a 'backing-array :direction :input)))
    (dotimes (y 28)
      (dotimes (x 28)
        (princ (if (< 0.5 (aref a (+ (* y 28) x))) #\O #\.)))
      (terpri))))

#+nil
(dotimes (i 100)
  (print-image-array (image-array (aref *training-images* i)))
  (print (image-label (aref *training-images* i)))
  (terpri))

(defun read-image-arrays (stream)
  (read-magic-or-lose stream 2051)
  (let ((n (read-low-endian-ub32 stream)))
    (read-magic-or-lose stream 28)
    (read-magic-or-lose stream 28)
    (coerce (loop repeat n collect (read-image-array stream))
            'vector)))

(defun load-training (&optional (mnist-data-dir *mnist-data-dir*))
  (log-msg "Loading training images~%")
  (prog1
      (map 'vector
           (lambda (label array)
             (make-image :label label :array array))
           (with-open-file (s (merge-pathnames "train-labels-idx1-ubyte"
                                               mnist-data-dir)
                            :element-type 'unsigned-byte)
             (read-image-labels s))
           (with-open-file (s (merge-pathnames "train-images-idx3-ubyte"
                                               mnist-data-dir)
                            :element-type 'unsigned-byte)
             (read-image-arrays s)))
    (log-msg "Loading training images done~%")))

(defun load-test (&optional (mnist-data-dir *mnist-data-dir*))
  (log-msg "Loading test images~%")
  (prog1
      (map 'vector
           (lambda (label array)
             (make-image :label label :array array))
           (with-open-file (s (merge-pathnames "t10k-labels-idx1-ubyte"
                                               mnist-data-dir)
                            :element-type 'unsigned-byte)
             (read-image-labels s))
           (with-open-file (s (merge-pathnames "t10k-images-idx3-ubyte"
                                               mnist-data-dir)
                            :element-type 'unsigned-byte)
             (read-image-arrays s)))
    (log-msg "Loading test images done~%")))

(defvar *training-images*)
(defvar *test-images*)


;;;; Sampling, clamping, utilities

(defun make-sampler (stories &key max-n omit-label-p sample-visible-p)
  (make-instance 'counting-function-sampler
                 :max-n-samples max-n
                 :sampler (let ((g (make-random-generator stories)))
                            (lambda ()
                              (list (funcall g)
                                    :omit-label-p omit-label-p
                                    :sample-visible-p sample-visible-p)))))

(defun make-training-sampler (&key omit-label-p)
  (make-sampler (subseq *training-images* 0 1000)
                :max-n 1000
                :omit-label-p omit-label-p))

(defun make-test-sampler (&key omit-label-p)
  (make-sampler *test-images*
                :max-n (length *test-images*)
                :omit-label-p omit-label-p))

(defun clamp-array (image array start)
  (declare (type flt-vector array)
           (optimize (speed 3)))
  (with-facets ((image-array ((image-array image) 'backing-array
                              :direction :input :type flt-vector)))
    (replace array image-array :start1 start)))

(defun clamp-striped-nodes (images striped)
  (assert (= (length images) (n-stripes striped)))
  (if (use-cuda-p)
      (let ((nodes (nodes striped)))
        (with-shape-and-displacement (nodes)
          (loop for image in images
                for stripe upfrom 0
                do (destructuring-bind (image &key omit-label-p
                                        sample-visible-p)
                       image
                     (declare (ignore omit-label-p sample-visible-p))
                     (with-stripes ((stripe striped start))
                       (reshape-and-displace! nodes #.(* 28 28) start)
                       (copy! (image-array image) nodes))))))
      (with-facets ((nodes ((nodes striped) 'backing-array :direction :output
                            :type flt-vector)))
        (loop for image in images
              for stripe upfrom 0
              do (destructuring-bind (image &key omit-label-p sample-visible-p)
                     image
                   (declare (ignore omit-label-p sample-visible-p))
                   (with-stripes ((stripe striped start))
                     (clamp-array image nodes start)))))))


;;;; Logging

(defclass mnist-base-trainer (cesc-trainer) ())

(defmethod log-training-period ((trainer mnist-base-trainer) learner)
  (declare (ignore learner))
  (length *training-images*))

(defmethod log-test-period ((trainer mnist-base-trainer) learner)
  (declare (ignore learner))
  (length *training-images*))


;;;; DBN

(defclass mnist-dbn (dbn) ())

(defclass mnist-rbm (rbm) ())

(defmethod set-input (images (rbm mnist-rbm))
  (let ((inputs (find 'inputs (visible-chunks rbm)
                      :key #'name)))
    (when inputs
      (clamp-striped-nodes images inputs))))

(defclass mnist-rbm-trainer (mnist-base-trainer segmented-gd-trainer)
  ())

(defclass mnist-rbm-cd-learner (rbm-cd-learner)
  ((trainer :initarg :trainer :reader trainer)))

(defmethod n-gibbs ((learner mnist-rbm-cd-learner))
  (let ((x (slot-value learner 'n-gibbs)))
    (if (integerp x)
        x
        (funcall x (trainer learner)))))

(defmethod log-test-error ((trainer mnist-rbm-trainer) learner)
  (call-next-method)
  (let ((rbm (rbm learner)))
    (log-dbn-cesc-accuracy rbm (make-training-sampler)
                           "training reconstruction")
    (log-dbn-cesc-accuracy rbm (make-training-sampler :omit-label-p t)
                           "training")
    (map nil (lambda (counter)
               (log-msg "dbn test: ~:_test ~:_~A~%" counter))
         (collect-dbn-mean-field-errors/labeled
          (make-test-sampler) (dbn rbm) :rbm rbm
          :counters-and-measurers
          (make-dbn-reconstruction-rmse-counters-and-measurers
           (dbn rbm) :rbm rbm)))
    (log-dbn-cesc-accuracy rbm (make-test-sampler :omit-label-p t) "test")
    (log-msg "---------------------------------------------------~%")))


;;;; DBN training

(defclass mnist-rbm-segment-trainer (batch-gd-trainer) ())

(defmethod learning-rate ((trainer mnist-rbm-segment-trainer))
  (let ((x (slot-value trainer 'learning-rate)))
    (if (numberp x)
        x
        (funcall x trainer))))

(defmethod momentum ((trainer mnist-rbm-segment-trainer))
  (if (< (n-inputs trainer) (* 5 (length *training-images*)))
      #.(flt 0.5)
      #.(flt 0.9)))

#+nil
(defmethod lag ((trainer mnist-rbm-trainer))
  (min (flt 0.99)
       (let ((n (/ (n-inputs trainer)
                   (length *training-images*))))
         (- 1 (expt 0.5 n)))))

(defun init-mnist-dbn (dbn &key stddev (start-level 0))
  (loop for i upfrom start-level
        for rbm in (subseq (rbms dbn) start-level) do
          (flet ((this (x)
                   (if (listp x)
                       (elt x i)
                       x)))
            (do-clouds (cloud rbm)
              (if (conditioning-cloud-p cloud)
                  (fill! (flt 0) (weights cloud))
                  (progn
                    (log-msg "init: ~A ~A~%" cloud (this stddev))
                    (let ((weights (weights cloud)))
                      (with-facets ((weights* (weights 'backing-array
                                                       :direction :output
                                                       :type flt-vector)))
                        
                        (dotimes (i (mat-size weights))
                          (setf (aref weights* i)
                                (flt (* (this stddev)
                                        (gaussian-random-1)))))))))))))

(defun train-mnist-dbn (dbn &key n-epochs n-gibbs learning-rate decay
                        visible-sampling (start-level 0))
  (loop
    for rbm in (subseq (rbms dbn) start-level)
    for i upfrom start-level do
      (log-msg "Starting to train level ~S RBM in DBN.~%" i)
      (flet ((this (x)
               (if (and x (listp x))
                   (elt x i)
                   x)))
        (let* ((n (length *training-images*))
               (trainer
                 (make-instance 'mnist-rbm-trainer
                                :segmenter
                                (lambda (cloud)
                                  (make-instance 'mnist-rbm-segment-trainer
                                                 :learning-rate
                                                 (this learning-rate)
                                                 :weight-decay
                                                 (if (conditioning-cloud-p
                                                      cloud)
                                                     (flt 0)
                                                     (this decay))
                                                 :batch-size 100)))))
          (train (make-sampler *training-images*
                               :max-n (* n-epochs n)
                               :sample-visible-p (this visible-sampling))
                 trainer
                 (make-instance 'mnist-rbm-cd-learner
                                :trainer trainer
                                :rbm rbm
                                :visible-sampling (this visible-sampling)
                                :n-gibbs (this n-gibbs)))))))


;;;; BPN

(defclass mnist-bpn (bpn) ())

(defmethod set-input (images (bpn mnist-bpn))
  (let* ((inputs (find-lump (chunk-lump-name 'inputs nil) bpn :errorp t))
         (expectations (find-lump 'expectations bpn :errorp t))
         (inputs-nodes (nodes inputs)))
    (with-facets ((expectations-nodes ((nodes expectations) 'backing-array
                                       :direction :output
                                       :type flt-vector)))
      (loop for image in images
            for stripe upfrom 0
            do (destructuring-bind (image &key omit-label-p sample-visible-p)
                   image
                 (assert omit-label-p)
                 (assert (not sample-visible-p))
                 (with-stripes ((stripe inputs inputs-start))
                   (with-shape-and-displacement (inputs-nodes #.(* 28 28)
                                                              inputs-start)
                     (copy! (image-array image) inputs-nodes)))
                 (with-stripes ((stripe expectations expectations-start
                                        expectations-end))
                   (locally (declare (optimize (speed 3)))
                     (fill expectations-nodes #.(flt 0)
                           :start expectations-start
                           :end expectations-end))
                   (setf (aref expectations-nodes
                               (+ expectations-start (image-label image)))
                         #.(flt 1))))))))

(defun make-bpn (defs chunk-name &key class initargs)
  (let ((bpn-def `(build-bpn (:class ',class
                              :max-n-stripes 1000
                              :initargs ',initargs)
                    ,@defs
                    ,@(tack-cross-entropy-softmax-error-on
                       10
                       (chunk-lump-name chunk-name nil)
                       :prefix '||))))
    (log-msg "bpn def:~%~S~%" bpn-def)
    (eval bpn-def)))


;;;; BPN training

(defclass mnist-bp-trainer (mnist-base-trainer) ())

(defclass mnist-cg-bp-trainer (mnist-bp-trainer cg-trainer) ())

(defmethod log-test-error ((trainer mnist-bp-trainer) learner)
  (call-next-method)
  (map nil (lambda (counter)
             (log-msg "bpn test: test ~:_~A~%" counter))
       (bpn-cesc-error (make-test-sampler :omit-label-p t) (bpn learner)))
  (log-msg "---------------------------------------------------~%"))

(defun init-weights (name bpn deviation)
  (multiple-value-bind (mat start end)
      (segment-weights (find-lump name bpn :errorp t))
    (with-facets ((array (mat 'backing-array :direction :output
                              :type flt-vector)))
      (loop for i upfrom start below end
            do (setf (aref array i) (flt (* deviation (gaussian-random-1))))))))

(defun train-mnist-bpn (bpn &key (batch-size
                                  (min (length *training-images*) 1000))
                        (n-softmax-epochs 5) n-epochs)
  (log-msg "Starting to train the softmax layer of BPN~%")
  (train (make-sampler *training-images*
                       :max-n (* n-softmax-epochs (length *training-images*))
                       :omit-label-p t)
         (make-instance 'mnist-cg-bp-trainer
                        :cg-args (list :max-n-line-searches 3)
                        :batch-size batch-size
                        :segment-filter
                        (lambda (lump)
                          (or (eq (name lump) 'prediction-biases)
                              (eq (name lump) 'prediction-weights))))
         (make-instance 'bp-learner :bpn bpn))
  (log-msg "Starting to train the whole BPN~%")
  (train (make-sampler *training-images*
                       :max-n (* (- n-epochs n-softmax-epochs)
                                 (length *training-images*))
                       :omit-label-p t)
         (make-instance 'mnist-cg-bp-trainer
                        :cg-args (list :max-n-line-searches 3)
                        :batch-size batch-size)
         (make-instance 'bp-learner :bpn bpn)))


;;;; Code for the DBN to BPN approach (paper [1]) and also for dropout
;;;; training with the bpn (paper [3]) with :DROPOUT T.

(defclass mnist-dbn/1 (mnist-dbn)
  ()
  (:default-initargs
   :layers (list (list (make-instance 'constant-chunk :name 'c0)
                       (make-instance 'sigmoid-chunk :name 'inputs
                                      :size (* 28 28)))
                 (list (make-instance 'constant-chunk :name 'c1)
                       (make-instance 'sigmoid-chunk :name 'f1
                                      :size 500))
                 (list (make-instance 'constant-chunk :name 'c2)
                       (make-instance 'sigmoid-chunk :name 'f2
                                      :size 500))
                 (list (make-instance 'constant-chunk :name 'c3)
                       (make-instance 'sigmoid-chunk :name 'f3
                                      :size 2000)))
    :rbm-class 'mnist-rbm
    :max-n-stripes 100))

(defun unroll-mnist-dbn/1 (dbn)
  (multiple-value-bind (defs inits) (unroll-dbn dbn :bottom-up-only t)
    (log-msg "bpn inits:~%~S~%" inits)
    (let ((bpn (make-bpn defs 'f3 :class 'mnist-bpn)))
      (initialize-bpn-from-bm bpn dbn inits)
      (init-weights 'prediction-weights bpn 0.1)
      (init-weights 'prediction-biases bpn 0.1)
      bpn)))

(defvar *dbn/1*)
(defvar *bpn/1*)

(defparameter *mnist-1-dbn-filename*
  (merge-pathnames "mnist-1.dbn" *mnist-save-dir*))

(defparameter *mnist-1-dropout-bpn-filename*
  (merge-pathnames "mnist-1-dropout.bpn" *mnist-save-dir*))

(defparameter *mnist-1-bpn-filename*
  (merge-pathnames "mnist-1.bpn" *mnist-save-dir*))

(defun train-mnist/1 (&key load-dbn-p quick-run-p dropoutp)
  (unless (boundp '*training-images*)
    (setq *training-images* (load-training)))
  (unless (boundp '*test-images*)
    (setq *test-images* (load-test)))
  (cond (load-dbn-p
         (setq *dbn/1* (make-instance 'mnist-dbn/1))
         (load-weights *mnist-1-dbn-filename* *dbn/1*)
         (log-msg "Loaded DBN~%")
         (map nil (lambda (counter)
                    (log-msg "dbn test ~:_~A~%" counter))
              (collect-dbn-mean-field-errors/labeled (make-test-sampler)
                                                     *dbn/1*)))
        (t
         (setq *dbn/1* (make-instance 'mnist-dbn/1))
         (init-mnist-dbn *dbn/1* :stddev 0.1)
         (train-mnist-dbn *dbn/1* :n-epochs (if quick-run-p 2 50) :n-gibbs 1
                          :start-level 0 :learning-rate (flt 0.1)
                          :decay (flt 0.0002) :visible-sampling nil)
         (unless quick-run-p
           (save-weights *mnist-1-dbn-filename* *dbn/1*))))
  (setq *bpn/1* (unroll-mnist-dbn/1 *dbn/1*))
  (cond (dropoutp
         (train-mnist-bpn-gd *bpn/1*
                             :n-softmax-epochs (if quick-run-p 1 10)
                             :n-epochs (if quick-run-p 2 1000)
                             :learning-rate (flt 1)
                             :learning-rate-decay (flt 0.998)
                             :l2-upper-bound nil
                             :rescale-on-dropout-p t)
         (unless quick-run-p
           (save-weights *mnist-1-dropout-bpn-filename* *bpn/1*)))
        (t
         (train-mnist-bpn *bpn/1*
                          :n-softmax-epochs (if quick-run-p 1 5)
                          :n-epochs (if quick-run-p 1 37))
         (unless quick-run-p
           (save-weights *mnist-1-bpn-filename* *bpn/1*)))))


;;;; Code for the DBN to DBM to BPN approach (paper [2]) and also for
;;;; dropout training with the bpn (paper [3]) with :DROPOUT T.

(defvar *dbn/2*)
(defvar *dbm/2*)
(defvar *bpn/2*)

(defparameter *mnist-2-dbn-filename*
  (merge-pathnames "mnist-2.dbn" *mnist-save-dir*))

(defparameter *mnist-2-dbm-filename*
  (merge-pathnames "mnist-2.dbm" *mnist-save-dir*))

(defparameter *mnist-2-bpn-filename*
  (merge-pathnames "mnist-2.bpn" *mnist-save-dir*))

(defparameter *mnist-2-dropout-bpn-filename*
  (merge-pathnames "mnist-2-dropout.bpn" *mnist-save-dir*))

(defclass mnist-rbm/2 (mnist-rbm) ())
(defclass mnist-bpn/2 (mnist-bpn bpn-clamping-cache) ())

(defun clamp-labels (images chunk)
  (setf (indices-present chunk)
        (if (and images (getf (rest (elt images 0)) :omit-label-p))
            (make-array 0 :element-type 'index)
            nil))
  (with-facets ((nodes ((nodes chunk) 'backing-array :direction :output
                        :type flt-vector)))
    (loop for image in images
          for stripe upfrom 0
          do (destructuring-bind (image &key omit-label-p sample-visible-p)
                 image
               (declare (ignore sample-visible-p))
               (with-stripes ((stripe chunk start end))
                 (unless omit-label-p
                   (fill nodes (flt 0) :start start :end end)
                   (setf (aref nodes (+ start (image-label image)))
                         #.(flt 1))))))))

(defun strip-sample-visible (samples)
  (mapcar (lambda (sample)
            (destructuring-bind (image &key omit-label-p sample-visible-p)
                sample
              (declare (ignore sample-visible-p))
              (list image :omit-label-p omit-label-p)))
          samples))

(defmethod set-input (images (rbm mnist-rbm/2))
  (call-next-method (strip-sample-visible images) rbm)
  ;; All samples have the same SAMPLE-VISIBLE-P, look at the first
  ;; only.
  (when (and images (getf (rest (elt images 0)) :sample-visible-p))
    (sample-visible rbm))
  (let ((label-chunk (find-chunk 'label rbm)))
    (when label-chunk
      (clamp-labels images label-chunk))))

(defclass mnist-dbm (dbm)
  ((layers :initform (list
                      (list (make-instance 'constant-chunk :name 'c0)
                            (make-instance 'sigmoid-chunk :name 'inputs
                                           :size (* 28 28)))
                      (list (make-instance 'constant-chunk :name 'c1)
                            (make-instance 'sigmoid-chunk :name 'f1
                                           :size 500)
                            (make-instance 'softmax-label-chunk* :name 'label
                                           :size 10 :group-size 10))
                      (list (make-instance 'constant-chunk :name 'c2)
                            (make-instance 'sigmoid-chunk :name 'f2
                                           :size 1000))))
   (clouds :initform '(:merge
                       (:chunk1 c0 :chunk2 label :class nil)
                       (:chunk1 inputs :chunk2 label :class nil)))))

(defun make-mnist-dbm ()
  (make-instance 'mnist-dbm :max-n-stripes 100))

(defmethod set-input (images (dbm mnist-dbm))
  (clamp-striped-nodes images (mgl-bm:find-chunk 'inputs dbm))
  (when (and images (getf (rest (elt images 0)) :sample-visible-p))
    (sample-visible dbm))
  (let ((label-chunk (find-chunk 'label dbm :errorp t)))
    (clamp-labels images label-chunk)))

(defclass mnist-dbm-trainer (mnist-base-trainer segmented-gd-trainer)
  ())

(defmethod log-test-error ((trainer mnist-dbm-trainer) learner)
  (call-next-method)
  (let ((dbm (bm learner)))
    (log-dbm-cesc-accuracy dbm (make-training-sampler)
                           "training reconstruction")
    (log-dbm-cesc-accuracy dbm (make-training-sampler :omit-label-p t)
                           "training")
    ;; This is too time consuming for little benefit.
    #+nil
    (map nil (lambda (counter)
               (log-msg "dbm test: ~:_test ~:_~A~%" counter))
         (collect-bm-mean-field-errors
          (make-test-sampler) dbm
          :counters-and-measurers
          (make-dbm-reconstruction-rmse-counters-and-measurers dbm)))
    (log-dbm-cesc-accuracy dbm (make-test-sampler :omit-label-p t) "test")
    (log-msg "---------------------------------------------------~%")))

(defclass mnist-dbm-segment-trainer (batch-gd-trainer) ())

(defmethod learning-rate ((trainer mnist-dbm-segment-trainer))
  ;; This is adjusted for each batch. Ruslan's code adjusts it per
  ;; epoch.
  (/ (slot-value trainer 'learning-rate)
     (min (flt 10)
          (expt 1.000015
                (* (/ (n-inputs trainer)
                      (length *training-images*))
                   600)))))

(defmethod momentum ((trainer mnist-dbm-segment-trainer))
  (if (< (n-inputs trainer) (* 5 (length *training-images*)))
      #.(flt 0.5)
      #.(flt 0.9)))

(defmethod initialize-gradient-source (learner dbm (trainer mnist-dbm-trainer))
  (declare (ignore dbm))
  (when (next-method-p)
    (call-next-method))
  (set-input (sample-batch (make-sampler *training-images*
                                         :max-n (length *training-images*)
                                         :sample-visible-p t)
                           (n-particles learner))
             (persistent-chains learner))
  (up-dbm (persistent-chains learner)))

(defun train-mnist-dbm (dbm &key (n-epochs 500))
  (log-msg "Starting to train DBM.~%")
  (train (make-sampler *training-images*
                       :max-n (* n-epochs (length *training-images*))
                       :sample-visible-p t)
         (make-instance 'mnist-dbm-trainer
                        :segmenter
                        (lambda (cloud)
                          (make-instance 'mnist-dbm-segment-trainer
                                         :learning-rate (flt 0.001)
                                         :weight-decay
                                         (if (conditioning-cloud-p cloud)
                                             (flt 0)
                                             (flt 0.0002))
                                         :batch-size 100)))
         (make-instance 'bm-pcd-learner
                        :bm dbm
                        :n-particles 100
                        :visible-sampling t
                        :n-gibbs 5
                        :sparser
                        (lambda (cloud chunk)
                          (when (and (member (name chunk) '(f1 f2))
                                     (not (equal 'label (name (chunk1 cloud))))
                                     (not (equal 'label (name (chunk2 cloud)))))
                            (make-instance
                             'cheating-sparsity-gradient-source
                             :cloud cloud
                             :chunk chunk
                             :sparsity (flt (if (eq 'f2 (name chunk))
                                                0.1
                                                0.2))
                             :cost (flt 0.001)
                             :damping (flt 0.9)))))))

(defun make-mnist-dbn/2 (dbm)
  (mgl-bm:dbm->dbn dbm :dbn-class 'mnist-dbn :rbm-class 'mnist-rbm/2
                   :dbn-initargs '(:max-n-stripes 100)))

(defun unroll-mnist-dbm (dbm &key use-label-weights initargs)
  (multiple-value-bind (defs inits)
      (unroll-dbm dbm :chunks (remove 'label (chunks dbm) :key #'name))
    (log-msg "inits:~%~S~%" inits)
    (let ((bpn (make-bpn defs 'f2 :class 'mnist-bpn/2 :initargs initargs)))
      (initialize-bpn-from-bm bpn dbm
                              (if use-label-weights
                                  (list*
                                   '(:cloud-name (label c2)
                                     :weight-name prediction-biases)
                                   '(:cloud-name (label f2)
                                     :weight-name prediction-weights)
                                   inits)
                                  inits))
      bpn)))

(defun train-mnist/2 (&key load-dbn-p load-dbm-p dropoutp quick-run-p)
  (unless (boundp '*training-images*)
    (setq *training-images* (load-training)))
  (unless (boundp '*test-images*)
    (setq *test-images* (load-test)))
  (flet ((train-dbn ()
           (init-mnist-dbn *dbn/2* :stddev '(0.001 0.01) :start-level 0)
           (train-mnist-dbn
            *dbn/2*
            :start-level 0
            :n-epochs (if quick-run-p 2 100)
            :n-gibbs (list 1
                           (lambda (trainer)
                             (ceiling (1+ (n-inputs trainer))
                                      (* 20 (length *training-images*)))))
            :learning-rate
            (list (flt 0.05)
                  (lambda (trainer)
                    (/ (flt 0.05)
                       (ceiling (1+ (n-inputs trainer))
                                (* 20 (length *training-images*))))))
            :decay (flt 0.001)
            :visible-sampling t)
           (unless quick-run-p
             (save-weights *mnist-2-dbn-filename* *dbn/2*)))
         (train-dbm ()
           (train-mnist-dbm *dbm/2* :n-epochs (if quick-run-p 1 500))
           (unless quick-run-p
             (save-weights *mnist-2-dbm-filename* *dbm/2*))))
    (cond (load-dbm-p
           (setq *dbm/2* (make-mnist-dbm))
           (load-weights *mnist-2-dbm-filename* *dbm/2*))
          (load-dbn-p
           (setq *dbm/2* (make-mnist-dbm))
           (setq *dbn/2* (make-mnist-dbn/2 *dbm/2*))
           (load-weights *mnist-2-dbn-filename* *dbn/2*)
           (log-msg "Loaded DBN~%")
           (train-dbm))
          (t
           (setq *dbm/2* (make-mnist-dbm))
           (setq *dbn/2* (make-mnist-dbn/2 *dbm/2*))
           (train-dbn)
           (train-dbm)))
    (setq *bpn/2*
          (unroll-mnist-dbm
           *dbm/2*
           :use-label-weights t
           :initargs
           ;; We are playing games with wrapping image objects in
           ;; lists when sampling, so let the map cache know what's
           ;; the key in the cache and what to pass to the dbm. We
           ;; carefully omit labels.
           (list :populate-key #'first
                 :populate-convert-to-dbm-sample-fn
                 (lambda (sample)
                   (list (first sample)
                         :sample-visible-p nil
                         :omit-label-p t))
                 :populate-map-cache-lazily-from-dbm *dbm/2*
                 :populate-periodic-fn
                 (make-instance 'periodic-fn :period 1000
                                :fn (lambda (n)
                                      (log-msg "populated: ~S~%" n))))))
    (unless (populate-map-cache-lazily-from-dbm *bpn/2*)
      (log-msg "Populating MAP cache~%")
      (populate-map-cache *bpn/2* *dbm/2* (concatenate 'vector *training-images*
                                                       *test-images*)
                          :if-exists :error))
    (cond (dropoutp
           (train-mnist-bpn-gd *bpn/2*
                               :n-softmax-epochs 0
                               :n-epochs (if quick-run-p 2 1000)
                               :learning-rate (flt 1)
                               :learning-rate-decay (flt 0.998)
                               :l2-upper-bound nil
                               :rescale-on-dropout-p t)
           (unless quick-run-p
             (save-weights *mnist-2-dropout-bpn-filename* *bpn/2*)))
          (t
           (train-mnist-bpn *bpn/2* :batch-size 10000
                            :n-softmax-epochs (if quick-run-p 1 5)
                            :n-epochs (if quick-run-p 1 100))
           (unless quick-run-p
             (save-weights *mnist-2-bpn-filename* *bpn/2*))))))

(defmethod negative-phase (batch (learner bm-pcd-learner)
                           (trainer mnist-dbm-trainer) multiplier)
  (let ((bm (persistent-chains learner)))
    (mgl-bm::check-no-self-connection bm)
    (flet ((foo (chunk)
             (mgl-bm::set-mean (list chunk) bm)
             (sample-chunk chunk)))
      (loop for i below (n-gibbs learner) do
        (sample-chunk (find-chunk 'f1 bm))
        (foo (find-chunk 'inputs bm))
        (foo (find-chunk 'f2 bm))
        (foo (find-chunk 'label bm))
        (mgl-bm::set-mean (list (find-chunk 'f1 bm)) bm))
      (mgl-bm::set-mean* (list (find-chunk 'f2 bm)) bm)
      (mgl-bm::accumulate-negative-phase-statistics
       learner trainer
       (* multiplier (/ (length batch) (n-stripes bm)))))))


;;;; Code for the plain dropout backpropagation network with rectified
;;;; linear units (paper [3])

(defclass mnist-bpn-gd-trainer (mnist-bp-trainer segmented-gd-trainer)
  ())

#+nil
(defclass mnist-bpn-gd-trainer (mnist-bp-trainer svrg-trainer)
  ())

(defclass mnist-bpn-gd-segment-trainer (batch-gd-trainer)
  ((n-inputs-in-epoch :initarg :n-inputs-in-epoch
                      :reader n-inputs-in-epoch)
   (n-epochs-to-reach-final-momentum
    :initarg :n-epochs-to-reach-final-momentum
    :reader n-epochs-to-reach-final-momentum)
   (learning-rate-decay
    :initform (flt 0.998)
    :initarg :learning-rate-decay
    :accessor learning-rate-decay)))

(defmethod learning-rate ((trainer mnist-bpn-gd-segment-trainer))
  (* (expt (learning-rate-decay trainer)
           (/ (n-inputs trainer)
              (n-inputs-in-epoch trainer)))
     (- 1 (momentum trainer))
     (slot-value trainer 'learning-rate)))

(defmethod momentum ((trainer mnist-bpn-gd-segment-trainer))
  (let ((n-epochs-to-reach-final (n-epochs-to-reach-final-momentum trainer))
        (initial (flt 0.5))
        (final (flt 0.99))
        (epoch (/ (n-inputs trainer)
                  (n-inputs-in-epoch trainer))))
    (if (< epoch n-epochs-to-reach-final)
        (let ((weight (/ epoch n-epochs-to-reach-final)))
          (+ (* initial (- 1 weight))
             (* final weight)))
        final)))

#+nil
(defmethod lag ((trainer mnist-bpn-gd-trainer))
  (min (flt 0.99)
       (let ((n (/ (n-inputs trainer)
                   (length *training-images*))))
         (- 1 (expt 0.5 n)))))

(defun find-activation-lump-for-weight (->weight bpn)
  (loop for lump across (lumps bpn) do
    (when (and (typep lump '->activation)
               (eq (mgl-bp::weights lump) ->weight))
      (return lump))))

(defun make-grouped-segmenter (name-groups segmenter)
  (let ((group-to-trainer (make-hash-table :test #'equal)))
    (lambda (segment)
      (let* ((name (name segment))
             (group (find-if (lambda (names)
                               (member name names :test #'equal))
                             name-groups)))
        (assert group)
        (or (gethash group group-to-trainer)
            (setf (gethash group group-to-trainer)
                  (funcall segmenter segment)))))))

(defun arrange-for-renormalize-activations (bpn trainer l2-upper-bound)
  (push (let ((->activations nil)
              (firstp t))
          (lambda ()
            (when firstp
              (setq ->activations
                    (loop for lump in (segments trainer)
                          collect (or (find-activation-lump-for-weight lump bpn)
                                      lump)))
              (setq firstp nil))
            (renormalize-activations ->activations l2-upper-bound)))
        (after-update-hook trainer)))

(defun set-dropout-and-rescale-weights (lump dropout bpn)
  (assert (null (dropout lump)))
  (setf (slot-value lump 'dropout) dropout)
  (let ((scale (/ (- (flt 1) dropout))))
    (loop for lump-2 across (lumps bpn) do
      (when (and (typep lump-2 '->activation)
                 (eq lump (mgl-bp::x lump-2))
                 (typep (mgl-bp::weights lump-2) '->weight))
        (log-msg "rescaling ~S by ~,2F~%" lump-2 scale)
        (scal! scale (nodes (mgl-bp::weights lump-2)))))))

(defun train-mnist-bpn-gd (bpn &key (n-softmax-epochs 5) (n-epochs 200)
                           (training *training-images*) l2-upper-bound
                           class-weights learning-rate learning-rate-decay
                           rescale-on-dropout-p)
  (when class-weights
    (setf (class-weights (find-lump 'predictions bpn)) class-weights))
  (setf (max-n-stripes bpn) 100)
  (let ((n (length *training-images*))
        (name-groups '(((:cloud (c0 f1))
                        (:cloud (inputs f1)))
                       ((:cloud (c1 f2))
                        (:cloud (f1 f2)))
                       ((:cloud (c2 f3))
                        (:cloud (f2 f3)))
                       (prediction-biases
                        prediction-weights))))
    (flet ((make-trainer (lump &key softmaxp)
             (declare (ignore lump))
             (let ((trainer (make-instance
                             'mnist-bpn-gd-segment-trainer
                             :n-inputs-in-epoch (length training)
                             :n-epochs-to-reach-final-momentum
                             (min 500
                                  (/ (if softmaxp n-softmax-epochs n-epochs)
                                     2))
                             :learning-rate (flt learning-rate)
                             :learning-rate-decay (flt learning-rate-decay)
                             :batch-size 100)))
               (when l2-upper-bound
                 (arrange-for-renormalize-activations
                  bpn trainer l2-upper-bound))
               trainer))
           (make-segmenter (fn)
             (if l2-upper-bound
                 (make-grouped-segmenter name-groups fn)
                 fn)))
      (unless (zerop n-softmax-epochs)
        (log-msg "Starting to train the softmax layer of BPN~%")
        (train
         (make-sampler training
                       :max-n (* n-softmax-epochs n)
                       :omit-label-p t)
         (make-instance 'mnist-bpn-gd-trainer
                        :segmenter
                        (make-segmenter
                         (lambda (lump)
                           (when (or (eq (name lump) 'prediction-biases)
                                     (eq (name lump) 'prediction-weights))
                             (make-trainer lump :softmaxp t)))))
         (make-instance 'bp-learner :bpn bpn)))
      (map nil (lambda (lump)
                 (when (and (typep lump '->dropout)
                            (not (typep lump '->input)))
                   (log-msg "dropout ~A ~A~%" lump 0.5)
                   (if rescale-on-dropout-p
                       (set-dropout-and-rescale-weights lump (flt 0.5) bpn)
                       (setf (slot-value lump 'dropout) (flt 0.5))))
                 (when (and (typep lump '->input)
                            (name= (name lump) '(:chunk inputs)))
                   (log-msg "dropout ~A ~A~%" lump 0.2)
                   (if rescale-on-dropout-p
                       (set-dropout-and-rescale-weights lump (flt 0.2) bpn)
                       (setf (slot-value lump 'dropout) (flt 0.2)))))
           (lumps bpn))
      (unless (zerop n-epochs)
        (mgl-example-util:log-msg "Starting to train the whole BPN~%")
        (train
         (make-sampler training
                       :max-n (* n-epochs n)
                       :omit-label-p t)
         (make-instance 'mnist-bpn-gd-trainer
                        :segmenter (make-segmenter #'make-trainer))
         (make-instance 'bp-learner :bpn bpn))))))

(defun build-rectified-mnist-bpn (&key (n-units-1 1200) (n-units-2 1200)
                                  (n-units-3 1200))
  (build-bpn (:class 'mnist-bpn :max-n-stripes 100)
    (g1813 (->input :name '(:chunk inputs) :size 784))
    (g1812 (->constant :name '(:chunk c0) :size 1 :default-value (flt 1.0)))
    (g1817 (->weight :name '(:cloud (inputs f1)) :size (* 784 n-units-1)))
    (g1818
     (->activation :name '(:cloud (inputs f1) :linear) :size n-units-1
                   :weights g1817 :x g1813))
    (g1819 (->weight :name '(:cloud (c0 f1)) :size n-units-1))
    (g1820
     (->activation :name '(:cloud (c0 f1) :linear) :size n-units-1
                   :weights g1819 :x g1812))
    (g1816 (->+ :name '(:chunk f1 :activation) :args (list g1818 g1820)))
    (g1811* (->rectified :name '(:chunk f1*) :x g1816))
    (g1811 (->dropout :name '(:chunk f1) :x g1811* :dropout (flt 0.5)))
    (g1810 (->constant :name '(:chunk c1) :size 1 :default-value (flt 1.0)))
    (g1823 (->weight :name '(:cloud (f1 f2)) :size (* n-units-1 n-units-2)))
    (g1824
     (->activation :name '(:cloud (f1 f2) :linear) :size n-units-2
                   :weights g1823 :x g1811))
    (g1825 (->weight :name '(:cloud (c1 f2)) :size n-units-2))
    (g1826
     (->activation :name '(:cloud (c1 f2) :linear) :size n-units-2
                   :weights g1825 :x g1810))
    (g1822 (->+ :name '(:chunk f2 :activation) :args (list g1824 g1826)))
    (g1809* (->rectified :name '(:chunk f2*) :x g1822))
    (g1809 (->dropout  :name '(:chunk f2) :x g1809* :dropout (flt 0.5)))
    (g1807 (->constant :name '(:chunk c2) :size 1 :default-value (flt 1.0)))
    (g1829 (->weight :name '(:cloud (f2 f3)) :size (* n-units-2 n-units-3)))
    (g1830
     (->activation :name '(:cloud (f2 f3) :linear) :size n-units-3
                   :weights g1829 :x g1809))
    (g1831 (->weight :name '(:cloud (c2 f3)) :size n-units-3))
    (g1832
     (->activation :name '(:cloud (c2 f3) :linear) :size n-units-3
                   :weights g1831 :x g1807))
    (g1828 (->+ :name '(:chunk f3 :activation) :args (list g1830 g1832)))
    (g1808* (->rectified :name '(:chunk f3*) :x g1828))
    (g1808 (->dropout :name '(:chunk f3) :x g1808* :dropout (flt 0.5)))
    (expectations (->input :size 10))
    (prediction-weights (->weight :size (* (size (lump '(:chunk f3))) 10)))
    (prediction-biases (->weight :size 10))
    (prediction-activations0
     (->activation :weights prediction-weights :x (lump '(:chunk f3))))
    (prediction-activations
     (->+ :args (list prediction-activations0 prediction-biases)))
    (predictions
     (->cross-entropy-softmax :group-size 10 :x prediction-activations
                              :target expectations))
    (ce-error (->error :x predictions))))

(defun init-bpn-weights (bpn &key stddev)
  (loop for lump across (lumps bpn) do
    (when (typep lump '->weight)
      (with-facets ((nodes ((nodes lump) 'backing-array :direction :output
                            :type flt-vector)))
        (dotimes (i (array-total-size nodes))
          (setf (aref nodes i)
                (flt (* stddev (gaussian-random-1)))))))))

(defvar *bpn/3*)

(defparameter *mnist-3-bpn-filename*
  (merge-pathnames "mnist-3.bpn" *mnist-save-dir*))

(defun train-mnist/3 (&key quick-run-p)
  (unless (boundp '*training-images*)
    (setq *training-images* (load-training)))
  (unless (boundp '*test-images*)
    (setq *test-images* (load-test)))
  (setq *bpn/3* (build-rectified-mnist-bpn))
  (init-bpn-weights *bpn/3* :stddev 0.01)
  (train-mnist-bpn-gd *bpn/3* :n-softmax-epochs 0
                      :n-epochs (if quick-run-p 2 3000)
                      :learning-rate (flt 1)
                      :learning-rate-decay (flt 0.998)
                      :l2-upper-bound (sqrt (flt 15)))
  (unless quick-run-p
    (save-weights *mnist-3-bpn-filename* *bpn/3*)))


;;;; Maxout

(defun build-maxout-mnist-bpn (&key (n-units-1 1200) (n-units-2 1200)
                               #+nil (n-units-3 1200) (group-size 5))
  (build-bpn (:class 'mnist-bpn :max-n-stripes 100)
    (g1813 (->input :name '(:chunk inputs) :size 784))
    (g1812 (->constant :name '(:chunk c0) :size 1 :default-value (flt 1.0)))
    (g1817 (->weight :name '(:cloud (inputs f1)) :size (* 784 n-units-1)))
    (g1818
     (->activation :name '(:cloud (inputs f1) :linear) :size n-units-1
                   :weights g1817 :x g1813))
    (g1819 (->weight :name '(:cloud (c0 f1)) :size n-units-1))
    (g1820
     (->activation :name '(:cloud (c0 f1) :linear) :size n-units-1
                   :weights g1819 :x g1812))
    (g1816 (->+ :name '(:chunk f1 :activation) :args (list g1818 g1820)))
    (g1811* (->max :name '(:chunk f1*) :x g1816 :group-size group-size))
    (g1811 (->dropout :name '(:chunk f1) :x g1811* :dropout (flt 0.5)))
    (g1810 (->constant :name '(:chunk c1) :size 1 :default-value (flt 1.0)))
    (g1823 (->weight :name '(:cloud (f1 f2))
                     :size (* (/ n-units-1 group-size) n-units-2)))
    (g1824
     (->activation :name '(:cloud (f1 f2) :linear) :size n-units-2
                   :weights g1823 :x g1811))
    (g1825 (->weight :name '(:cloud (c1 f2)) :size n-units-2))
    (g1826
     (->activation :name '(:cloud (c1 f2) :linear) :size n-units-2
                   :weights g1825 :x g1810))
    (g1822 (->+ :name '(:chunk f2 :activation) :args (list g1824 g1826)))
    (g1809* (->max :name '(:chunk f2*) :x g1822 :group-size group-size))
    (g1809 (->dropout  :name '(:chunk f2) :x g1809* :dropout (flt 0.5)))
    ;; (g1807 (->constant :name '(:chunk c2) :size 1 :default-value (flt 1.0)))
    ;; (g1829 (->weight :name '(:cloud (f2 f3))
    ;;                  :size (* (/ n-units-2 group-size) n-units-3)))
    ;; (g1830
    ;;  (->activation :name '(:cloud (f2 f3) :linear) :size n-units-3
    ;;                :weights g1829 :x g1809))
    ;; (g1831 (->weight :name '(:cloud (c2 f3)) :size n-units-3))
    ;; (g1832
    ;;  (->activation :name '(:cloud (c2 f3) :linear) :size n-units-3
    ;;                :weights g1831 :x g1807))
    ;; (g1828 (->+ :name '(:chunk f3 :activation) :args (list g1830 g1832)))
    ;; (g1808* (->max :name '(:chunk f3*) :x g1828 :group-size group-size))
    ;; (g1808 (->dropout :name '(:chunk f3) :x g1808* :dropout (flt 0.5)))
    (expectations (->input :size 10))
    (prediction-weights (->weight :size (* (size (lump '(:chunk f2))) 10)))
    (prediction-biases (->weight :size 10))
    (prediction-activations0
     (->activation :weights prediction-weights :x (lump '(:chunk f2))))
    (prediction-activations
     (->+ :args (list prediction-activations0 prediction-biases)))
    (predictions
     (->cross-entropy-softmax :group-size 10 :x prediction-activations
                              :target expectations))
    (ce-error (->error :x predictions))))

(defvar *bpn/4*)

(defparameter *mnist-4-bpn-filename*
  (merge-pathnames "mnist-4.bpn" *mnist-save-dir*))

(defun train-mnist/4 (&key quick-run-p)
  (unless (boundp '*training-images*)
    (setq *training-images* (load-training)))
  (unless (boundp '*test-images*)
    (setq *test-images* (load-test)))
  (setq *bpn/4* (build-maxout-mnist-bpn))
  (init-bpn-weights *bpn/4* :stddev 0.01)
  (train-mnist-bpn-gd *bpn/4*
                      :n-softmax-epochs 0
                      :n-epochs (if quick-run-p 2 3000)
                      :learning-rate (flt 1)
                      :learning-rate-decay (flt 0.998)
                      :l2-upper-bound (sqrt (flt 3.75)))
  (unless quick-run-p
    (save-weights *mnist-4-bpn-filename* *bpn/4*)))

#|

(progn
  (with-cuda ()
    (let ((*random-state* (sb-ext:seed-random-state 983274)))
      (train-mnist/1)))

  (with-cuda ()
    (let ((*random-state* (sb-ext:seed-random-state 983274)))
      (train-mnist/1 :load-dbn-p t :dropoutp t)))

  (with-cuda ()
    (let ((*random-state* (sb-ext:seed-random-state 983274)))
      (train-mnist/2)))

  (with-cuda ()
    (let ((*random-state* (sb-ext:seed-random-state 983274)))
      (train-mnist/2 :load-dbm-p t :dropoutp t)))

  (with-cuda ()
    (let ((*random-state* (sb-ext:seed-random-state 983274)))
      (train-mnist/3)))

  (with-cuda ()
    (let ((*random-state* (sb-ext:seed-random-state 983274)))
      (train-mnist/4))))

(with-cuda ()
  (let ((*random-state* (sb-ext:seed-random-state 983274)))
    (train-mnist/2 :load-dbn-p t :dropoutp t)))

(require :sb-sprof)

(progn
  (sb-sprof:reset)
  (sb-sprof:start-profiling)
  (sleep 10)
  (sb-sprof:stop-profiling)
  (sb-sprof:report :type :graph))

(let ((dgraph (cl-dot:generate-graph-from-roots *dbn/2* (chunks *dbn/2*)
                                                '(:rankdir "BT"))))
  (cl-dot:dot-graph dgraph
                    (asdf-system-relative-pathname "example/mnist-dbn-2.png")
                    :format :png))

(let ((dgraph (cl-dot:generate-graph-from-roots *dbm/2* (chunks *dbm/2*)
                                                '(:rankdir "BT"))))
  (cl-dot:dot-graph dgraph
                    (asdf-system-relative-pathname "example/mnist-dbm-2.png")
                    :format :png))

(let ((dgraph (cl-dot:generate-graph-from-roots *bpn/2* (lumps *bpn/2*))))
  (cl-dot:dot-graph dgraph
                    (asdf-system-relative-pathname "example/mnist-bpn-2.png")
                    :format :png))

|#
