import Array "mo:base/Array";
import Blob "mo:base/Blob";
import Debug "mo:base/Debug";
import Int "mo:base/Int";
import Iter "mo:base/Iter";
import Nat "mo:base/Nat";
import Nat64 "mo:base/Nat64";
import Nat8 "mo:base/Nat8";
import Option "mo:base/Option";
import Principal "mo:base/Principal";
import Result "mo:base/Result";
import Time "mo:base/Time";

import Itertools "mo:itertools/Iter";
import StableBuffer "mo:StableBuffer/StableBuffer";
import STMap "mo:StableTrieMap";

import Account "Account";

import T "Types";
import Utils "Utils";

module {
    let { SB } = Utils;

    /// 检查交易备注是否有效
    public func validate_memo(memo : ?T.Memo) : Bool {
        switch (memo) {
            case (?bytes) {
                bytes.size() <= 32;
            };
            case (_) true;
        };
    };

    /// 检查转账请求的 `created_at_time` 是否在可接受时间范围之前
    public func is_too_old(token : T.TokenData, created_at_time : Nat64) : Bool {
        let { permitted_drift; transaction_window } = token;

        let lower_bound = Time.now() - transaction_window - permitted_drift;
        Nat64.toNat(created_at_time) < lower_bound;
    };

    /// 检查转账请求的 `created_at_time` 是否相对于罐子的当前时间还未到达
    public func is_in_future(token : T.TokenData, created_at_time : Nat64) : Bool {
        let upper_bound = Time.now() + token.permitted_drift;
        Nat64.toNat(created_at_time) > upper_bound;
    };

    /// 检查主罐中是否存在与转账请求一致的重复交易
    ///
    /// 如果找到了重复的交易，则函数返回一个包含重复交易索引的错误 (`#err`)
    public func deduplicate(token : T.TokenData, tx_req : T.TransactionRequest) : Result.Result<(), Nat> {
        // 仅在设置了 created_at_time 时进行去重
        if (tx_req.created_at_time == null) {
            return #ok();
        };

        let { transactions = txs; archive } = token;

        var phantom_txs_size = 0;
        let phantom_txs = SB._clearedElemsToIter(txs);
        let current_txs = SB.vals(txs);

        let last_2000_txs = if (archive.stored_txs > 0) {
            phantom_txs_size := SB.capacity(txs) - SB.size(txs);
            Itertools.chain(phantom_txs, current_txs);
        } else {
            current_txs;
        };

        label for_loop for ((i, tx) in Itertools.enumerate(last_2000_txs)) {

            let is_duplicate = switch (tx_req.kind) {
                case (#mint) {
                    switch (tx.mint) {
                        case (?mint) {
                            ignore do ? {
                                if (is_too_old(token, mint.created_at_time!)) {
                                    break for_loop;
                                };
                            };

                            let mint_req : T.Mint = tx_req;

                            mint_req == mint;
                        };
                        case (_) false;
                    };
                };
                case (#burn) {
                    switch (tx.burn) {
                        case (?burn) {
                            ignore do ? {
                                if (is_too_old(token, burn.created_at_time!)) {
                                    break for_loop;
                                };
                            };
                            let burn_req : T.Burn = tx_req;

                            burn_req == burn;
                        };
                        case (_) false;
                    };
                };
                case (#transfer) {
                    switch (tx.transfer) {
                        case (?transfer) {
                            ignore do ? {
                                if (is_too_old(token, transfer.created_at_time!)) {
                                    break for_loop;
                                };
                            };

                            let transfer_req : T.Transfer = tx_req;

                            transfer_req == transfer;
                        };
                        case (_) false;
                    };
                };
            };

            if (is_duplicate) { return #err(tx.index) };
        };

        #ok();
    };

    /// 检查转账手续费是否有效
    public func validate_fee(
        token : T.TokenData,
        opt_fee : ?T.Balance,
    ) : Bool {
        switch (opt_fee) {
            case (?tx_fee) {
                if (tx_fee < token._fee) {
                    return false;
                };
            };
            case (null) {
                if (token._fee > 0) {
                    return false;
                };
            };
        };

        true;
    };

    /// 检查转账请求是否有效
    public func validate_request(
        token : T.TokenData,
        tx_req : T.TransactionRequest,
    ) : Result.Result<(), T.TransferError> {

        if (tx_req.from == tx_req.to) {
            return #err(
                #GenericError({
                    error_code = 0;
                    message = "The sender cannot have the same account as the recipient.";
                }),
            );
        };

        if (not Account.validate(tx_req.from)) {
            return #err(
                #GenericError({
                    error_code = 0;
                    message = "Invalid account entered for sender.";
                }),
            );
        };

        if (not Account.validate(tx_req.to)) {
            return #err(
                #GenericError({
                    error_code = 0;
                    message = "Invalid account entered for recipient";
                }),
            );
        };

        if (not validate_memo(tx_req.memo)) {
            return #err(
                #GenericError({
                    error_code = 0;
                    message = "Memo must not be more than 32 bytes";
                }),
            );
        };

        if (tx_req.amount == 0) {
            return #err(
                #GenericError({
                    error_code = 0;
                    message = "Amount must be greater than 0";
                }),
            );
        };

        switch (tx_req.kind) {
            case (#transfer) {
                if (not validate_fee(token, tx_req.fee)) {
                    return #err(
                        #BadFee {
                            expected_fee = token._fee;
                        },
                    );
                };

                let balance : T.Balance = Utils.get_balance(
                    token.accounts,
                    tx_req.encoded.from,
                );

                if (balance < tx_req.amount + token._fee) {
                    return #err(#InsufficientFunds { balance = balance });
                };
            };

            case (#mint) {
                if (token.max_supply < token._minted_tokens + tx_req.amount) {
                    let remaining_tokens = (token.max_supply - token._minted_tokens) : Nat;

                    return #err(
                        #GenericError({
                            error_code = 0;
                            message = "Cannot mint more than " # Nat.toText(remaining_tokens) # " tokens";
                        }),
                    );
                };
            };
            case (#burn) {
                if (tx_req.to == token.minting_account and tx_req.amount < token.min_burn_amount) {
                    return #err(
                        #BadBurn { min_burn_amount = token.min_burn_amount },
                    );
                };

                let balance : T.Balance = Utils.get_balance(
                    token.accounts,
                    tx_req.encoded.from,
                );

                if (balance < tx_req.amount) {
                    return #err(#InsufficientFunds { balance = balance });
                };
            };
        };

        switch (tx_req.created_at_time) {
            case (null) {};
            case (?created_at_time) {

                if (is_too_old(token, created_at_time)) {
                    return #err(#TooOld);
                };

                if (is_in_future(token, created_at_time)) {
                    return #err(
                        #CreatedInFuture {
                            ledger_time = Nat64.fromNat(Int.abs(Time.now()));
                        },
                    );
                };

                switch (deduplicate(token, tx_req)) {
                    case (#err(tx_index)) {
                        return #err(
                            #Duplicate {
                                duplicate_of = tx_index;
                            },
                        );
                    };
                    case (_) {};
                };
            };
        };

        #ok();
    };

};
