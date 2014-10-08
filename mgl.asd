;;;; -*- mode: Lisp -*-

;;; See MGL:@MGL-MANUAL for the user guide.
(asdf:defsystem #:mgl
  :licence "MIT, see COPYING."
  :version "0.0.8"
  :name "MGL, the machine learning library"
  :author "Gábor Melis"
  :mailto "mega@retes.hu"
  :homepage "http://quotenil.com"
  :description "MGL is a machine learning library for backpropagation
  neural networks, boltzmann machines, gaussian processes and more."
  :components ((:module "src"
                :serial t
                :components ((:file "package")
                             (:file "common")
                             (:file "resample")
                             (:file "util")
                             (:file "dataset")
                             (:file "copy")
                             (:file "confusion-matrix")
                             (:file "feature")
                             (:file "core")
                             (:file "classification")
                             (:file "optimize")
                             (:file "gradient-descent")
                             (:file "conjugate-gradient")
                             (:file "differentiable-function")
                             (:file "boltzmann-machine")
                             (:file "deep-belief-network")
                             (:file "backprop")
                             (:file "unroll")
                             (:file "gaussian-process")
                             (:file "mgl"))))
  :depends-on (#:alexandria #:closer-mop #:array-operations #:lla #:cl-reexport
                            #:mgl-gnuplot #:mgl-mat #:mgl-pax))

(defmethod asdf:perform ((o asdf:test-op) (c (eql (asdf:find-system '#:mgl))))
  (asdf:oos 'asdf:load-op '#:mgl-test)
  (funcall (intern (symbol-name '#:test) (find-package '#:mgl-test))))
