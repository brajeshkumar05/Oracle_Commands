# Oracle ORA Error and Log Playbook (RAC-ready)

For: you have an **error message or a log line** (ORA-xxxxx, an alert log entry, a listener or RMAN message) and need to know what it means, where to look, how to fix it and how to stop it coming back.
Companions in this folder:
- `Oracle_Wait_Event_Playbook.sql`: **live** problems (sessions waiting right now). It stays the live-troubleshooting playbook.
- `Oracle_Historical_Analysis_Playbook.sql`: "performance was bad 3 hours ago" (AWR/ASH). **Planned, not created yet.**

Conventions: queries are read-only unless marked ACTION. `v$` / `gv$` as appropriate; **there is no `gv$` version of `v$diag_alert_ext`**, so read the alert log on each RAC node. In a CDB, connect to the PDB where the application runs; the alert log is shared by the whole CDB (PDB messages carry a `PDBNAME(n):` prefix).
Everything marked "(lab)" was reproduced on Oracle AI Database 26ai Free in the Colima/Docker lab; entries marked "(not reproduced)" come from Oracle documentation or general behaviour: check them on your version.

---

## 1. Workflow for any error

```
1. Copy the EXACT message (code, text, object names, numbers).         2. When did it start, how often, which user/app/job?
3. Find it in the logs (section 3): alert log, trace file, listener log, RMAN output, clusterware logs.
4. Read what the message names (object, file, segment, SQL) and look at the lines BEFORE and AFTER it.
5. Check the facts with views (undo, tablespace, locks, sessions ...), do not guess.
6. Fix with the least risky action; for configuration changes use: pre-checks, steps, verification, rollback.
7. Validate with a different query than the one that found it; write the prevention item.
```
Tip: `oerr ora 1555` (on a server with the Oracle software) or the Oracle Database Error Messages reference gives the official cause and action. In 23ai/26ai many errors also print a `Help:` link.

## 2. Where the logs are

| Log | Where | Notes |
|---|---|---|
| Database alert log | `$ORACLE_BASE/diag/rdbms/<db>/<instance>/trace/alert_<instance>.log` (lab: `/opt/oracle/diag/rdbms/free/FREE/trace/alert_FREE.log`) | one per instance; XML copy in `.../alert/log.xml` |
| Trace files | `.../trace/*.trc` (named in the alert log: "Errors in file ...") | session traces, incident dumps |
| Listener log | `$ORACLE_BASE/diag/tnslsnr/<host>/listener/trace/listener.log` | connections and TNS errors (ORA-12xxx) |
| RMAN | the log file you redirected, `v$rman_output`, `v$rman_status` | `RMAN> LOG` or shell redirect |
| Clusterware (RAC) | `$GRID_HOME/log/<host>/alert<host>.log`, `crsd`, `cssd`, `evmd` folders | node eviction, resource failures |
| ASM | `$ORACLE_BASE/diag/asm/+asm/<+ASMn>/trace/alert_+ASMn.log` | disk group problems |
| OS | `/var/log/messages`, `dmesg`, `journalctl` (Linux) | OOM killer, disk and network errors |
| Audit | `$ORACLE_BASE/admin/<db>/adump`, `unified_audit_trail` | logon failures, privilege use |

Find the exact paths from the database:
```sql
SELECT name, value FROM v$diag_info WHERE name IN ('ADR Home','Diag Trace','Diag Alert','Default Trace File') ORDER BY name;
```
`adrci` (not installed in the lab image, standard on servers): `adrci> show alert -tail 100`, `show problem`, `show incident`, `ips pack incident <id>` to package evidence for Oracle Support.

## 3. Reading the alert log from SQL (all tested in the lab)

```sql
-- 3.1 Which error codes happened in the last 24 hours, how often, first and last time
SELECT REGEXP_SUBSTR(message_text, 'ORA-[0-9]{5}') ora_code, COUNT(*) occurrences,
       TO_CHAR(MIN(originating_timestamp),'MM-DD HH24:MI') first_seen, TO_CHAR(MAX(originating_timestamp),'MM-DD HH24:MI') last_seen
FROM   v$diag_alert_ext
WHERE  originating_timestamp > SYSTIMESTAMP - INTERVAL '24' HOUR AND REGEXP_LIKE(message_text, 'ORA-[0-9]{5}')
GROUP  BY REGEXP_SUBSTR(message_text, 'ORA-[0-9]{5}') ORDER BY occurrences DESC;

-- 3.2 One error with the record BEFORE it (often the SQL text or the object) and the trace file name
COL ts FORMAT A15
COL before_record FORMAT A62 TRUNC
COL error FORMAT A100 TRUNC
SELECT TO_CHAR(originating_timestamp,'MM-DD HH24:MI:SS') ts, prev1 before_record, REPLACE(message_text, CHR(10), ' | ') error
FROM  (SELECT originating_timestamp, message_text, record_id, LAG(message_text, 1) OVER (ORDER BY record_id) prev1
       FROM   v$diag_alert_ext WHERE originating_timestamp > SYSTIMESTAMP - INTERVAL '60' HOUR)
WHERE  message_text LIKE '%&error_code%'
ORDER  BY originating_timestamp DESC FETCH FIRST 10 ROWS ONLY;

-- 3.3 Everything around a point in time (what else happened at 18:21?)
SELECT TO_CHAR(originating_timestamp,'HH24:MI:SS') ts, SUBSTR(message_text,1,160) message_text FROM v$diag_alert_ext
WHERE  originating_timestamp BETWEEN TO_TIMESTAMP('&start','YYYY-MM-DD HH24:MI') AND TO_TIMESTAMP('&end','YYYY-MM-DD HH24:MI') ORDER BY record_id;
```
Shell equivalents: `grep -n -B3 -A6 'ORA-01555' alert_<SID>.log | tail -50`, `tail -f alert_<SID>.log`.
Important: **the alert log does not record every occurrence of every error.** In the lab ORA-01555 failed about 28 times but only 2 entries were written; use the application log and the counters in the views (for example `v$undostat.ssolderrcnt`) to count.

## 4. Entry template

```
Error           : ORA-xxxxx  message text
Meaning         : what Oracle is telling you in plain words
Where to look   : log or view that names the object/SQL (section 2 and 3)
Common causes   : the usual reasons
Confirm with    : query that proves the cause
Fix and Prevent : numbered steps, with rollback for configuration changes
Lab             : where we met it and what we saw
```

## 5. Index of entries

| Error | Short meaning | Status |
|---|---|---|
| ORA-01555 | snapshot too old: undo needed for a consistent read is gone | **done (6.0, lab 09)** |
| ORA-00054 | resource busy: DDL could not get the lock | done (6.1) |
| ORA-08104 | index is being online built/rebuilt | done (6.2) |
| ORA-14147 | another visible index exists on the same columns | done (6.3) |
| ORA-00031 | session marked for kill | done (6.4) |
| ORA-00942 | table or view does not exist | done (6.5) |
| ORA-01403 | no data found | done (6.6) |
| ORA-00990 | missing or invalid privilege | done (6.7) |
| ORA-03049 | SQL keyword not valid here (new in 23ai) | done (6.8) |
| ORA-03405 | end of query reached, no more text (SQL*Plus paste) | done (6.9) |
| ORA-12954 | request exceeds the maximum allowed database size of 12 GB (Free/XE edition limit) | done (6.10) |
| ORA-00060 | deadlock detected: two sessions wait for each other | **done (6.11, lab 21)** |
| ORA-01652 | unable to extend temp segment: temporary space is full | **in progress (6.12, lab 22)** |
| ORA-01653 / tablespace full, ORA-01653 / tablespace full, ORA-00257 archiver stuck, ORA-04031 / ORA-04030, ORA-00018 / ORA-00020, listener errors (ORA-12514, 12541, 12170, 03113), ORA-00600 / ORA-07445, ORA-28000 / 28001 / 01017 | planned | not started |

## 6. Entries

### 6.0 ORA-01555: snapshot too old: rollback segment number N with name "_SYSSMUn_...$" too small
```
Meaning         : A query (or a fetch) needs the OLD version of a block as of the moment it started (read consistency). Oracle rebuilds it from
                  undo, but the undo records it needs have been overwritten, so the query cannot be completed and fails.
Where to look   : The failing SQL: alert log (3.2, shows the SQL text and the trace file; only a SAMPLE of the occurrences), application/job log,
                  gv$undostat / dba_hist_undostat (count of every occurrence + the longest query and its SQL_ID).
Common causes   : 1. Undo too small and/or undo_retention shorter than the longest query (reproduced in lab 09).
                  2. A long-running report on tables that heavy DML is changing at the same time (reproduced).
                  3. Fetching across commits: a loop that fetches from a cursor and commits inside the loop (not reproduced).
                  4. Delayed block cleanout after a big batch load (not reproduced). 5. LOB columns: ORA-22924 (not reproduced).
Confirm with (RAC format; there is no gv$ version of v$diag_alert_ext, read it on each node):
```
```sql
-- 1. every ORA-01555 per 10 minutes, per instance, with the longest query and its text (Oracle's own records, no application table needed)
SELECT u.inst_id, TO_CHAR(u.begin_time,'MM-DD HH24:MI') bt, u.ssolderrcnt ora1555, u.maxquerylen, u.maxqueryid,
       u.unxpblkreucnt unexpired_reused, u.nospaceerrcnt, u.tuned_undoretention, SUBSTR(q.sql_text,1,60) sql_text
FROM   gv$undostat u LEFT JOIN gv$sqlarea q ON q.sql_id = u.maxqueryid AND q.inst_id = u.inst_id
ORDER  BY u.begin_time DESC, u.inst_id FETCH FIRST 8 ROWS ONLY;
-- 2. past incidents (AWR, about 7 to 8 days; the SQL_ID column is called maxquerysqlid here)
SELECT TO_CHAR(h.begin_time,'MM-DD HH24:MI') bt, h.instance_number inst, h.ssolderrcnt ora1555, h.maxquerylen, h.maxquerysqlid, SUBSTR(t.sql_text,1,60) sql_text
FROM   dba_hist_undostat h LEFT JOIN dba_hist_sqltext t ON t.sql_id = h.maxquerysqlid AND t.dbid = h.dbid
WHERE  h.begin_time > SYSDATE - 1 AND h.ssolderrcnt > 0 ORDER BY h.begin_time DESC, h.instance_number FETCH FIRST 10 ROWS ONLY;
-- 3. configuration: parameters per instance, undo tablespaces (size, autoextend, retention guarantee), what the undo holds
SELECT inst_id, name, value FROM gv$parameter WHERE name IN ('undo_management','undo_tablespace','undo_retention') ORDER BY name, inst_id;
SELECT t.tablespace_name, t.retention, ROUND(SUM(d.bytes)/1048576) size_mb, MAX(d.autoextensible) autoextend, ROUND(SUM(d.maxbytes)/1048576) max_mb
FROM   dba_tablespaces t JOIN dba_data_files d ON d.tablespace_name = t.tablespace_name WHERE t.contents = 'UNDO' GROUP BY t.tablespace_name, t.retention;
SELECT tablespace_name, status, ROUND(SUM(bytes)/1048576) mb FROM dba_undo_extents GROUP BY tablespace_name, status ORDER BY 1, 2;   -- ACTIVE / UNEXPIRED / EXPIRED
-- 4. how fast undo is generated and the longest query, per instance, last hour: undo needed = rate x retention you want
SELECT u.inst_id, ROUND(SUM(u.undoblks) * (SELECT TO_NUMBER(value) FROM gv$parameter p WHERE p.name = 'db_block_size' AND p.inst_id = u.inst_id) / 1048576
                  / NULLIF(SUM((u.end_time - u.begin_time) * 86400), 0), 2) undo_mb_per_sec, ROUND(MAX(u.maxquerylen)) longest_query_s
FROM   gv$undostat u WHERE u.begin_time > SYSDATE - 1/24 GROUP BY u.inst_id;
```
```
How to read it   : ssolderrcnt = number of ORA-01555 in the 10-minute interval (counts every one; the alert log wrote 2 of about 70 in the lab).
                   maxquerylen = seconds of the longest query in the interval (an order-of-magnitude figure; it did not match single runs exactly).
                   unxpblkreucnt > 0 = undo still inside the retention period had to be reused because there was no room: undo too small.
                   nospaceerrcnt > 0 = DML failed for lack of undo (worse). tuned_undoretention = the history Oracle can really keep now.
                   History kept = undo space / undo generation rate. Needed space = rate x retention wanted (use the BUSIEST period).
Fix and Prevent  :
  1. Size and policy (RAC: for EACH instance's undo tablespace; parameter with SID='*', SCOPE=BOTH):
       ALTER DATABASE DATAFILE '<undo file>' RESIZE <size>;
       ALTER DATABASE DATAFILE '<undo file>' AUTOEXTEND ON NEXT 64M MAXSIZE <cap>;
       ALTER SYSTEM SET undo_retention = <2 to 3 x longest query in seconds> SCOPE=BOTH SID='*';
     Raising only undo_retention does NOT help on a small fixed-size tablespace: Oracle reuses protected undo when it runs out of room.
     With autoextend ON, Oracle auto-tunes the retention up towards the longest query as long as it can extend (lab: 25 s -> 541 to 988 s).
  2. Fix the query side: make the report faster, read in chunks by key range, do not fetch slowly, run it when DML is quiet, never commit inside a
     loop that fetches from an open cursor (fetching across commits), or run reports on a standby (not tested).
  3. Optional, with care: ALTER TABLESPACE <undo> RETENTION GUARANTEE keeps unexpired undo no matter what, but DML can then fail with ORA-30036
     when undo is full (not tested).
  4. Prevent: size undo from the busiest period (AWR), keep autoextend ON with a cap that fits the disk, alert when ssolderrcnt > 0 or
     unxpblkreucnt > 0 in gv$undostat, review reports whose maxquerylen grows.
Validate         : ssolderrcnt = 0 for several 10-minute intervals while maxquerylen stays the same or higher; unxpblkreucnt = 0;
                   tuned_undoretention > maxquerylen; the application confirms the job completes. Oracle does not log successes, so there is no OK count.
                   Expect the first one or two runs right after the change to still fail: the undo history needs time to build.
Lab (lab 09)     : 60 MB fixed undo, retention 10 s, 4 sessions updating, report needing about 100 s: 39 of 39 runs FAILED after 23 to 50 s,
                   about 70 errors counted by gv$undostat but only 2 in the alert log, tuned retention 24 to 28 s, 120 to 695,498 unexpired reuses per interval.
                   Fix: file 512 MB with autoextend (grew to 1,088 MB), retention 300 s: after the transition 6 consecutive OK runs of about 102 s,
                   unxpblkreucnt 0, tuned retention 541 to 988 s.
Pitfalls         : one OK run does not prove the fix (the first run after the lab started succeeded by luck); my first size guess (512 MB) was too low,
                   the real rate under load was about 2.4 MB/s; a SERVERERROR trigger only sees errors that reach the client, not errors caught inside PL/SQL.
```

### 6.1 ORA-00054: resource busy and acquire with NOWAIT specified or timeout expired
```
Meaning         : A DDL statement (DROP/ALTER INDEX, ALTER TABLE ...) needs a lock on a table or index that other sessions have open
                  transactions on, and it was not allowed to wait (or the wait ran out).
Where to look   : the statement that failed; gv$lock (type TM, lmode > 0) and gv$session for the holders.
Common causes   : DDL on a busy table: some session always has an open transaction (constant inserts/updates).
Confirm with    : SELECT inst_id, sid, type, lmode, request FROM gv$lock WHERE type = 'TM' AND id1 = <object_id>;
Fix and Prevent :
  1. Let the DDL wait for a gap:  ALTER SESSION SET ddl_lock_timeout = 60;  (then retry; a gap must appear within that time)
  2. Prefer ONLINE operations and run DDL in a quiet window; have the owner commit long transactions.
  3. Never kill sessions just to get a lock without checking their owner and rollback cost (Oracle_Wait_Event_Playbook.sql section 7).
Lab             : DROP INDEX on a table under 12 inserting sessions failed; with ddl_lock_timeout=60 it succeeded in 6.7 s.
```

### 6.2 ORA-08104: this index object N is being online built or rebuilt
```
Meaning         : An ALTER INDEX ... REBUILD ONLINE (or CREATE INDEX ... ONLINE) was started and did not finish cleanly (interrupted,
                  session killed, waiting forever for gaps), and the index is still marked "in rebuild".
Where to look   : gv$session for a session really running the rebuild; leftover table SYS_JOURNAL_<object_id> in dba_objects.
Common causes   : online rebuild on a table that never has a gap in transactions; Ctrl-C or kill of the session doing it.
Confirm with    : SELECT owner, object_name FROM dba_objects WHERE object_name LIKE 'SYS_JOURNAL%' OR object_id = <N>;
                  and check no session is running the rebuild (gv$session / gv$sql text LIKE '%REBUILD%').
Fix and Prevent :
  1. If no session runs it, clean up:  DECLARE ok BOOLEAN; BEGIN ok := DBMS_REPAIR.ONLINE_INDEX_CLEAN(object_id => <N>, wait_for_lock => DBMS_REPAIR.LOCK_NOWAIT); END;
     (constant is LOCK_NOWAIT; NOWAIT_LOCK does not exist and gives PLS-00302). SMON also cleans it up after some time. Never drop the journal table by hand.
  2. Prevent: stop the load or pick a quiet window, set ddl_lock_timeout, do not interrupt an online rebuild.
Lab             : A reverse-key rebuild under 12 inserting sessions was abandoned; the next attempt gave ORA-08104; cleanup returned YES.
```

### 6.3 ORA-14147: there is an existing VISIBLE index defined on the same set of columns
```
Meaning         : Only one index per column set can be visible; you tried to make a second one visible.
Fix and Prevent : Swap in this order:  ALTER INDEX old INVISIBLE;  ALTER INDEX new VISIBLE;  then drop the old one later.
Lab             : Moving a primary key to a hash-partitioned index (Oracle_Wait_Event_Playbook.sql section 8.9).
```

### 6.4 ORA-00031: session marked for kill
```
Meaning         : You (or a script) already ran ALTER SYSTEM KILL SESSION on it; Oracle has marked it and will finish the kill when the
                  session can be cleaned up (rollback of its transaction, end of its call). A second kill gives this error.
Where to look   : SELECT sid, serial#, status FROM gv$session  (status KILLED); v$transaction for the rollback still running.
Fix and Prevent : Wait for PMON to clean up; check the rollback progress (used_ublk in gv$transaction, gv$fast_start_transactions).
                  Do not repeat the kill. Only if it never goes away, ask the system team about the server process (spid in gv$process),
                  as a last resort.
Lab             : The lab "stop" scripts kill sessions; the alert log recorded ORA-00031 190 times in a day from repeated kills.
```

### 6.5 ORA-00942: table or view does not exist
```
Meaning         : The name is not visible to the current user in the current container.
Common causes   : wrong name (a view that does not exist), missing privilege or synonym, wrong schema, connected to the wrong container
                  (a table created in a PDB is invisible from CDB$ROOT), object dropped.
Confirm with    : SELECT SYS_CONTEXT('USERENV','CON_NAME') FROM dual;  SELECT owner, object_name FROM dba_objects WHERE object_name = '<NAME>';
Fix and Prevent : correct the name/owner, grant the privilege, connect to the right container.
Lab             : gv$diag_alert_ext does not exist (only v$diag_alert_ext); lab tables exist only in FREEPDB1.
```

### 6.6 ORA-01403: no data found
```
Meaning         : A SELECT INTO returned no rows, or PL/SQL read a collection element that does not exist.
Common causes   : the query found nothing in this container; a key missing from an associative array.
Lab             : A script asked a PDB session for log file parallel write, which is only visible from CDB$ROOT, so the array key did not exist.
Fix and Prevent : handle NO_DATA_FOUND (or test the key with EXISTS) and print a clear hint; check which container you are in.
```

### 6.7 ORA-00990: missing or invalid privilege
```
Meaning         : A GRANT names something that is not a system privilege.
Lab             : GRANT ... CREATE INDEX TO user is invalid: owners create indexes on their own tables with CREATE TABLE; CREATE ANY INDEX is the system privilege.
```

### 6.8 ORA-03049: SQL keyword 'X' is not syntactically valid following '...'  (new in 23ai/26ai)
```
Meaning         : Syntax error with the exact keyword and the text before it. Older versions only said ORA-00933.
Lab             : "... WHERE owner='LAB' groupby table_name" (GROUP BY written as one word). The Help: link in the output explains it.
```

### 6.9 ORA-03405: end of query reached; no additional text should follow
```
Meaning         : More than one SQL statement was sent as one (typically two statements pasted on one line in SQL*Plus).
Fix and Prevent : one statement per terminator (;), or save the statements in a file and run it with @file.sql.
```

### 6.10 ORA-12954: The request exceeds the maximum allowed database size of 12 GB
```
Meaning         : Oracle Database Free (and XE) limit the size of the database (12 GB of user data in Free; also 2 CPU threads and 2 GB of RAM).
                  Any request that needs more space fails with this error. It is NOT a normal "tablespace full" error: you can see free space inside
                  the tablespace and still get it, because the limit is applied to the ALLOCATED size of the data files.
Where to look   : data file sizes (not used space) and what is really inside them.
Common causes   : labs and loads that grew a data file (autoextend) and later dropped or truncated the data: the file stays big, with free space inside.
                  Even a SELECT or a PL/SQL block can fail, because Oracle needs to write something recursive (dictionary, SQL management base, AWR).
Confirm with    :
```
```sql
SELECT con_id, tablespace_name, ROUND(SUM(bytes)/1048576) file_mb FROM cdb_data_files GROUP BY con_id, tablespace_name ORDER BY 3 DESC;       -- allocated
SELECT tablespace_name, ROUND(SUM(bytes)/1048576) used_by_segments_mb FROM dba_segments GROUP BY tablespace_name ORDER BY 2 DESC;            -- really used (PDB)
SELECT tablespace_name, ROUND(SUM(bytes)/1048576) free_inside_mb FROM dba_free_space GROUP BY tablespace_name ORDER BY 2 DESC;
-- how far each file can shrink = end of its last used extent
SELECT f.tablespace_name, ROUND(f.bytes/1048576) size_mb,
       ROUND(NVL((SELECT MAX((e.block_id + e.blocks) * ts.block_size) FROM dba_extents e WHERE e.file_id = f.file_id), 0) / 1048576) min_mb
FROM   dba_data_files f JOIN dba_tablespaces ts ON ts.tablespace_name = f.tablespace_name ORDER BY f.bytes DESC;
```
```
Fix and Prevent :
  1. Drop what you do not need (DROP TABLE ... PURGE, PURGE DBA_RECYCLEBIN), then SHRINK THE FILE; dropping data alone does not help:
       ALTER DATABASE DATAFILE '<file>' RESIZE <size at least min_mb>;
     If the last extents are in the way, drop or move (ALTER TABLE ... MOVE) the objects sitting at the end of the file first.
  2. Cap the growth so the failure is predictable:  ALTER DATABASE DATAFILE '<file>' AUTOEXTEND ON NEXT 100M MAXSIZE 8G;
  3. Undo and temp files did not count in the lab (shrinking only USERS fixed it while undo stayed at 13.8 GB); verify on your edition.
  4. Prevent: have a cleanup script per lab, check file sizes after every heavy lab, keep the lab disk and memory free.
Lab             : After the labs, USERS had grown to 11.6 GB (only 4.6 GB of segments inside). Dropping tables did not clear the error; shrinking the file
                  to 4.7 GB did. Disk free went 17 GB -> 30 GB after also shrinking the empty undo file.
Not applicable  : Standard/Enterprise Edition have no such limit (you get ORA-01653 / ORA-01654 for a full tablespace instead).
```

### 6.11 ORA-00060: deadlock detected while waiting for resource
```
Meaning         : Two (or more) sessions each hold a lock the other needs, so none can continue. After about 3 seconds Oracle picks one session as the victim, rolls back ONLY its last statement
                  (the transaction stays open!) and raises ORA-00060 in it. The other session keeps waiting until the victim commits or rolls back. It is an application design problem,
                  Oracle cannot prevent it.
Where to look   : the alert log line "ORA-00060: Deadlock detected ... More info in file <trace>.trc" and that trace file (section 3.1 / 3.2; RAC: the file is on the node of the victim session,
                  and the other session may be on another node: the graph then shows instance numbers). Different victims give different trace files.
Common causes   : - two code paths update the same rows/tables in a different ORDER (lab 21: job A account 1 then 2, job B account 2 then 1)
                  - unindexed foreign keys (TM locks on the child table, see lab 05) and bitmap indexes, ITL slots too small (INITRANS) in a block with many sessions: graph shows TM or TX with mode 4/6 differences
                  - an application that catches the error, does not roll back and keeps the transaction open.
Confirm with    : the deadlock graph in the trace (shell, on the server; replace the file name from the alert log):
                    n=$(grep -n "DEADLOCK DETECTED" <file>.trc | tail -1 | cut -d: -f1) && sed -n "$((n+10)),$((n+80))p" <file>.trc | cut -c1-190
                  Read it: each row of "Deadlock graph" = one resource; Blocker(s) holds it, Waiter(s) waits for it; rows form a circle (A waits for B, B waits for A).
                  Resource name TX = row lock (or ITL wait), TM = table lock (foreign key, DDL). Then "Information for waiting sessions": application name / action (who), current SQL (the statement it is WAITING with, i.e. the SECOND lock it wants).
                  The statement that took the FIRST lock is NOT in the trace (lab 21: the user asked, checked: neither trace nor ASH has it). Three ways to get it:
                    a) LIVE, while the deadlock lasts (about 3 s, repeat the query until it catches): prev_sql_id = the statement run before the one the session is stuck on (the first statement only if nothing else ran in between):
                       SELECT s.inst_id, s.sid, s.module, s.event, s.blocking_instance b_inst, s.blocking_session blocker, SUBSTR(c.sql_text,1,60) waiting_for_lock_with, SUBSTR(p.sql_text,1,60) first_statement_of_txn
                       FROM gv$session s LEFT JOIN gv$sql c ON c.inst_id = s.inst_id AND c.sql_id = s.sql_id AND c.child_number = s.sql_child_number
                                         LEFT JOIN gv$sql p ON p.inst_id = s.inst_id AND p.sql_id = s.prev_sql_id AND p.child_number = s.prev_child_number
                       WHERE s.state = 'WAITING' AND s.event = 'enq: TX - row lock contention' ORDER BY s.sid;
                       Two sessions that name each other in the blocker column = the circle, visible live. (lab: sid 51 JOB_B waits on ACCT_ID = 1 after "- 10 ... ACCT_ID = 2"; sid 225 JOB_A waits on ACCT_ID = 2 after "- 10 ... ACCT_ID = 1"; user run: sid 51 JOB_A blocked by 207, sid 207 JOB_B blocked by 51, same statements)
                    b) the application code / job definition (dba_source, dba_scheduler_jobs) - the authoritative answer;
                    c) a 10046 trace of one run of the job (section 11 of Oracle_SQL_Tuning_Playbook.sql) - shows every call in order.
                  ASH does not help: it samples the waiting second update only.
                  How often: SELECT REGEXP_SUBSTR(message_text,'ORA-[0-9]{5}') code, COUNT(*) n, MIN(originating_timestamp) first_seen, MAX(originating_timestamp) last_seen FROM v$diag_alert_ext WHERE message_text LIKE '%ORA-00060%' AND originating_timestamp > SYSTIMESTAMP - INTERVAL '30' MINUTE GROUP BY REGEXP_SUBSTR(message_text,'ORA-[0-9]{5}');
                  After a fix, count only the last minutes: ... AND originating_timestamp > SYSTIMESTAMP - INTERVAL '2' MINUTE;   (older events stay in the log)
Fix and Prevent :
  1. Take the locks in the same order in every code path (for example lowest key first). If a transaction needs several rows: SELECT ... FROM t WHERE id IN (...) ORDER BY id FOR UPDATE, then update.
  2. Keep transactions short: commit right after the business step, no waiting for users or sleeping while holding locks.
  3. The application must handle ORA-00060: ROLLBACK the whole transaction (not only the statement), wait a random short time, retry a limited number of times, and log it.
  4. Index foreign keys (lab 05) and check INITRANS if the graph shows TM/ITL waits instead of row locks.
  5. Monitor: count of ORA-00060 per hour from the alert log; alert when it grows.
  If the code cannot be changed yet: shorten the time between the first and second lock, make the caller roll back the whole transaction and retry after a random wait, schedule the two jobs not to overlap, or serialize them with one application lock (costs concurrency).
  Do NOT "fix" it with a kill session or an Oracle parameter: there is none for application deadlocks.
Lab             : lab/21_deadlock_lab.sh start [seconds] [fixed]. Original: 13 deadlocks in about 63 seconds. Graph: session 222 (TRANSFER_JOB_B, current SQL UPDATE ... ACCT_ID = 1) and session 51 (TRANSFER_JOB_A, current SQL UPDATE ... ACCT_ID = 2), each holding the row the other wants. Fixed version (both lock accounts 1 then 2 first): 76 updates in 40 s, 0 deadlocks (tested by me); user run: 0 deadlocks in 2 minutes. Two trace files in the alert log = two sessions/server processes, the VICTIM's process writes the file (JOB_B in 64870, JOB_A in 64860). An index does not prevent a deadlock (it is about lock ORDER); only an unindexed foreign key causes a TM deadlock that an index fixes. Note: the alert log and the trace file in the lab were from several server processes, one per session; the application logged the error to a table and continued (LAB.DL_LOG).
```

### 6.12 ORA-01652: unable to extend temp segment (23ai/26ai text: "unable to grow temp segment in tablespace T by 1MB during operation with SQL ID : x, temp space used by session : N (MB)")
```
Meaning         : A session needed more temporary space (sort, hash join, hash aggregate, global temporary table, index build, LOB) than the temporary tablespace has free. Only the statement that
                  asked fails (the transaction stays open); the session that hit the limit is not always the one that used most: others may hold the space (victim vs culprit).
Where to look   : the message itself in 23ai/26ai names the SQL ID and the temp the session had used. Alert log: v$diag_alert_ext (older versions print "ORA-1652" without the zero: search for '%165%').
Common causes   : - a bad plan or a mistake in the SQL: missing join condition (MERGE JOIN CARTESIAN), huge sort/hash with no filter, a join that multiplies rows
                  - one or more big legitimate sessions holding temp for a long time (open cursors, long reports, index builds)
                  - temp tablespace too small / no autoextend for the workload, or tempfile on a full disk
                  - temp usage growing slowly because of a leak (sessions never closed) - check the number of sessions and segtype.
Confirm with    : (SYS; RAC: gv$ and dba_temp_free_space already cover all instances; temp tablespace is shared)
                  1. free space:  SELECT tablespace_name, ROUND(tablespace_size/1048576) total_mb, ROUND(allocated_space/1048576) allocated_mb, ROUND(free_space/1048576) free_mb FROM dba_temp_free_space;
                  2. who uses it NOW:
                     SELECT u.inst_id, s.sid, s.serial#, s.username, s.module, u.sql_id, u.tablespace, u.segtype, ROUND(SUM(u.blocks) * 8192 / 1048576) mb
                     FROM gv$tempseg_usage u JOIN gv$session s ON s.saddr = u.session_addr AND s.inst_id = u.inst_id
                     GROUP BY u.inst_id, s.sid, s.serial#, s.username, s.module, u.sql_id, u.tablespace, u.segtype ORDER BY mb DESC;
                     (8192 = block size of the temp tablespace; check SELECT block_size FROM dba_tablespaces WHERE tablespace_name = '<temp>'. segtype SORT/HASH/DATA/INDEX/LOB_DATA.)
                  3. who used it in the PAST 10 minutes (ASH has temp_space_allocated; the culprit may be gone when you look):
                     SELECT inst_id, session_id sid, session_serial# serial, module, sql_id, ROUND(MAX(temp_space_allocated)/1048576) max_temp_mb, COUNT(*) samples
                     FROM gv$active_session_history WHERE sample_time > SYSTIMESTAMP - INTERVAL '10' MINUTE AND temp_space_allocated > 0
                     GROUP BY inst_id, session_id, session_serial#, module, sql_id ORDER BY max_temp_mb DESC FETCH FIRST 10 ROWS ONLY;
                     (older: dba_hist_active_sess_history, 10 s samples)
                  4. the SQL and its plan (estimated temp is in the TempSpc column; look for MERGE JOIN CARTESIAN, SORT, HASH GROUP BY with huge Rows):
                     SELECT sql_id, SUBSTR(sql_text,1,100) FROM gv$sql WHERE sql_id = '&sql_id';
                     SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY_CURSOR('&sql_id', NULL, 'TYPICAL'));
                     (format 'BASIC +TEMPSPC' is NOT valid: use TYPICAL; the TempSpc column appears only when it is large)
                  Read the Rows column line by line: a join that outputs far more rows than its biggest input (lab: 60 x 100K = 6,000K from 60 and 100K) is a missing/wrong join condition. The SQL Analysis Report at the end of the plan (26ai) also says "cartesian product".
                  Is a join condition missing? Which columns relate the tables: foreign keys (dba_constraints type 'R'), primary key + same column name, the data model, the application owner. Prove it with the data:
                     SELECT COUNT(*) AS orphans FROM <child> c WHERE NOT EXISTS (SELECT 1 FROM <parent> p WHERE p.<key> = c.<key>);
                     SELECT (SELECT COUNT(*) FROM <child> WHERE <filter>) AS child_rows, (SELECT COUNT(*) FROM <child> c JOIN <parent> p ON p.<key> = c.<key> WHERE <filter>) AS joined_rows FROM dual;      -- equal = the join is right; much larger = still missing something; smaller = unmatched rows
                     Without a declared foreign key (the lab has none) the database cannot tell you the relationship; declaring it (ALTER TABLE ... ADD CONSTRAINT ... FOREIGN KEY) documents it. See section 6.12 lab.
                  Check the fix WITHOUT running the statement:  EXPLAIN PLAN FOR <fixed query>;  SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY(NULL, NULL, 'TYPICAL'));   (lab: MERGE JOIN CARTESIAN 6,000K rows / 207M temp -> HASH JOIN 100K rows / 4,336K temp)
Fix and Prevent : 1. Fix the cause first: a Cartesian join / missing predicate in the SQL, a plan change, a missing filter. Adding temp space for a bad statement only delays the next failure.
                  2. If the workload is legitimate: add a tempfile or resize/autoextend with a sensible MAXSIZE:  ALTER TABLESPACE temp ADD TEMPFILE '<path>' SIZE 2G AUTOEXTEND ON NEXT 256M MAXSIZE 16G;
                     check disk space first. RAC: tempfiles are shared storage (ASM); each instance has its own sort segments inside the same tablespace.
                  3. Limit the damage of one session: Resource Manager (SESSION_TEMP_MB / "temp space limit" in a consumer group) or a profile; a temp tablespace group to spread load.
                  4. Shrink after an incident: ALTER TABLESPACE temp SHRINK SPACE KEEP 1G;  (free space is not returned to the OS automatically).
                  5. Monitor: free_mb of dba_temp_free_space, top temp users from ASH, count of ORA-01652 per hour.
                  Do NOT kill the "biggest" session before reading its SQL and owner (Oracle_Wait_Event_Playbook.sql section 7).
Lab             : lab/22_temp_lab.sh start [seconds] | stop | drop. TEMP_SMALL 64 MB for user LAB. MONTH_END_RPT (report, runs every 20 s, fails with ORA-01652 after about 5 s, SQL fq9qzaawdn48b: Cartesian join, plan 6,000K rows,
                  estimated 207 MB temp) and FINANCE_QUERY (legitimate, holds about 14 MB of SORT for 50 s). Message example: "temp space used by session : 49 (MB)". (user result: pending)
```
