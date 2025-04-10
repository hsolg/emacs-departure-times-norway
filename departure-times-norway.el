;;; departure-times-norway.el --- Description -*- lexical-binding: t; -*-
;;
;; Copyright (C) 2025 Henrik Solgaard
;;
;; Author: Henrik Solgaard <henrik.solgaard@gmail.com>
;; Maintainer: Henrik Solgaard <henrik.solgaard@gmail.com>
;; Created: March 28, 2025
;; Version: 0.0.1
;; Keywords: transport
;; Homepage: https://github.com/hsolg/emacs-departure-times-norway
;; Package-Requires: ((emacs "27.1") (persist "0.6.1"))
;;
;; This file is not part of GNU Emacs.
;;
;;; Commentary:
;;
;;  Show public transport departure times
;;
;;; Code:

(require 'json)
(require 'url)
(require 'iso8601)
(require 'persist)

(persist-defvar departure-times-norway-selected-stop nil "Selected stop ID")

(define-derived-mode departure-times-norway-mode special-mode "Departure times"
  "Major mode for displaying public transport departure times.")

;; GraphQL request:
;; estimatedCalls(timeRange: 72100, numberOfDepartures: 10) {
;;   realtime
;;   expectedArrivalTime
;;   expectedDepartureTime
;;   forBoarding
;;   destinationDisplay {
;;     frontText
;;   }
;;   serviceJourney {
;;     journeyPattern {
;;       line {
;;         id
;;         name
;;         transportMode
;;       }
;;     }
;;   }
;;   aimedDepartureTime
;; }

(defun departure-times-norway--search-stops (string)
  "Search for stop names that contain STRING with EnTur API."
  (let* ((url-request-method "GET")
         (url (format "https://api.entur.io/geocoder/v1/autocomplete?text=%s&lang=en" string))
         (url-request-extra-headers '(("Et-Client-Name" . "emacs-departure-times-norway")))
         (buffer (url-retrieve-synchronously url)))
    (when buffer
      (with-current-buffer buffer
        (goto-char (point-min))
        (re-search-forward "\n\n") ;; Skip HTTP headers
        (let* ((json-text (buffer-substring-no-properties (point) (point-max))))
          (decode-coding-string json-text 'utf-8)
          (json-parse-string json-text :object-type 'alist))))))

(defun departure-times-norway--get-stops (string)
  "Get stops with name that contain STRING."
  (let* ((res (departure-times-norway--search-stops string))
         (features (cdr (assoc 'features res)))
         (stops (mapcar (lambda (item) (let* ((props (cdr (assoc 'properties item)))
                                              (id (cdr (assoc 'id props)))
                                              (label (cdr (assoc 'label props))))
                                         (cons label id))) features)))
    stops))

(defun departure-times-norway--fetch-departure-times-norway (stop-id)
  "Fetch departure times for STOP-ID."
  (let* ((url-request-method "POST")
         (url "https://api.entur.io/journey-planner/v3/graphql")
         (url-request-extra-headers '(("Et-Client-Name" . "emacs-departure-times-norway")
                                      ("Content-Type" . "application/json")))
         (query (format "{ stopPlace(id: \"%s\") { id name estimatedCalls(timeRange: 72100, numberOfDepartures: 10) { realtime expectedDepartureTime forBoarding destinationDisplay { frontText } serviceJourney { journeyPattern { line { id name transportMode } } } aimedDepartureTime } } }" stop-id))
         (url-request-data (json-encode `(("query" . ,query))))
         (buffer (url-retrieve-synchronously url)))
    (when buffer
      (with-current-buffer buffer
        (goto-char (point-min))
        (re-search-forward "\n\n") ;; Skip HTTP headers
        (let* ((json-text (buffer-substring-no-properties (point) (point-max))))
          (decode-coding-string json-text 'utf-8)
          (json-parse-string json-text :object-type 'alist))))))

(defun departure-times-norway--format-time (iso-time)
  "Format ISO-TIME as local time."
  (let* ((decoded-time (iso8601-parse iso-time)))
    (format-time-string "%H:%M:%S" (apply 'encode-time decoded-time))))

(defun departure-times-norway--format-mode (mode)
  "Get icon for MODE."
  (pcase mode
    ("bus" "🚌")
    ("tram" "🚋")
    ("metro" "🚇")
    ("rail" "🚆")
    (_ mode)))

(defun departure-times-norway--format-line (line-id)
  "Get line number from LINE-ID."
  (car (last (split-string line-id ":"))))

(defun departure-times-norway--select-stop (choices)
  "Select stop from CHOICES."
  (let* ((selection (completing-read "Select stop: " choices nil t)))
    (cdr (assoc selection choices))))

(defun departure-times-norway--prompt-stop ()
  "Prompt the user for a stop."
  (let* ((user-input (read-string "Stop name: "))
         (choices (departure-times-norway--get-stops user-input))
         (selected-stop-id (departure-times-norway--select-stop choices)))
    selected-stop-id))

(defun departure-times-norway-show-departures (arg)
  "Show departure times for a preset stop.

With a prefix ARG, select a new station."
  (interactive "p")

  ;; Example stops:
  ;; Oslo S 337
  ;; Jernbanetorget 3978, 3986, 3990, 3995, 4000, 4004, 4013, 59734, 61733, 62091, 62122
  ;; Klosterheim 6111
  ;; Bryn skole 6114
  (let* ((stop (if (or (/= arg 1) (not departure-times-norway-selected-stop))
                   (departure-times-norway--prompt-stop)
                 departure-times-norway-selected-stop))
         (buffer-name "*Departure times*")
         (departures (departure-times-norway--fetch-departure-times-norway stop)))
    (setq departure-times-norway-selected-stop stop)
    (persist-save 'departure-times-norway-selected-stop)
    (with-current-buffer-window buffer-name nil nil
      (departure-times-norway-mode)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (let* ((stop-place (alist-get 'stopPlace (alist-get 'data departures)))
               (stop-name (alist-get 'name stop-place))
               (calls (alist-get 'estimatedCalls stop-place)))
          (insert (propertize (format "%s\n" stop-name) 'face '(:height 2.0)))
          (dotimes (i (length calls))
            (let* ((call (aref calls i))
                   ;; (realtime (alist-get 'realtime call))
                   (expectedDepartureTime (alist-get 'expectedDepartureTime call))
                   (destination (alist-get 'frontText (alist-get 'destinationDisplay call)))
                   (line (alist-get 'id (alist-get 'line (alist-get 'journeyPattern (alist-get 'serviceJourney call)))))
                   (mode (alist-get 'transportMode (alist-get 'line (alist-get 'journeyPattern (alist-get 'serviceJourney call))))))
              (insert (propertize (format "%s\t%s\t%s\t%s\n"
                                          (departure-times-norway--format-time expectedDepartureTime)
                                          (departure-times-norway--format-mode mode)
                                          (departure-times-norway--format-line line)
                                          destination)
                                  'face '(:height 1.2)))))
          (insert "\nData made available by Entur")
          (goto-char (point-min)))))
    (pop-to-buffer buffer-name)))

(defmacro departure-times-norway--comment (&rest _body)
  "Ignore body expressions. For temporary commenting of code blocks."
  nil)

(departure-times-norway--comment
 (departure-times-norway-show-departures))

(provide 'departure-times-norway)
;;; departure-times-norway.el ends here
