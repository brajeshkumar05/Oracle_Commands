# Oracle Historical Analysis Playbook (AWR / ASH / ADDM, RAC-ready)

For: "it was slow earlier" ("3 hours ago", "last night between 23:00 and 00:00"). The problem is over, so you use the history Oracle keeps: AWR snapshots (`dba_hist_*`), ASH history, ADDM, and the in-memory ASH (`gv$active_session_history`) when the problem is recent.
Companions: `Oracle_Wait_Event_Playbook.sql` (live), `Oracle_SQL_Tuning_Playbook.sql` (control a plan), `Oracle_ORA_Error_Playbook.sql` (errors and logs), `00_Playbook_Index.md`.
Conventions: read-only queries; `inst_id` / `instance_number` for RAC; tested on Oracle AI Database 26ai Free in the Colima/Docker lab (PDB `FREEPDB1`); entries marked "(not reproduced)" come from Oracle documentation. Licence: AWR, ASH and ADDM need the Diagnostics Pack (ADDM and SQL tuning parts: Diagnostics and Tuning Packs); check your licence before using on production.

---

## 1. Workflow: from a complaint to a cause (lab 14)

1. Pin down the window and the clock. Ask: from when to when, in which time zone? The database clock is what AWR uses (lab: UTC `+00:00`; the Mac was on local time). `SELECT SYSTIMESTAMP, DBTIMEZONE FROM dual;`
2. Map the window to snapshots (section 2.1). Note the interval boundaries inside or next to the window.
3. Was the database busier? DB time and average active sessions per snapshot (2.2). Compare with the quiet intervals around it and with the CPU count.
4. Which SQL? Top SQL of the bad interval and of a good one (2.3). Separate culprit from victim (2.4).
5. When exactly, and who? ASH history per minute (2.5); in-memory ASH for one-second resolution if recent (2.6).
6. Reports: AWR report, ADDM, compare periods (2.7). Check their claims against host statistics.
7. Cause, fix, prevention (section 4). Write the summary for the people who asked.

## 2. Queries and commands (all tested in lab 14 unless marked)

### 2.1 Which snapshots cover the window
  SELECT snap_id, instance_number inst, TO_CHAR(begin_interval_time,'MM-DD HH24:MI:SS') begin_time, TO_CHAR(end_interval_time,'MM-DD HH24:MI:SS') end_time
  FROM   dba_hist_snapshot WHERE dbid = TO_NUMBER(SYS_CONTEXT('USERENV','CON_DBID')) AND end_interval_time > SYSTIMESTAMP - INTERVAL '3' HOUR
  ORDER  BY snap_id, instance_number;
  A snapshot is a point in time; a report is the DIFFERENCE between two. The interval "snap N" is (end of N-1, end of N]. Window 23:56:10-00:04:10 and snapshots ending 23:56:01 / 00:03:03 / 00:06:05: the window is covered by the intervals ending 00:03:03 and 00:06:05.
  Default retention 8 days, interval 1 hour (`dba_hist_wr_control`). With an hourly interval a 3-minute spike is averaged over 60 minutes: use ASH (2.5, 2.6). Intervals can be uneven (manual snapshots, restarts).
  Multitenant: a PDB has its own snapshots (own snap ids, `dbid` = PDB `CON_DBID` 84253675 in the lab). The CDB-level snapshots use the CDB dbid. Many views carry rows under both dbids. Use the PDB dbid as above; exception: `DBMS_XPLAN.DISPLAY_AWR` (2.4).
  RAC: one row per instance for each snap_id; AWR reports are per instance (awrrpt) or global (awrgrpt, not reproduced).
  Create a snapshot now: `EXEC DBMS_WORKLOAD_REPOSITORY.CREATE_SNAPSHOT;` Drop a range: `EXEC DBMS_WORKLOAD_REPOSITORY.DROP_SNAPSHOT_RANGE(low_snap_id, high_snap_id, dbid);` (after dropping, the next snapshot spans the gap).

### 2.2 DB time and average active sessions per snapshot
  WITH tm AS (SELECT snap_id, instance_number, SUM(CASE WHEN stat_name = 'DB time' THEN value END) db_time, SUM(CASE WHEN stat_name = 'DB CPU' THEN value END) db_cpu
              FROM dba_hist_sys_time_model WHERE dbid = TO_NUMBER(SYS_CONTEXT('USERENV','CON_DBID')) AND stat_name IN ('DB time','DB CPU') GROUP BY snap_id, instance_number),
  d AS (SELECT s.snap_id, s.instance_number inst, s.end_interval_time e, LAG(s.end_interval_time) OVER (PARTITION BY s.instance_number ORDER BY s.snap_id) prev_e,
               tm.db_time - LAG(tm.db_time) OVER (PARTITION BY tm.instance_number ORDER BY tm.snap_id) dbt,
               tm.db_cpu  - LAG(tm.db_cpu)  OVER (PARTITION BY tm.instance_number ORDER BY tm.snap_id) cpu
        FROM dba_hist_snapshot s JOIN tm ON tm.snap_id = s.snap_id AND tm.instance_number = s.instance_number WHERE s.dbid = TO_NUMBER(SYS_CONTEXT('USERENV','CON_DBID')))
  SELECT snap_id, inst, TO_CHAR(prev_e,'MM-DD HH24:MI:SS') from_time, TO_CHAR(e,'MM-DD HH24:MI:SS') to_time, ROUND((CAST(e AS DATE)-CAST(prev_e AS DATE))*86400) elapsed_s,
         ROUND(dbt/1e6) db_time_s, ROUND(cpu/1e6) db_cpu_s, ROUND(dbt/1e6/NULLIF((CAST(e AS DATE)-CAST(prev_e AS DATE))*86400,0),2) avg_active_sessions
  FROM   d WHERE e > SYSTIMESTAMP - INTERVAL '3' HOUR ORDER BY snap_id, inst;
  Counters are cumulative, hence LAG. Use the previous AVAILABLE snapshot's time for the elapsed (my first version divided by the interval of the row and gave 8.5 sessions for a 52-minute gap).
  AAS = DB time / elapsed. Compare with the CPU count (`cpu_count` 2, host 4 in the lab) and with DB CPU / elapsed (cores really used). Mostly DB CPU = working, not blocked; a low DB CPU share = waits (look at events).
  Lab: quiet intervals 0.53 and 0.68 AAS, bad interval 4.59 AAS, DB CPU 1656 of 1936 s (86%) = 3.9 cores of 4.

### 2.3 Top SQL in an interval (snap = END snapshot of the interval)
  DEFINE snap = 351
  SELECT x.*, (SELECT DBMS_LOB.SUBSTR(t.sql_text, 60, 1) FROM dba_hist_sqltext t WHERE t.dbid = TO_NUMBER(SYS_CONTEXT('USERENV','CON_DBID')) AND t.sql_id = x.sql_id AND ROWNUM = 1) sql_text
  FROM (SELECT s.instance_number inst, s.sql_id, s.plan_hash_value phv, MAX(s.module) module, SUM(s.executions_delta) execs, ROUND(SUM(s.elapsed_time_delta)/1e6) ela_s, ROUND(SUM(s.cpu_time_delta)/1e6) cpu_s,
               ROUND(SUM(s.elapsed_time_delta)/NULLIF(SUM(s.executions_delta),0)/1e6,3) ela_per_exec_s, SUM(s.buffer_gets_delta) gets, SUM(s.disk_reads_delta) disk_reads
        FROM dba_hist_sqlstat s WHERE s.dbid = TO_NUMBER(SYS_CONTEXT('USERENV','CON_DBID')) AND s.snap_id = &snap
        GROUP BY s.instance_number, s.sql_id, s.plan_hash_value ORDER BY ela_s DESC FETCH FIRST 8 ROWS ONLY) x ORDER BY x.ela_s DESC;
  Use the `_delta` columns (change inside the interval), not the cumulative ones. Run it for the bad interval AND a good one.
  Traps: (a) `MAX(sql_text)` fails with ORA-22849 (CLOB): use DBMS_LOB.SUBSTR in a subquery. (b) PL/SQL wrapper rows (`DECLARE ... BEGIN`, execs 0, phv 0, module SQL*Plus) contain the time of the statements inside: do not add them (4 x 420 s wrappers vs 1569 s of the SELECT). (c) `disk_reads` counts direct path reads even when the OS file cache served them (8 GB/s is not a disk). (d) A statement missing from the good interval is NEW: that is "what changed".
  Plan of a past statement: SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY_AWR('&sql_id', NULL, NULL, 'TYPICAL'));  -- pass NULL for the dbid in the multitenant lab; with the PDB dbid it returned nothing (plan rows exist under both dbids in dba_hist_sql_plan).

### 2.4 Culprit or victim?
  Culprit: its WORK changed (new statement, more executions, more gets per run, new plan) and it takes the time. Victim: same executions per second, same gets per run, but elapsed grows relative to CPU (waiting for a CPU or a resource).
  Lab: ORDER_SCREEN 27,384 execs / 240 s (114/s) and 2,030 gets per run in the quiet interval; 47,651 / 422 s (113/s) and 2,020 gets in the bad one; elapsed 122 s -> 246 s but CPU 109 s -> 123 s: elapsed minus CPU 13 s -> 123 s (10x). ADDM listed it as a second "Top SQL" with benefit 0.7 AAS; tuning it first would be wrong.

### 2.5 ASH history: when exactly, which module (1 sample in 10 on disk, so count x 10 = approximate seconds)
  SELECT TO_CHAR(TRUNC(CAST(sample_time AS DATE),'MI'),'HH24:MI') minute, NVL(module,'(none)') module, COUNT(*)*10 est_db_secs, ROUND(COUNT(*)*10/60,1) avg_active_sessions
  FROM   dba_hist_active_sess_history WHERE dbid = TO_NUMBER(SYS_CONTEXT('USERENV','CON_DBID')) AND snap_id BETWEEN 350 AND 352 AND module IN ('ORDER_SCREEN','MONTH_END_BALANCE')
  GROUP  BY TRUNC(CAST(sample_time AS DATE),'MI'), module ORDER BY 1, 2;
  SELECT module, NVL(event,'ON CPU') event, COUNT(*)*10 est_db_secs, ROUND(100*RATIO_TO_REPORT(COUNT(*)) OVER (PARTITION BY module),1) pct FROM dba_hist_active_sess_history
  WHERE  dbid = TO_NUMBER(SYS_CONTEXT('USERENV','CON_DBID')) AND snap_id = 351 AND module IN ('ORDER_SCREEN','MONTH_END_BALANCE') GROUP BY module, NVL(event,'ON CPU') ORDER BY module, 3 DESC;
  Lab: the batch appeared at 23:56 with exactly 4 sessions per minute through 00:02, 71% ON CPU / 29% direct path read.
  Traps: small signals are noise (a light module has 3-6 samples a minute; the order screen's per-minute counts did not show the incident, the elapsed-versus-CPU gap in AWR did). ASH shows ON CPU also for a session that is runnable but waiting for a CPU (Oracle cannot see the OS run queue): ON CPU in ASH greater than DB CPU in the time model = CPU saturation. The same applies to the ASH report.
  Also available: more columns (sql_id, session_id, blocking_session, current_obj#, p1/p2/p3) in the same view.

### 2.6 One-second resolution while the memory still holds it (RAC: gv$)
  SELECT inst_id, TO_CHAR(MIN(sample_time),'MM-DD HH24:MI:SS') oldest, TO_CHAR(MAX(sample_time),'MM-DD HH24:MI:SS') newest, COUNT(*) FROM gv$active_session_history GROUP BY inst_id;
  SELECT TO_CHAR(sample_time,'HH24:MI:SS') sec, module, COUNT(*) sessions FROM gv$active_session_history WHERE module = '&module' AND sample_time BETWEEN TIMESTAMP '&from' AND TIMESTAMP '&to' GROUP BY TO_CHAR(sample_time,'HH24:MI:SS'), module ORDER BY 1;
  Lab: still held the incident four hours later and showed the first batch session at 23:56:03. On a busy system the retention may be minutes: query it first.

### 2.7 Reports (helper: lab/awr_report.sh writes them to lab/reports/ on the Mac)
  AWR report (one interval):   ./lab/awr_report.sh <begin_snap> <end_snap>       -> DBMS_WORKLOAD_REPOSITORY.AWR_REPORT_TEXT(dbid, 1, begin, end)
  ADDM (same interval):        ./lab/awr_report.sh addm <begin_snap> <end_snap>  -> DBMS_ADDM.ANALYZE_INST(task, begin, end, 1, dbid) then DBMS_ADDM.GET_REPORT(task)
  Compare periods:             ./lab/awr_report.sh diff <good_b> <good_e> <bad_b> <bad_e>  -> DBMS_WORKLOAD_REPOSITORY.AWR_DIFF_REPORT_TEXT
  The interactive scripts awrrpt.sql, awrgrpt.sql (RAC global), awrddrpt.sql (compare), ashrpt.sql, addmrpt.sql are in $ORACLE_HOME/rdbms/admin (not reproduced; same content). ASH_REPORT_TEXT (not reproduced).
  What to read in the AWR report (first ~110 lines): header (Elapsed, DB Time), Top ADDM Findings, Load Profile (DB Time(s), DB CPU(s) per second against CPUs), Top 10 Foreground Events, Wait Classes, I/O Profile (Direct (blocks) vs Via Buffer Cache), then SQL ordered by Elapsed Time / CPU Time.
  Lab AWR: DB time 32.27 min in 7.02 min; DB CPU 3.9/s of 4 CPUs; DB CPU 85.5% + direct path read 30.2% (> 100%: the two overlap in this VM, rank with AWR, split with ASH); physical read 1.10M blocks/s, 8.6 GB/s, all direct; resmgr:cpu quantum 1.9 s (negligible: the 2-CPU limit was not enforced).
  What to read in the compare report: Host Configuration Comparison (load, %User, %System, %Idle), Workload Comparison (what changed vs what did not), Top Timed Events (events in only one period), Top SQL Comparison ("Common SQL Elapsed Time as a % of DB time": 96.4% vs 12.8% = most of the time is in a statement that did not exist before).
  Lab compare: executes 117/s -> 116/s and user calls unchanged, but DB time per call 4.1 s -> 42.1 s: not more traffic, one much heavier statement. Ignore the Per Txn columns when there are no transactions.
  ADDM lab output: Top SQL Statements 97.98% (batch 3.81 AAS benefit, order screen 0.7), Top Segments by User I/O 30.24% (26,444 full scans of RPT_ORDERS, 463M direct reads). It recommends "run SQL Tuning Advisor / Segment Advisor", not the index.
  ADDM said "CPU was not a bottleneck", but the host showed 99.6% busy (dba_hist_osstat: BUSY_TIME +1680 s of 1688 s, LOAD 1.1 -> 4.56; compare report %Idle 0.18). Never accept an ADDM statement without checking host statistics:
  SELECT snap_id, stat_name, value FROM dba_hist_osstat WHERE dbid = TO_NUMBER(SYS_CONTEXT('USERENV','CON_DBID')) AND snap_id IN (&begin, &end) AND stat_name IN ('BUSY_TIME','IDLE_TIME','LOAD','NUM_CPUS') ORDER BY stat_name, snap_id;
  (BUSY_TIME / IDLE_TIME are in centiseconds, cumulative.)

## 3. Gotchas collected in the lab
  - Time zone: database UTC, laptop local time. Convert the ticket's times first.
  - A gap in snapshots makes the first row after the gap span the gap (LAG on the previous available snapshot).
  - gv$session.event keeps the last wait after the session returns to CPU: test `state = 'WAITING'`.
  - Wrapper PL/SQL rows double count; ASH counts of a light workload are noise; `disk_reads` of direct reads can be OS-cache hits; ON CPU in ASH includes waiting for a CPU.
  - DISPLAY_AWR: dbid NULL in the multitenant lab.
  - Manual snapshots, test data: drop with DROP_SNAPSHOT_RANGE so they do not confuse later investigations.

## 4. Worked case (lab 14): customer-orders screen slow 23:56-00:04
  Cause: the month-end batch (module MONTH_END_BALANCE, sql_id a8s3b71q2z3x6, 4 sessions, 28 runs x 56 s, 17M gets per run) did one full scan of LAB.RPT_ORDERS (16,942 blocks, no index on CUST_ID) per customer; it took 4 of 4 CPUs; ORDER_SCREEN was a victim (elapsed twice its CPU).
  Fix: CREATE INDEX on RPT_ORDERS(CUST_ID) (lab 13: 198 s -> 0.25 s, 67M -> 41K gets). Prevention: run batch jobs outside business hours or limit them (Resource Manager consumer groups / instance caging, not reproduced), review new batch SQL before release, alert on AAS above CPU count (not reproduced).
  Keep the evidence: AWR baselines (DBMS_WORKLOAD_REPOSITORY.CREATE_BASELINE for a good and a bad period, not reproduced) so the intervals survive the 8-day retention.
  Lab scripts: lab/14_awr_lab.sh setup | run [normal] [incident] [after] | status | stop (about 14 minutes, takes manual PDB snapshots at the phase boundaries; its log names the phases: spoiler); lab/awr_report.sh.

---

## 5. ADDM in depth (Automatic Database Diagnostic Monitor)  (lab 19, tested on 26ai Free)

### 5.1 What ADDM is
  A diagnostic engine that reads two AWR snapshots and explains where DB time went: it builds a tree of DB time (CPU, and waits by class), reports PROBLEM findings ranked by their share of the DB time ("impact" in average active sessions and percent), the SYMPTOM(s) that led to each (for example a wait class), recommendations with estimated benefit, and INFORMATION items ("this class was not significant"). It does NOT see the application: it can say "row lock waits 98 percent" but not why (the missing foreign-key index of lab 05 produced "Row Lock Waits ... No recommendations are available").
  It runs AUTOMATICALLY after every AWR snapshot (task name ADDM:<dbid>_<instance>_<end snap id>) and the results are kept in the advisor repository: in this lab 378 analyses from 13 October.
  Manual run for any pair of snapshots: DBMS_ADDM.ANALYZE_INST (one instance), ANALYZE_DB (all instances, RAC, documentation), ANALYZE_PARTIAL (chosen instances, documentation); report with DBMS_ADDM.GET_REPORT(task_name). Real-time ADDM (documented): triggered when a performance spike is detected; not reproduced.

### 5.2 Views (tested)
  DBA_ADDM_TASKS (task_id, task_name, created, status), DBA_ADDM_FINDINGS (task_id, finding_id, parent, type PROBLEM|SYMPTOM|INFORMATION, finding_name, active_sessions, perc_active_sess, message, filtered), DBA_ADDM_INSTANCES (per instance DB time and AAS for a global analysis), DBA_ADVISOR_RECOMMENDATIONS and DBA_ADVISOR_ACTIONS (recommendations and their actions: command + message), DBA_ADVISOR_RATIONALE.

### 5.3 What did ADDM say lately? (the automatic analyses, newest first)
  SELECT t.task_name, TO_CHAR(t.created,'MM-DD HH24:MI') created, f.type, f.finding_name, ROUND(f.active_sessions,2) aas, ROUND(f.perc_active_sess,1) pct_of_db_time
  FROM   dba_addm_tasks t JOIN dba_addm_findings f ON f.task_id = t.task_id
  WHERE  t.created > SYSDATE - 2 AND t.status = 'COMPLETED' AND f.type = 'PROBLEM' AND f.perc_active_sess >= 20
  ORDER  BY t.created DESC, f.perc_active_sess DESC FETCH FIRST 25 ROWS ONLY;
  The task name ends with the END snapshot of the interval it analysed (ADDM:84253675_1_351 = snapshots 350 to 351).
  Which kinds of finding does this database have, how often and how big (lab history):
  SELECT f.finding_name, COUNT(*) times, ROUND(MAX(f.perc_active_sess)) max_pct, ROUND(AVG(f.perc_active_sess)) avg_pct
  FROM   dba_addm_tasks t JOIN dba_addm_findings f ON f.task_id = t.task_id
  WHERE  f.type = 'PROBLEM' AND t.status = 'COMPLETED' GROUP BY f.finding_name ORDER BY times DESC;
  Lab result (15 days): Top SQL Statements 68 times (max 100 percent), Top Segments by User I/O and Cluster 20, Row Lock Waits 14, Unusual Concurrency Wait Event 10, Soft Parse 6, Buffer Busy - Hot Objects 5, Hard Parse Due to Literal Usage 5, Buffer Busy - Hot Block 4, PL/SQL Execution 4, Log File Switches 3, Free Buffer Waits 2, Hard Parse Due to Sharing Criteria 2, Index Block Split 1, PL/SQL Compilation 1, CPU Usage 1, Hard Parse Due to Invalidations 1. These match our wait-event labs (row lock, parse storm, hot blocks, log switches).

### 5.4 One analysis in detail
  The findings tree of a task (parent shows which symptom led to which problem):
  SELECT f.finding_id, f.parent, f.type, f.finding_name, ROUND(f.perc_active_sess,1) pct, f.message FROM dba_addm_findings f WHERE f.task_id = (SELECT task_id FROM dba_addm_tasks WHERE task_name = '&task_name') ORDER BY f.finding_id;
  Recommendations and actions:
  SELECT r.rec_id, r.finding_id, r.type rec_type, ROUND(r.benefit/1e6) benefit_s, a.command, SUBSTR(a.message,1,100) action_msg
  FROM   dba_advisor_recommendations r LEFT JOIN dba_advisor_actions a ON a.task_id = r.task_id AND a.rec_id = r.rec_id
  WHERE  r.task_id = (SELECT task_id FROM dba_addm_tasks WHERE task_name = '&task_name') ORDER BY r.rec_id, a.action_id;
  The text report: SET LONG 1000000 LONGCHUNKSIZE 1000000 PAGESIZE 0 LINESIZE 200; SELECT DBMS_ADDM.GET_REPORT('&task_name') FROM dual;
  Lab example (ADDM:84253675_1_255, 23 Oct, the unindexed-foreign-key purge, lab 05): Finding 1 Row Lock Waits 98.64 percent (.82 active sessions), symptom "Application" wait class, "No recommendations are available"; Finding 2 Top SQL Statements 66.67 percent with one recommendation: run the SQL Tuning Advisor on DELETE FROM LAB.PURCHASE_ORDERS WHERE PO_ID = :B1 (268 executions, 14 s each), with the PL/SQL batch that calls it. ADDM found the symptom and the statement but NOT the missing index on the child table's foreign key: that took the hidden count(1) child scan and the TM/TX analysis of the wait-event playbook (8.4).

### 5.5 Run ADDM for any interval (tested)
  DECLARE tname VARCHAR2(100) := 'ADDM_MY_&b._&e.';
  BEGIN
    BEGIN DBMS_ADVISOR.DELETE_TASK(tname); EXCEPTION WHEN OTHERS THEN NULL; END;
    DBMS_ADDM.ANALYZE_INST(tname, &b, &e, 1, TO_NUMBER(SYS_CONTEXT('USERENV','CON_DBID')));     -- begin snap, end snap, instance number, dbid (PDB dbid in the lab)
  END;
  /
  SELECT DBMS_ADDM.GET_REPORT('ADDM_MY_&b._&e.') FROM dual;
  Helper: ./lab/awr_report.sh addm <begin_snap> <end_snap> writes lab/reports/addm_<b>_<e>.txt on the Mac.
  Clean old manual tasks: EXEC DBMS_ADVISOR.DELETE_TASK('ADDM_MY_350_351');

### 5.6 How to use ADDM well
  - It is a ranking, not a verdict: read the percentage, the symptom and the statements; then confirm with AWR / ASH / the wait-event playbook.
  - Impact is relative to DB time of THAT interval: a 98 percent finding of a quiet interval may be small in absolute terms (check the active sessions).
  - Lab 14 caveat: ADDM said "CPU was not a bottleneck" while the host was 99.6 percent busy (dba_hist_osstat); verify against host statistics.
  - A symptom without a recommendation (Row Lock Waits, Unusual Concurrency Wait Event) means: look in the application (wait-event playbook).
  - Recommendations such as "Run SQL Tuning Advisor on SQL_ID x" lead to the tuning playbook (sections 3, 8).
