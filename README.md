# stacklogic

A conditional logic engine for programmable transfers on the Stacks blockchain. Create proposals with configurable approval rules, multi-signature trustee voting, and automatic execution once conditions are met.

## Features

- **Proposal System**: Create actions with customizable execution rules
- **Multi-Sig Approvals**: Trustee-based approval mechanism with configurable threshold
- **Dual-Token Support**: Transfer both STX and SIP-010 fungible tokens
- **Timelock Delays**: Schedule proposals to execute after a specified block height
- **Amount Caps**: Optional maximum transfer limits per proposal
- **Two-Step Deposits**: Secure funding via transfer + credit pattern
- **Admin Controls**: Pause/unpause contract and manage trustees
- **Balance Tracking**: Per-user, per-token balance management

## Contract Overview

### Core Components

#### Admin & Control
- `set-admin(new-admin)` - Transfer admin privileges
- `pause()` / `unpause()` - Pause/resume all contract functions
- `get-admin()` / `is-paused()` - Read admin state

#### Trustees & Approvals
- `add-trustee(who)` - Register a trustee (approver)
- `remove-trustee(who)` - Unregister a trustee
- `set-threshold(n)` - Set minimum approvals required
- `get-threshold()` - Read approval threshold

#### Deposits (Two-Step Pattern)
1. User transfers STX/tokens to contract
2. User calls `credit-stx()` or `credit-ft(token)`

**Functions:**
- `credit-stx()` - Credit STX balance
- `credit-ft(token)` - Credit fungible token balance
- `get-stx-balance-of(owner)` - Read STX balance
- `get-ft-balance-of(owner, token)` - Read token balance
- `withdraw-stx(amount)` - Withdraw STX
- `withdraw-ft(token, amount)` - Withdraw tokens

#### Proposals (Actions)
- `create-action(beneficiary, token, amount, min-approvals, unlock, max-allowed)` - Create proposal
  - `beneficiary`: Recipient principal
  - `token`: Token contract (or sentinel for STX)
  - `amount`: Transfer amount
  - `min-approvals`: Required trustee approvals
  - `unlock`: Block height after which execution is allowed
  - `max-allowed`: Maximum transfer cap (0 = no cap)
  
- `approve-action(aid)` - Trustee approval (single-use per trustee)

#### Rules Engine
- `rules-satisfied?(action)` - Internal check for execution readiness
  - Validates: min-approvals met, timelock passed, amount within cap

## Usage Example

```clarity
;; 1. Add a trustee
(contract-call? .stacklogic add-trustee 'ST1PQHQV0RRRNRNGZ3THGKIYHC5EU2MSJP2JSC04)

;; 2. Set approval threshold
(contract-call? .stacklogic set-threshold u2)

;; 3. Transfer STX to contract
(stx-transfer? u1000000 tx-sender .stacklogic)

;; 4. Credit STX balance
(contract-call? .stacklogic credit-stx)

;; 5. Create proposal (beneficiary, token, amount, min-approvals, unlock-block, max-cap)
(contract-call? .stacklogic 
  create-action
  'ST2YCSRZJQQQZC8Z1T3FYQR39V0KQZZX1B9QJE06
  .stacklogic  ;; sentinel for STX
  u500000
  u2           ;; 2 approvals required
  u200         ;; unlock at block 200
  u0)          ;; no cap

;; 6. Trustees approve
(contract-call? .stacklogic approve-action u0)  ;; Trustee 1
(contract-call? .stacklogic approve-action u0)  ;; Trustee 2

;; 7. After unlock block reached, execute via separate handler
```

## Error Codes

| Code | Constant | Description |
|------|----------|-------------|
| u100 | ERR-UNAUTHORIZED | Caller is not admin |
| u101 | ERR-NOT-TRUSTEE | Caller is not a trustee |
| u102 | ERR-ALREADY_APPROVED | Trustee already approved this action |
| u103 | ERR-NO_DEPOSIT | No new deposit detected |
| u104 | ERR-INVALID_AMOUNT | Amount is zero or invalid |
| u105 | ERR-ALREADY_EXECUTED | Action already executed |
| u106 | ERR-PAUSED | Contract is paused |
| u107 | ERR-EXEC_FAIL | Execution failed |
| u108 | ERR-INVALID_RULE | Invalid action or rule |

## Data Structures

### Action (Proposal)
```clarity
{
  creator: principal,
  beneficiary: principal,
  token: principal,
  amount: uint,
  min-approvals: uint,
  unlock: uint,              ;; block height
  max-allowed: uint,         ;; 0 = no cap
  approvals: uint,           ;; current count
  executed: bool
}
```

### Trustee
```clarity
{
  who: principal,
  active: bool
}
```

## Security Considerations

1. **Two-Step Deposits**: Users must explicitly credit their balance after transfer
2. **Timelock**: Proposals cannot execute until specified block height
3. **Multi-Sig**: Configurable approval threshold prevents single-point-of-failure
4. **Amount Caps**: Optional per-proposal transfer limits
5. **Admin Controls**: Pause mechanism for emergency shutdown
6. **Trustee Validation**: Only approved trustees can vote on proposals

## Testing

Deploy to testnet:
```bash
clarinet deploy
```

Run tests:
```bash
clarinet test
```

## Contact

For questions or support, please open an issue or contact the maintainers.
