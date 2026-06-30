       IDENTIFICATION DIVISION.
       PROGRAM-ID. OPS-DAILY-DRIVER.
      *>===================================================================
      *> 日次パイプライン step ドライバ（e2e-driver.cob と同型の薄いシム）。
      *>
      *> 役割: ワーカー（IACR-RUN-DAILY / AD-RUN-DAILY / FEE-CHARGE /
      *>       STMT-GENERATE-BATCH / INTI-DECODE-BATCH / INTO-DRAIN-QUEUE）は
      *>       いずれも PROCEDURE DIVISION USING <INPUT> <OUTPUT> のサブルーチン。
      *>       本ドライバが INPUT/OUTPUT レコードを WORKING-STORAGE に確保し、
      *>       argv から制御パラメータ（batch-id / business-date / ファイル名）を
      *>       詰めて CALL する。実データは ISAM/順ファイル/PG 経由（従来どおり）。
      *>
      *> 使い方: ops-daily-driver <step> <args...>
      *>   step19 <bid> <bdate> <in> <out> <reject> <sentinel> <thr> <req>
      *>   step13 <bid> <bdate> <summary> <checkpoint>
      *>   step15 <bid> <bdate> <failed> <checkpoint> <summary>
      *>   step16 <bid> <bdate> <summary>
      *>   step17 <bid> <bdate> <mode> <out> <summary> <skip-inactive>
      *>   step20 <source> <max-records> <mode>
      *>
      *> 終了コード = ワーカー STATUS の数値（00→0 / 04→4 / 08→8 / 12→12 /
      *>             16→16）。CALL 解決失敗（モジュール不在）は 16 で返す。
      *>===================================================================
       ENVIRONMENT DIVISION.

       DATA DIVISION.
       WORKING-STORAGE SECTION.
       01  WS-STEP                  PIC X(10).
       01  WS-ARG                   PIC X(120).
       01  WS-RC                    PIC 9(4) VALUE 0.

           COPY "iacr-api.cpy".

           COPY "ad-api.cpy".

           COPY "fee-api.cpy".

           COPY "stmt-api.cpy".

           COPY "inti-api.cpy".

           COPY "into-api.cpy".

       PROCEDURE DIVISION.
       MAIN-LOGIC.
           ACCEPT WS-STEP FROM ARGUMENT-VALUE
           EVALUATE FUNCTION TRIM(WS-STEP)
               WHEN "step19" PERFORM DO-STEP19
               WHEN "step13" PERFORM DO-STEP13
               WHEN "step15" PERFORM DO-STEP15
               WHEN "step16" PERFORM DO-STEP16
               WHEN "step17" PERFORM DO-STEP17
               WHEN "step20" PERFORM DO-STEP20
               WHEN OTHER
                   DISPLAY "[ops-daily-driver] unknown step: "
                           WS-STEP UPON SYSERR
                   MOVE 1 TO WS-RC
           END-EVALUATE
           STOP RUN RETURNING WS-RC.

      *>------ step 19: integration-in decode ------
       DO-STEP19.
           ACCEPT WS-ARG FROM ARGUMENT-VALUE
           MOVE WS-ARG(1:14) TO INTI-BATCH-ID
           ACCEPT WS-ARG FROM ARGUMENT-VALUE
           COMPUTE INTI-BUSINESS-DATE = FUNCTION NUMVAL(WS-ARG)
           ACCEPT INTI-INPUT-FILENAME FROM ARGUMENT-VALUE
           ACCEPT INTI-OUTPUT-FILENAME FROM ARGUMENT-VALUE
           ACCEPT INTI-REJECT-FILENAME FROM ARGUMENT-VALUE
           ACCEPT INTI-SENTINEL-FILENAME FROM ARGUMENT-VALUE
           ACCEPT WS-ARG FROM ARGUMENT-VALUE
           COMPUTE INTI-REJECT-THRESHOLD-PCT = FUNCTION NUMVAL(WS-ARG)
           ACCEPT WS-ARG FROM ARGUMENT-VALUE
           MOVE WS-ARG(1:1) TO INTI-REQUIRE-SENTINEL
           MOVE "00" TO INTI-STATUS
           CALL "INTI-DECODE-BATCH" USING INTI-INPUT INTI-OUTPUT
               ON EXCEPTION MOVE "16" TO INTI-STATUS
           END-CALL
           DISPLAY "{""step"":""19"",""status"":""" INTI-STATUS
                   """,""read"":" INTI-OUT-RECORDS-READ
                   ",""decoded"":" INTI-OUT-DETAILS-DECODED
                   ",""rejected"":" INTI-OUT-DETAILS-REJECTED "}"
           COMPUTE WS-RC = FUNCTION NUMVAL(INTI-STATUS).

      *>------ step 13: interest accrual (daily) ------
       DO-STEP13.
           ACCEPT WS-ARG FROM ARGUMENT-VALUE
           MOVE WS-ARG(1:14) TO IACR-RUN-BATCH-ID
           ACCEPT WS-ARG FROM ARGUMENT-VALUE
           COMPUTE IACR-RUN-BUSINESS-DATE = FUNCTION NUMVAL(WS-ARG)
           ACCEPT IACR-RUN-SUMMARY-FILENAME FROM ARGUMENT-VALUE
           ACCEPT IACR-RUN-CHECKPOINT-FILENAME FROM ARGUMENT-VALUE
           MOVE "00" TO IACR-RUN-STATUS
           CALL "IACR-RUN-DAILY" USING IACR-RUN-INPUT IACR-RUN-OUTPUT
               ON EXCEPTION MOVE "16" TO IACR-RUN-STATUS
           END-CALL
           DISPLAY "{""step"":""13"",""status"":""" IACR-RUN-STATUS
                   """,""scanned"":" IACR-OUT-ACCOUNTS-SCANNED
                   ",""accrued"":" IACR-OUT-ACCRUALS-INSERTED "}"
           COMPUTE WS-RC = FUNCTION NUMVAL(IACR-RUN-STATUS).

      *>------ step 15: auto-debit (daily) ------
       DO-STEP15.
           ACCEPT WS-ARG FROM ARGUMENT-VALUE
           MOVE WS-ARG(1:14) TO AD-RUN-BATCH-ID
           ACCEPT WS-ARG FROM ARGUMENT-VALUE
           COMPUTE AD-RUN-BUSINESS-DATE = FUNCTION NUMVAL(WS-ARG)
           ACCEPT AD-RUN-FAILED-FILENAME FROM ARGUMENT-VALUE
           ACCEPT AD-RUN-CHECKPOINT-FILENAME FROM ARGUMENT-VALUE
           ACCEPT AD-RUN-SUMMARY-FILENAME FROM ARGUMENT-VALUE
           MOVE "00" TO AD-RUN-STATUS
           CALL "AD-RUN-DAILY" USING AD-RUN-INPUT AD-RUN-OUTPUT
               ON EXCEPTION MOVE "16" TO AD-RUN-STATUS
           END-CALL
           DISPLAY "{""step"":""15"",""status"":""" AD-RUN-STATUS
                   """,""due"":" AD-OUT-INSTRUCTIONS-DUE
                   ",""posted"":" AD-OUT-INSTRUCTIONS-POSTED
                   ",""failed_nf"":" AD-OUT-FAILED-NF "}"
           COMPUTE WS-RC = FUNCTION NUMVAL(AD-RUN-STATUS).

      *>------ step 16: fee charge ------
       DO-STEP16.
           ACCEPT WS-ARG FROM ARGUMENT-VALUE
           MOVE WS-ARG(1:14) TO FEE-CHARGE-BATCH-ID
           ACCEPT WS-ARG FROM ARGUMENT-VALUE
           COMPUTE FEE-CHARGE-BUSINESS-DATE = FUNCTION NUMVAL(WS-ARG)
           ACCEPT FEE-CHARGE-SUMMARY-FILENAME FROM ARGUMENT-VALUE
           MOVE "00" TO FEE-CHARGE-STATUS
           CALL "FEE-CHARGE" USING FEE-CHARGE-INPUT FEE-CHARGE-OUTPUT
               ON EXCEPTION MOVE "16" TO FEE-CHARGE-STATUS
           END-CALL
           DISPLAY "{""step"":""16"",""status"":""" FEE-CHARGE-STATUS
                   """,""scanned"":" FEE-OUT-TXNS-SCANNED
                   ",""posted"":" FEE-OUT-CHARGES-POSTED "}"
           COMPUTE WS-RC = FUNCTION NUMVAL(FEE-CHARGE-STATUS).

      *>------ step 17: statement generate ------
       DO-STEP17.
           ACCEPT WS-ARG FROM ARGUMENT-VALUE
           MOVE WS-ARG(1:14) TO STMT-BATCH-ID
           ACCEPT WS-ARG FROM ARGUMENT-VALUE
           COMPUTE STMT-BUSINESS-DATE = FUNCTION NUMVAL(WS-ARG)
           ACCEPT WS-ARG FROM ARGUMENT-VALUE
           MOVE WS-ARG(1:1) TO STMT-MODE
           ACCEPT STMT-OUTPUT-FILENAME FROM ARGUMENT-VALUE
           ACCEPT STMT-SUMMARY-FILENAME FROM ARGUMENT-VALUE
           ACCEPT WS-ARG FROM ARGUMENT-VALUE
           MOVE WS-ARG(1:1) TO STMT-SKIP-INACTIVE
           MOVE "00" TO STMT-STATUS
           CALL "STMT-GENERATE-BATCH" USING STMT-INPUT STMT-OUTPUT
               ON EXCEPTION MOVE "16" TO STMT-STATUS
           END-CALL
           DISPLAY "{""step"":""17"",""status"":""" STMT-STATUS
                   """,""accounts"":" STMT-OUT-ACCOUNTS-PROCESSED
                   ",""lines"":" STMT-OUT-LINES-WRITTEN "}"
           COMPUTE WS-RC = FUNCTION NUMVAL(STMT-STATUS).

      *>------ step 20: integration-out drain (autodebit failed → MQ) ------
       DO-STEP20.
           ACCEPT INTD-SOURCE-FILENAME FROM ARGUMENT-VALUE
           ACCEPT WS-ARG FROM ARGUMENT-VALUE
           COMPUTE INTD-MAX-RECORDS = FUNCTION NUMVAL(WS-ARG)
           ACCEPT WS-ARG FROM ARGUMENT-VALUE
           MOVE WS-ARG(1:1) TO INTD-MODE
           MOVE "00" TO INTD-STATUS
           CALL "INTO-DRAIN-QUEUE" USING INTD-INPUT INTD-OUTPUT
               ON EXCEPTION MOVE "16" TO INTD-STATUS
           END-CALL
           DISPLAY "{""step"":""20"",""status"":""" INTD-STATUS
                   """,""drained"":" INTD-OUT-DRAINED-COUNT
                   ",""failed"":" INTD-OUT-FAILED-COUNT "}"
           COMPUTE WS-RC = FUNCTION NUMVAL(INTD-STATUS).

       END PROGRAM OPS-DAILY-DRIVER.
