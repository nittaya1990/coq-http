From Extract Require Import
     IO_Test.
From HTTP Require Import
     Execute.

Definition run_test : io_unit :=
  IO.unsafe_run
    (ORandom.self_init tt;; run_test (multi_test $ @test void http_smi)).

Separate Extraction run_test.