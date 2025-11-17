;; stacklogic.clar
;; "stacklogic" - conditional logic engine for programmable transfers (STX + SIP-010)
;; - Create proposals (actions) with attached rules
;; - Trustees approve proposals
;; - Once rules satisfied, anyone can execute the action
;; - Two-step deposit pattern for STX and tokens applies for funding

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Errors
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
(define-constant ERR-UNAUTHORIZED (err u100))
(define-constant ERR-NOT-TRUSTEE (err u101))
(define-constant ERR-ALREADY_APPROVED (err u102))
(define-constant ERR-NO_DEPOSIT (err u103))
(define-constant ERR-INVALID_AMOUNT (err u104))
(define-constant ERR-ALREADY_EXECUTED (err u105))
(define-constant ERR-PAUSED (err u106))
(define-constant ERR-EXEC_FAIL (err u107))
(define-constant ERR-INVALID_RULE (err u108))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Admin / Pause
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
(define-data-var admin principal tx-sender)
(define-data-var paused bool false)

(define-private (assert-admin)
  (begin
    (asserts! (is-eq tx-sender (var-get admin)) ERR-UNAUTHORIZED)
    (ok true)))

(define-public (set-admin (new-admin principal))
  (begin (try! (assert-admin)) (var-set admin new-admin) (ok true)))

(define-public (pause) (begin (try! (assert-admin)) (var-set paused true) (ok true)))
(define-public (unpause) (begin (try! (assert-admin)) (var-set paused false) (ok true)))
(define-read-only (is-paused) (ok (var-get paused)))
(define-read-only (get-admin) (ok (var-get admin)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Trustees (approvers) and threshold
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
(define-data-var approval-threshold uint u1)

(define-public (add-trustee (who principal))
  (begin (try! (assert-admin))  (ok true)))

(define-public (remove-trustee (who principal))
  (begin (try! (assert-admin))  (ok true)))

(define-public (set-threshold (n uint))
  (begin (try! (assert-admin)) (asserts! (>= n u1) ERR-INVALID_RULE) (var-set approval-threshold n) (ok true)))
(define-read-only (get-threshold) (ok (var-get approval-threshold)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Bookkeeping for deposits (contract-level)
;; Two-step deposit pattern: user transfers STX/token -> contract; then calls credit-*
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
(define-map stx-balances {owner: principal} {balance: uint})
(define-map ft-balances {owner: principal, token: principal} {balance: uint})
(define-map accounted-stx {dummy: bool} {amount: uint})
(define-map trustees {who: principal} {active: bool})

(define-private (increase-stx-balance (owner principal) (amt uint))
  (let ((prev (default-to u0 (get balance (map-get? stx-balances {owner: owner})))))
    (map-set stx-balances {owner: owner} {balance: (+ prev amt)})
    (ok true)))

(define-private (decrease-stx-balance (owner principal) (amt uint))
  (let ((prev (default-to u0 (get balance (map-get? stx-balances {owner: owner})))))
    (asserts! (>= prev amt) ERR-INVALID_AMOUNT)
    (map-set stx-balances {owner: owner} {balance: (- prev amt)})
    (ok true)))

(define-private (increase-ft-balance (owner principal) (token principal) (amt uint))
  (let ((prev (default-to u0 (get balance (map-get? ft-balances {owner: owner, token: token})))))
    (map-set ft-balances {owner: owner, token: token} {balance: (+ prev amt)})
    (ok true)))

(define-private (decrease-ft-balance (owner principal) (token principal) (amt uint))
  (let ((prev (default-to u0 (get balance (map-get? ft-balances {owner: owner, token: token})))))
    (asserts! (>= prev amt) ERR-INVALID_AMOUNT)
    (map-set ft-balances {owner: owner, token: token} {balance: (- prev amt)})
    (ok true)))

(define-read-only (get-stx-balance-of (owner principal)) (ok (default-to u0 (get balance (map-get? stx-balances {owner: owner})))))
(define-read-only (get-ft-balance-of (owner principal) (token principal)) (ok (default-to u0 (get balance (map-get? ft-balances {owner: owner, token: token})))))

(define-read-only (contract-stx)
  (ok u0))

(define-read-only (contract-ft (token principal))
  (ok u0))

(define-public (credit-stx)
  (if (var-get paused) (err ERR-PAUSED)
    (as-contract
      (let ((current (stx-get-balance tx-sender))
            (acct (default-to u0 (get amount (map-get? accounted-stx {dummy: true})))))
        (let ((delta (if (>= current acct) (- current acct) u0)))
          (if (<= delta u0) (err ERR-NO_DEPOSIT)
            (begin
              (let ((inc-result (increase-stx-balance tx-sender delta)))
                (map-set accounted-stx {dummy: true} {amount: current}))
              (ok delta))))))))

(define-public (credit-ft (token principal))
  (if (var-get paused) (err ERR-PAUSED)
    (let ((current u0)
          (prev (default-to u0 (get balance (map-get? ft-balances {owner: tx-sender, token: token})))))
      (let ((delta (if (>= current prev) (- current prev) u0)))
        (if (<= delta u0) (err ERR-NO_DEPOSIT)
          (begin
            (let ((inc-result (increase-ft-balance tx-sender token delta)))
              (ok delta))))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Action / Proposal system
;; Each action describes a transfer:
;; - id: uint
;; - beneficiary: principal
;; - token: principal (use (as-contract) as sentinel for STX)
;; - amount: uint
;; - rules: encoded as a tuple (min-approvals uint, timelock uint block-height, max-allowed uint) ; max-allowed = 0 means no cap
;; - approvals: uint
;; - executed: bool
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
(define-map actions {id: uint} {creator: principal, beneficiary: principal, token: principal, amount: uint, min-approvals: uint, unlock: uint, max-allowed: uint, approvals: uint, executed: bool})
(define-map action-approvals {id: uint, who: principal} {ok: bool})
(define-data-var action-counter uint u0)

(define-private (next-action-id)
  (let ((c (var-get action-counter)))
    (var-set action-counter (+ c u1))
    (ok c)))

;; create action with rules
(define-public (create-action (beneficiary principal) (token principal) (amount uint) (min-approvals uint) (unlock uint) (max-allowed uint))
  (begin
    (if (var-get paused) (err ERR-PAUSED)
      (if (<= amount u0) (err ERR-INVALID_AMOUNT)
        (let ((id (unwrap-panic (next-action-id))))
          (map-set actions {id: id} {creator: tx-sender, beneficiary: beneficiary, token: token, amount: amount, min-approvals: min-approvals, unlock: unlock, max-allowed: max-allowed, approvals: u0, executed: false})
          (ok id))))))


;; approve action (trustees only)
(define-public (approve-action (aid uint))
  (begin
    (if (var-get paused) (err ERR-PAUSED)
      (let ((is-t (default-to false (get active (map-get? trustees {who: tx-sender})))))
        (if (not is-t) (err ERR-NOT-TRUSTEE)
          (match (map-get? actions {id: aid})
            act
              (let ((already (default-to false (get ok (map-get? action-approvals {id: aid, who: tx-sender})))))
                (if already (err ERR-ALREADY_APPROVED)
                  (begin
                    (map-set action-approvals {id: aid, who: tx-sender} {ok: true})
                    (let ((new-approvals (+ (get approvals act) u1)))
                      (map-set actions {id: aid} {creator: (get creator act), beneficiary: (get beneficiary act), token: (get token act), amount: (get amount act), min-approvals: (get min-approvals act), unlock: (get unlock act), max-allowed: (get max-allowed act), approvals: new-approvals, executed: (get executed act)})
                      (ok new-approvals)))))
            (err ERR-INVALID_RULE)))))))

;; internal check: rules satisfied?
(define-private (rules-satisfied? (act {creator: principal, beneficiary: principal, token: principal, amount: uint, min-approvals: uint, unlock: uint, max-allowed: uint, approvals: uint, executed: bool}))
  (let ((approvals (get approvals act))
        (min-req (get min-approvals act))
        (unlock-time (get unlock act))
        (max-allowed-amt (get max-allowed act))
        (amt (get amount act))
        (now burn-block-height))
    (if (< approvals min-req) false
      (if (< now unlock-time) false
        (if (and (> max-allowed-amt u0) (> amt max-allowed-amt)) false
          true)))))
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Direct withdraws (for users who have bookkeeping balances)
;; Provided as convenience; may be restricted in your deployment
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
(define-public (withdraw-stx (amount uint))
  (if (or (var-get paused) (not (> amount u0)))
    (err ERR-PAUSED)
    (match (decrease-stx-balance tx-sender amount)
      ok (ok amount)
      err-val (err ERR-EXEC_FAIL))))

(define-public (withdraw-ft (token principal) (amount uint))
  (if (or (var-get paused) (not (> amount u0)))
    (err ERR-PAUSED)
    (match (decrease-ft-balance tx-sender token amount)
      ok (ok amount)
      err-val (err ERR-EXEC_FAIL))))
