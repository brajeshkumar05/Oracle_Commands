# Oracle Wait-Event Playbook (RAC-ready)

For: "the database is slow", "the screen hangs", "the job is stuck".
Built from the lab exercises (CPU/plan bottleneck, row lock contention). Companion files in this folder:
`Slow_SQL_Troubleshooting.sql` (deep SQL-tuning runbook), `lab/` (practice scenarios).

**Conventions**
- Every query uses `gv$` (all instances) and carries `inst_id`. On single instance it just returns `inst_id = 1`.
- A session on RAC is identified by **`inst_id` + `sid` + `serial#`**. Never use `sid` alone.
- `&name` values prompt in SQL*Plus. Everything is read-only except section 7 (marked ACTION).
- Licence tags: **[NONE]** no extra licence, **[DIAG]** needs the Diagnostics Pack (ASH/AWR).
- In a CDB, `gv$` shows only the container you are connected to. Connect to the PDB where the application runs, or to `CDB$ROOT` to see everything.
- Tested on Oracle AI Database 26ai Free (single instance). The SQL is the same on 19c RAC, but I have not run it on a multi-node cluster.

Set up your session once:
```sql
SET LINESIZE 250 PAGESIZE 100 TRIMSPOOL ON VERIFY OFF
COL event FORMAT A36
COL module FORMAT A16
COL username FORMAT A14
COL sql_text FORMAT A70 TRUNC
```
Tip: pasting several statements at once into SQL*Plus can garble the output (a blank line ends a statement). Paste one statement at a time, or save to a file and run `@file.sql`.

---

## 1. Triage flow (follow the order)

```
Customer: "slow" / "hangs"
   |
   +-- 1. Ask: which app/job/user? since when? all users or one? what changed?
   +-- 2. WHAT IS THE DB DOING NOW?          -> section 2 (wait summary)
   +-- 3. Pick the family by wait class:
          Application (enq: TX / TM)  -> section 6  row locks
          CPU (not waiting)           -> section 5  CPU / bad plan
          User I/O                    -> section 8  I/O
          Concurrency / Other         -> section 8  latch, mutex, parse
          Cluster (gc ...)            -> section 8  RAC interconnect, hot blocks
          Commit / Configuration      -> section 8  redo, log file sync
   +-- 4. Find the culprit (sql_id / root blocker)
   +-- 5. Prove the root cause with evidence
   +-- 6. Fix with the least destructive action (section 7)  [ACTION]
   +-- 7. Validate with a different query than the one that found it (section 9)
   +-- 8. Prevention (section 10)
```

---

## 2. What is the database doing right now?  [NONE]

### 2.1 One-line summary per instance
```sql
SELECT inst_id,
       CASE WHEN state = 'WAITING' THEN wait_class ELSE 'CPU (not waiting)' END activity,
       CASE WHEN state = 'WAITING' THEN event ELSE 'ON CPU' END event,
       COUNT(*) sessions,
       ROUND(MAX(CASE WHEN state = 'WAITING' THEN wait_time_micro END)/1e6) max_wait_secs
FROM   gv$session
WHERE  type = 'USER' AND status = 'ACTIVE'
AND    NOT (inst_id = USERENV('INSTANCE') AND sid = USERENV('SID'))
GROUP  BY inst_id, CASE WHEN state = 'WAITING' THEN wait_class ELSE 'CPU (not waiting)' END,
          CASE WHEN state = 'WAITING' THEN event ELSE 'ON CPU' END
ORDER  BY sessions DESC;
```
Read it: most sessions in one row = the family. `max_wait_secs` tells you how long they have been stuck.

### 2.2 Why you must look at STATE before EVENT (important)
| `STATE` | Meaning | What `EVENT` shows |
|---|---|---|
| `WAITING` | waiting right now | the current wait (real) |
| `WAITED SHORT TIME` / `WAITED KNOWN TIME` / `WAITED UNKNOWN TIME` | **not waiting, so on CPU** | the *previous*, already finished wait (stale) |

Oracle has no "ON CPU" wait event. A session with state `WAITED …` is running; its `EVENT`/`WAIT_CLASS` columns are leftovers. For such a session `seconds_in_wait` means "seconds since the last wait ended", so a big number proves it has been on CPU that long.

### 2.3 Active session list (who, what, how long)
```sql
SELECT inst_id, sid, serial# serial, username, module, status, state, wait_class, event,
       ROUND(wait_time_micro/1e6) secs_in_this_wait, last_call_et secs_in_call,
       sql_id, blocking_instance b_inst, blocking_session b_sid
FROM   gv$session
WHERE  type = 'USER' AND status = 'ACTIVE'
AND    NOT (inst_id = USERENV('INSTANCE') AND sid = USERENV('SID'))
ORDER  BY last_call_et DESC;
```
To focus on one user or application add `AND username = '&user'` or `AND module = '&module'`.

### 2.4 Load context, last 60 seconds  [NONE]
```sql
SELECT inst_id, metric_name, ROUND(value,2) value, metric_unit FROM gv$sysmetric
WHERE  group_id = 2 AND metric_name IN ('Average Active Sessions','Host CPU Utilization (%)','Database Wait Time Ratio',
       'Average Synchronous Single-Block Read Latency','Executions Per Sec','Hard Parse Count Per Sec','Logons Per Sec')
ORDER  BY metric_name, inst_id;
SELECT inst_id, stat_name, value FROM gv$osstat WHERE stat_name IN ('NUM_CPUS','LOAD');

```
Average Active Sessions well above the CPU count = overloaded. In a PDB `gv$sysmetric` may return no rows; use the CDB.

---

## 3. Find the culprit SQL

### 3.1 Right now, top SQL by DB time (last N minutes)  [DIAG]
```sql
col WAIT_CLASS for a20
COL module FORMAT A18
COL event FORMAT A36
SELECT inst_id, sql_id, sql_plan_hash_value phv, COUNT(*) db_secs,
       ROUND(100*RATIO_TO_REPORT(COUNT(*)) OVER (),1) pct,
       SUM(CASE WHEN session_state = 'ON CPU' THEN 1 ELSE 0 END) on_cpu_secs, MIN(module) module
FROM   gv$active_session_history
WHERE  sample_time > SYSTIMESTAMP - INTERVAL '&mins' MINUTE AND sql_id IS NOT NULL
GROUP  BY inst_id, sql_id, sql_plan_hash_value ORDER BY db_secs DESC FETCH FIRST 10 ROWS ONLY;

```
`db_secs` is about one DB second per sample. Ignore your own diagnostic `sqlplus` rows.
DB_SECS/Secs - we given above(we given in mins) = No of sessions running
ON_CPU_SECS/DB_SECS*100 = CPU time
```sql 5 mins interval with event separated
SET LINESIZE 250 PAGESIZE 60
COL event FORMAT A30

SELECT inst_id, sql_id, sql_plan_hash_value phv, NVL(event,'ON CPU') event, COUNT(*) db_secs,
       ROUND(100*RATIO_TO_REPORT(COUNT(*)) OVER (),1) pct
FROM   gv$active_session_history
WHERE  sample_time > SYSTIMESTAMP - INTERVAL '5' MINUTE AND sql_id IS NOT NULL
GROUP  BY inst_id, sql_id, sql_plan_hash_value, NVL(event,'ON CPU')
ORDER  BY db_secs DESC FETCH FIRST 8 ROWS ONLY;

```

### 3.2 Top wait events in the same window  [DIAG]
```sql
SELECT inst_id, NVL(event,'ON CPU') event, NVL(wait_class,'CPU') wait_class, COUNT(*) db_secs,
       ROUND(100*RATIO_TO_REPORT(COUNT(*)) OVER (),1) pct
FROM   gv$active_session_history WHERE sample_time > SYSTIMESTAMP - INTERVAL '&mins' MINUTE
GROUP  BY inst_id, event, wait_class ORDER BY db_secs DESC FETCH FIRST 12 ROWS ONLY;

```
```sql
COL event FORMAT A40
SELECT NVL(event,'ON CPU') event, COUNT(*) samples, ROUND(100*RATIO_TO_REPORT(COUNT(*)) OVER (),1) pct
FROM   gv$active_session_history
WHERE  sample_time > SYSTIMESTAMP - INTERVAL '15' SECOND AND module = '&module'
GROUP  BY event ORDER BY samples DESC FETCH FIRST 6 ROWS ONLY;

```
```sql
SET LINESIZE 250 PAGESIZE 100
COL module FORMAT A16
COL sql_text FORMAT A60 TRUNC
SELECT inst_id, module, sql_id, plan_hash_value phv, executions execs, ROUND(elapsed_time/1e6) total_ela_s,
       ROUND(elapsed_time/NULLIF(executions,0)/1e3,1) ms_per_exec, ROUND(buffer_gets/NULLIF(executions,0)) gets_per_exec, sql_text
FROM   gv$sql
WHERE  parsing_schema_name = '&scehmaname' AND module IS NOT NULL AND executions > 0 AND sql_text NOT LIKE 'DECLARE%'
ORDER  BY elapsed_time DESC FETCH FIRST 8 ROWS ONLY;
```

### 3.3 Cost per execution (is it called too often, or slow each time?)  [NONE]
```sql
COL sql_text FORMAT A80 WORD_WRAPPED
SELECT inst_id, sql_id, plan_hash_value phv, executions execs,
       ROUND(elapsed_time/NULLIF(executions,0)/1e6,5) ela_per_exec_s,
       ROUND(cpu_time/NULLIF(executions,0)/1e6,5) cpu_per_exec_s,
       ROUND(buffer_gets/NULLIF(executions,0),1) gets_per_exec,
       ROUND(disk_reads/NULLIF(executions,0),1) phys_reads_per_exec,   -- blocks per run that had to come from disk
       ROUND(100*disk_reads/NULLIF(buffer_gets,0)) pct_from_disk,      -- low = served from memory, high = cache not helping
       ROUND(rows_processed/NULLIF(executions,0),1) rows_per_exec,
       disk_reads total_disk_reads,                                    -- cumulative since the cursor was loaded, not per run
       sql_text
FROM   gv$sqlstats WHERE sql_id = '&sql_id' ORDER BY inst_id;

```
Tens of thousands of `gets_per_exec` for a handful of returned rows = wasted work (full scan, bad plan).
cpu_per_exec_s-ela_per_exec_s = Waiting on other event

### 3.4 The problem happened earlier (customer reports after the fact)
```sql
-- [DIAG] AWR ASH, one sample per 10 seconds. Times are database time zone.
SELECT instance_number inst, sql_id, sql_plan_hash_value phv, COUNT(*)*10 est_db_secs, MIN(module) module
FROM   dba_hist_active_sess_history
WHERE  sample_time BETWEEN TO_TIMESTAMP('&start','YYYY-MM-DD HH24:MI') AND TO_TIMESTAMP('&end','YYYY-MM-DD HH24:MI')
AND    sql_id IS NOT NULL
GROUP  BY instance_number, sql_id, sql_plan_hash_value ORDER BY est_db_secs DESC FETCH FIRST 10 ROWS ONLY;
```
Reports for a window: `@?/rdbms/admin/awrgrpt.sql` (RAC, all instances), `awrrpt.sql` (one instance), `awrddrpt.sql` (compare a good period with the bad one), `ashrpt.sql`, `addmrpt.sql`.

---

## 4. Read the execution plan (estimates vs actuals)

```sql
-- run the statement with the hint, then in the same session:
--   SELECT /*+ GATHER_PLAN_STATISTICS */ ...
SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY_CURSOR(NULL, NULL, 'ALLSTATS LAST'));

-- plan of a statement already in the shared pool (estimates only unless it ran with the hint)
SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY_CURSOR('&sql_id', NULL, 'TYPICAL'));
-- on RAC the cursor must be read from the instance that holds it; if it says "not found" connect to that instance

-- plan from the past (AWR)   [DIAG]
SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY_AWR('&sql_id', &plan_hash_value, NULL, 'TYPICAL'));
```
What to check:
- **`E-Rows` vs `A-Rows`**: a big gap means bad statistics or a bad estimate (the optimizer chose the plan on false numbers).
- **`Buffers`** (and `Reads`): the real work. Compare it with the rows returned.
- **`TABLE ACCESS FULL`** on a big table with a selective filter: missing or unusable index.
- **Predicate lines**: `filter` = read then discard, `access` = used an index/hash key. A function on the column (`TRUNC(col)`) blocks the index.
- **Note section / SQL Analysis Report** (23ai+): it names predicates that block index use.
- Several plans for one `sql_id`? `SELECT plan_hash_value, COUNT(*), SUM(executions) FROM gv$sql WHERE sql_id='&sql_id' GROUP BY plan_hash_value;`

Table stats vs reality:
```sql
SELECT owner, table_name, num_rows, TO_CHAR(last_analyzed,'MM-DD HH24:MI') analyzed, stale_stats, stattype_locked
FROM   dba_tab_statistics WHERE owner = '&owner' AND table_name = '&table' AND partition_name IS NULL;
SELECT ROUND(SUM(bytes)/1048576) mb FROM dba_segments WHERE owner = '&owner' AND segment_name = '&table';
```
`stattype_locked` set = the nightly stats job skips this table. Index list:
```sql
SELECT index_name, column_name, column_position FROM dba_ind_columns
WHERE  table_owner = '&owner' AND table_name = '&table' ORDER BY index_name, column_position;
```

### 4.1 How to read a plan, step by step (worked example from the I/O lab)
```
| Id | Operation                             | Name            | Starts | E-Rows | Cost | A-Rows | Buffers |
|  0 | SELECT STATEMENT                      |                 |      1 |        |   81 |      1 |      77 |
|  1 |  SORT AGGREGATE                       |                 |      1 |      1 |      |      1 |      77 |
|  2 |   TABLE ACCESS BY INDEX ROWID BATCHED | TXN_LOG         |      1 |     79 |   81 |     74 |      77 |
|* 3 |    INDEX RANGE SCAN                   | TXN_LOG_ACCT_IX |      1 |     79 |    3 |     74 |       3 |
   3 - access("ACCT_ID"=:B)
```
1. **Order of execution**: the most indented line runs first and feeds its parent. Here 3, then 2, then 1, then 0. (Between siblings, the upper one runs first.) The `Id` is only a label, not the order.
2. **Id 3**: finds the rowids for the account in the index (3 blocks) and returns 74 of them.
3. **Id 2**: for each rowid, fetches the table block (BATCHED = several requested at once, which is what the wait event `db file parallel read` is). Returns 74 rows.
4. **Id 1**: adds up `amount`, one row out. **Id 0**: hands the result to the client.
5. **Cost, A-Time and Buffers are cumulative**: a parent includes its children. The table step's own work is `81 - 3 = 78` cost units and `77 - 3 = 74` buffers (74 rows = 74 table blocks).
6. **E-Rows** is the estimate, **A-Rows** the truth: `79` vs `74` is fine. `Starts` is how many times the step ran (matters under nested loops: total rows = Starts x rows per start).
7. **Where the estimate comes from**: `E-Rows = num_rows / num_distinct` = `8,000,000 / 100,824` = about 79 (`dba_tab_col_statistics`).
8. **Where the table-access cost comes from**: about `E-Rows x clustering_factor / num_rows` = `79 x 7,829,570 / 8,000,000` = about 77. A well-clustered index (clustering factor near the number of table blocks, 151,584) would cost about 1 to 2 there. Clustering factor is how the optimizer knows the table is scattered.
9. **Why this plan won**: the optimizer picks the lowest estimated cost. Index path 81 vs full scan 41,102 (`EXPLAIN PLAN FOR SELECT /*+ FULL(t) */ ...` shows the alternative).
10. **Predicates**: `access` = used to navigate (index key, hash key). `filter` = rows read and then thrown away. A star `*` on the Id means the line has a predicate listed below.
Is the plan "wrong"? Only if estimates differ greatly from actuals (statistics problem) or a cheaper access path exists that Oracle cannot use (function on a column, missing index). When estimates are right and Buffers are high for few rows, the plan is doing what it can and the fix is on the data/index design (covering index, re-clustering).
Block-level evidence for one key (does a key's rows share blocks?):
```sql
SELECT COUNT(*) rows_for_key, COUNT(DISTINCT DBMS_ROWID.ROWID_BLOCK_NUMBER(ROWID)) distinct_table_blocks
FROM   &owner..&table WHERE &column = &value;      -- rows = blocks means fully scattered
SELECT i.index_name, i.clustering_factor, t.blocks, t.num_rows FROM dba_indexes i JOIN dba_tables t
ON     t.owner = i.table_owner AND t.table_name = i.table_name WHERE i.owner = '&owner' AND i.index_name = '&index';
```

### 4.2 Decode an enqueue wait (do not stop at the event name)
For `enq: ...` events `P1` packs the lock type and mode into one number. Decode it:
```sql
SELECT inst_id, sid, event, p1,
       CHR(BITAND(p1,-16777216)/16777215)||CHR(BITAND(p1,16711680)/65535) lock_type,
       BITAND(p1,65535) lock_mode, p2, p3
FROM   gv$session WHERE state = 'WAITING' AND event LIKE 'enq:%';
```
| Type / mode | Typical meaning |
|---|---|
| `TX` mode 6 | plain row lock: another transaction changed the row (forgotten commit, long transaction) |
| `TX` mode 4 | waiting for another transaction to finish for an integrity reason: unique key or foreign key check, or no free ITL slot in a block |
| `TM` modes 3 to 6 | table lock: conflicting `LOCK TABLE`, DDL, or an unindexed foreign key on versions that use table-level locks |
| `HW` | high water mark: concurrent inserts extending a segment |
| `TS`, `ST` | temp or space management |
One event name can hide several situations: `enq: TX - row lock contention` was shown for the plain lock lab (mode 6) and for the foreign-key lab (mode 4). Always check the mode. Details by lock type are in the Oracle Database Reference (wait events) for your version.

---

## 5. CPU-bound (sessions "ON CPU", state `WAITED ...`, no real waits)

1. Confirm with 2.1 and 3.2 (`ON CPU` high) and `gv$osstat` (CPU count).
2. Find the SQL (3.1), then its gets per execution (3.3), then the plan (section 4).
3. Typical causes and fixes:

| Cause | Evidence | Fix |
|---|---|---|
| Stale or locked statistics | `E-Rows` far from `A-Rows`, `stattype_locked` | unlock and regather stats |
| Function on indexed column | `filter(TRUNC(...))`, index unused | rewrite as a range predicate |
| Missing or non-covering index | full scan, huge `Buffers` | index (a covering index avoids table visits) |
| Query called too often | small cost per run, huge executions | cache, reduce calls, fix app loop |
| Parse storm | many near-identical `sql_text`, high hard parse rate | bind variables |

Literal flood check:
```sql
SELECT inst_id, force_matching_signature, COUNT(*) copies, MIN(sql_id) sample_sql_id, SUBSTR(MIN(sql_text),1,80) sample_text
FROM   gv$sqlarea WHERE force_matching_signature <> 0
GROUP  BY inst_id, force_matching_signature HAVING COUNT(*) > 50 ORDER BY copies DESC FETCH FIRST 10 ROWS ONLY;
```
Measure each fix on its own. In the lab, correct statistics alone gave +5%, the SQL rewrite 2.5x, and a covering index 80x. The obvious fix is not always the big one.

---

## 6. Row lock contention (`enq: TX - row lock contention`, class Application)

### 6.1 Victims and their blocker  [NONE]
```sql
SELECT inst_id, sid, serial# serial, username, module, state, event,
       ROUND(wait_time_micro/1e6) secs_waiting, blocking_instance b_inst, blocking_session b_sid, sql_id
FROM   gv$session WHERE blocking_session IS NOT NULL ORDER BY wait_time_micro DESC;

```
The blocker may be on **another instance**: always read `b_inst` with `b_sid`.

### 6.2 Root blocker with number of victims and its open transaction
```sql
SELECT b.inst_id, b.sid, b.serial# serial, b.username, b.status, b.module, b.machine, b.sql_id, b.prev_sql_id,
       ROUND(b.last_call_et/60,1) minutes_in_current_call,
       t.start_time txn_start, t.used_ublk undo_blocks, t.used_urec undo_records, COUNT(*) victims
FROM   gv$session w
JOIN   gv$session b ON b.inst_id = w.final_blocking_instance AND b.sid = w.final_blocking_session
LEFT   JOIN gv$transaction t ON t.inst_id = b.inst_id AND t.ses_addr = b.saddr
WHERE  w.final_blocking_session IS NOT NULL
GROUP  BY b.inst_id, b.sid, b.serial#, b.username, b.status, b.module, b.machine, b.sql_id, b.prev_sql_id,
          b.last_call_et, t.start_time, t.used_ublk, t.used_urec
ORDER  BY victims DESC;
```
`final_blocking_*` follows the chain to the **root**; that is the only session worth acting on.

### 6.2b Two sessions block EACH OTHER = deadlock (lab 21): which two statements?
Symptom: users get ORA-00060, or in the blocking tree two sessions name each other as blocker (a circle, no root). Oracle breaks it after about 3 seconds, so the live view only lasts that long: repeat the query. Full entry (graph in the trace, fix): Oracle_ORA_Error_Playbook.sql section 6.11.
```sql
SELECT s.inst_id, s.sid, s.module, s.event, s.blocking_instance b_inst, s.blocking_session blocker,
       SUBSTR(c.sql_text,1,60) waiting_for_lock_with, SUBSTR(p.sql_text,1,60) first_statement_of_txn
FROM   gv$session s
LEFT   JOIN gv$sql c ON c.inst_id = s.inst_id AND c.sql_id = s.sql_id      AND c.child_number = s.sql_child_number
LEFT   JOIN gv$sql p ON p.inst_id = s.inst_id AND p.sql_id = s.prev_sql_id AND p.child_number = s.prev_child_number
WHERE  s.state = 'WAITING' AND s.event = 'enq: TX - row lock contention'
ORDER  BY s.sid;
```
Read: waiting_for_lock_with = the second statement (the one stuck), first_statement_of_txn = prev_sql_id = what the session ran before (the first lock), valid when nothing else ran in between. Lab result (user): sid 51 JOB_A blocked by 207 and sid 207 JOB_B blocked by 51; JOB_A "- 10 ... ACCT_ID = 1" then "+ 10 ... ACCT_ID = 2", JOB_B the opposite order.

### 6.3 Whole blocking tree (chains of blockers)
```sql
col tree for a40
SELECT LPAD(' ',2*(LEVEL-1))||'inst'||inst_id||' sid '||sid||' ser '||serial# tree, username, module, event,
       ROUND(wait_time_micro/1e6) wait_secs
FROM   gv$session
START  WITH blocking_session IS NULL
       AND (inst_id, sid) IN (SELECT blocking_instance, blocking_session FROM gv$session WHERE blocking_session IS NOT NULL)
CONNECT BY PRIOR sid = blocking_session AND PRIOR inst_id = blocking_instance;

```

### 6.4 What did the blocker run? (current and previous SQL)
```sql
SELECT s.inst_id, s.sid, 'CURRENT' which, s.sql_id, a.sql_text
FROM   gv$session s LEFT JOIN gv$sqlarea a ON a.inst_id = s.inst_id AND a.sql_id = s.sql_id
WHERE  s.inst_id = &b_inst AND s.sid = &b_sid
UNION ALL
SELECT s.inst_id, s.sid, 'PREVIOUS', s.prev_sql_id, a.sql_text
FROM   gv$session s LEFT JOIN gv$sqlarea a ON a.inst_id = s.inst_id AND a.sql_id = s.prev_sql_id
WHERE  s.inst_id = &b_inst AND s.sid = &b_sid;
```
Pattern to recognise: previous = `UPDATE/INSERT/DELETE`, current = something that does no database work (sleep, waiting on a network/file/user), no COMMIT anywhere = forgotten commit. `command_type 6` = UPDATE.

### 6.5 Which exact row is locked
```sql
COL locked_rowid FORMAT A20
SELECT w.inst_id, w.sid, w.serial# serial, o.owner, o.object_name,
       w.row_wait_file# fno, w.row_wait_block# blk, w.row_wait_row# rw,
       DBMS_ROWID.ROWID_CREATE(1, o.data_object_id, d.rfile#, w.row_wait_block#, w.row_wait_row#) locked_rowid
FROM   gv$session w
JOIN   dba_objects o ON o.object_id = w.row_wait_obj#
JOIN   v$datafile d  ON d.file# = w.row_wait_file#
WHERE  w.event LIKE 'enq: TX - row lock%' AND w.row_wait_obj# > 0;
-- then look at the row:   SELECT * FROM <owner>.<table> WHERE ROWID = '<locked_rowid>';
```
All victims on the same ROWID = one hot row. A plain SELECT is not blocked (readers never wait for writers), so you cannot see the lock from a query; use the lock views.

### 6.6 Lock detail: who holds, who waits
```sql
SELECT l.inst_id, l.sid, s.serial# serial, s.module, l.type, l.id1, l.id2, l.lmode, l.request, l.ctime secs
FROM   gv$lock l JOIN gv$session s ON s.inst_id = l.inst_id AND s.sid = l.sid
WHERE  l.type = 'TX'
AND    (l.id1, l.id2) IN (SELECT id1, id2 FROM gv$lock WHERE type = 'TX' AND lmode = 6 AND inst_id = &b_inst AND sid = &b_sid)
ORDER  BY l.lmode DESC, l.ctime DESC;
```
| Lock | Mode | Meaning |
|---|---|---|
| `TX` (transaction) | `LMODE 6`, `REQUEST 0` | session **holds** the exclusive transaction lock (the blocker) |
| `TX` | `LMODE 0`, `REQUEST 6` | session **waits** for that transaction to end |
| `TM` (table) | `LMODE 3` (row exclusive) | normal; many sessions can hold it on the same table at once |
| `TM` | `LMODE 0`, `REQUEST 3/4/5/6` | waiting on a table lock: DDL, or a **missing foreign-key index** (see 8.4) |

`ID1/ID2` identify the transaction: `usn = TRUNC(id1/65536)`, `slot = MOD(id1,65536)`, `ID2` = sequence. Same pair = same transaction. `ctime` = seconds held or waiting.

### 6.7 Who owns the blocker and what would a rollback cost?
```sql
COL machine FORMAT A22
COL program FORMAT A26
SELECT s.inst_id, s.sid, s.serial# serial, s.username, s.osuser, s.machine, s.program, s.module, s.action,
       TO_CHAR(s.logon_time,'MM-DD HH24:MI') logon, s.process client_pid,
       t.start_time txn_start, t.used_ublk undo_blocks, t.used_urec undo_records
FROM   gv$session s LEFT JOIN gv$transaction t ON t.inst_id = s.inst_id AND t.ses_addr = s.saddr
WHERE  s.inst_id = &b_inst AND s.sid = &b_sid;
```
- `machine`, `osuser`, `module`, `client_pid`: who to call, and where to find the process.
- `undo_blocks/undo_records`: rollback cost. A few records = instant. Millions = as long as the transaction ran (killing it does not make the lock go away faster).

### 6.8 History: who blocked whom in the past hour (or after the fact)  [DIAG]
```sql
SELECT TO_CHAR(MIN(sample_time),'HH24:MI:SS') first_seen, TO_CHAR(MAX(sample_time),'HH24:MI:SS') last_seen,
       blocking_inst_id b_inst, blocking_session b_sid, blocking_session_serial# b_serial, event, sql_id,
       COUNT(*) waiter_secs
FROM   gv$active_session_history
WHERE  sample_time > SYSTIMESTAMP - INTERVAL '&mins' MINUTE AND blocking_session IS NOT NULL
GROUP  BY blocking_inst_id, blocking_session, blocking_session_serial#, event, sql_id ORDER BY waiter_secs DESC;
```
For older incidents use `dba_hist_active_sess_history` (same blocking columns, 10-second samples). **Always match on `serial#` too**: SIDs are reused. In the lab, SID 205 appeared as a blocker in one incident and as a victim in the next, with different serial numbers.

---

## 7. Resolve  [ACTION: change approval, owner, rollback noted]

Order of preference for a blocker:
1. **Ask the owner** (from 6.7) to commit or roll back properly. Often one phone call.
2. `ALTER SYSTEM KILL SESSION 'sid,serial#,@inst_id' IMMEDIATE;` rolls back its transaction, releases the locks.
3. `ALTER SYSTEM DISCONNECT SESSION 'sid,serial#,@inst_id' IMMEDIATE;` also ends the server process (use when the client is gone).
4. OS `kill -9` of the server process only as a last resort, on the right node, after checking the PID with `gv$process`.

```sql
ALTER SYSTEM KILL SESSION '&sid,&serial,@&inst_id' IMMEDIATE;
```
Before you run it:
- The `serial#` protects you: if the SID was reused by someone else you get an error, not the wrong kill.
- On RAC run it from any node; `@inst_id` routes it.
- Check the rollback cost first (6.7). Rolling back a huge transaction can take as long as it ran and blocks nothing new, but it holds the lock until done.
- `ALTER SYSTEM CANCEL SQL` stops only the running statement. If the application then continues and exits normally it can **commit** the open transaction, which may be wrong.
- Sessions marked `KILLED` may stay visible until PMON finishes cleanup; `ORA-00031` means it is already marked, wait.

For other causes the fix is: statistics/index/rewrite (section 5), space or redo (8.5, 8.6), and for runaway SQL a kill as above or Resource Manager limits.

---

## 8. Other wait families, quick checks

### 8.1 User I/O (`db file sequential read`, `db file scattered read`, `direct path read`)
```sql
SELECT inst_id, event, total_waits, ROUND(time_waited_micro/NULLIF(total_waits,0)/1000,2) avg_ms
FROM   gv$system_event WHERE event IN ('db file sequential read','db file scattered read','direct path read','log file sync','log file parallel write')
ORDER  BY inst_id, event;
```
Healthy: single-block read under about 10 ms on spinning disk, about 1 ms on flash; `log file parallel write` a few ms. High latency = storage; high waits with normal latency = too much I/O from bad SQL (go to section 4). Which objects (ASH, [DIAG]):
```sql
SELECT o.owner, o.object_name, o.object_type, NVL(h.event,'ON CPU') event, COUNT(*) db_secs
FROM   gv$active_session_history h JOIN dba_objects o ON o.object_id = h.current_obj#
WHERE  h.sample_time > SYSTIMESTAMP - INTERVAL '&mins' MINUTE AND h.current_obj# > 0
GROUP  BY o.owner, o.object_name, o.object_type, h.event ORDER BY db_secs DESC FETCH FIRST 15 ROWS ONLY;
```
Operating system view of the same disks (run on each node; `-x` extended, `-m` MB/s):
```bash
iostat -xm 2 5
```
**The first report is the average since boot, ignore it.** Read the later ones: `r/s`, `rMB/s`, `r_await` (ms per read), `%util` for the database device, and `%iowait` in the CPU line.

**Worked case (I/O lab): many random reads from one SQL, solved by a covering index.**
1. Wait summary: User I/O about 80% (`db file parallel read`), short waits, no blocker.
2. ASH: one `sql_id` at 99.5% of DB time, 3.5 M executions at 3 ms each.
3. Per run: 83 gets, 49 physical reads for 1 result row (query 3.3: `gets_per_exec`, `phys_reads_per_exec`). High reads per run = look at the plan.
4. Plan: `INDEX RANGE SCAN` then `TABLE ACCESS BY INDEX ROWID BATCHED`, estimates correct. So the plan is right; the table step is the cost.
5. Cause: clustering factor 7.83 M vs 8 M rows (blocks: 151,584). Rows of one key are in different blocks (74 rows = 74 blocks). Table 1.2 GB vs buffer cache 416 MB, so reads miss the cache and the cache thrashes.
6. Fix options: covering index (do not visit the table), re-cluster the table (rebuild ordered by the key, partitioning), more cache. Covering index tested as `INVISIBLE ONLINE` with `ALTER SESSION SET optimizer_use_invisible_indexes = TRUE`, then `ALTER INDEX ... VISIBLE` (rollback: `INVISIBLE`).
7. Result: cost 81 to 3, 77 to 3 buffers, 2.76 ms to 0.02 ms, disk reads 49 to 0, disk `%util` 54% to about 0%.
A leftover from the fix: the older single-column index is now redundant; test it invisible over a business cycle before dropping.

### 8.2 Cluster waits (RAC: `gc cr ...`, `gc current ...`, `gc buffer busy ...`)
```sql
SELECT inst_id, event, total_waits, ROUND(time_waited_micro/NULLIF(total_waits,0)/1000,2) avg_ms
FROM   gv$system_event WHERE event LIKE 'gc%' AND total_waits > 0 ORDER BY time_waited_micro DESC FETCH FIRST 10 ROWS ONLY;
SELECT * FROM gv$cluster_interconnects;
```
Average block transfer above about 2 ms: check the interconnect (OS: NIC errors, `ethtool -S`, `oifcfg getif`), and hot blocks (8.1 object query). Typical fixes: service affinity (route one workload to one node), hash-partitioned or reverse-key indexes for hot inserts, larger sequence cache.

### 8.3 Concurrency / parse (`library cache`, `cursor: pin S wait on X`, `latch`, `mutex`)
Check hard parse rate (2.4), literal flood (section 5), versions per cursor:
```sql
SELECT sql_id, COUNT(*) children FROM gv$sql GROUP BY sql_id HAVING COUNT(*) > 20 ORDER BY children DESC FETCH FIRST 10 ROWS ONLY;
SELECT * FROM gv$sql_shared_cursor WHERE sql_id = '&sql_id' AND ROWNUM <= 5;   -- Y flags say why cursors were not shared
```
**Parse storm: hard parses from literals (worked case, parse lab, 26ai)**
Symptoms: CPU high, queries tiny and by primary key, plans fine, adding application servers does not raise throughput. Nearly all sessions in `latch: shared pool` (class Concurrency, waits near 0 s, no blocker), with `row cache mutex` and `library cache: bucket mutex X` behind it.
Checks, in order (all RAC-ready; the rates need two readings):
```sql
-- 1. hard parse share: hard parses should be a tiny fraction of executions
SET SERVEROUTPUT ON LINESIZE 200
DECLARE
  TYPE t IS TABLE OF NUMBER INDEX BY VARCHAR2(64);
  a t; b t; secs CONSTANT NUMBER := 10;
  PROCEDURE snap(x IN OUT t) IS BEGIN
    FOR r IN (SELECT name, SUM(value) v FROM gv$sysstat
              WHERE name IN ('parse count (total)','parse count (hard)','execute count','parse time cpu','session cursor cache hits') GROUP BY name) LOOP
      x(r.name) := r.v;
    END LOOP;
  END;
BEGIN
  snap(a); DBMS_SESSION.SLEEP(secs); snap(b);
  DBMS_OUTPUT.PUT_LINE('executions per second     : '||ROUND((b('execute count')-a('execute count'))/secs));
  DBMS_OUTPUT.PUT_LINE('parses per second (total) : '||ROUND((b('parse count (total)')-a('parse count (total)'))/secs));
  DBMS_OUTPUT.PUT_LINE('hard parses per second    : '||ROUND((b('parse count (hard)')-a('parse count (hard)'))/secs));
  DBMS_OUTPUT.PUT_LINE('parse CPU seconds per sec : '||ROUND((b('parse time cpu')-a('parse time cpu'))/100/secs,2));
  DBMS_OUTPUT.PUT_LINE('cursor cache hits per sec : '||ROUND((b('session cursor cache hits')-a('session cursor cache hits'))/secs));
END;
/
-- 2. many different sql_ids in a short window, each with one or two samples (ASH shows the PL/SQL caller while it parses; the real statements are in the long tail)
SELECT COUNT(DISTINCT sql_id) distinct_sql_ids, COUNT(*) samples FROM gv$active_session_history
WHERE  sample_time > SYSTIMESTAMP - INTERVAL '2' MINUTE AND module = '&module';
-- 3. same statement with different literals: one force_matching_signature with thousands of copies and about 1 execution each
SELECT force_matching_signature, COUNT(*) copies, SUM(executions) total_executions, MIN(sql_id) sample_sql_id
FROM   gv$sqlarea WHERE sql_text LIKE '&text_start%' GROUP BY force_matching_signature ORDER BY copies DESC FETCH FIRST 5 ROWS ONLY;
-- 4. time model (cumulative since startup: look at proportions, or take two readings)
SELECT stat_name, ROUND(value/1e6) secs FROM v$sys_time_model
WHERE  stat_name IN ('DB time','DB CPU','sql execute elapsed time','parse time elapsed','hard parse elapsed time') ORDER BY value DESC;
```
Numbers from the lab (12 sessions, tiny primary-key query): literals 5,000 to 5,800 executions/s with 5,000+ hard parses/s and about 2 CPU-seconds per second of parse CPU (the machine had 2 CPU threads, so about all of the CPU); `cursor_sharing=FORCE` about 167,000/s but still a soft parse per call, `library cache: mutex X` about 67 to 69%; real bind variables about 368,000 to 372,000/s, 0 parses, parse CPU 0 (about 64 times the literal case).
Fixes, in order: (1) the real fix, bind variables in the application (`:1` in PL/SQL `EXECUTE IMMEDIATE ... USING`, `?` / `:1` with prepared statements in JDBC, Python, etc.; it is also the SQL injection fix); (2) emergency stopgap that needs no code change, tested first and set so a restart undoes it: `ALTER SYSTEM SET cursor_sharing = FORCE SCOPE=MEMORY;` (rollback `... = EXACT SCOPE=MEMORY`). Risk of FORCE: one plan reused for all values (skewed columns can get slower) and a soft parse still happens on every call; (3) do not "fix" it by growing the shared pool or flushing it (`ALTER SYSTEM FLUSH SHARED_POOL` makes everything hard-parse again).
Related events: `cursor: pin S` at very high execution rates of one popular cursor is mutex traffic, not a parsing problem (reduce calls, cache results, batch). `cursor: pin S wait on X` = sessions wanting to run a cursor while another session holds it exclusively (parsing or invalidating it, for example right after statistics gathering or DDL on a hot table); it was not reproduced in the lab, check it on your RAC.

### 8.4 Unindexed foreign key (`enq: TM - contention` on older versions; see the worked case)
Find foreign keys whose first column is not the leading column of any index (approximate check):
```sql
SELECT c.owner, c.table_name, c.constraint_name FROM dba_constraints c
WHERE  c.constraint_type = 'R' AND c.owner = '&owner'
AND    NOT EXISTS (SELECT 1 FROM dba_cons_columns cc JOIN dba_ind_columns ic
                   ON ic.table_owner = cc.owner AND ic.table_name = cc.table_name
                   AND ic.column_name = cc.column_name AND ic.column_position = 1
                   WHERE cc.owner = c.owner AND cc.constraint_name = c.constraint_name AND cc.position = 1);

```
Which parent tables does a foreign key point at, and what happens on delete (`NO ACTION` = refuse if children exist):
```sql
SELECT c.table_name child_table, c.constraint_name, c.delete_rule, c.status, cc.column_name, cc.position
FROM   dba_constraints c JOIN dba_constraints p ON p.owner = c.r_owner AND p.constraint_name = c.r_constraint_name
JOIN   dba_cons_columns cc ON cc.owner = c.owner AND cc.constraint_name = c.constraint_name
WHERE  c.constraint_type = 'R' AND p.owner = '&owner' AND p.table_name = '&parent_table' ORDER BY 1, 2, 6;

```
The hidden statement Oracle runs for the check shows up in the shared pool (look for `count(1)` and a full scan on the child):
```sql
SELECT sql_id, plan_hash_value phv, executions execs, ROUND(elapsed_time/NULLIF(executions,0)/1e6,5) ela_per_exec_s,
       ROUND(buffer_gets/NULLIF(executions,0)) gets_per_exec, sql_text
FROM   gv$sqlstats WHERE UPPER(sql_text) LIKE '%&child_table%' AND UPPER(sql_text) NOT LIKE '%GV$%'
ORDER  BY buffer_gets DESC FETCH FIRST 5 ROWS ONLY;
```
**Worked case (FK lab, Oracle 26ai): slow nightly purge of parent rows**
1. Symptoms: no long lock chain, tiny waits that change second to second; the purge session alternates `enq: TX - row lock contention` and CPU; order-entry sessions mostly idle. Not a blocker problem: one snapshot cannot show it, use ASH over minutes.
2. ASH by module: the purge SQL was 83% of DB time, one session busy 100% of the time.
3. Cost per run (3.3): `DELETE ... WHERE po_id = :B1` took 0.35 s and **19,495 gets for 1 row**. A primary-key delete should need under 10.
4. Plan of the DELETE was perfect (`INDEX UNIQUE SCAN`, cost 1). A good plan with huge `gets_per_exec` means the extra work happens **outside the plan**: constraint checks, triggers, cascades, many indexes.
5. Foreign-key query: child `PO_ITEMS` references the parent, `NO ACTION`, no index on `PO_ITEMS(PO_ID)`.
6. The hidden recursive statement `select /*+ all_rows */ count(1) from "LAB"."PO_ITEMS" where "PO_ID" = :1` was in the shared pool with `TABLE ACCESS FULL`, cost 3301 growing to 5798 as the child table grew.
7. Cause: for every parent delete Oracle must prove no child rows exist; with no index it scans the whole child table. Cost = (parents deleted) x (child table size), so it drifts worse as data grows.
8. Fix: `ALTER SESSION SET ddl_lock_timeout = 60; CREATE INDEX lab.po_items_po_ix ON lab.po_items (po_id) ONLINE;`
9. Result: logical reads for one parent delete 28,553 to 11; purge 5 to 24,500 deletes per second; no more TX waits; FK check query returns no rows.
Things this case taught (do not assume the textbook):
- **On 26ai the wait event was not `enq: TM - contention`.** The signature was high `gets_per_exec` on a trivial DML plus a recursive `count(1)` full scan. Check what your version shows; the method (gets per exec, constraint list, recursive SQL) does not depend on the event name.
- **An invisible index does NOT give a safe test here**: the foreign-key check used the index as soon as it existed, even `INVISIBLE`. Test with a before/after measurement of one delete instead (`lab/05_fk_check_test.sql` pattern: delete one parent inside a transaction, read `session logical reads` from `v$mystat`, roll back).
- **DDL on a busy table fails with `ORA-00054`** unless you wait for a quiet moment: `ALTER SESSION SET ddl_lock_timeout = <seconds>;` before `CREATE INDEX` / `DROP INDEX` (and use `ONLINE`).
- **The cost of the fix**: one more index on the child table slows its inserts and uses space; measure insert time and redo with and without it on a copy.
- **A fix can expose the next bottleneck**: after the purge became fast it produced redo faster than the checkpoint could keep up, and sessions stalled on `log file switch (checkpoint incomplete)` (section 8.5). Look again after every fix.

### 8.5 Commit and redo (`log file sync`, `log file switch (...)`)
```sql
SELECT TO_CHAR(first_time,'MM-DD HH24') hour, thread#, COUNT(*) switches FROM gv$log_history
WHERE  first_time > SYSDATE-1 GROUP BY TO_CHAR(first_time,'MM-DD HH24'), thread# ORDER BY 1, 2;     -- above about 6 per hour per thread = logs too small
SELECT thread#, group#, ROUND(bytes/1048576) mb, status, archived FROM gv$log ORDER BY thread#, group#;
SELECT name, ROUND(space_limit/1073741824,1) limit_gb, ROUND(space_used/1073741824,1) used_gb FROM v$recovery_file_dest;
```
`log file sync` high: too many commits, slow redo storage, or a synchronous standby. `log file switch (archiving needed)` / `(checkpoint incomplete)`: archive destination or FRA full, logs too small.

**Commit rate and cost, over 10 seconds** (run from `CDB$ROOT`: LGWR events such as `log file parallel write` are not visible inside a PDB; the script prints a hint instead of failing):
```sql
SET SERVEROUTPUT ON LINESIZE 200
DECLARE
  TYPE t IS TABLE OF NUMBER INDEX BY VARCHAR2(64);
  a t; b t;
  PROCEDURE snap(x IN OUT t) IS
  BEGIN
    FOR r IN (SELECT name, SUM(value) v FROM gv$sysstat WHERE name IN ('user commits','redo size') GROUP BY name) LOOP x(r.name) := r.v; END LOOP;
    FOR r IN (SELECT event, SUM(total_waits) w, SUM(time_waited_micro) u FROM gv$system_event
              WHERE event IN ('log file sync','log file parallel write') GROUP BY event) LOOP
      x(r.event||' waits') := r.w; x(r.event||' us') := r.u;
    END LOOP;
  END;
  FUNCTION g(x t, k VARCHAR2) RETURN NUMBER IS BEGIN RETURN CASE WHEN x.EXISTS(k) THEN x(k) ELSE 0 END; END;
BEGIN
  DBMS_OUTPUT.PUT_LINE('container: '||SYS_CONTEXT('USERENV','CON_NAME'));
  snap(a); DBMS_SESSION.SLEEP(10); snap(b);
  DBMS_OUTPUT.PUT_LINE('commits per second              : '||ROUND((g(b,'user commits')-g(a,'user commits'))/10));
  DBMS_OUTPUT.PUT_LINE('redo generated MB per second     : '||ROUND((g(b,'redo size')-g(a,'redo size'))/10/1048576,2));
  DBMS_OUTPUT.PUT_LINE('redo bytes per commit            : '||ROUND((g(b,'redo size')-g(a,'redo size'))/NULLIF(g(b,'user commits')-g(a,'user commits'),0)));
  DBMS_OUTPUT.PUT_LINE('log file sync avg ms             : '||ROUND((g(b,'log file sync us')-g(a,'log file sync us'))/NULLIF(g(b,'log file sync waits')-g(a,'log file sync waits'),0)/1000,3));
  DBMS_OUTPUT.PUT_LINE('log file parallel write avg ms   : '||NVL(TO_CHAR(ROUND((g(b,'log file parallel write us')-g(a,'log file parallel write us'))/NULLIF(g(b,'log file parallel write waits')-g(a,'log file parallel write waits'),0)/1000,3)),'(connect to CDB$ROOT)'));
  DBMS_OUTPUT.PUT_LINE('log writes per second            : '||ROUND((g(b,'log file parallel write waits')-g(a,'log file parallel write waits'))/10));
  DBMS_OUTPUT.PUT_LINE('commits per log write            : '||NVL(TO_CHAR(ROUND((g(b,'user commits')-g(a,'user commits'))/NULLIF(g(b,'log file parallel write waits')-g(a,'log file parallel write waits'),0),1)),'(connect to CDB$ROOT)'));
END;
/
```
How to read it: `log file sync` (what the session waits) vs `log file parallel write` (the actual disk write). Disk fast but sync high and commits per second huge = **too many commits** (application), not slow storage. Total commit wait per second = commits per second x sync ms / 1000; divide by the number of sessions to get the share of their time.

**Redo log sizing** (high-risk change, online): target one switch every 15 to 30 minutes at peak (`size = peak redo MB/s x 900..1800 s`, take the real rate from AWR). Per RAC thread; ASM names instead of paths.
```sql
ALTER DATABASE ADD LOGFILE THREAD 1 GROUP 3 ('/path/redo03.log') SIZE 1G;      -- add the new groups first
ALTER SYSTEM SWITCH LOGFILE;  ALTER SYSTEM CHECKPOINT;                         -- once, not repeatedly
SELECT group#, status FROM v$log;                                              -- only INACTIVE groups can be dropped
ALTER DATABASE DROP LOGFILE GROUP 1;                                           -- without Oracle-managed files remove the old file at OS level afterwards
```
Rollback: add or drop groups the same way; no data is touched. Watch after the change: the switch rate (queries above) and `iostat` (see below).

**Worked case (commit lab, 26ai): nightly import with a commit after every row**
1. Wait summary: 6 of 8 sessions in class `Commit`, `log file sync`, each wait under 0.05 ms, no blocker, no I/O reads.
2. Rates: 23,000 commits/s, 748 bytes of redo per commit, `log file sync` 0.26 ms vs `log file parallel write` 0.135 ms, about 4 commits per log write. 23,000 x 0.26 ms = 6 s of waiting per second over 8 sessions = 75% of their time. Verdict: **too many commits, storage fine**.
3. Second layer in the same data: 16.5 MB/s of redo into two 20 MB logs = a switch every 1.2 s (55 per minute), with `log file switch (checkpoint incomplete)` averaging 52 ms per wait (about 200 times a commit).
4. Fixes: DBA resized redo to 3 groups of 1 GB (switches 55 per minute to about 1); application commits every 500 rows instead of every row (17,000 to 312,000 rows/s, 18x faster; `log file sync` 90% to 5.6%).
5. Next bottleneck: `free buffer waits` 53% (DBWR cannot flush dirty blocks as fast as the load dirties them). For bulk loads use array inserts (`FORALL`/JDBC batching) or direct path (`INSERT /*+ APPEND */`, SQL*Loader direct) and stop tuning when the load window is met.
Things this case taught:
- Per-commit cost can be tiny while the **count** is the problem. Do the multiplication (rate x time per event).
- A COMMIT inside a PL/SQL loop is optimised and does not wait for each log write; a real client with autocommit does. Test harnesses must use `COMMIT WRITE IMMEDIATE WAIT` to behave like a driver.
- Resizing redo can have side effects in a lab with buffered I/O: with 3 GB of redo files in a small VM, `iostat` showed about 3,500 reads/s of 4 KB (read-modify-write in the OS page cache) and `log file parallel write` rose from 0.135 to 0.20 ms. Direct I/O or ASM avoids this. Measure after every change.
- Batching trade-off: a crash loses the open batch (rolled back, consistent), so make the job restartable (progress table, `MERGE`, or reload the failed batch). `COMMIT WRITE BATCH NOWAIT` can lose a commit the application was told succeeded; only use it for reloadable data and with the owner's agreement.

### 8.6 Temp, PGA, undo
```sql
SELECT s.inst_id, s.sid, s.serial# serial, s.username, u.sql_id, u.tablespace, ROUND(u.blocks*ts.block_size/1048576) temp_mb
FROM   gv$tempseg_usage u JOIN gv$session s ON s.saddr = u.session_addr AND s.inst_id = u.inst_id
JOIN   dba_tablespaces ts ON ts.tablespace_name = u.tablespace ORDER BY temp_mb DESC FETCH FIRST 10 ROWS ONLY;
SELECT inst_id, TO_CHAR(begin_time,'HH24:MI') bt, undoblks, txncount, maxquerylen, ssolderrcnt, nospaceerrcnt
FROM   gv$undostat ORDER BY begin_time DESC FETCH FIRST 12 ROWS ONLY;   -- ssolderrcnt > 0 = ORA-01555; nospaceerrcnt > 0 = undo full
```

### 8.7 Limits and connection storms
The first query (limits for processes and sessions are instance-wide) returns NO ROWS inside a PDB: run it from `CDB$ROOT` (tested in the lab).
```sql
SELECT inst_id, resource_name, current_utilization cur, max_utilization max, limit_value FROM gv$resource_limit
WHERE  resource_name IN ('processes','sessions','transactions') ORDER BY resource_name, inst_id;
SELECT inst_id, machine, program, COUNT(*) sessions FROM gv$session WHERE type = 'USER'
GROUP  BY inst_id, machine, program ORDER BY sessions DESC FETCH FIRST 10 ROWS ONLY;
```

### 8.8 Check the cluster itself (OS, as grid/oracle)
```bash
crsctl check cluster -all
srvctl status database -d <db_unique_name>
srvctl status service -d <db_unique_name>
```
Also alert logs per node: `$ORACLE_BASE/diag/rdbms/<db>/<instance>/trace/alert_<instance>.log`, and recent errors from SQL (there is no `gv$` version of this view, so run it on each RAC node; the log is also read per instance):
```sql
SELECT originating_timestamp, SUBSTR(message_text,1,160) message_text FROM v$diag_alert_ext
WHERE  originating_timestamp > SYSTIMESTAMP - INTERVAL '2' HOUR AND message_text LIKE '%ORA-%' ORDER BY originating_timestamp;
```

### 8.9 Hot spots: sequences and hot index/table blocks (`row cache lock`, `buffer busy waits`, `enq: TX - index contention`; RAC: `gc buffer busy`, `gc current/cr block ...`)
Symptom: "slower the more users", sessions in class Concurrency (or Cluster on RAC), tiny waits, no blocker, many sessions inserting into the same table/index.
Run in this order (all RAC-ready):
```sql
-- 1. Which row-cache entry? (P1 of row cache waits is the cache id)
SELECT h.inst_id, h.event, h.p1 cache_id, NVL(rc.parameter,'(unknown)') cache_name, COUNT(*) samples
FROM   gv$active_session_history h LEFT JOIN (SELECT DISTINCT cache#, parameter FROM gv$rowcache) rc ON rc.cache# = h.p1
WHERE  h.sample_time > SYSTIMESTAMP - INTERVAL '2' MINUTE AND h.event IN ('row cache lock','row cache mutex')
GROUP  BY h.inst_id, h.event, h.p1, rc.parameter ORDER BY samples DESC;          -- dc_sequences = a sequence

-- 2. Sequence settings: cache_size 0 (NOCACHE) or order_flag Y on a busy sequence is the first suspect
SELECT sequence_owner, sequence_name, increment_by, cache_size, order_flag, last_number FROM dba_sequences WHERE sequence_owner = '&owner';

-- 3. Which OBJECT is hot (index or table)? (current_obj# of the waiting samples, per instance)
SELECT h.inst_id, NVL(o.object_name,'(none)') object_name, o.object_type, NVL(h.event,'ON CPU') event, COUNT(*) samples
FROM   gv$active_session_history h LEFT JOIN dba_objects o ON o.object_id = h.current_obj#
WHERE  h.sample_time > SYSTIMESTAMP - INTERVAL '2' MINUTE
AND   (h.event IN ('buffer busy waits','enq: TX - index contention') OR h.event LIKE 'gc%busy%')
GROUP  BY h.inst_id, o.object_name, o.object_type, h.event ORDER BY samples DESC FETCH FIRST 10 ROWS ONLY;

-- 4. Which BLOCKS? (for buffer busy waits P1 = file#, P2 = block#). Many neighbouring blocks of the same index = hot right-hand edge moving along
SELECT h.inst_id, h.p1 file#, h.p2 block#, COUNT(*) samples, MAX(e.segment_name) segment_name, MAX(e.segment_type) segment_type
FROM   gv$active_session_history h LEFT JOIN dba_extents e ON e.file_id = h.p1 AND h.p2 BETWEEN e.block_id AND e.block_id + e.blocks - 1
WHERE  h.sample_time > SYSTIMESTAMP - INTERVAL '2' MINUTE AND h.event = 'buffer busy waits'
GROUP  BY h.inst_id, h.p1, h.p2 ORDER BY samples DESC FETCH FIRST 10 ROWS ONLY;     -- dba_extents can be slow on a huge database

-- 5. Cumulative per-segment counters (since startup; compare two readings). RAC adds gc statistics
SELECT inst_id, owner, object_name, object_type, statistic_name, value FROM gv$segment_statistics
WHERE  owner = '&owner' AND statistic_name IN ('buffer busy waits','ITL waits','row lock waits','gc buffer busy','gc cr blocks received','gc current blocks received')
AND    value > 0 ORDER BY value DESC FETCH FIRST 15 ROWS ONLY;
```
RAC extra checks (average cost of moving a block between nodes, and which node hits the block):
```sql
SELECT inst_id, event, total_waits, ROUND(time_waited_micro/NULLIF(total_waits,0)/1000,2) avg_ms
FROM   gv$system_event WHERE event LIKE 'gc%' AND total_waits > 0 ORDER BY time_waited_micro DESC FETCH FIRST 10 ROWS ONLY;   -- above about 1 to 2 ms: look at hot blocks and the interconnect
SELECT inst_id, name, ip_address FROM gv$cluster_interconnects;
SELECT inst_id, COUNT(*) samples FROM gv$active_session_history
WHERE  sample_time > SYSTIMESTAMP - INTERVAL '2' MINUTE AND event LIKE 'gc%' GROUP BY inst_id ORDER BY samples DESC;   -- one node doing most of the waiting?
```
Layers and fixes (apply one, look again):
| Layer | Evidence | Fix | Cost |
|---|---|---|---|
| Sequence NOCACHE or ORDER | `row cache lock`/`row cache mutex` on `dc_sequences`; on RAC also `enq: SQ - contention`, `DFS lock handle` | `ALTER SEQUENCE s CACHE 1000 NOORDER` (size >= NEXTVAL calls per second per instance) | gaps after a crash or aged-out cache; no strict order across RAC nodes |
| Hot right-hand index leaf (keys always increasing: sequence, timestamp) | `buffer busy waits` and `enq: TX - index contention` on one index; neighbouring blocks in query 4; RAC: `gc buffer busy acquire/release`, `gc current block 2-way/3-way` | reverse key index, hash-partitioned index, scalable sequence (`SCALE EXTEND`), or route the workload to one node with a service | reverse key: no range scans, whole index becomes the working set (needs cache); scalable sequence: longer ids, no time order |
| Hot table block (small table updated by everyone) | `buffer busy waits` or `gc buffer busy` on a TABLE, rows/block high | more `PCTFREE`/fewer rows per block, hash-partition, redesign counters | space |
Reverse key: `CREATE INDEX i ON t (c) REVERSE;`  or  `ALTER INDEX i REBUILD REVERSE ONLINE;`  (undo with `REBUILD NOREVERSE ONLINE`). Check: `SELECT index_name, index_type FROM dba_indexes` shows `NORMAL/REV`.
`ALTER INDEX ... REBUILD ONLINE` needs quiet moments on a busy table: set `ALTER SESSION SET ddl_lock_timeout = <secs>` first. If it is interrupted you may get `ORA-08104`: look for a leftover `SYS_JOURNAL_<object_id>` table and run `DBMS_REPAIR.ONLINE_INDEX_CLEAN(object_id => <id>, wait_for_lock => DBMS_REPAIR.LOCK_NOWAIT)` (I ran it on the lab; do the same on a test system first).
Lab numbers (single instance, 12 sessions, equal empty tables, 50 s each): NOCACHE ORDER + normal index 8,385 rows/s; CACHE 1000 NOORDER + normal index 66,173; CACHE 1000 + reverse key index 81,801 (`buffer busy waits` 31% to under 3%). The same reverse key setup fell to about 21,000 rows/s once the table reached 98 million rows (3.5 GB table + 1.7 GB index vs a 608 MB cache): `free buffer waits` and index reads dominated. Always compare fixes on equal data and check the working set against the cache. Range query `order_id BETWEEN ...` changed from an index plan (cost 3 for equality) to a full table scan (cost 6,068).
**Reverse key versus global hash-partitioned index** (same workload, 12 sessions, 200 s, empty tables; script `lab/07_hashpart_test.sh`; hash-partitioned = 16 partitions; Partitioning is a separately licensed option on Enterprise Edition and not available in Standard Edition):
| | Reverse key | Hash-partitioned (two runs) |
|---|---|---|
| Rows/s at about 30 s | 95,122 | 99,140 and 94,973 |
| Rows/s at about 175 s (table 0.5 to 0.6 GB, index 0.3 GB) | **53,648** (down 44%) | **87,495 and 74,288** (down 12% and 22%) |
| Top events at the end | `free buffer waits` 32%, `log file sync` 31%, `library cache: mutex X` 15%, `buffer busy waits` 5% | `log file sync` 39 to 50%, `library cache: mutex X` 27 to 36%, `buffer busy waits` 2.5%, **no** `free buffer waits` |
| Plan for `order_id BETWEEN 12345 AND 12445` | `TABLE ACCESS FULL`, cost **18,283** | `PARTITION HASH ALL` + `INDEX RANGE SCAN`, cost **1** |
Reading: at the start they are equal; as the index grows the reverse key index loses speed (it scatters writes over the whole index, DBWR falls behind, `free buffer waits` appears), while the hash-partitioned index keeps its speed and keeps range queries on the index (it only has to look in all 16 partitions). Repeated runs vary by about 10 to 15%, so look at the pattern, not at single numbers.
Prefer hash partitioning when the Partitioning option is licensed and you need range queries or a growing index; prefer reverse key when the option is not licensed, lookups are by equality only, and the index will stay small enough for the cache.
How to move a primary key to a hash-partitioned index (global, 16 partitions). Recommended method, no gap in uniqueness enforcement (each step run in the lab; not tested end to end on a table under heavy write load):
```sql
-- 0. pre-checks: Partitioning installed and licensed (v$option), space for a second index, range queries on the key,
--    foreign keys that reference this key, partition count (power of 2; 16 used in the lab)
ALTER SESSION SET ddl_lock_timeout = 60;                                       -- 1. let DDL wait for a gap in transactions
CREATE UNIQUE INDEX t_hp ON t (id) GLOBAL PARTITION BY HASH (id) PARTITIONS 16 INVISIBLE ONLINE;   -- 2. build, no effect yet
ALTER TABLE t MODIFY PRIMARY KEY USING INDEX t_hp;                             -- 3. constraint moves to the new index, never dropped
ALTER INDEX t_old INVISIBLE;                                                   -- 4. swap visibility in THIS order
ALTER INDEX t_hp  VISIBLE;                                                     --    (only one visible index per column set: ORA-14147 otherwise)
-- 5. verify: dba_indexes (partitioned=YES, visible), plan shows PARTITION HASH SINGLE + INDEX UNIQUE SCAN; measure rows/s and waits
DROP INDEX t_old;                                                              -- 6. later, after a business cycle (it is also your rollback)
-- rollback while t_old exists: ALTER INDEX t_hp INVISIBLE; ALTER INDEX t_old VISIBLE; ALTER TABLE t MODIFY PRIMARY KEY USING INDEX t_old;
```
The older method (drop and re-create the primary key) leaves a gap with no uniqueness check and no index, and fails with `ORA-02273` when other tables have foreign keys to the key (from Oracle behaviour, not hit in the lab): use it only in a maintenance window.
```sql
ALTER TABLE t DROP PRIMARY KEY DROP INDEX;
CREATE UNIQUE INDEX t_pk ON t (id) GLOBAL PARTITION BY HASH (id) PARTITIONS 16;
ALTER TABLE t ADD CONSTRAINT t_pk PRIMARY KEY (id) USING INDEX t_pk;
```
(The lab is single instance, so no real `gc` waits were seen; the RAC rows above come from Oracle's behaviour, not from a cluster I ran. Verify on your RAC.)

---

## 9. Validate (use a different query from the one that found it)

```sql
-- nothing blocked, nothing waiting on locks
SELECT inst_id, sid, serial# serial, username, event, blocking_session FROM gv$session WHERE blocking_session IS NOT NULL;
SELECT inst_id, sid, type, id1, id2, lmode, request, ctime FROM gv$lock WHERE type = 'TX' AND request > 0;
-- the work completed: check the business data (for example the update the users made went through)
-- wait profile quiet and throughput recovered: run 2.1 and 3.1 again, compare with the "before" numbers
-- SQL fixed: compare gets_per_exec and elapsed per exec (3.3) and the plan hash value
-- no new errors: the alert log query in 8.8
```
For a SQL fix, also check nothing else changed plan after you touched stats/indexes ([DIAG]):
```sql
SELECT sql_id, COUNT(DISTINCT plan_hash_value) plans FROM dba_hist_sqlstat
WHERE  snap_id IN (SELECT snap_id FROM dba_hist_snapshot WHERE begin_interval_time > SYSDATE-1)
GROUP  BY sql_id HAVING COUNT(DISTINCT plan_hash_value) > 1 ORDER BY plans DESC FETCH FIRST 20 ROWS ONLY;
```
Watch for one business cycle (or 1 to 2 hours) before closing the ticket.

---

## 10. Prevention

**Locks**
- Batches and apps must `COMMIT`/`ROLLBACK` before they sleep, wait for a user, a file or a network call. Never hold a transaction open while waiting.
- Keep transactions short; commit per logical unit of work.
- Fail fast instead of hanging: `SELECT ... FOR UPDATE NOWAIT`, `WAIT n`, or `SKIP LOCKED` for queue work.
- Resource Manager `MAX_IDLE_BLOCKER_TIME` and profile `IDLE_TIME` kill **idle** blockers. They would not catch an `ACTIVE` session that is busy or sleeping inside a call.
- 23ai and later: check "Priority Transactions" in your version's documentation (auto-rollback of lower-priority blockers). Verify availability before relying on it.

**SQL and statistics**
- No function on an indexed column in `WHERE` (use range predicates or a function-based index).
- Do not lock statistics on growing tables without a reason and a review date. Find them:
  `SELECT owner, table_name FROM dba_tab_statistics WHERE stattype_locked IS NOT NULL AND partition_name IS NULL AND owner NOT IN (SELECT username FROM dba_users WHERE oracle_maintained='Y');`
- Baseline good plans for critical SQL (SQL Plan Management) before patches and releases.
- Bind variables, bulk operations, pagination for big results.
- Load-test reports with realistic concurrency: a 0.8 s query called 10 times a second is a CPU problem.

**Monitoring**
- Alert: blocked session longer than 60 s, Average Active Sessions above 80% of CPU count for 10 minutes, tablespace 85/95%, FRA 80%, log switches above 6 per hour, processes above 85% of limit, `gc` latency above 2 ms.
- Keep AWR for 30 days (`DBMS_WORKLOAD_REPOSITORY.MODIFY_SNAPSHOT_SETTINGS(retention=>43200, interval=>30)`, check SYSAUX space) and save a baseline of a normal busy period.
- Schedule a daily health check and keep the output (`DB_Health_Check.sql`).

---

## 11. Ticket notes template

```
Reported:        who / app / time / symptom (exact words)
Scope:           all users or one? one instance or all? since when? what changed?
Evidence:        wait class + top event + counts (2.1), culprit sql_id or root blocker (inst,sid,serial#)
Root cause:      one sentence, with the proof query
Action taken:    command, who approved, rollback cost, time
Validation:      queries re-run, before/after numbers
Prevention:      owner + due date
```

## 12. Pitfalls we hit in the labs

- `EVENT` is stale unless `STATE = 'WAITING'`.
- `SID` alone is ambiguous on RAC and reused over time: use `inst_id`, `sid` and `serial#`.
- A rewrite that helps CPU may not change the plan: compare `plan_hash_value`, not only the timing.
- The obvious fix (fresh statistics) may change almost nothing. Measure after each step.
- `v$sysmetric` may be empty inside a PDB, and `gv$` shows only the connected container.
- `ALTER SYSTEM CANCEL SQL` on a sleeping/waiting session can let the application commit on exit.
- A killed session shows `KILLED` until PMON cleans it up: `ORA-00031` on a second kill means wait.
- `iostat`: the first report is the average since boot. Use the second and later ones.
- A fast query (3 ms) can still be the top consumer if it runs millions of times: judge by total DB time and per-run reads, not only elapsed time.
- Estimates correct and plan sensible but many buffers for few rows = data layout problem (clustering factor near the row count), not a statistics problem.
- After a fix, "all sessions are busy" can just mean a test loop with no pause. Judge by cost per run and throughput.
- A plan can look perfect while `gets_per_exec` is huge: the work is outside the plan (foreign-key checks, triggers, cascades). Look at constraints and at the shared pool for recursive SQL.
- `last_call_et` is time inside the current top-level call; for a session running one long PL/SQL block it says nothing about the current statement.
- DDL on a busy table: use `ddl_lock_timeout`, otherwise `ORA-00054`.
- In ASH, a statement that is being parsed is recorded under its PL/SQL caller's `sql_id`; in a parse storm the real statements are in the long tail of one-sample `sql_id`s.
- `cursor_sharing = FORCE` is a stopgap: soft parse on every call, possible plan changes. Always `SCOPE=MEMORY` first and keep the rollback ready.
- LGWR-level numbers (`log file parallel write`, log switches) are visible only from `CDB$ROOT`, not inside a PDB.
- A COMMIT inside a PL/SQL loop is optimised (no wait per commit). Test harnesses must use `COMMIT WRITE IMMEDIATE WAIT` to behave like an application driver.
- `COMMIT WRITE BATCH NOWAIT` removes the log wait but can lose a commit the application believed succeeded.
- After resizing redo logs, check `iostat` and `log file parallel write` again; buffered I/O can add read-modify-write reads.
- Manual `ALTER SYSTEM SWITCH LOGFILE` wastes the rest of the current log; use it once when dropping groups, not repeatedly.
- Pick a representative row range when sampling the table: a query that selects only an indexed column can be answered from the index and shows a sorted order the table doesn't have.

---

## 13. Wait event cheat sheet (find the event, read the entry)

How to use: find the event you see in `gv$session` / ASH, read **Explanation** (what it means), **Why** (what usually causes it), **Confirm with** (the query that proves it, section number in this file) and **Fix and Prevent**. "Lab" shows where we saw it and the numbers measured. Events marked *(not tested in the lab)* come from Oracle's behaviour, check them on your RAC.

### 13.1 Quick lookup

| Wait event | Class | One-line meaning | Usual cause | Section |
|---|---|---|---|---|
| `ON CPU` (not a wait) | CPU | session is running, not waiting | bad plan, parse storm, too many calls | 5 |
| `enq: TX - row lock contention` (mode 6) | Application | waiting for a row locked by another transaction | uncommitted/forgotten transaction | 6 |
| `enq: TX - row lock contention` (mode 4) | Application | waiting for another transaction for an integrity reason | unindexed foreign key, unique key, ITL | 8.4 |
| `blocking txn id for DDL` | Application | DDL/lock waits for open transactions on the table | DDL on a busy table | 8.4 |
| `enq: TM - contention` | Application | table-level lock conflict | `LOCK TABLE`, DDL, unindexed FK on older versions | 8.4 |
| `db file sequential read` | User I/O | single-block disk read | index lookups, scattered rows, small cache | 8.1 |
| `db file parallel read` | User I/O | batched random block reads | index range scan + table access by rowid | 8.1 |
| `db file scattered read` / `direct path read` | User I/O | multiblock / direct reads | full scans | 8.1 |
| `log file sync` | Commit | session waits for its commit to be written | too many commits | 8.5 |
| `log file parallel write` | System I/O | LGWR writing redo | slow redo storage | 8.5 |
| `log file switch (checkpoint incomplete)` / `log file switch completion` | Configuration | cannot reuse the next redo log yet | redo logs too small | 8.5 |
| `free buffer waits` / `write complete waits` | Configuration | no clean memory slot, waiting for DBWR | writes dirty blocks faster than DBWR flushes | 13.2 |
| `buffer busy waits` | Concurrency | waiting for a block another session is using | hot block, hot right-hand index leaf | 8.9 |
| `enq: TX - index contention` | Concurrency | waiting while an index leaf is split | hot right-hand index leaf | 8.9 |
| `latch: cache buffers chains` | Concurrency | many sessions on the same buffer | hot block, heavy logical reads | 8.9 |
| `row cache lock` / `row cache mutex` | Concurrency | waiting for a dictionary cache entry | NOCACHE/ORDER sequence (`dc_sequences`) | 8.9 |
| `latch: shared pool` | Concurrency | allocating/freeing shared pool memory | hard parses from literal SQL | 8.3 |
| `library cache: mutex X` | Concurrency | contention on library cache structures | soft/hard parse storm, very hot sequence/object | 8.3 |
| `cursor: pin S` | Concurrency | many sessions executing the same cursor | one statement executed at extreme rate | 8.3 |
| `cursor: pin S wait on X` | Concurrency | waiting for a cursor being changed | parse/invalidation of a popular cursor | 8.3 |
| `gc buffer busy acquire/release`, `gc current/cr block 2-way/3-way` | Cluster | RAC block shipping between nodes | hot blocks, slow interconnect | 8.2 |
| `enq: SQ - contention`, `DFS lock handle` | Configuration/Cluster | sequence coordination across nodes | ORDER or small cache on RAC | 8.9 |
| `SQL*Net message from client`, `PL/SQL lock timer` | Idle | waiting for the client / sleeping | not a database problem | 2.2 |
| `resmgr:cpu quantum` | Scheduler | Resource Manager is throttling CPU | CPU limit in the resource plan | 5 |

### 13.2 Details, grouped by family

#### A. Locks and transactions

```
Wait event      : enq: TX - row lock contention  (mode 6, decode P1: section 4.2)
Class           : Application
Explanation     : A session wants to change a row that another transaction has changed and not yet committed or rolled back.
                  It waits for that transaction to end. Readers are never blocked, only writers.
Why             : Forgotten commit (a batch or user session that updated a row and then went idle/slept), long transactions,
                  two applications updating the same hot row.
Confirm with    : Root blocker with victims (6.2), blocking tree (6.3), what it ran (6.4), locked row (6.5), lock detail gv$lock (6.6),
                  owner and undo size (6.7).
Fix and Prevent :
  1. Ask the owner (machine, module, client_pid) to commit or roll back.
  2. If not possible and approved: ALTER SYSTEM KILL SESSION 'sid,serial#,@inst' IMMEDIATE (check undo size first, section 7).
  3. Prevent: commit before any wait/sleep, keep transactions short, SELECT ... FOR UPDATE NOWAIT / WAIT n / SKIP LOCKED,
     alert on sessions blocked more than 60 s.
Lab             : Row lock lab (1 blocker, 4 victims waiting ~19 minutes, 1 undo record).
```

```
Wait event      : enq: TX - row lock contention  (mode 4)   and   blocking txn id for DDL
Class           : Application
Explanation     : A session waits for another transaction to finish for an integrity reason, not for a plain row lock:
                  a foreign-key check, a unique key check, or no free ITL slot. "blocking txn id for DDL" is the same idea for
                  DDL or a table lock request that must wait until every open transaction on the table ends.
Why             : Unindexed foreign key: every parent delete makes Oracle scan the whole child table to prove no children exist
                  (a hidden "select count(1) from child where fk = :1" with TABLE ACCESS FULL). Cost grows with child size.
Confirm with    : A trivial DML with huge gets_per_exec (3.3), good plan (4), foreign keys without an index (8.4), hidden recursive
                  statement in gv$sqlstats (8.4), ASH current_obj# showing the CHILD table (13.3 tip).
Fix and Prevent :
  1. CREATE INDEX on the child foreign-key column:  ALTER SESSION SET ddl_lock_timeout = 60; CREATE INDEX ... ONLINE;
  2. An invisible index is NOT a safe test here: the FK check uses the index as soon as it exists. Measure one delete before/after.
  3. Prevent: index every foreign key on large child tables, run the 8.4 check after each release.
Lab             : FK lab: 28,553 logical reads per parent delete -> 11; purge 5 -> 24,500 deletes/s.
```

```
Wait event      : enq: TM - contention
Class           : Application
Explanation     : A session needs a table-level lock that conflicts with a lock another session already holds on the table.
Why             : LOCK TABLE, DDL (ALTER TABLE, CREATE INDEX without ONLINE, TRUNCATE) on a table with open transactions;
                  on older versions an unindexed foreign key under parent DML.
Confirm with    : gv$lock WHERE type = 'TM' with request > 0 (6.6). Note: on 26ai the FK lab did NOT show this event (see above).
Fix and Prevent :
  1. Find the holder (gv$lock TM with lmode > 0, then gv$session) and have it commit/rollback.
  2. Run DDL in a quiet window, use ONLINE operations and ddl_lock_timeout, index foreign keys.
Lab             : Textbook pattern tested; the event did not appear on 26ai. Test your own version.
```

#### B. Disk reads and writes

```
Wait event      : db file sequential read   (and db file parallel read)
Class           : User I/O
Explanation     : One block at a time (sequential read) or a batch of scattered blocks at once (parallel read) is read from
                  outside Oracle's buffer cache. Typical for index lookups followed by table access by rowid.
Why             : Rows of one key are scattered over many table blocks (clustering factor close to the number of rows), table
                  larger than the cache, so each lookup costs about one block read per row.
Confirm with    : Top SQL by DB time (3.1), gets_per_exec and phys_reads_per_exec (3.3), plan and clustering factor (4.1),
                  Oracle avg_ms (8.1) compared with iostat r_await. If Oracle sees reads but iostat sees none, the OS cache served them
                  (buffered I/O, 8.1).
Fix and Prevent :
  1. Covering index (the query never visits the table), tested as INVISIBLE first.
  2. Re-cluster the table by the key (rebuild ordered, partitioning) or add memory (masks, does not fix).
  3. Prevent: watch physical reads per execution for top SQL; check clustering_factor on indexes of large tables.
Lab             : I/O lab: 49 physical reads per run -> 0; 2.76 ms -> 0.02 ms; iostat util 54% -> ~0%.
```

```
Wait event      : db file scattered read   and   direct path read
Class           : User I/O
Explanation     : Multiblock reads: Oracle is scanning a whole table (or index) instead of fetching a few blocks.
Why             : Full table scan on a big table because there is no usable index, a function on the column, or stale statistics.
Confirm with    : Plan shows TABLE ACCESS FULL on a large segment with a selective filter (4); SQL Analysis Report; E-Rows vs A-Rows.
Fix and Prevent :
  1. Index or rewrite the predicate (no function on the column); refresh statistics (unlock them if locked).
  2. Partition pruning for very large tables. Prevent: code review rule "no function on an indexed column".
Lab             : Slow SQL lab (stale locked statistics + TRUNC on an indexed column): 9.2 -> 770 runs/s with a covering index.
```

```
Wait event      : free buffer waits   (and write complete waits)
Class           : Configuration
Explanation     : A session needs a clean slot in the buffer cache to read or change a block, but all candidate slots are dirty
                  (changed, not yet written). It waits for the database writer (DBWR) to write some out.
Why             : Blocks are being dirtied faster than DBWR can write them: huge write rate, scattered dirty blocks (for example a
                  reverse key index on a very large table), small buffer cache, slow storage, a single DBWR process.
Confirm with    : ASH events and current_obj# (13.3), segment sizes against buffer cache size, iostat write rate, gv$sysstat
                  'dirty buffers inspected' / 'free buffer inspected'.
Fix and Prevent :
  1. Reduce the dirtying: direct-path loads (INSERT /*+ APPEND */, SQL*Loader direct), array inserts, avoid scattering writes.
  2. More cache and DBWR capacity (db_writer_processes, faster storage) after checking memory with the system team.
  3. Prevent: size cache against the hot working set (index + table), measure fixes on realistic data volume.
Lab             : Hot block lab (reverse key on a 98 M-row table: 21,000 rows/s, free buffer waits 40%); commit lab (53%).
```

#### C. Commit and redo

```
Wait event      : log file sync
Class           : Commit
Explanation     : After COMMIT, the session waits until the log writer (LGWR) has safely written its redo to the online redo log.
Why             : Not slow disks but TOO MANY COMMITS (commit after every row). Slow redo storage or a synchronous standby can add to it.
Confirm with    : Commit rate script from CDB$ROOT (8.5): commits/s x log file sync ms / 1000 = seconds of waiting per second;
                  compare log file sync ms with log file parallel write ms (the disk part).
Fix and Prevent :
  1. Application: commit in batches (every few hundred rows), make the job restartable.
  2. Only if data is reloadable and the owner agrees: COMMIT WRITE BATCH NOWAIT (a commit can be lost on a crash).
  3. Check redo storage latency and standby network if log file parallel write is slow.
Lab             : Commit lab: 23,000 commits/s at 0.26 ms = 75% of session time; batching 500 rows: 17,000 -> 312,000 rows/s.
```

```
Wait event      : log file switch (checkpoint incomplete)   and   log file switch completion
Class           : Configuration
Explanation     : Oracle must switch to the next redo log but cannot reuse it yet (its changes are not yet checkpointed by DBWR),
                  or the switch is still completing. Every session that needs redo space stalls.
Why             : Redo logs too small for the redo rate (a switch every second instead of every 15 to 30 minutes), too few groups,
                  slow DBWR/storage.
Confirm with    : Switches per minute from gv$log_history, gv$log sizes and status, cost of the waits in gv$system_event (8.5).
Fix and Prevent :
  1. Add bigger/more redo log groups, then drop the old INACTIVE ones (section 8.5 steps and rollback).
  2. Size = peak redo MB/s x 900 to 1800 s (from AWR); reduce redo volume (batch commits, direct path).
  3. Prevent: alert on more than 6 log switches per hour per thread.
Lab             : 55 switches/min with 2 x 20 MB logs -> ~1/min with 3 x 1 GB; each wait cost 52 to 69 ms (about 200 times a commit).
```

#### D. Hot spots (concurrency)

```
Wait event      : row cache lock   and   row cache mutex
Class           : Concurrency
Explanation     : Sessions queue for an entry in the dictionary cache (Oracle's in-memory copy of dictionary rows). P1 is the cache id.
Why             : A NOCACHE (and/or ORDER) sequence: every NEXTVAL must update the sequence's dictionary row (cache name dc_sequences).
Confirm with    : Decode P1 through gv$rowcache (8.9 query 1), sequence settings in dba_sequences (cache_size, order_flag).
Fix and Prevent :
  1. ALTER SEQUENCE s CACHE 1000 NOORDER  (size >= NEXTVAL calls per second per instance). Cost: gaps after a crash, no strict order.
  2. Prevent: never create busy sequences NOCACHE or ORDER; on RAC prefer NOORDER with a large cache.
Lab             : Hot block lab, layer 1: 8,385 -> 66,173 rows/s.
```

```
Wait event      : buffer busy waits   and   enq: TX - index contention   and   latch: cache buffers chains
Class           : Concurrency
Explanation     : Many sessions want to modify the same block at the same time and queue (buffer busy waits); when a full index leaf is
                  split, others wait (index contention); many sessions on the same buffer chain latch (cache buffers chains).
Why             : Keys that always increase (sequence, timestamp) all go to the right-most leaf of the index: the hot right-hand edge.
                  Or a small table block updated by everyone.
Confirm with    : Which object (8.9 query 3), which blocks (query 4: neighbouring blocks of one index = the edge moving), per-segment
                  counters (query 5). On RAC the same hot block appears as gc buffer busy.
Fix and Prevent :
  1. Reverse key index (equality lookups only; no range scans; needs the index to fit in cache), hash-partitioned index,
     scalable sequence (SCALE EXTEND), or a service that keeps the workload on one RAC node.
  2. Compare fixes on equal data size; ALTER INDEX ... REBUILD REVERSE ONLINE needs quiet moments (ddl_lock_timeout; ORA-08104 recovery in 8.9).
Lab             : Hot block lab, layer 2: 66,173 -> 81,801 rows/s (buffer busy 31% -> under 3%); a range query went from cost 3 to a
                  full scan (cost 6,068) with the reverse key index.
```

#### E. Shared pool and parsing

```
Wait event      : latch: shared pool
Class           : Concurrency
Explanation     : When sessions wait on this latch, they are trying to allocate, free, or search for memory chunks in the shared
                  pool at the exact same time, and they have to wait their turn.
Why             : Literal SQL and hard parses: every new statement text needs fresh shared pool memory.
Confirm with    : Hard parse rate vs executions (8.3 check 1: hard parses should be a tiny fraction), many distinct sql_ids (check 2),
                  one force_matching_signature with thousands of copies (check 3).
Fix and Prevent :
  1. Fix the code: use bind variables (the permanent fix; also stops SQL injection).
  2. Emergency band-aid: ALTER SYSTEM SET CURSOR_SHARING = FORCE SCOPE=MEMORY;  (rollback: = EXACT SCOPE=MEMORY). Test first:
     it can reuse one plan for all values, and every call is still a soft parse.
  3. Right-size the shared pool only as a supporting step (v$shared_pool_advice, ORA-04031 history). A bigger pool alone hides the
     problem; never "fix" it with ALTER SYSTEM FLUSH SHARED_POOL.
Lab             : Parse lab: literals 5,800/s with 2.2 CPU-seconds/s of parse CPU; FORCE ~167,000/s; real binds ~370,000/s (64x).
```

```
Wait event      : library cache: mutex X   (and library cache: bucket mutex X)
Class           : Concurrency
Explanation     : Contention on the library cache's internal structures (the hash buckets and objects that hold prepared statements and
                  objects). P1 is the hash value of the object being touched.
Why             : Soft parse on every call (for example after cursor_sharing=FORCE), a hard parse storm, or a single object pinned at
                  an extreme rate (a sequence called 80,000 times/s).
Confirm with    : Find the object: ASH P1 -> v$db_object_cache / v$sqlarea hash_value; v$mutex_sleep by location (13.3 tip).
Fix and Prevent :
  1. Bind variables and keep cursors open (PL/SQL static SQL, JDBC statement caching, session_cached_cursors).
  2. Reduce the call rate to the object (fetch ids in batches, several sequences).
Lab             : 67 to 69% under cursor_sharing=FORCE; ~20% in the hot sequence (HOT_SEQ) lab (the sequence handle itself).
```

```
Wait event      : cursor: pin S   and   cursor: pin S wait on X
Class           : Concurrency
Explanation     : "pin S": sessions take a shared pin on a cursor to run it; at extreme rates they collide on the mutex.
                  "pin S wait on X" (not reproduced in the lab): a session wants to run a cursor while another holds it exclusively,
                  for example while parsing or invalidating it.
Why             : pin S: one very popular statement run hundreds of thousands of times a second (16% at 372,000/s in the lab, with
                  binds, so not a parsing problem). pin S wait on X: stats gather/DDL on a hot table, many versions of a cursor.
Confirm with    : Executions per second of the statement (3.3), hard parses/s (8.3), time of the last DDL/stats operation (1.7).
Fix and Prevent :
  1. Reduce the call rate: cache results, batch lookups. For pin S wait on X: avoid DDL and immediate-invalidation stats gathers at peak.
Lab             : Parse lab, bind mode (pin S). pin S wait on X could not be reproduced, check it on your RAC.
```

#### F. CPU and others

```
Wait event      : ON CPU   (a state, not a wait; state starts with WAITED...)
Class           : CPU
Explanation     : The session is running. In gv$session its EVENT column still shows the last finished wait; trust STATE first.
Why             : Bad plan or stale/locked statistics, a function on an indexed column, parsing, too many calls.
Confirm with    : Top SQL (3.1), gets_per_exec (3.3), plan with E-Rows vs A-Rows (4); stale/locked statistics (4.4 in the SQL runbook).
Fix and Prevent :
  1. Fix the plan (statistics, index, rewrite), measure each fix separately.
Lab             : Slow SQL lab: 9.2 -> 9.7 (statistics) -> 24.8 (rewrite) -> 770 runs/s (covering index).
```

```
Wait event      : SQL*Net message from client   and   PL/SQL lock timer   and   resmgr:cpu quantum
Class           : Idle / Idle / Scheduler
Explanation     : Idle: the session waits for the client or sleeps in PL/SQL; not a database problem. resmgr:cpu quantum: Resource
                  Manager is limiting this consumer group's CPU.
Why             : Normal idle time; a sleeping blocker (watch its open transaction); a CPU cap in the resource plan.
Confirm with    : Check STATE and whether the session holds a transaction (6.2/6.7); resource plan in dba_rsrc_plans.
Fix and Prevent :
  1. Do not tune idle waits; look for the blocker or for the work the client is doing before it calls again.
```

#### G. RAC (not tested in the lab)

```
Wait event      : gc buffer busy acquire / release,  gc current block 2-way / 3-way,  gc cr block 2-way / 3-way,  gc current block busy
Class           : Cluster
Explanation     : A block needed by one node is held (or being changed) on another node and must be shipped over the interconnect.
                  "busy" means the holder was itself busy with the block when the request arrived.
Why             : The same hot-block causes as the single instance (hot right-hand index leaf, sequences), amplified by node-to-node
                  transfers; or a slow interconnect.
Confirm with    : Average ms per gc event, waits per node, per-segment gc statistics, interconnect interfaces (8.2, 8.9 RAC extra checks);
                  AWR RAC report awrgrpt.sql ("Global Cache Load Profile").
Fix and Prevent :
  1. Same fixes as hot blocks (cache + NOORDER sequence, reverse key / hash partition / scalable sequence), plus services so one
     workload runs on one node.
  2. Interconnect health (NIC errors, bandwidth, jumbo frames) if the average transfer time is above about 1 to 2 ms.
Lab             : Not reproducible on single-instance Oracle Free; the hot-block lab shows the same causes locally.
```

```
Wait event      : enq: SQ - contention   and   DFS lock handle
Class           : Configuration / Cluster
Explanation     : Sequence coordination between sessions or nodes.
Why             : A sequence with ORDER or a small CACHE on RAC: every instance must coordinate for the numbers it hands out.
Fix and Prevent :
  1. ALTER SEQUENCE s CACHE 1000 NOORDER (larger for very high rates); fetch ids in batches.
Lab             : Not tested; on 26ai single instance the sequence layer showed row cache lock / row cache mutex (dc_sequences).
```

#### 13.3 Tips for reading any wait

- Always read `STATE` before `EVENT`: only `WAITING` is a real current wait (2.2).
- Decode `P1`/`P2`/`P3` instead of trusting the name: enqueue type and mode (4.2), row cache id (8.9), file and block of a busy buffer (8.9), object hash of a mutex.
- Which object is the session really touching? ASH `current_obj#` joined to `dba_objects`. A DELETE on the parent table that shows the CHILD table is the foreign-key clue.
- Which object does a library cache mutex protect? `SELECT p1, COUNT(*) FROM gv$active_session_history WHERE event = 'library cache: mutex X' GROUP BY p1` then match `p1` to `v$db_object_cache.hash_value` or `v$sqlarea.hash_value`.
- Tiny waits, many sessions, no blocker means a shared structure (sequence, index leaf, shared pool), not a lock someone holds.
- Do the multiplication: events per second x time per event, divided by sessions = share of their time.
- After every fix look again: the next narrowest point will show. Measure on equal data and ask what the fix costs.
- Seen in the labs but not studied: `enq: FB - contention`, `enq: CR - block range reuse ckpt`, `enq: HW - contention` (space management while segments grow fast), `log buffer space`.
