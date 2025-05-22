;; pulsetide-core
;; A smart contract that manages events, feedback collection, and result aggregation
;; for the PulseTide Live Feedback Platform.
;;
;; This contract enables event organizers to create feedback sessions for live events,
;; collect authenticated audience responses, and analyze real-time sentiment data
;; in a secure, transparent manner.

;; ==================
;; Error constants
;; ==================
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-EVENT-NOT-FOUND (err u101))
(define-constant ERR-EVENT-EXPIRED (err u102))
(define-constant ERR-EVENT-NOT-STARTED (err u103))
(define-constant ERR-INVALID-FEEDBACK-TYPE (err u104))
(define-constant ERR-INVALID-FEEDBACK-VALUE (err u105))
(define-constant ERR-DUPLICATE-SUBMISSION (err u106))
(define-constant ERR-EVENT-ALREADY-EXISTS (err u107))
(define-constant ERR-UNAUTHORIZED-PARTICIPANT (err u108))
(define-constant ERR-EVENT-CLOSED (err u109))
(define-constant ERR-INCENTIVE-FAILED (err u110))

;; ==================
;; Data definitions
;; ==================

;; Tracks all event IDs for enumeration
(define-data-var last-event-id uint u0)

;; Event data structure
;; Contains all configuration parameters for a feedback session
(define-map events 
  { event-id: uint }
  {
    creator: principal,             ;; Event organizer
    title: (string-ascii 100),      ;; Event title
    description: (string-utf8 500), ;; Event description
    start-time: uint,               ;; Block height when event starts
    end-time: uint,                 ;; Block height when event ends
    feedback-types: (list 10 (string-ascii 20)), ;; Types of feedback allowed (e.g., "rating", "reaction", "text")
    min-rating: uint,               ;; Minimum rating value (typically 1)
    max-rating: uint,               ;; Maximum rating value (e.g., 5, 10)
    requires-authentication: bool,  ;; Whether anonymous feedback is allowed
    incentive-enabled: bool,        ;; Whether participants receive rewards
    is-closed: bool                 ;; Whether the event has been manually closed
  }
)

;; Tracks allowed participants per event if restricted access is enabled
(define-map event-participants
  { event-id: uint, participant: principal }
  { allowed: bool }
)

;; Stores all feedback submissions
(define-map feedback-submissions
  { event-id: uint, submission-id: uint }
  {
    participant: principal,         ;; Who submitted the feedback
    feedback-type: (string-ascii 20), ;; Type of feedback
    rating-value: (optional uint),  ;; Numeric rating if applicable
    reaction-value: (optional (string-ascii 20)), ;; Reaction if applicable
    text-value: (optional (string-utf8 280)), ;; Text feedback if applicable
    timestamp: uint,                ;; Block height when submitted
    anonymous: bool                 ;; Whether to hide participant identity in results
  }
)

;; Tracks submissions per participant to prevent duplicates
(define-map participant-submissions
  { event-id: uint, participant: principal, feedback-type: (string-ascii 20) }
  { has-submitted: bool }
)

;; Counters for submission IDs per event
(define-map event-submission-counter
  { event-id: uint }
  { count: uint }
)

;; Aggregate data for ratings
(define-map event-rating-aggregates
  { event-id: uint }
  {
    total-ratings: uint,
    sum-ratings: uint,
    count-by-value: (list 10 { rating: uint, count: uint })
  }
)

;; ==================
;; Private functions
;; ==================

;; Validate if the feedback type is supported for the event
(define-private (is-valid-feedback-type 
                 (event-id uint) 
                 (feedback-type (string-ascii 20)))
  (let ((event-data (unwrap! (map-get? events { event-id: event-id }) false))
        (feedback-types (get feedback-types event-data)))
    (is-some (index-of feedback-types feedback-type))
  )
)

;; Validate rating value is within allowed range
(define-private (is-valid-rating-value
                 (event-id uint)
                 (rating-value uint))
  (let ((event-data (unwrap! (map-get? events { event-id: event-id }) false)))
    (and (>= rating-value (get min-rating event-data))
         (<= rating-value (get max-rating event-data)))
  )
)

;; Check if the event is active
(define-private (is-event-active (event-id uint))
  (let ((event-data (unwrap! (map-get? events { event-id: event-id }) false))
        (current-block block-height))
    (and 
      (>= current-block (get start-time event-data))
      (<= current-block (get end-time event-data))
      (not (get is-closed event-data)))
  )
)

;; Check if a user is authorized to participate
(define-private (is-authorized-participant (event-id uint) (participant principal))
  (let ((event-data (unwrap! (map-get? events { event-id: event-id }) false)))
    (if (get requires-authentication event-data)
        (default-to 
          false 
          (get allowed (map-get? event-participants { event-id: event-id, participant: participant })))
        true) ;; If authentication not required, all can participate
  )
)

;; Generate a new submission ID for an event
(define-private (get-next-submission-id (event-id uint))
  (let ((counter (default-to { count: u0 } (map-get? event-submission-counter { event-id: event-id })))
        (new-count (+ (get count counter) u1)))
    ;; Update the counter
    (map-set event-submission-counter 
      { event-id: event-id } 
      { count: new-count })
    ;; Return the new ID
    new-count)
)



;; ==================
;; Read-only functions
;; ==================

;; Get event details
(define-read-only (get-event (event-id uint))
  (map-get? events { event-id: event-id })
)

;; Get total event count
(define-read-only (get-event-count)
  (var-get last-event-id)
)

;; Get all feedback for an event (admin only function in UI)
(define-read-only (get-event-feedback (event-id uint))
  (map-get? event-submission-counter { event-id: event-id })
)

;; Get individual feedback submission
(define-read-only (get-feedback-submission (event-id uint) (submission-id uint))
  (map-get? feedback-submissions { event-id: event-id, submission-id: submission-id })
)

;; Get rating aggregates for an event
(define-read-only (get-event-rating-stats (event-id uint))
  (map-get? event-rating-aggregates { event-id: event-id })
)

;; Check if a participant has submitted feedback of a specific type
(define-read-only (has-participant-submitted (event-id uint) (participant principal) (feedback-type (string-ascii 20)))
  (default-to 
    false 
    (get has-submitted (map-get? participant-submissions 
      { event-id: event-id, participant: participant, feedback-type: feedback-type })))
)

;; Calculate average rating for an event
(define-read-only (get-average-rating (event-id uint))
  (let ((aggregates (default-to 
                      { total-ratings: u0, sum-ratings: u0, count-by-value: (list) }
                      (map-get? event-rating-aggregates { event-id: event-id }))))
    (if (> (get total-ratings aggregates) u0)
        (some (/ (get sum-ratings aggregates) (get total-ratings aggregates)))
        none)
  )
)

;; ==================
;; Public functions
;; ==================

;; Create a new feedback event
(define-public (create-event
               (title (string-ascii 100))
               (description (string-utf8 500))
               (duration uint)  ;; Number of blocks the event will run
               (feedback-types (list 10 (string-ascii 20)))
               (min-rating uint)
               (max-rating uint)
               (requires-authentication bool)
               (incentive-enabled bool))
  (let ((event-id (+ (var-get last-event-id) u1))
        (start-block block-height)
        (end-block (+ block-height duration)))
    
    ;; Input validation
    (asserts! (> (len feedback-types) u0) (err u400))
    (asserts! (< min-rating max-rating) (err u401))
    
    ;; Create the event
    (map-set events
      { event-id: event-id }
      {
        creator: tx-sender,
        title: title,
        description: description,
        start-time: start-block,
        end-time: end-block,
        feedback-types: feedback-types,
        min-rating: min-rating,
        max-rating: max-rating,
        requires-authentication: requires-authentication,
        incentive-enabled: incentive-enabled,
        is-closed: false
      })
    
    ;; Update the event counter
    (var-set last-event-id event-id)
    
    ;; Return success with the new event ID
    (ok event-id))
)

;; Add authorized participants to an event
(define-public (add-event-participant (event-id uint) (participant principal))
  (let ((event-data (unwrap! (map-get? events { event-id: event-id }) ERR-EVENT-NOT-FOUND)))
    
    ;; Check if caller is the event creator
    (asserts! (is-eq tx-sender (get creator event-data)) ERR-NOT-AUTHORIZED)
    
    ;; Add participant to allowed list
    (map-set event-participants
      { event-id: event-id, participant: participant }
      { allowed: true })
    
    (ok true))
)

;; Remove authorized participant from an event
(define-public (remove-event-participant (event-id uint) (participant principal))
  (let ((event-data (unwrap! (map-get? events { event-id: event-id }) ERR-EVENT-NOT-FOUND)))
    
    ;; Check if caller is the event creator
    (asserts! (is-eq tx-sender (get creator event-data)) ERR-NOT-AUTHORIZED)
    
    ;; Remove participant from allowed list
    (map-set event-participants
      { event-id: event-id, participant: participant }
      { allowed: false })
    
    (ok true))
)

;; Submit reaction feedback
(define-public (submit-reaction-feedback
               (event-id uint)
               (reaction-value (string-ascii 20))
               (anonymous bool))
  (let ((event-data (unwrap! (map-get? events { event-id: event-id }) ERR-EVENT-NOT-FOUND))
        (feedback-type "reaction"))
    
    ;; Validate event is active
    (asserts! (is-event-active event-id) (if (> block-height (get end-time event-data)) 
                                             ERR-EVENT-EXPIRED 
                                             ERR-EVENT-NOT-STARTED))
    
    ;; Validate participant is authorized
    (asserts! (is-authorized-participant event-id tx-sender) ERR-UNAUTHORIZED-PARTICIPANT)
    
    ;; Check feedback type is valid for this event
    (asserts! (is-valid-feedback-type event-id feedback-type) ERR-INVALID-FEEDBACK-TYPE)
    
    ;; Check if participant already submitted this feedback type
    (asserts! (not (has-participant-submitted event-id tx-sender feedback-type)) ERR-DUPLICATE-SUBMISSION)
    
    ;; Generate submission ID
    (let ((submission-id (get-next-submission-id event-id)))
      
      ;; Record the submission
      (map-set feedback-submissions
        { event-id: event-id, submission-id: submission-id }
        {
          participant: tx-sender,
          feedback-type: feedback-type,
          rating-value: none,
          reaction-value: (some reaction-value),
          text-value: none,
          timestamp: block-height,
          anonymous: anonymous
        })
      
      ;; Mark participant as having submitted this feedback type
      (map-set participant-submissions
        { event-id: event-id, participant: tx-sender, feedback-type: feedback-type }
        { has-submitted: true })
      
      (ok submission-id)))
)

;; Submit text feedback
(define-public (submit-text-feedback
               (event-id uint)
               (text-value (string-utf8 280))
               (anonymous bool))
  (let ((event-data (unwrap! (map-get? events { event-id: event-id }) ERR-EVENT-NOT-FOUND))
        (feedback-type "text"))
    
    ;; Validate event is active
    (asserts! (is-event-active event-id) (if (> block-height (get end-time event-data)) 
                                             ERR-EVENT-EXPIRED 
                                             ERR-EVENT-NOT-STARTED))
    
    ;; Validate participant is authorized
    (asserts! (is-authorized-participant event-id tx-sender) ERR-UNAUTHORIZED-PARTICIPANT)
    
    ;; Check feedback type is valid for this event
    (asserts! (is-valid-feedback-type event-id feedback-type) ERR-INVALID-FEEDBACK-TYPE)
    
    ;; Check if participant already submitted this feedback type
    (asserts! (not (has-participant-submitted event-id tx-sender feedback-type)) ERR-DUPLICATE-SUBMISSION)
    
    ;; Generate submission ID
    (let ((submission-id (get-next-submission-id event-id)))
      
      ;; Record the submission
      (map-set feedback-submissions
        { event-id: event-id, submission-id: submission-id }
        {
          participant: tx-sender,
          feedback-type: feedback-type,
          rating-value: none,
          reaction-value: none,
          text-value: (some text-value),
          timestamp: block-height,
          anonymous: anonymous
        })
      
      ;; Mark participant as having submitted this feedback type
      (map-set participant-submissions
        { event-id: event-id, participant: tx-sender, feedback-type: feedback-type }
        { has-submitted: true })
      
      (ok submission-id)))
)

;; Close an event early (only callable by event creator)
(define-public (close-event (event-id uint))
  (let ((event-data (unwrap! (map-get? events { event-id: event-id }) ERR-EVENT-NOT-FOUND)))
    
    ;; Check if caller is the event creator
    (asserts! (is-eq tx-sender (get creator event-data)) ERR-NOT-AUTHORIZED)
    
    ;; Update the event to closed status
    (map-set events
      { event-id: event-id }
      (merge event-data { is-closed: true }))
    
    (ok true))
)

;; Extend event duration (only callable by event creator)
(define-public (extend-event-duration (event-id uint) (additional-blocks uint))
  (let ((event-data (unwrap! (map-get? events { event-id: event-id }) ERR-EVENT-NOT-FOUND)))
    
    ;; Check if caller is the event creator
    (asserts! (is-eq tx-sender (get creator event-data)) ERR-NOT-AUTHORIZED)
    
    ;; Check that event hasn't ended already
    (asserts! (<= block-height (get end-time event-data)) ERR-EVENT-EXPIRED)
    
    ;; Update the event end time
    (map-set events
      { event-id: event-id }
      (merge event-data { end-time: (+ (get end-time event-data) additional-blocks) }))
    
    (ok true))
)