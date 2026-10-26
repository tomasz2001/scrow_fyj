import Text "mo:core/Text";
import Blob "mo:core/Blob";
import Array "mo:core/Array";
import Principal "mo:core/Principal";
import Icp "icp";
import Nat "mo:core/Nat";
import Map "mo:core/Map";
import Nat8 "mo:core/Nat8";
import Time "mo:core/Time";
import Nat64 "mo:core/Nat64";
import Random "mo:core/Random";
import Iter "mo:core/Iter";

// ---------------------------------------------------------------------------
// Główny actor canistera odpowiedzialny za logikę escrow i zarządzanie kontami.
// ---------------------------------------------------------------------------
persistent actor Self {
  // ---------------------------------------------------------------------------
  // Struktury danych
  // Główne typy reprezentujące stan aplikacji używany przez canister.
  // ---------------------------------------------------------------------------
  type Escrow_ckbtc = {
    start : Principal;
    middle : Principal;
    end : Principal;

    start_vote : Text;
    middle_vote : Text;
    end_vote : Text;

    state : Text;

    wallet_id : Nat;
    middle_drop : Nat;
    sylli_drop : Nat;
    burn_time : Nat64;
  };
  type user = {
    escrow: Nat;
    pgp: Text;
    wallet: Principal;
    kontakt: Text;
  };
  // ---------------------------------------------------------------------------
  // Stabilny stan runtime
  // Prosty licznik zapewnia unikatowe identyfikatory escrow w bieżącym stanie.
  // ---------------------------------------------------------------------------
  var escrow_line : Nat = 0;
  var ICP_FEE : Nat = 10_000;
  // Portfel projektu używany w logice powiązanej z SYLLI.
  var sylli_wallet : Principal = Principal.fromText("zrhhh-ywbav-h3hdh-rnx6m-5odfe-cctn5-ibevz-7hxco-hkz6r-7vyv7-7ae");

  // Rejestr użytkowników i rejestr escrow.
  var users = Map.empty<Principal, user>();
  var escrows = Map.empty<Nat, Escrow_ckbtc>();
  var recover = Map.empty<Nat, Principal>();
  // Referencja do ledgera ICP.
  let icpLedger = actor ("ryjl3-tyaaa-aaaaa-aaaba-cai") : actor {
    icrc1_fee : shared query () -> async Nat;
  };

  // Pobiera aktualne fee z ledgera, zapisuje je i zwraca rezultat.
  public func update_feeup() : async Nat {
    let fee = await icpLedger.icrc1_fee();
    ICP_FEE := fee;
    fee
  };
  // ---------------------------------------------------------------------------
  // Cykl życia / pomocnicze czyszczenie
  // Ta funkcja pełni rolę maintenance hooka i może usuwać wygasłe escrowy.
  // ---------------------------------------------------------------------------
  public func death() : async Text {
    let keys : [Nat] = Iter.toArray<Nat>(Map.keys(escrows));

    if (keys.size() == 0) {
      return "no burn";
    };

    let entropy = await Random.blob();
    let bytes = Blob.toArray(entropy);
    let idx = Nat8.toNat(bytes[0]) % keys.size();
    let selected_id = keys[idx];

    let ?escrow = Map.get(escrows, Nat.compare, selected_id) else {
      return "no burn";
    };

    if (escrow.burn_time < Nat64.fromIntWrap(Time.now())) {

      // Usuwanie escrow z pamięci.
      ignore Map.delete(users, Principal.compare, escrow.start);
      ignore Map.delete(users, Principal.compare, escrow.middle);
      ignore Map.delete(users, Principal.compare, escrow.end);
      ignore Map.delete(escrows, Nat.compare, selected_id);

      // Czyszczenie kont użytkowników powiązanych z usuwanym escrow.
      let allEntries = Map.entries(users);
      let filtered = Iter.filter<(Principal, user)>(
        allEntries,
        func(entry : (Principal, user)) : Bool {
            let (_principal, u) = entry;
            u.escrow == 0
        }
      );
      users := Map.fromIter<Principal, user>(filtered, Principal.compare);
      
      return "Escrow ID: " # Nat.toText(selected_id) # " to burn";
    } else {
      return "no burn";
    };
};
  // ---------------------------------------------------------------------------
  // Prosta kontrola zdrowia canistera
  // ---------------------------------------------------------------------------
  public query func greet(name : Text) : async Text {
    return "Hello, " # name # "!";
  };

  // ---------------------------------------------------------------------------
  // Placeholder tworzenia escrow
  // Ta funkcja obecnie sprawdza wywołującego i kończy działanie na wczesnym etapie.
  // ---------------------------------------------------------------------------
  public shared(msg) func make_escrow(middle : Principal, end : Principal, middle_drop : Nat, sylli_drop : Nat) : async Text {
    let start = msg.caller;
        if (start == Principal.fromText("2vxsx-fae")) {
            return "Anonymous caller is not allowed to create an escrow.";
        };

        return "OK";
    };
  // ---------------------------------------------------------------------------
  // Zarządzanie profilem użytkownika
  // Tworzy profil lub odrzuca próbę aktualizacji dla bieżącego wywołującego.
  // ---------------------------------------------------------------------------
  public shared(msg) func account_edit(pgp : Text, wallet : Principal, kontakt : Text) : async Text {
    let caller = msg.caller;
    if (caller == Principal.fromText("2vxsx-fae")) {
        return "Anonymous caller is not allowed to edit account.";
    };
    if (pgp == "" or wallet == Principal.fromText("2vxsx-fae") or kontakt == "") {
        return "All fields must be filled.";
    };
    if (Map.get(users, Principal.compare, caller) != null) {
        return "data is existing, update is not possible.";
    } else {
        let account = { escrow = 0; pgp = pgp; wallet = wallet; kontakt = kontakt };
        Map.add(users, Principal.compare, caller, account);
        return "data added successfully.";
    };
    
  };
  // ---------------------------------------------------------------------------
  // Tworzenie escrow
  // Sprawdza wywołującego i wszystkie zaangażowane strony, a następnie tworzy nowe escrow.
  // ---------------------------------------------------------------------------
  public shared(msg) func new_escrow(middle : Principal, end : Principal, middle_drop : Nat, sylli_drop : Nat) : async Text {
    let start = msg.caller;
    if (start == Principal.fromText("2vxsx-fae")) {
        return "Anonymous caller is not allowed to create an escrow.";
    };
    let ?start_profile = Map.get(users, Principal.compare, start) else {return "Start profile not found."};
    let ?middle_profile = Map.get(users, Principal.compare, middle) else {return "Middle profile not found."};
    let ?end_profile = Map.get(users, Principal.compare, end) else {return "End profile not found."};
    if ((start_profile.escrow != 0) or (middle_profile.escrow != 0) or (end_profile.escrow != 0)) {
        return "One of the users is already in an escrow.";
    };
    let now_nat64 : Nat64 = Nat64.fromIntWrap(Time.now());
    escrow_line := escrow_line + 1;
    let escrow_id = escrow_line;
    let escrow = {
        start = start;
        middle = middle;
        end = end;
        start_vote = "";
        middle_vote = "";
        end_vote = "";
        state = "created";
        wallet_id = escrow_id;
        middle_drop = middle_drop;
        sylli_drop = sylli_drop;
        burn_time = now_nat64 + 10_368_000_000_000_000;
    };
    Map.add(users, Principal.compare, start, { start_profile with escrow = escrow_id });
    Map.add(users, Principal.compare, middle, { middle_profile with escrow = escrow_id });
    Map.add(users, Principal.compare, end, { end_profile with escrow = escrow_id });
    Map.add(escrows, Nat.compare, escrow_id, escrow);
    return "Escrow created with ID: " # Nat.toText(escrow_id);
  };
  // ---------------------------------------------------------------------------
  // Wyszukiwanie escrow
  // Pobiera escrow powiązane z profilem aktualnego wywołującego.
  // ---------------------------------------------------------------------------
  public shared(msg) func get_escrow() : async ?Escrow_ckbtc{
    let ?user = Map.get(users, Principal.compare, msg.caller) else {
      return null;
    };
    let escrow_id = user.escrow;

    if (escrow_id == 0) {
      return null;
    };
    return Map.get(escrows, Nat.compare, escrow_id);
  };

  // ---------------------------------------------------------------------------
  // Głosowanie
  // Zapisuje głos wywołującego dla konkretnej roli uczestnika escrow.
  // ---------------------------------------------------------------------------
  public shared(msg) func vote_escrow(escrow_id : Nat, vote : Text) : async Text {
    if (vote != "frezze" and vote != "refund" and vote != "done") {
        return "Invalid vote. Please vote 'frezze', 'refund', or 'done'.";      
    };
    let caller = msg.caller;
    if (caller == Principal.fromText("2vxsx-fae")) {
        return "Anonymous caller is not allowed to vote on escrow.";
    };
    let ?escrow = Map.get(escrows, Nat.compare, escrow_id) else {
        return "Escrow not found.";
    };
    if (caller == escrow.start) {
        Map.add(escrows, Nat.compare, escrow_id, { escrow with start_vote = vote });
        return "Vote recorded for start party.";
    } else if (caller == escrow.middle) {
        Map.add(escrows, Nat.compare, escrow_id, { escrow with middle_vote = vote });
        return "Vote recorded for middle party.";
    } else if (caller == escrow.end) {
        Map.add(escrows, Nat.compare, escrow_id, { escrow with end_vote = vote });
        return "Vote recorded for end party.";
    } else {
        return "Caller is not a participant in this escrow.";

  };
  };
  // ---------------------------------------------------------------------------
  // Saldo portfela
  // Odczytuje saldo przypisane do aktywnego portfela escrow.
  // ---------------------------------------------------------------------------
  public shared(msg)func escrow_balance() : async Nat {
    let ?user = Map.get(users, Principal.compare, msg.caller) else {
      return 0;};
      let escorw_id = user.escrow;
      if (escorw_id == 0) {
        return 0;
      };
      let ?escrow = Map.get(escrows, Nat.compare, escorw_id) else {
        return 0;
      };
      let get_balance = await Icp.getBalance(Principal.fromActor(Self), escrow.wallet_id);
      return get_balance;

  };
  // ---------------------------------------------------------------------------
  // Informacje o portfelu escrow
  // Zwraca szczegóły konta portfela powiązanego z aktywnym escrow wywołującego.
  // ---------------------------------------------------------------------------
  public shared(msg) func escrow_wallet() : async ?Icp.Account{
    let ?user = Map.get(users, Principal.compare, msg.caller) else {
      return null;};
      let escorw_id = user.escrow;
      if (escorw_id == 0) {
        return null;
      };
      let ?escrow = Map.get(escrows, Nat.compare, escorw_id) else {
        return null;
      };
      return ?{
        owner = Principal.fromActor(Self);
        subaccount = ?Icp.natToSubaccount(escrow.wallet_id);
      };
  };
  // ---------------------------------------------------------------------------
  // Publiczne wyszukiwanie konta
  // Odczytuje profil użytkownika po principalu.
  // ---------------------------------------------------------------------------
  public query func get_account(a : Principal) : async ?user {
    return Map.get(users, Principal.compare, a);
  };

  // ---------------------------------------------------------------------------
  // Rozstrzygnięcie i realizacja escrow
  // Wdraża wybrane rozwiązanie po spełnieniu wymaganych głosów.
  // ---------------------------------------------------------------------------
  // Funkcja rozpatruje wynik escrow po zgodności głosów uczestników.
  public func law_escrow(escrow_id : Nat, v : Text) : async Text {
    let ?escrow_work = Map.get(escrows, Nat.compare, escrow_id) else {
        return "Escrow not found.";
    };
    if (v != "frezze" and v != "refund" and v != "done"){
        return "Invalid vote. Please vote 'frezze', 'refund', or 'done'.";      
    };
    let vot = v;
    if((escrow_work.start_vote == vot and escrow_work.end_vote == vot) or (escrow_work.start_vote == vot and escrow_work.middle_vote == vot) or (escrow_work.middle_vote == vot and escrow_work.end_vote == vot)) {
        Map.add(escrows, Nat.compare, escrow_id, { escrow_work with state = vot });
        if(vot == "frezze") {
          let pienioszki = await Icp.getBalance(Principal.fromActor(Self), escrow_work.wallet_id);
          if ((escrow_work.sylli_drop + escrow_work.middle_drop + ICP_FEE) > pienioszki) {
            return "small amount of ICP in escrow, cannot freeze.";
          };
          Map.add(escrows, Nat.compare, escrow_id, { escrow_work with state = "frezze" });
          return "ICP has been frozen.";    
        }; if(vot == "refund") {
          if(escrow_work.state != "frezze") {
            return "Escrow is already for this first make frezze";
          };
          let pienioszki = await Icp.getBalance(Principal.fromActor(Self), escrow_work.wallet_id);
          let ?target_profile  = Map.get(users, Principal.compare, escrow_work.start) else {return "sus error";};
          let ?midle_profile  = Map.get(users, Principal.compare, escrow_work.middle) else {return "sus error";};
          let target_wallet = target_profile.wallet;
          let midle_wallet = midle_profile.wallet;
          ICP_FEE := await icpLedger.icrc1_fee();

          
          ignore Map.delete(escrows, Nat.compare, escrow_id);
          if(escrow_work.middle_drop > ICP_FEE){
          ignore await Icp.transfer( escrow_work.wallet_id, midle_wallet, escrow_work.middle_drop, ICP_FEE);
          };
          if(escrow_work.sylli_drop > ICP_FEE){
          ignore await Icp.transfer( escrow_work.wallet_id, sylli_wallet, escrow_work.sylli_drop, ICP_FEE);
          };
          ignore Map.add(recover, escrow_work.wallet_id, target_wallet);
          loop {
            try {
            let pienioszki = await Icp.getBalance(Principal.fromActor(Self), escrow_work.wallet_id);
            let result = await Icp.transfer( escrow_work.wallet_id, target_wallet, pienioszki, ICP_FEE);
             switch (result) {
              case (#Ok(_) or #Err(#Duplicate(_))) { break };
              case (#Err(_)) {};
            };
            } catch (_) {};
          };


          
          ignore Map.delete(users, Principal.compare, escrow_work.start);
          ignore Map.delete(users, Principal.compare, escrow_work.middle);
          ignore Map.delete(users, Principal.compare, escrow_work.end);
          ignore Map.delete(escrows, Nat.compare, escrow_id);
          return "ICP has been refunded.";
        }; if(vot == "done") {
          if(escrow_work.state != "frezze") {
            return "Escrow is already for this first make frezze";
          };
          let pienioszki = await Icp.getBalance(Principal.fromActor(Self), escrow_work.wallet_id);
          let ?target_profile = Map.get(users, Principal.compare, escrow_work.end) else {return "sus error";};
          let ?midle_profile = Map.get(users, Principal.compare, escrow_work.middle) else {return "sus error";};
          let target_wallet = target_profile.wallet;
          let midle_wallet = midle_profile.wallet;
          ICP_FEE := await icpLedger.icrc1_fee();

          
          ignore Map.delete(escrows, Nat.compare, escrow_id);
          if(escrow_work.middle_drop > ICP_FEE){
          ignore await Icp.transfer( escrow_work.wallet_id, midle_wallet, escrow_work.middle_drop, ICP_FEE);
          };
          if(escrow_work.sylli_drop > ICP_FEE){
          ignore await Icp.transfer( escrow_work.wallet_id, sylli_wallet, escrow_work.sylli_drop, ICP_FEE);
          };
          ignore Map.add(recover, escrow_work.wallet_id, target_wallet);
          loop {
            try {
            let pienioszki = await Icp.getBalance(Principal.fromActor(Self), escrow_work.wallet_id);
            let result = await Icp.transfer( escrow_work.wallet_id, target_wallet, pienioszki, ICP_FEE);
             switch (result) {
              case (#Ok(_) or #Err(#Duplicate(_))) { break };
              case (#Err(_)) {};
            };
            } catch (_) {};
          };


          
          ignore Map.delete(users, Principal.compare, escrow_work.start);
          ignore Map.delete(users, Principal.compare, escrow_work.middle);
          ignore Map.delete(users, Principal.compare, escrow_work.end);
          ignore Map.delete(escrows, Nat.compare, escrow_id);
          return "Escrow is completed.";
        };
        
        
      };
    return "why are you gay?";
};

  // ---------------------------------------------------------------------------
  // Przywracanie środków z portfela escrow
  // Umożliwia odzyskanie środków po zapisaniu informacji o odzyskiwaniu.
  // ---------------------------------------------------------------------------
  public func recovery(wallet_id : Nat) : async Text {
    
    let ?target_wallet = Map.get(recover, wallet_id) else {
      return "No recovery information found for this wallet ID.";
    };
    let pienioszki = await Icp.getBalance(Principal.fromActor(Self), wallet_id);
    ICP_FEE := await icpLedger.icrc1_fee();
    if(pienioszki > ICP_FEE){
      ignore await Icp.transfer( wallet_id, target_wallet, pienioszki, ICP_FEE);
      ignore Map.delete(recover, wallet_id);
      return "Recovery transfer completed.";
    } else {
      return "Insufficient funds for recovery transfer.";
    };
    return "you are gay";
  };
};
