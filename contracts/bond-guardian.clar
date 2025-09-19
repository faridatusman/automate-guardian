;; Automate Guardian: Decentralized Bond Management Platform
;; This contract provides a comprehensive solution for digital bond lifecycle management
;; on the Stacks blockchain, enabling automated issuance, trading, and redemption processes.

;; Error codes
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-BOND-NOT-FOUND (err u101))
(define-constant ERR-BOND-ALREADY-EXISTS (err u102))
(define-constant ERR-INSUFFICIENT-FUNDS (err u103))
(define-constant ERR-BOND-SOLD-OUT (err u104))
(define-constant ERR-INVALID-AMOUNT (err u105))
(define-constant ERR-BOND-NOT-MATURE (err u106))
(define-constant ERR-BOND-ALREADY-MATURE (err u107))
(define-constant ERR-PAYMENT-ALREADY-MADE (err u108))
(define-constant ERR-INSUFFICIENT-BALANCE (err u109))
(define-constant ERR-INVALID-PARAMETERS (err u110))
(define-constant ERR-NOT-BOND-OWNER (err u111))
(define-constant ERR-PAYMENT-INSUFFICIENT (err u112))

;; Data Maps and Variables

;; Tracks bond issuers and their authorization status
(define-map bond-issuers principal bool)

;; Bond structure storing all bond parameters and state
(define-map bonds 
  uint 
  {
    issuer: principal,
    total-face-value: uint,
    denomination: uint,
    interest-rate: uint,  ;; Basis points (e.g., 500 = 5.00%)
    payment-frequency: uint, ;; In days
    maturity-date: uint, ;; Block height
    is-mature: bool,
    remaining-supply: uint,
    allow-early-redemption: bool
  }
)

;; Track individual holdings of each bond
(define-map bond-holdings 
  { bond-id: uint, owner: principal } 
  uint
)

;; Track interest payment schedules
(define-map interest-payments
  { bond-id: uint, payment-date: uint }
  { amount: uint, is-paid: bool }
)

;; Track total interest payment amount funded by issuer
(define-map interest-payment-funds
  uint  ;; bond-id
  uint  ;; amount
)

;; Counter for bond IDs
(define-data-var next-bond-id uint u1)

;; Private Functions

;; Check if principal is an authorized bond issuer
(define-private (is-authorized-issuer (issuer principal))
  (default-to false (map-get? bond-issuers issuer))
)

;; Calculate interest payment amount based on holdings and interest rate
(define-private (calculate-interest-amount (bond-id uint) (holdings uint))
  (let (
    (bond (unwrap! (map-get? bonds bond-id) u0))
    (interest-rate (get interest-rate bond))
    (denomination (get denomination bond))
  )
    ;; Calculate: holdings * denomination * interest-rate / 10000 (basis points)
    (/ (* (* holdings denomination) interest-rate) u10000)
  )
)

;; Get current bond balance for an owner
(define-private (get-bond-balance (bond-id uint) (owner principal))
  (default-to u0 
    (map-get? bond-holdings { bond-id: bond-id, owner: owner })
  )
)

;; Check if bond exists
(define-private (bond-exists (bond-id uint))
  (is-some (map-get? bonds bond-id))
)

;; Transfer bond units between principals
(define-private (transfer-bond-units (bond-id uint) (sender principal) (recipient principal) (amount uint))
  (let (
    (sender-balance (get-bond-balance bond-id sender))
    (recipient-balance (get-bond-balance bond-id recipient))
  )
    (if (>= sender-balance amount)
      (begin
        ;; Update sender balance
        (map-set bond-holdings 
          { bond-id: bond-id, owner: sender }
          (- sender-balance amount)
        )
        ;; Update recipient balance
        (map-set bond-holdings 
          { bond-id: bond-id, owner: recipient }
          (+ recipient-balance amount)
        )
        (ok true)
      )
      ERR-INSUFFICIENT-BALANCE
    )
  )
)

;; Read-only Functions

;; Get bond details
(define-read-only (get-bond (bond-id uint))
  (map-get? bonds bond-id)
)

;; Get bond balance for a specific owner
(define-read-only (get-balance (bond-id uint) (owner principal))
  (ok (get-bond-balance bond-id owner))
)

;; Check if a bond is mature
(define-read-only (is-bond-mature (bond-id uint))
  (match (map-get? bonds bond-id)
    bond (ok (get is-mature bond))
    (err ERR-BOND-NOT-FOUND)
  )
)

;; Get upcoming interest payment for a bond
(define-read-only (get-next-interest-payment (bond-id uint))
  (match (map-get? bonds bond-id)
    bond 
    (let (
      (current-block block-height)
      (payment-frequency (get payment-frequency bond))
      (maturity-date (get maturity-date bond))
    )
      (if (>= current-block maturity-date)
        (ok { payment-date: u0, amount: u0 }) ;; No more payments after maturity
        (let (
          (next-payment-date (+ current-block payment-frequency))
        )
          (if (> next-payment-date maturity-date)
            (ok { payment-date: maturity-date, amount: u0 })
            (ok { payment-date: next-payment-date, amount: u0 })
          )
        )
      )
    )
    (err ERR-BOND-NOT-FOUND)
  )
)

;; Get total interest payment fund for a bond
(define-read-only (get-interest-payment-fund (bond-id uint))
  (default-to u0 (map-get? interest-payment-funds bond-id))
)

;; Public Functions

;; Add a new authorized bond issuer (admin only)
(define-public (add-bond-issuer (issuer principal))
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR-NOT-AUTHORIZED)
    (ok (map-set bond-issuers issuer true))
  )
)

;; Remove bond issuer authorization (admin only)
(define-public (remove-bond-issuer (issuer principal))
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR-NOT-AUTHORIZED)
    (ok (map-set bond-issuers issuer false))
  )
)

;; Create a new bond
(define-public (create-bond 
  (total-face-value uint) 
  (denomination uint) 
  (interest-rate uint) 
  (payment-frequency uint) 
  (maturity-blocks uint)
  (allow-early-redemption bool))
  
  (let (
    (bond-id (var-get next-bond-id))
    (maturity-date (+ block-height maturity-blocks))
  )
    ;; Validation checks
    (asserts! (is-authorized-issuer tx-sender) ERR-NOT-AUTHORIZED)
    (asserts! (> total-face-value u0) ERR-INVALID-PARAMETERS)
    (asserts! (> denomination u0) ERR-INVALID-PARAMETERS)
    (asserts! (>= interest-rate u0) ERR-INVALID-PARAMETERS)
    (asserts! (> payment-frequency u0) ERR-INVALID-PARAMETERS)
    (asserts! (> maturity-blocks u0) ERR-INVALID-PARAMETERS)
    
    ;; Ensure total face value is divisible by denomination
    (asserts! (is-eq u0 (mod total-face-value denomination)) ERR-INVALID-PARAMETERS)
    
    ;; Create the bond
    (map-set bonds 
      bond-id
      {
        issuer: tx-sender,
        total-face-value: total-face-value,
        denomination: denomination,
        interest-rate: interest-rate,
        payment-frequency: payment-frequency,
        maturity-date: maturity-date,
        is-mature: false,
        remaining-supply: (/ total-face-value denomination),
        allow-early-redemption: allow-early-redemption
      }
    )
    
    ;; Increment bond ID counter
    (var-set next-bond-id (+ bond-id u1))
    
    (ok bond-id)
  )
)

;; Purchase bonds in primary market (from issuer)
(define-public (purchase-bonds (bond-id uint) (units uint) (recipient (optional principal)))
  (let (
    (bond (unwrap! (map-get? bonds bond-id) ERR-BOND-NOT-FOUND))
    (issuer (get issuer bond))
    (denomination (get denomination bond))
    (remaining-supply (get remaining-supply bond))
    (buyer (default-to tx-sender recipient))
    (total-cost (* units denomination))
  )
    ;; Check if bond has available supply
    (asserts! (>= remaining-supply units) ERR-BOND-SOLD-OUT)
    ;; Check if buyer has enough STX
    (asserts! (>= (stx-get-balance tx-sender) total-cost) ERR-INSUFFICIENT-FUNDS)
    
    ;; Transfer STX to issuer
    (try! (stx-transfer? total-cost tx-sender issuer))
    
    ;; Update buyer's bond balance
    (let (
      (current-balance (get-bond-balance bond-id buyer))
    )
      (map-set bond-holdings 
        { bond-id: bond-id, owner: buyer }
        (+ current-balance units)
      )
    )
    
    ;; Update remaining supply
    (map-set bonds 
      bond-id
      (merge bond { remaining-supply: (- remaining-supply units) })
    )
    
    (ok units)
  )
)

;; Transfer bonds to another investor (secondary market)
(define-public (transfer (bond-id uint) (amount uint) (recipient principal))
  (begin
    (asserts! (bond-exists bond-id) ERR-BOND-NOT-FOUND)
    (asserts! (> amount u0) ERR-INVALID-AMOUNT)
    (asserts! (not (is-eq tx-sender recipient)) ERR-INVALID-PARAMETERS)
    
    ;; Execute the transfer
    (try! (transfer-bond-units bond-id tx-sender recipient amount))
    
    (ok amount)
  )
)

;; Fund interest payments (issuer only)
(define-public (fund-interest-payments (bond-id uint) (amount uint))
  (let (
    (bond (unwrap! (map-get? bonds bond-id) ERR-BOND-NOT-FOUND))
    (issuer (get issuer bond))
    (current-fund (get-interest-payment-fund bond-id))
  )
    ;; Ensure only the issuer can fund payments
    (asserts! (is-eq tx-sender issuer) ERR-NOT-AUTHORIZED)
    ;; Ensure amount is positive
    (asserts! (> amount u0) ERR-INVALID-AMOUNT)
    ;; Check if issuer has enough STX
    (asserts! (>= (stx-get-balance tx-sender) amount) ERR-INSUFFICIENT-FUNDS)
    
    ;; Transfer STX to contract
    (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
    
    ;; Update payment fund
    (map-set interest-payment-funds bond-id (+ current-fund amount))
    
    (ok amount)
  )
)

;; Claim interest payment as bondholder
(define-public (claim-interest (bond-id uint))
  (let (
    (bond (unwrap! (map-get? bonds bond-id) ERR-BOND-NOT-FOUND))
    (holder-units (get-bond-balance bond-id tx-sender))
    (payment-fund (get-interest-payment-fund bond-id))
  )
    ;; Check if the caller owns any bonds
    (asserts! (> holder-units u0) ERR-NOT-BOND-OWNER)
    
    ;; Calculate interest payment amount
    (let (
      (interest-amount (calculate-interest-amount bond-id holder-units))
    )
      ;; Check if sufficient funds exist in the payment pool
      (asserts! (>= payment-fund interest-amount) ERR-PAYMENT-INSUFFICIENT)
      
      ;; Transfer interest payment to holder
      (try! (as-contract (stx-transfer? interest-amount tx-sender tx-sender)))
      
      ;; Update payment fund
      (map-set interest-payment-funds bond-id (- payment-fund interest-amount))
      
      (ok interest-amount)
    )
  )
)

;; Update bond maturity status (can be called by anyone)
(define-public (update-bond-maturity (bond-id uint))
  (let (
    (bond (unwrap! (map-get? bonds bond-id) ERR-BOND-NOT-FOUND))
    (is-mature (get is-mature bond))
    (maturity-date (get maturity-date bond))
  )
    ;; Check if bond is already marked as mature
    (asserts! (not is-mature) ERR-BOND-ALREADY-MATURE)
    ;; Check if bond has reached maturity date
    (asserts! (>= block-height maturity-date) ERR-BOND-NOT-MATURE)
    
    ;; Mark bond as mature
    (map-set bonds 
      bond-id
      (merge bond { is-mature: true })
    )
    
    (ok true)
  )
)

;; Redeem mature bonds for principal
(define-public (redeem-bonds (bond-id uint))
  (let (
    (bond (unwrap! (map-get? bonds bond-id) ERR-BOND-NOT-FOUND))
    (is-mature (get is-mature bond))
    (issuer (get issuer bond))
    (holder-units (get-bond-balance bond-id tx-sender))
    (denomination (get denomination bond))
    (redemption-amount (* holder-units denomination))
  )
    ;; Check if bond is mature
    (asserts! is-mature ERR-BOND-NOT-MATURE)
    ;; Check if holder has bonds to redeem
    (asserts! (> holder-units u0) ERR-NOT-BOND-OWNER)
    ;; Check if issuer has sufficient balance for redemption
    (asserts! (>= (stx-get-balance issuer) redemption-amount) ERR-INSUFFICIENT-FUNDS)
    
    ;; Transfer principal from issuer to holder
    (try! (stx-transfer? redemption-amount issuer tx-sender))
    
    ;; Update holder's bond balance (set to zero after redemption)
    (map-set bond-holdings 
      { bond-id: bond-id, owner: tx-sender }
      u0
    )
    
    (ok redemption-amount)
  )
)

;; Allow early redemption if permitted by bond terms
(define-public (early-redemption (bond-id uint))
  (let (
    (bond (unwrap! (map-get? bonds bond-id) ERR-BOND-NOT-FOUND))
    (allow-early (get allow-early-redemption bond))
    (issuer (get issuer bond))
    (holder-units (get-bond-balance bond-id tx-sender))
    (denomination (get denomination bond))
    (redemption-amount (* holder-units denomination))
  )
    ;; Check if early redemption is allowed
    (asserts! allow-early ERR-NOT-AUTHORIZED)
    ;; Check if holder has bonds to redeem
    (asserts! (> holder-units u0) ERR-NOT-BOND-OWNER)
    ;; Ensure bond is not already mature
    (asserts! (not (get is-mature bond)) ERR-BOND-ALREADY-MATURE)
    ;; Check if issuer has sufficient balance for redemption
    (asserts! (>= (stx-get-balance issuer) redemption-amount) ERR-INSUFFICIENT-FUNDS)
    
    ;; Transfer principal from issuer to holder
    (try! (stx-transfer? redemption-amount issuer tx-sender))
    
    ;; Update holder's bond balance
    (map-set bond-holdings 
      { bond-id: bond-id, owner: tx-sender }
      u0
    )
    
    (ok redemption-amount)
  )
)

;; Contract owner variable
(define-data-var contract-owner principal tx-sender)

;; Transfer contract ownership
(define-public (transfer-ownership (new-owner principal))
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR-NOT-AUTHORIZED)
    (var-set contract-owner new-owner)
    (ok true)
  )
)