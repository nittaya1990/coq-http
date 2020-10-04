From ExtLib Require Export
     Applicative
     OptionMonad
     Reducible.
From Parsec Require Export
     Core.
From HTTP Require Export
     Message
     Common.
From Coq Require Import
     String.
Export
  ApplicativeNotation.

(** https://www.rfc-editor.org/rfc/rfc3986.html#section-2.1 *)
Definition parsePctEncoded : parser string :=
  liftA2 String (expect "%"%char)
         (string_of_list_ascii <$> manyN 2 (satisfy ishexdig)).

(** https://www.rfc-editor.org/rfc/rfc3986.html#section-2.3 *)
Definition isunreserved (a : ascii) : bool :=
  isalpha a ||| isdigit a ||| in_string "-._~" a.

Definition issubdelims : ascii -> bool :=
  in_string "!$&'()*+,;=".

Fixpoint expectString (s : string) : parser string :=
  match s with
  | "" => ret ""
  | String a s' => liftA2 String (expect a) (expectString s')
  end.

(** https://www.rfc-editor.org/rfc/rfc3986.html#section-3.1 *)
Definition parseScheme : parser http_scheme :=
  (expectString "http://" ;; ret Scheme__HTTP) <|>
  (expectString "https://";; ret Scheme__HTTPS).

(** https://www.rfc-editor.org/rfc/rfc3986.html#section-3.2 *)
Definition parseUserinfo : parser (option string) :=
  maybe (i <- concat "" <$>
                    (many (flip String "" <$> satisfy
                                (fun a => isunreserved a ||| issubdelims a
                                                    ||| (a =? ":")%char)
                                <|> parsePctEncoded));;
         expect "@"%char;;
         ret i).

Definition parseRegName : parser string :=
  concat "" <$>
         many (flip String "" <$>
                    satisfy (fun a => isunreserved a ||| issubdelims a)
                    <|> parsePctEncoded).

Definition parseHost : parser string :=
  (* TODO: IP-literal and IPv4address *)
  parseRegName.

Definition parsePort : parser (option N) :=
  maybe $ firstExpect ":"%char parseDec.

Definition parseAuthority : parser authority :=
  liftA2 Authority parseUserinfo parseHost <*> parsePort.

(** https://www.rfc-editor.org/rfc/rfc3986.html#section-3.3 *)
Definition parsePchar : parser string :=
  flip String "" <$>
       satisfy (fun a => isunreserved a ||| issubdelims a ||| in_string ":@" a)
       <|> parsePctEncoded.

(** https://www.rfc-editor.org/rfc/rfc5234.html#appendix-B.1 *)
Definition isvchar (a : ascii) : bool :=
  (("033" <=? a) &&& (a <=? "126"))%char.

(** https://httpwg.org/http-core/draft-ietf-httpbis-semantics-latest.html#rfc.section.4.1 *)
Definition parseAbsolutePath : parser path :=
  firstExpect "/"%char $
              concat "" <$>
              many (parsePchar <|> firstExpect "/"%char (ret "/")).

Definition parseQuery : parser (option query) :=
  maybe $
        firstExpect "?"%char
        (concat "" <$> many (parsePchar
                               <|> flip String "" <$> satisfy (in_string "/?"))).

(** https://httpwg.org/http-core/draft-ietf-httpbis-semantics-latest.html#rfc.section.5.7.4 *)
Definition isobstext (a : ascii) : bool :=
  (("128" <=? a) &&& (a <=? "255"))%char.

(** https://httpwg.org/http-core/draft-ietf-httpbis-semantics-latest.html#rfc.section.5.4.4 *)
Definition parseFieldVchar : parser ascii :=
  satisfy $ fun a => isvchar a ||| isobstext a.

Definition parseFieldValue : parser field_value :=
  string_of_list_ascii <$> (many $ parseSP <|> parseHTAB <|> parseFieldVchar).

(** https://httpwg.org/http-core/draft-ietf-httpbis-semantics-latest.html#rfc.section.5.7.2 *)
Definition istchar (a : ascii) : bool :=
  isalpha a ||| isdigit a ||| in_string "!#$%&'*+-.^_`|~" a.

Definition parseToken : parser string :=
  string_of_list_ascii <$> many1 (satisfy istchar).

(** https://httpwg.org/http-core/draft-ietf-httpbis-semantics-latest.html#rfc.section.5.7.3 *)
Definition parseOWS : parser unit :=
  many (parseSP <|> parseHTAB);; ret tt.

(** https://httpwg.org/http-core/draft-ietf-httpbis-semantics-latest.html#rfc.section.7.9.3.2 *)
Definition isetagc (a : ascii) : bool :=
  ((a =? "033") ||| ("035" <=? a) &&& (a <=? "126") ||| isobstext a)%char.

Definition parseEntityTag : parser field_value :=
  liftA2 append
         (weak <- maybe (expectString "W/");;
          match weak with
          | Some w => ret w
          | None   => ret ""
          end)
         (liftA2 String parseDQUOTE $
                 liftA2 append (string_of_list_ascii
                                  <$> (many $ satisfy isetagc)) $
                 flip String "" <$> parseDQUOTE).

Definition parseCSV {T} (p : parser T) : parser (list T) :=
  liftA2 cons p $ many (parseOWS;; firstExpect ","%char (parseOWS;; p)).

(** https://httpwg.org/http-core/draft-ietf-httpbis-messaging-latest.html#rfc.section.2.3 *)
Definition parseVersion : parser http_version :=
  expectString "HTTP/";;
  liftA2 Version parseDec (firstExpect "."%char parseDec).

(** https://httpwg.org/http-core/draft-ietf-httpbis-messaging-latest.html#rfc.section.3 *)
Definition parseMethod : parser request_method :=
  s <- parseToken;;
  ret (match s with
       | "GET"     => Method__GET
       | "HEAD"    => Method__HEAD
       | "POST"    => Method__POST
       | "PUT"     => Method__PUT
       | "DELETE"  => Method__DELETE
       | "CONNECT" => Method__CONNECT
       | "OPTIONS" => Method__OPTIONS
       | "TRACE"   => Method__TRACE
       | s         => Method s
       end).

Definition parseTarget : parser request_target :=
  liftA2 RequestTarget__Origin parseAbsolutePath parseQuery <|>
  liftA2 RequestTarget__Absolute parseScheme parseAuthority <*> parseAbsolutePath
         <*> parseQuery <|>
  RequestTarget__Authority <$> parseAuthority <|>
  firstExpect "*"%char (ret RequestTarget__Asterisk).

Definition parseRequestLine : parser request_line :=
  liftA2 RequestLine parseMethod (parseSP;; parseTarget) <*>
         (parseSP;; parseVersion).

(** https://httpwg.org/http-core/draft-ietf-httpbis-messaging-latest.html#rfc.section.4 *)
Definition parseStatusCode : parser status_code :=
  d3 <- manyN 3 (satisfy isdigit);;
  match evalStateT parseDec d3 with
  | inl e => raise e
  | inr n => ret n
  end.

Definition parsePhrase : parser (option reason_phrase) :=
  maybe $ string_of_list_ascii
        <$> many1 (parseHTAB <|> parseSP
                             <|> satisfy (fun a => isvchar a ||| isobstext a)).

Definition parseStatusLine : parser status_line :=
  liftA2 Status parseVersion (parseSP;; parseStatusCode)
         <*> (parseSP;; parsePhrase).

(** https://httpwg.org/http-core/draft-ietf-httpbis-messaging-latest.html#rfc.section.5 *)
Definition parseFieldLine : parser (field_line id) :=
  liftA2 Field parseToken $
         firstExpect ":"%char
         (parseOWS;;
          v <- parseFieldValue;;
          parseOWS;;
          ret v).

(** https://httpwg.org/http-core/draft-ietf-httpbis-messaging-latest.html#rfc.section.2.1 *)
Definition parseFieldLines : parser (list (field_line id)) :=
  many (l <- parseFieldLine;; parseCRLF;; ret l).

(** https://httpwg.org/http-core/draft-ietf-httpbis-messaging-latest.html#rfc.section.6 *)
Definition findField {exp_} (n : field_name) (fs : list (field_line exp_))
  : option (exp_ field_value) :=
  field__value <$> find (fun f => fold (String ∘ tolower) "" (field__name f) =?
                             fold (String ∘ tolower) "" n) fs.

Definition parseBody (fs : list (field_line id))
  : parser (option message_body) :=
  match findField "Content-Length" fs with
  | Some v =>
    match parse parseDec v with
    | inl _
    | inr (_, String _ _) => raise $ Some "Content-Length not a number."
    | inr (n, "") => Some ∘ string_of_list_ascii <$> manyN (N.to_nat n) anyToken
    end
  | None =>
    (* TODO: Transfer-Encoding *)
    ret None
  end.

(** https://httpwg.org/http-core/draft-ietf-httpbis-messaging-latest.html#rfc.section.2.1 *)
Definition parseRequest : parser http_request :=
  l <- parseRequestLine;;
  parseCRLF;;
  f <- parseFieldLines;;
  parseCRLF;;
  b <- parseBody f;;
  ret (Request l f b).

Definition parseResponse : parser (http_response id) :=
  l <- parseStatusLine;;
  parseCRLF;;
  f <- parseFieldLines;;
  parseCRLF;;
  b <- parseBody f;;
  ret (Response l f b).
