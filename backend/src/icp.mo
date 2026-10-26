import Text "mo:core/Text";
import Blob "mo:core/Blob";
import Array "mo:core/Array";
import Principal "mo:core/Principal";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Nat64 "mo:core/Nat64";
import Int "mo:core/Int";
import Time "mo:core/Time";

module {
  // ===== Typy =====
  public type Account = {
    owner : Principal;
    subaccount : ?Blob;
  };

  public type TransferArgs = {
    from_subaccount : ?Blob;
    to : Account;
    amount : Nat;
    fee : ?Nat;
    memo : ?Blob;
    created_at_time : ?Nat64;
  };

  public type TransferError = {
    #BadFee : { expected_fee : Nat };
    #BadBurn : { min_burn_amount : Nat };
    #InsufficientFunds : { balance : Nat };
    #TooOld;
    #CreatedInFuture : { ledger_time : Nat64 };
    #Duplicate : { duplicate_of : Nat };
    #TemporarilyUnavailable;
    #GenericError : { error_code : Nat; message : Text };
  };

  public type TransferResult = {
    #Ok : Nat;
    #Err : TransferError;
  };

  // ===== ICP Ledger actor =====
  // Natywny ICP ledger – stały, dobrze znany canister ID
  public type Ledger = actor {
    icrc1_transfer : shared (TransferArgs) -> async TransferResult;
    icrc1_balance_of : shared query (Account) -> async Nat;
    icrc1_fee : shared query () -> async Nat;
  };

  let ledger : Ledger = actor ("ryjl3-tyaaa-aaaaa-aaaba-cai");

  // Stała opłata ICP = 10_000 e8s (0.0001 ICP)
  // Konwersja Nat -> 32-bajtowe subkonto (big-endian)
  public func natToSubaccount(id : Nat) : Blob {
    let sub = Array.tabulate<Nat8>(32, func(i : Nat) : Nat8 {
      let shift = (31 - i) * 8;
      Nat8.fromNat((id / (2 ** shift)) % 256)
    });
    Blob.fromArray(sub)
  };

  // Adres portfela użytkownika = subkonto kanistra
  // owner = canisterPrincipal, subaccount = natToSubaccount(id)
  public func walletAccount(canisterPrincipal : Principal, id : Nat) : Account {
    {
      owner = canisterPrincipal;
      subaccount = ?natToSubaccount(id);
    }
  };

  // Pobierz saldo portfela (subkonta kanistra)
  public func getBalance(canisterPrincipal : Principal, id : Nat) : async Nat {
    await ledger.icrc1_balance_of(walletAccount(canisterPrincipal, id))
  };

  // Przelew z subkonta kanistra (portfela id) do zewnętrznego adresu
  // WARNING: Dodaj kontrolę dostępu w produkcji
  public func transfer(
    fromId : Nat,
    to : Principal,
    amount : Nat,
    ICP_FEE : Nat,
  ) : async TransferResult {
    let now = Nat64.fromNat(Int.abs(Time.now()));

    await ledger.icrc1_transfer({
      from_subaccount = ?natToSubaccount(fromId);
      to = { owner = to; subaccount = null };
      amount = amount - ICP_FEE;
      fee = ?ICP_FEE;
      memo = null;
      created_at_time = ?now;
    })
  };
};