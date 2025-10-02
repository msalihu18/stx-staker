;; Staking & Rewards contract (Clarity)
;; - Users stake STX (micro-STX units). Rewards accrue per block and are distributed proportionally.
;; - Uses reward-per-share accumulator with fixed integer scaling.

(define-constant contract-title "Staking & Rewards")
(define-constant contract-description "Stake STX and earn per-block rewards distributed proportionally to stake. Admin funds reward pool and sets reward rate.")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Constants and Imports
(define-constant SCALE u1000000000000) ;; 1e12 scaling factor

;; Track current block for rewards
(define-data-var current-block uint u0)

;; Get block height
(define-read-only (get-block-height)
  (var-get current-block))

;; Update block height - called by users when interacting with contract
(define-public (update-block-height (new-height uint))
  (begin
    (asserts! (is-eq tx-sender (var-get provider)) (err ERR_NOT_PROVIDER))
    (asserts! (> new-height (var-get current-block)) (err ERR_INVALID_HEIGHT))
    (var-set current-block new-height)
    (ok new-height)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Admin/provider
(define-data-var provider principal tx-sender)

;; Global bookkeeping
(define-data-var total-staked uint u0)            ;; total staked micro-STX
(define-data-var reward-rate-per-block uint u0)  ;; micro-STX distributed per block (total across stakers)
(define-data-var reward-per-share uint u0)       ;; accumulated reward per share (scaled by SCALE)
(define-data-var last-reward-block uint u0)      ;; last block height we updated global accumulator

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Per-user state
;; key: { account: principal } 
;; value: { amount: uint (staked), reward-debt: uint }
(define-map stakes
  {account: principal}
  {amount: uint, reward-debt: uint}
)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Error codes
(define-constant ERR_NOT_PROVIDER u100)
(define-constant ERR_ZERO_AMOUNT u101)
(define-constant ERR_TRANSFER_FAILED u102)
(define-constant ERR_INSUFFICIENT_STAKE u103)
(define-constant ERR_NO_STAKE u104)
(define-constant ERR_NOTHING_TO_CLAIM u105)
(define-constant ERR_ZERO_RATE u106)
(define-constant ERR_INVALID_HEIGHT u107)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Internal: calculate new reward-per-share value
(define-private (calculate-reward-increment (blocks uint) (total-stake uint))
  (let ((rate (var-get reward-rate-per-block)))
    (let ((total-reward (* blocks rate)))
      (/ (* total-reward SCALE) total-stake)))
)

;; Internal: update global reward accumulator
(define-private (update-global)
  (let ((last (var-get last-reward-block))
        (now (get-block-height)))
    ;; If never initialized, set last to now and return
    (if (is-eq last u0)
        (begin
          (var-set last-reward-block now)
          true)
        (let ((blocks (- now last)))
          (if (<= blocks u0)
              true
              (let ((total (var-get total-staked)))
                (if (<= total u0)
                    ;; no stakers: just advance last-reward-block
                    (begin
                      (var-set last-reward-block now)
                      true)
                    ;; distribute rewards across shares
                    (let ((inc (calculate-reward-increment blocks total)))
                      (var-set reward-per-share (+ (var-get reward-per-share) inc))
                      (var-set last-reward-block now)
                      true))))))
    )
)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Internal: calculate new reward-debt based on stake amount and current reward-per-share
(define-private (calculate-new-debt (amount uint))
  (/ (* amount (var-get reward-per-share)) SCALE)
)

;; Internal: calculate accumulated rewards
(define-private (calculate-accumulated (staked uint) (rps uint))
  (/ (* staked rps) SCALE)
)

;; Internal: calculate pending reward amount
(define-private (calculate-pending (acc uint) (debt uint))
  (if (<= acc debt) 
      u0 
      (- acc debt))
)

;; Internal: calculate pending rewards
(define-private (calculate-stake-rewards (stake-data (optional {amount: uint, reward-debt: uint})))
  (match stake-data
    stake-record
    (let ((acc (calculate-accumulated 
                 (get amount stake-record)
                 (var-get reward-per-share))))
      (calculate-pending 
        acc
        (get reward-debt stake-record)))
    u0)
)



;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Admin: set reward rate per block (micro-STX total distributed each block)
(define-public (set-reward-rate (new-rate uint))
  (begin
    (asserts! (is-eq tx-sender (var-get provider)) (err ERR_NOT_PROVIDER))
    (asserts! (> new-rate u0) (err ERR_ZERO_RATE))
    ;; update global before changing rate
    (update-global)
    (var-set reward-rate-per-block new-rate)
    (ok new-rate)
  )
)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Admin: fund the contract with STX to pay rewards (and/or cover stake transfers)
(define-public (fund (amount uint))
  (begin
    (asserts! (> amount u0) (err ERR_ZERO_AMOUNT))
    ;; transfer STX from caller into contract
    (match (stx-transfer? amount tx-sender (as-contract tx-sender))
      transfer-ok (ok amount)
      transfer-err (err ERR_TRANSFER_FAILED))
  )
)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Admin: withdraw available contract STX (owner only)
;; NOTE: Use carefully - withdrawing while obligations exist may cause claim failures.
(define-public (withdraw-owner (amount uint))
  (begin
    (asserts! (is-eq tx-sender (var-get provider)) (err ERR_NOT_PROVIDER))
    (asserts! (> amount u0) (err ERR_ZERO_AMOUNT))
    (match (stx-transfer? amount (as-contract tx-sender) tx-sender)
      transfer-ok (ok amount)
      transfer-err (err ERR_TRANSFER_FAILED))
  )
)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Internal: update stake record
(define-private (update-stake-record (caller principal) (new-amount uint))
  (let ((new-debt (calculate-new-debt new-amount)))
    (map-set stakes {account: caller} 
             {amount: new-amount, reward-debt: new-debt})
    (var-set total-staked (+ (var-get total-staked) new-amount))
    new-amount))

;; Stake: user stakes `amount` micro-STX into contract
(define-public (stake (amount uint))
  (begin 
    (asserts! (> amount u0) (err ERR_ZERO_AMOUNT))
    (match (stx-transfer? amount tx-sender (as-contract tx-sender))
      transfer-ok 
      (begin
        (update-global)
        (let ((existing-stake (map-get? stakes {account: tx-sender})))
          (match existing-stake
            existing 
            (ok (update-stake-record tx-sender (+ (get amount existing) amount)))
            (ok (update-stake-record tx-sender amount)))))
      transfer-err (err ERR_TRANSFER_FAILED))))

;; Claim pending rewards (does not change staked amount)
(define-public (claim)
  (begin
    (update-global)
    (let ((pending (calculate-stake-rewards (map-get? stakes {account: tx-sender}))))
      (asserts! (> pending u0) (err ERR_NOTHING_TO_CLAIM))
      (match (stx-transfer? pending (as-contract tx-sender) tx-sender)
        transfer-ok
        (begin
          (match (map-get? stakes {account: tx-sender})
            current-stake
            (let ((new-debt (calculate-new-debt (get amount current-stake))))
              (map-set stakes {account: tx-sender} 
                       {amount: (get amount current-stake), reward-debt: new-debt})
              (ok pending))
            (err ERR_NO_STAKE)))
        transfer-err (err ERR_TRANSFER_FAILED))))
)

;; Unstake `amount` micro-STX and claim pending rewards
(define-public (unstake (amount uint))
  (begin
    (asserts! (> amount u0) (err ERR_ZERO_AMOUNT))
    (update-global)
    (match (map-get? stakes {account: tx-sender})
      current-stake
      (let ((staked (get amount current-stake)))
        (asserts! (> staked u0) (err ERR_NO_STAKE))
        (asserts! (<= amount staked) (err ERR_INSUFFICIENT_STAKE))
        (let ((pending (calculate-stake-rewards (some current-stake)))
              (new-stake (- staked amount)))
          (begin
            (var-set total-staked (- (var-get total-staked) amount))
            (if (<= new-stake u0)
                (map-delete stakes {account: tx-sender})
                (let ((new-debt (calculate-new-debt new-stake)))
                  (map-set stakes {account: tx-sender} 
                           {amount: new-stake, reward-debt: new-debt})))
            (let ((to-transfer (+ amount pending)))
              (match (stx-transfer? to-transfer (as-contract tx-sender) tx-sender)
                transfer-ok (ok {unstaked: amount, reward: pending})
                transfer-err (err ERR_TRANSFER_FAILED))))))
      (err ERR_NO_STAKE)))
)



;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Read-only helpers

(define-read-only (get-stake (acct principal))
  (ok (map-get? stakes {account: acct}))
)

(define-read-only (get-total-staked)
  (ok (var-get total-staked))
)

(define-read-only (get-reward-rate)
  (ok (var-get reward-rate-per-block))
)

(define-read-only (get-reward-per-share)
  (ok (var-get reward-per-share))
)

(define-read-only (get-last-reward-block)
  (ok (var-get last-reward-block))
)

(define-read-only (get-pending (acct principal))
  ;; Note: this read-only does NOT advance the global accumulator; it uses current stored rps.
  (ok (calculate-stake-rewards (map-get? stakes {account: acct})))
)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Utility: change provider (admin transfer)
(define-public (transfer-provider (new-provider principal))
  (begin
    (asserts! (is-eq tx-sender (var-get provider)) (err ERR_NOT_PROVIDER))
    (asserts! (not (is-eq new-provider tx-sender)) (err ERR_NOT_PROVIDER))
    (var-set provider new-provider)
    (ok new-provider)
  )
)
