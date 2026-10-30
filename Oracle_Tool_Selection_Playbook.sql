# Oracle Tool Selection Playbook: "I have an issue, which tool do I use?"

Open this file FIRST when you do not know where to start. Part 1 maps a symptom to the first tool, Part 2 is a short decision path, Part 3 describes every tool with the same fields, Part 4 lists the usual combinations.
Facts and numbers come from our labs on Oracle AI Database 26ai Free (Colima/Docker); "(documentation)" marks what we did not run. Licence remarks are from memory of the Oracle licensing guide: confirm for your site.
Detailed commands live in the other playbooks: W = Oracle_Wait_Event_Playbook.sql, O = Oracle_ORA_Error_Playbook.sql, T = Oracle_SQL_Tuning_Playbook.sql, H = Oracle_Historical_Analysis_Playbook.sql.

---

## PART 1. Symptom -> first tool -> next step

| # | What you see / are asked | First tool | Then | Where |
|---|---|---|---|---|
| 1 | "The database is slow RIGHT NOW" | Live session and wait summary (gv$session with state = 'WAITING', ASH last 5 minutes) | find the top SQL, then the wait-event entry for the event | W sections 2, 3, 13 |
| 2 | "This job has run for minutes: is it stuck, which step, when does it end?" | SQL Monitor report | health check of the statement, plan | T section 5 |
| 3 | "It was slow 3 hours ago / last night" | AWR snapshots + DB time per snapshot, then ASH history | ADDM, AWR report, compare periods | H sections 1, 2, 5 |
| 4 | "What changed between the good and the bad period?" | AWR compare periods | top SQL of both periods, new statements | H section 2.7 |
| 5 | "Which SQL is the heaviest?" | ASH top SQL (live) / dba_hist_sqlstat deltas (past) | plan, health check | W 3, H 2.3 |
| 6 | "Several problems at once, what is biggest?" | ADDM ranking + ASH by module | verify each finding with the wait-event playbook | H section 5 |
| 7 | "One SQL is slow, the text did not change" | Health check by hand (indexes, statistics, parameters, history) | SQLHC if you want the priority list | T section 7 |
| 8 | "The plan changed / fast yesterday, slow today" | Plan history (dba_hist_sqlstat by plan_hash_value, gv$sql children) | find the cause; baseline only if the old plan can be reproduced | H 2.3, T 2 |
| 9 | "Estimates are wrong (E-Rows far from A-Rows), I cannot edit the SQL" | SQL Tuning Advisor (sqltrpt.sql) | accept the profile only if ELAPSED improves; or fix the cause with extended statistics | T 3, 8 |
| 10 | "Estimates are wrong because columns are correlated / expression on a column" | Extended statistics | check the advisor again | T 3.3 |
| 11 | "I want a specific join method / access path and I can edit the SQL" | Hint in the text | Hint Report must show it resolved | T 4 |
| 12 | "I know the hint but cannot edit the SQL (vendor)" | SQL patch | check Hint Report, Note line | T 4.4 |
| 13 | "I need one specific plan frozen and stable" | SQL plan baseline (SPM) | evolve later | T 2 |
| 14 | "Index suspected missing" | SQL Tuning Advisor index finding | measure the write cost first, then create ONLINE | T 8.3 |
| 15 | "Query uses a function / implicit conversion on an indexed column" | Advisor "Restructure SQL" finding / plan filter line | fix the predicate in the application | T 8.1 |
| 16 | "Oracle Support asks for diagnostics of a SQL" | SQLHC (or SQLT if they ask) | AWR + ASH + ADDM reports | T 7.3, 9 |
| 17 | "Will my SQL statements regress after the patch/upgrade?" | SQL Performance Analyzer (RAT option) or the mini-SPA by hand | fix regressions, compare again | T 10 |
| 18 | "Will the system hold up under production load after the change?" | Database Replay (RAT option) | divergence first, then performance | T 6 |
| 19 | "Need exact per-call timing of one session's workload" | 10046 trace + tkprof (lab 20) | wait list: blocker / lock playbook; blocks per execution: index or set-based SQL | T section 11 |
| 20 | "I have an ORA- error or a log message" | ORA error playbook (alert log, trace, ADR) | | O |
| 21 | "ORA-00060 deadlock detected / two sessions block each other" | alert log line + trace file (deadlock graph); live: gv$session blocker circle with prev_sql_id | same lock order in every code path | O 6.11, W 6.2b |

## PART 2. Decision path (30 seconds)

  1. Is it happening NOW or in the PAST?  NOW -> live session view (row 1) or SQL Monitor (row 2). PAST -> AWR / ASH history (rows 3 to 6).
  2. Do you know WHICH SQL?  No -> ASH top SQL / ADDM. Yes -> step 3.
  3. Did the plan CHANGE (different plan_hash_value in the history)?  Yes -> find what changed (indexes, statistics, parameters: health check). No -> step 4.
  4. Is the plan bad because ESTIMATES are wrong (E-Rows against A-Rows from a copy run with GATHER_PLAN_STATISTICS or SQL Monitor)?  Yes -> extended statistics / profile. No -> missing access path (index), wrong predicate, or just too much data.
  5. CAN you edit the SQL?  Yes -> fix the SQL (predicate, hint). No -> profile / baseline / patch.
  6. Before ANY change on production: test on a clone (SPA for statements, Database Replay for the system), and change ONE thing at a time.

---

## PART 3. The tools, one by one

Fields: WHAT / PROBLEM IT SOLVES / USE IT WHEN / DO NOT USE IT WHEN / NEEDS / HOW (minimum) / READ / LAB EVIDENCE / PITFALLS / NEXT

### 3.1 Live session and wait view (gv$session, gv$active_session_history)
  WHAT: what every session is doing at this moment; ASH samples active sessions every second in memory.
  PROBLEM IT SOLVES: "slow right now": finds the waiting sessions, their wait event, SQL and blocker.
  USE IT WHEN: the problem is happening now or ended minutes ago (memory keeps it; in the lab it still held an incident 4 hours later).
  DO NOT USE IT WHEN: the problem was hours ago and memory has aged out (use AWR/ASH history).
  NEEDS: SELECT on gv$ views; ASH queries need the Diagnostics Pack.
  HOW: gv$session with CASE WHEN state = 'WAITING' THEN event ELSE 'ON CPU' END; ASH top SQL last 5 minutes (W section 3, line 125).
  READ: the event class, blocking_session, sql_id, seconds in wait.
  LAB EVIDENCE: gv$session.event keeps the LAST wait after a session returns to CPU: lab 12 showed `cursor: pin S` for sessions that were 100 percent ON CPU.
  PITFALLS: forgetting the state test; ON CPU in ASH includes waiting for a CPU (runnable but queued).
  NEXT: wait-event cheat sheet (W section 13) for the event, then the SQL tools.

### 3.2 SQL Monitor report
  WHAT: a report of ONE execution of a long statement: plan with actual rows, executions (Execs), time and wait activity per plan line, live while it runs.
  PROBLEM IT SOLVES: "is it stuck, which step is slow, how far along is it, when will it finish".
  USE IT WHEN: a statement runs longer than about 5 s CPU/IO time, or is parallel, or has /*+ MONITOR */.
  DO NOT USE IT WHEN: fast statements (not monitored); you need averages over many runs (use gv$sqlstats/AWR).
  NEEDS: Tuning Pack licence (documentation); DBMS_SQLTUNE.REPORT_SQL_MONITOR.
  HOW: gv$sql_monitor WHERE status = 'EXECUTING'; then REPORT_SQL_MONITOR(sql_id, type => 'TEXT', report_level => 'ALL').
  READ: Global Stats (CPU/IO), the plan line with Activity 100 percent, Execs against Rows (Estim)/(Actual), the "->" lines still running.
  LAB EVIDENCE (lab 13): 402 of 4,000 customers after 22 s = 10 percent -> ~220 s total (actual 198 s); one full-scan step ran 4,000 times; index added: 198 s -> 0.25 s, 67M -> 41K gets.
  PITFALLS: a PL/SQL block and its SELECT appear as two rows with the same sql_exec_id; use the SELECT's sql_id.
  NEXT: fix the step that dominates (missing index, bad estimate).

### 3.3 AWR report (history of an interval)
  WHAT: the difference between two snapshots: load profile, top events, top SQL, host statistics.
  PROBLEM IT SOLVES: "what did the database do between 23:56 and 00:03?"
  USE IT WHEN: the problem is in the past and falls inside (or next to) snapshot boundaries.
  DO NOT USE IT WHEN: the spike is shorter than the snapshot interval (the average hides it: use ASH); you need to know the cause in the application.
  NEEDS: Diagnostics Pack; default snapshot every 60 min, retention 8 days.
  HOW: dba_hist_snapshot to map times to snapshots; DBMS_WORKLOAD_REPOSITORY.AWR_REPORT_TEXT (helper lab/awr_report.sh). Database clock may differ from yours (lab: UTC).
  READ: DB Time / elapsed = average active sessions against the CPU count; Top events; SQL ordered by elapsed; I/O profile; host CPU.
  LAB EVIDENCE (lab 14): quiet intervals 0.53 and 0.68 active sessions, the incident 4.59 (DB CPU 3.9 of 4 cores); the batch statement was 81 percent of DB time.
  PITFALLS: snapshots can be uneven or dropped (first row after a gap spans the gap); PL/SQL wrapper rows double count; disk_reads of direct reads can be OS-cache hits.
  NEXT: ASH history for the exact minute; ADDM for a ranked explanation.

### 3.4 ASH history (dba_hist_active_session_history)
  WHAT: 1 sample in 10 of the active sessions, kept in AWR.
  PROBLEM IT SOLVES: "when exactly did it start and which module/SQL was active, per minute".
  USE IT WHEN: you know the interval and need minute-level detail. For second-level detail use gv$active_session_history while memory holds it.
  DO NOT USE IT WHEN: the workload is light (3 to 6 samples a minute is noise).
  NEEDS: Diagnostics Pack.
  HOW: COUNT(*) * 10 = estimated seconds, group by TRUNC(sample_time,'MI'), module, event (H section 2.5).
  LAB EVIDENCE (lab 14): the batch appeared at 23:56 with exactly 4 sessions per minute; in memory the first session was at 23:56:03.
  PITFALLS: ON CPU includes run-queue time; small modules look random.
  NEXT: AWR totals (elapsed against CPU) to see victims.

### 3.5 ADDM (Automatic Database Diagnostic Monitor)
  WHAT: automatic analysis of an AWR interval; ranks PROBLEM findings by share of DB time, with symptoms, recommendations and estimated benefit. Runs after every snapshot.
  PROBLEM IT SOLVES: "I do not know where to look": gives a ranked list of the biggest DB-time consumers.
  USE IT WHEN: first look at a past period; several causes at once; you want a second opinion on an AWR interval.
  DO NOT USE IT WHEN: you need the application cause; you take its sentences as facts.
  NEEDS: Diagnostics Pack; DBA_ADDM_FINDINGS, DBMS_ADDM.GET_REPORT, ANALYZE_INST for any pair of snapshots (H section 5).
  READ: PROBLEM with its SYMPTOM (parent column), percent of activity, recommendations ("Run SQL Tuning Advisor on SQL_ID x").
  LAB EVIDENCE: lab 05 (unindexed foreign key): Row Lock Waits 98.6 percent with "No recommendations are available" plus Top SQL naming the DELETE; it did NOT find the missing index. Lab 14: said "CPU was not a bottleneck" while the host was 99.6 percent busy.
  PITFALLS: "Top SQL Statements" appears almost every busy interval (68 times in 15 days): it is a pointer, not a diagnosis; a symptom without a recommendation means the application analysis is yours.
  NEXT: wait-event playbook for lock and concurrency findings; SQL tools for statement findings.

### 3.6 AWR compare periods (good against bad)
  WHAT: one report with two intervals side by side.
  PROBLEM IT SOLVES: "what changed?": a workload spike or one heavier statement.
  USE IT WHEN: you have a good and a bad interval.
  NEEDS: Diagnostics Pack; AWR_DIFF_REPORT_TEXT (helper lab/awr_report.sh diff ...).
  READ: Workload Comparison (what changed vs what did not), Top Timed Events (events in only one period), Top SQL "Common SQL Elapsed Time as a % of DB time" (low in the bad period = a new statement).
  LAB EVIDENCE (lab 14): executes 117 -> 116 per second (no more traffic) but DB time per call 4.1 -> 42.1 s; common SQL 96.4 vs 12.8 percent.
  PITFALL: ignore the Per Txn columns when there are no transactions.

### 3.7 Plan display and history (DBMS_XPLAN.DISPLAY_CURSOR / DISPLAY_AWR, gv$sql children, dba_hist_sqlstat)
  WHAT: the plan a statement used (now or in the past), with estimates and, with row-source statistics, actual rows.
  PROBLEM IT SOLVES: "what plan, and is it a plan change?" Different plan_hash_value for the same sql_id = a plan change.
  USE IT WHEN: always, as the second step after you know the SQL.
  HOW: DISPLAY_CURSOR('sql_id', NULL, 'TYPICAL +PEEKED_BINDS'); copy run with /*+ GATHER_PLAN_STATISTICS */ and 'ALLSTATS LAST +HINT_REPORT'; DISPLAY_AWR('sql_id', NULL, NULL, 'TYPICAL') (pass NULL for the dbid in the multitenant lab).
  READ: the first step where E-Rows and A-Rows differ; Starts on inner steps; Note and Hint Report lines.
  LAB EVIDENCE: E-Rows 200 against A-Rows 20,000 -> index probed 20,000 times (labs 11, 12).
  PITFALLS: GATHER_PLAN_STATISTICS can change the plan (statistics feedback, child number 1); read child number and Note; ALLSTATS LAST does not print the Hint Report (add +HINT_REPORT); check last_active_time against the time of your change.

### 3.8 Health check by hand
  WHAT: the nine checks around one SQL: cost per run, plan, indexes (VISIBILITY and STATUS), statistics (stale, locked, rows), non-default optimizer settings, plan history, attached controls, a session-only test, fix and proof.
  PROBLEM IT SOLVES: "the SQL did not change but it got slow".
  USE IT WHEN: first thing for a single slow statement; always before any SQLHC or advisor.
  NEEDS: SELECT on the dictionary only.
  LAB EVIDENCE (lab 16): invisible index: 58.3 ms and 20,803 gets -> 0.03 ms and 16 gets; the stale/locked statistics and index_cost_adj were noise.
  PITFALLS: do not change five things at once; sort findings into CAUSE, NOISE, FOLLOW-UP.
  NEXT: SQLHC for the priority list, the advisor for an opinion. Where: T section 7.1.

### 3.9 SQLHC (SQL Health Check, My Oracle Support note 1366133.1)
  WHAT: a script bundle that produces a zip of HTML reports for ONE sql_id with a prioritised list of observations.
  PROBLEM IT SOLVES: collects everything about one statement in one run and ranks suspicious findings; also what Oracle Support asks for.
  USE IT WHEN: you want a checklist you did not write yourself, or you must open a service request.
  DO NOT USE IT WHEN: a production change is not approved: it forces an AWR snapshot, creates a tuning task, dumps a 10053 trace and runs zip/cp/mv on the OS.
  NEEDS: the scripts from MOS in one directory; SQL*Plus as SYS; the sql_id in the shared pool; licence letter T, D or N.
  HOW: SQL> START sqlhc.sql T <sql_id> (T 7.3, helper lab/run_sqlhc.sh).
  READ: 1_health_check.html Observations (priority), 2_diagnostics.html (plan history, ASH by plan line, statistics versions), 6 the 10053 trace ("Access path analysis").
  LAB EVIDENCE (lab 16): 14 observations; invisible index priority 90 (top); stale statistics 83 was NOT the cause; "Disable the statistics job immediately" is generic advice not to follow blindly.
  PITFALLS: false positives (optimizer features 23.1.0); the tuning advisor and Test Case Builder parts failed in the PDB lab.

### 3.10 DBMS_SQLDIAG.REPORT_SQL
  WHAT: built into recent releases: one PL/SQL call returns one HTML report for a sql_id.
  USE IT WHEN: a quick data collection without installing or approving anything.
  DO NOT USE IT WHEN: you expect findings: in our tests its Observations section was empty.
  HOW: VAR r CLOB; EXEC :r := DBMS_SQLDIAG.REPORT_SQL(sql_id => '...'); SPOOL; PRINT r (a SELECT ... FROM dual raises ORA-14552).
  NOTE: a SQL*Plus copy of an application statement gets a different sql_id. T section 7.5.

### 3.11 SQL Tuning Advisor and sqltrpt.sql
  WHAT: the advisor analyses one statement (also by sampling executions) and reports Index, Restructure SQL, SQL Profile, Statistics or Alternative Plan findings with a validation table. sqltrpt.sql ($ORACLE_HOME/rdbms/admin) lists the 15 most expensive statements, asks for a sql_id and runs the advisor.
  PROBLEM IT SOLVES: "tell me what could be wrong with this statement": index missing, predicate prevents an index, estimates wrong, better plan known.
  USE IT WHEN: you know the statement and want a second opinion; the SQL cannot be edited; ADDM says "Run SQL Tuning Advisor".
  DO NOT USE IT WHEN: you want to accept its profile on the headline percentage alone.
  NEEDS: Tuning Pack; leaves a TASK_<n> to drop.
  HOW: SQL> @?/rdbms/admin/sqltrpt.sql then the sql_id (T section 8).
  READ: FINDINGS (type, estimated benefit), then the VALIDATION table: elapsed time, CPU, buffer gets, reads.
  LAB EVIDENCE (lab 17): balance lookup: Index finding 99.73 percent, 72 ms -> 0.025 ms with the index (inserts 4.8 times slower, +26 percent space); account search: Index + Restructure; fixing the predicate: 0.24 s -> 0.01 s; the segment report got "no recommendation" once and a profile once (elapsed 4.98 percent WORSE in validation).
  PITFALLS: the answer can differ between runs on a loaded system (run again at a quiet moment); read the Restructure finding before the Index finding; the advisor sees one statement, not the write overhead of an index.

### 3.12 SQLT (SQLTXPLAIN)  (documentation, skipped in the labs)
  WHAT: the deepest diagnostic: installs a schema, runs methods (XTRACT, XECUTE, COMPARE...) and produces a large report with plan comparison, 10053 trace, test case.
  USE IT WHEN: a hard plan problem, comparing the same statement between two systems, or Oracle Support requests it.
  DO NOT USE IT WHEN: SQLHC or the by-hand health check is enough: it needs an installation (a change request).
  T section 9.

### 3.13 10046 trace and tkprof  (lab 20; commands and reading guide: SQL Tuning playbook section 11)
  WHAT: a trace of ONE session's calls (parse, execute, fetch, every wait, optionally bind values); tkprof formats it per statement.
  PROBLEM IT SOLVES: the exact cost of every statement of one session or one job (count x cost per execution, cpu versus waits), which AWR/ASH (sampled, all sessions) cannot give.
  USE IT WHEN: you can name the session/job/user and it is reproducible or running now; you need numbers per statement; ASH is too coarse; a PL/SQL loop hides many cheap-looking calls; you must prove where the time goes (cpu or which wait).
  DO NOT USE IT WHEN: the problem is system-wide or unknown (AWR/ADDM first); you cannot find the session; it is hours long on a busy production session without a plan to switch it off (the file grows).
  NEEDS: ALTER SESSION privilege for your own session (ORA-01031 otherwise), or DBMS_MONITOR (SYS/DBA) for another session; access to the trace directory on the server (RAC: the node where the session ran); overhead is small at level 8, higher with binds.
  HOW: own session 11.2, another session 11.6, tkprof 11.3, reading 11.4 and 11.5.
  READ: first block of the tkprof report; do count x cost; query/rows; cpu versus elapsed and the wait list under the statement.
  LAB EVIDENCE (lab 20): PL/SQL month-end job 1.6 s: one SELECT run 400 times read 530,000 blocks (96% of the time); a plain index was ignored (clustering factor 300,000), a covering index gave 2,017 blocks and 0.07 s. Lab 20b: traced POSTING_JOB from outside: cpu 0.21 s, elapsed 37.70 s, 99.4% in "enq: TX - row lock contention" - the fix was the blocker, not the SQL.
  PITFALLS: wrong file (ls -t); forget to switch tracing off; trace the right schema; a snapshot of gv$session can miss a job that alternates wait and sleep; with connection pools trace by client id/service/module and merge with trcsess (SQL Tuning playbook 11.7; trcsess untested, it does not run in the lab image).
  NEXT TOOL: the blocker with gv$session.blocking_session (Wait Event playbook, row lock); a plan or index change; SQL Monitor for a long single statement.

### 3.14 SQL profile
  WHAT: a stored set of corrections for the optimizer's row estimates for one statement (for example "table C returns 92.8 times more rows"); it stores no plan. Usually created from the advisor (ACCEPT_SQL_PROFILE).
  PROBLEM IT SOLVES: bad plan caused by wrong estimates when you cannot edit the SQL.
  USE IT WHEN: the cause is estimates and you cannot fix it at the source (vendor SQL).
  DO NOT USE IT WHEN: the elapsed time does not improve in the validation table; you can fix the cause (extended statistics); the estimates may drift (a fixed multiplier goes stale).
  NEEDS: Tuning Pack (via the advisor); force_match => TRUE for literal variants.
  LAB EVIDENCE (lab 11): plan 1912197898 -> 3981533769, 17 -> 48 executions/s, 412 -> 129 ms, 244K -> 18K gets, no cursor purge needed.
  PITFALLS: dropping a profile does not remove its cursor. T section 3.

### 3.15 Extended statistics and statistics fixes
  WHAT: column groups or expressions so the optimizer knows correlated columns; also fixing stale/locked/missing statistics.
  PROBLEM IT SOLVES: the ROOT CAUSE of wrong estimates for every query on those columns.
  USE IT WHEN: columns move together (seg/tier/grp), or a function is applied; statistics are stale or locked.
  HOW: DBMS_STATS.CREATE_EXTENDED_STATS + GATHER_TABLE_STATS(method_opt => 'FOR ALL COLUMNS SIZE 1', no_invalidate => FALSE).
  LAB EVIDENCE (labs 11, 17, 18): estimate 200 -> 20,000; segment report 1,078 ms -> 135 ms; after it the advisor found nothing to correct.
  PITFALLS: a group is ignored if the member columns have histograms and the group has none. T section 3.3.

### 3.16 SQL plan baseline (SQL Plan Management)
  WHAT: the optimizer may only use accepted plans for the statement; new plans are held back until verified (evolve).
  PROBLEM IT SOLVES: plan regression and instability: "fast yesterday, slow today": lock the good plan.
  USE IT WHEN: you have (or can get) the good plan and need stability, including after upgrades.
  DO NOT USE IT WHEN: the good plan cannot be reproduced (an invisible index: the baseline shows REPRODUCED = NO); remove the cause first.
  NEEDS: Enterprise Edition feature (documentation); load from AWR through a SQL tuning set or from the cursor cache; a purge of the existing cursor so it applies at the next hard parse.
  LAB EVIDENCE (lab 10): 33-34 executions/s at ~187 ms -> 425-490 executions/s at ~13 ms.
  PITFALLS: aliases in a hinted copy (use none); EVOLVE_SQL_PLAN_BASELINE must be called from PL/SQL. T section 2.

### 3.17 Hint in the SQL text
  WHAT: an instruction in the statement (/*+ USE_HASH(o) */).
  PROBLEM IT SOLVES: you own the SQL and know the right access path or join.
  DO NOT USE IT WHEN: you cannot edit the SQL; you have not checked the Hint Report (an unresolved hint is ignored silently).
  HOW: DISPLAY_CURSOR(... 'ALLSTATS LAST +HINT_REPORT') and read "N - Unresolved". LAB: USE_HASH(o): 18,185 gets; USE_HASH(x) FULL(z) did nothing, no error. T section 4.

### 3.18 SQL patch
  WHAT: attaches hints to a statement from outside (DBMS_SQLDIAG.CREATE_SQL_PATCH).
  PROBLEM IT SOLVES: you know the hint but cannot change the SQL (vendor code).
  NEEDS: the hint qualified with its query block: USE_HASH(o@sel$1); plain USE_HASH(o) stayed Unresolved in a patch. Licence not verified (check).
  LAB EVIDENCE (lab 12): 260-336 ms -> 92 ms, 241K -> 17,962 gets, the SQL text untouched.
  PITFALLS: dropping or creating a patch may leave the old cursor: purge it and test sql_patch in gv$sql. T section 4.4.

### 3.19 SQL tuning set (STS)
  WHAT: a saved collection of statements with plans, binds and statistics (from the cursor cache, AWR or another set).
  PROBLEM IT SOLVES: it is the input for loading baselines (lab 10), for SPA, and a record of a workload.
  NEEDS: DBMS_SQLTUNE (Tuning Pack); works on Free.
  PITFALLS: sql_text is a CLOB: DBMS_LOB.SUBSTR, never ORDER BY it.

### 3.20 SQL Performance Analyzer (SPA)  (RAT option; mini-SPA by hand on Free)
  WHAT: runs a tuning set before and after a change and compares statement by statement.
  PROBLEM IT SOLVES: "will any SQL regress after the patch/upgrade/parameter change?"
  USE IT WHEN: before the change; first of the two RAT tools.
  DO NOT USE IT WHEN: you need concurrency, locking or capacity answers (Database Replay).
  NEEDS: Real Application Testing option (ORA-00438 on Free); a representative test system (no point-in-time restore needed).
  LAB EVIDENCE (lab 18, by hand): invisible index: S1 13 -> 21,466 gets and S5 6 -> 21,469 regressed, S2 improved, S3/S4 unchanged; verdict on buffer gets and plan, not milliseconds. T section 10.

### 3.21 Database Replay  (RAT option, documentation)
  WHAT: records the production workload with its concurrency and replays it on a restored clone with the change applied.
  PROBLEM IT SOLVES: "will the whole system hold up after the change?"
  USE IT WHEN: second step of a big change, after SPA.
  NEEDS: RAT option; ARCHIVELOG + backup + the capture start SCN; a clone restored to that SCN; disabled links and jobs; wrc clients (calibrate first). Neither wrc command starts the replay: START_REPLAY does.
  READ: data divergence and error divergence first, then DB time, top SQL and top waits against the capture.
  T section 6.

---

## PART 4. Typical combinations (follow the arrows)

  Slow right now:        live session view -> ASH top SQL -> plan (DISPLAY_CURSOR) -> health check -> fix (index / predicate / statistics) -> prove with before/after numbers.
  Slow earlier:          AWR DB time per snapshot -> top SQL of the interval -> ASH per minute -> ADDM -> compare periods -> cause -> fix.
  One statement, unknown cause:  plan -> health check by hand -> SQLHC (priority list) -> advisor (opinion) -> confirm in your own session -> fix one thing.
  Bad estimates, cannot edit:    advisor -> (profile if ELAPSED improves) or extended statistics -> verify with the advisor again.
  Plan flipped:          plan history -> find the cause -> baseline only if the old plan can be reproduced -> evolve later.
  Before a change:       STS -> SPA (or mini-SPA) -> fix regressions -> Database Replay -> go/no-go with written pass criteria.
  Support case:          SQLHC (+ AWR/ASH/ADDM reports) -> SQLT only if asked.

Golden rules from the labs: (1) fix the cause before using a control (profile, baseline, patch); (2) change one thing at a time and measure each; (3) read the validation / Hint Report / Note lines before trusting a result; (4) a tool's percentage or priority is a pointer, not a verdict; (5) check last_active_time and child numbers before concluding that a plan did not change.


## PART 5. How to reason about ANY plan, trace or incident (five steps, from the labs)

  1. Say the answer you EXPECT before you look at the output ("one row per new order, about 50,000 rows"). Without an expectation nothing looks wrong.
  2. Follow ONE concrete row/session/block by hand ("order 7 belongs to region 8: which region rows does it meet?"). With a join condition one, without it all 60 = a Cartesian join.
  3. Do the arithmetic with the numbers on the screen: 60 x 100K = 6,000K rows (lab 22); 530,000 blocks / 400 executions = 1,325 per execution (lab 20); 0.21 s cpu of 37.7 s elapsed = waiting (lab 20b); 44 alert-log lines / 2 per failure = 22 failures (lab 22).
  4. Compare every plan step with its inputs (the Rows column, read bottom to top): output far above the inputs = a join that multiplies; far below = a strong filter; estimate versus actual (E-Rows / A-Rows) = bad statistics.
  5. When two things interact (locks, waits), draw the TIMELINE: one column per session, time going down, who holds what at each moment (lab 21 deadlock).
  Habit: write down (a) what it should return, (b) which step you suspect, (c) which number would prove you wrong, BEFORE you read the output. Then verify with a count query. Tiny data on paper (3 orders, 2 regions) is enough to see why a join multiplies.
  Also ask the business question first in plain words, then check that the SQL says exactly that.
