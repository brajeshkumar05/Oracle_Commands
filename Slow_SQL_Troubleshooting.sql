-- =====================================================================================
-- SLOW SQL / SLOW DATABASE TROUBLESHOOTING RUNBOOK  (Oracle 12c+ / 19c, single instance or RAC)
-- Customer says: "query is slow" or "database is slow"  -->  work top to bottom.
--
-- HOW TO USE
--   * Run in SQL*Plus or SQL Developer as a DBA user (SYSDBA not required). In a CDB, connect to the PDB
--     where the application runs. Copy ONE numbered block at a time, they are independent.
--   * Lines with an ampersand prefix (sql_id, owner, tab, start_time ...) will prompt you for a value.
--   * All gv$ queries work on single instance too (they just return one instance).
--   * Everything in sections 1, 2, 3, 4 and 6 is READ-ONLY. Section 5 (fixes) is commented out,
--     change production only after you have the evidence, an approver and the rollback noted.
--   * LICENSE tags:  [NONE] = no extra license | [DIAG] = needs Diagnostics Pack (AWR/ASH)
--                    [TUNE] = needs Tuning Pack (SQL Monitor, SQL Tuning Advisor).
--     If you are not licensed, use the [NONE] queries or Statspack. Check:  SHOW PARAMETER control_management_pack_access
--
-- 5-MINUTE TRIAGE ORDER
--   1.1 where am I -> 1.3 load now -> 1.5 what is the DB waiting on -> 2.1 who/what is running slow
--   -> 4.2 blocking? -> 2.12 plan of the worst SQL -> match symptom in section 3 -> fix in 5 -> prove in 6
-- =====================================================================================

SET LINESIZE 250 PAGESIZE 200 LONG 1000000 LONGCHUNKSIZE 1000000 TRIMSPOOL ON VERIFY OFF FEEDBACK ON
SET SERVEROUTPUT ON SIZE UNLIMITED
ALTER SESSION SET NLS_DATE_FORMAT='YYYY-MM-DD HH24:MI:SS';
COL sql_text FORMAT A60 TRUNC
COL event FORMAT A42 TRUNC
COL wait_class FORMAT A16
COL module FORMAT A25 TRUNC
COL program FORMAT A25 TRUNC
COL machine FORMAT A22 TRUNC
COL username FORMAT A16
COL metric_name FORMAT A50
COL object_name FORMAT A30
COL message FORMAT A150 TRUNC

-- =====================================================================================
-- 0. FIRST: ASK THE CUSTOMER (30 seconds, saves hours)
-- =====================================================================================
--  a) Which application / report / job / screen, and which user?       -> one SQL or the whole DB?
--  b) Since WHEN (exact time, time zone)?  Was it ever fast?  How fast?  -> baseline for comparison
--  c) All users or one user?  One module or everything?                  -> system-wide vs single SQL
--  d) What changed: deploy, patch, stats gather, data load, new users, parameter change, restart, failover?
--  e) Any error text (ORA-xxxxx, timeouts, connection refused)?
--  f) Is it slow every time, or only at certain times (batch window, month end, backups)?

-- =====================================================================================
-- 1. WHAT TO CHECK  (system-wide health, 2 minutes)
-- =====================================================================================

-- [1.1] Which database/instance/PDB am I on?  [NONE]
SELECT d.name, d.db_unique_name, d.database_role, d.open_mode, i.instance_name, i.host_name, i.version,
       i.status, TO_CHAR(i.startup_time,'YYYY-MM-DD HH24:MI') startup, SYS_CONTEXT('USERENV','CON_NAME') con_name
FROM   v$database d, v$instance i;

-- [1.2] Host check (run in a separate OS terminal, Linux shown; AIX: topas / vmstat / iostat)
--   uptime                       -> load average vs number of CPUs
--   top -b -n1 | head -25        -> who is eating CPU (oracle processes? something else?)
--   vmstat 2 5                   -> r (run queue) > CPUs, si/so > 0 = swapping, wa = IO wait
--   iostat -xm 2 5               -> await / %util on database disks
--   free -m ; df -h              -> memory, swap, full filesystems (including archive and ORACLE_HOME)

-- [1.3] Key load metrics, last 60 seconds  [NONE]
-- Read: Average Active Sessions (AAS) vs CPU count (1.4). AAS much greater than CPUs = overloaded.
SELECT inst_id, metric_name, ROUND(value,2) value, metric_unit
FROM   gv$sysmetric
WHERE  group_id = 2
AND    metric_name IN ('Average Active Sessions','Host CPU Utilization (%)','CPU Usage Per Sec','Current OS Load',
                       'Database Wait Time Ratio','SQL Service Response Time','Average Synchronous Single-Block Read Latency',
                       'Executions Per Sec','User Calls Per Sec','Logons Per Sec','Hard Parse Count Per Sec',
                       'Physical Read Total Bytes Per Sec','Physical Write Total Bytes Per Sec','Redo Generated Per Sec')
ORDER  BY metric_name, inst_id;

-- [1.4] CPU count and OS counters  [NONE]
SELECT inst_id, stat_name, value FROM gv$osstat
WHERE  stat_name IN ('NUM_CPUS','NUM_CPU_CORES','LOAD','PHYSICAL_MEMORY_BYTES','FREE_MEMORY_BYTES','VM_PAGE_IN_BYTES','VM_PAGE_OUT_BYTES')
ORDER  BY inst_id, stat_name;

-- [1.5] What is the database doing RIGHT NOW? Active sessions by activity  [NONE]
-- Big ON CPU = CPU bound. Big User I/O = disk. Concurrency/Application/Cluster = contention (go to 4.x).
SELECT CASE WHEN state='WAITING' THEN wait_class ELSE 'CPU' END activity,
       CASE WHEN state='WAITING' THEN event ELSE 'ON CPU' END event,
       COUNT(*) active_sessions
FROM   gv$session
WHERE  type='USER' AND status='ACTIVE'
GROUP  BY CASE WHEN state='WAITING' THEN wait_class ELSE 'CPU' END, CASE WHEN state='WAITING' THEN event ELSE 'ON CPU' END
ORDER  BY active_sessions DESC;

-- [1.6a] Space and limits: tablespaces above 85 percent, temp, FRA, process/session limits  [NONE]
SELECT tablespace_name, ROUND(used_percent,1) used_pct FROM dba_tablespace_usage_metrics WHERE used_percent > 85 ORDER BY used_percent DESC;
SELECT tablespace_name, ROUND(tablespace_size/1048576) total_mb, ROUND(free_space/1048576) free_mb FROM dba_temp_free_space;
SELECT name, ROUND(space_limit/1073741824,1) limit_gb, ROUND(space_used/1073741824,1) used_gb,
       ROUND(100*space_used/NULLIF(space_limit,0),1) pct_used FROM v$recovery_file_dest;
SELECT inst_id, resource_name, current_utilization cur, max_utilization max, limit_value FROM gv$resource_limit
WHERE  resource_name IN ('processes','sessions','transactions') ORDER BY resource_name, inst_id;

-- [1.6b] Errors in the alert log, last 2 hours  [NONE]  (can be slow on a huge alert log)
SELECT originating_timestamp, message_text message FROM v$diag_alert_ext
WHERE  originating_timestamp > SYSTIMESTAMP - INTERVAL '2' HOUR
AND   (message_text LIKE '%ORA-%' OR message_text LIKE '%Checkpoint not complete%' OR message_text LIKE '%cannot allocate new log%'
       OR message_text LIKE '%Deadlock%' OR message_text LIKE '%terminating the instance%')
ORDER  BY originating_timestamp;

-- [1.7] WHAT CHANGED?  [NONE]
-- stats gathers and other optimizer-stat operations, last 2 days
SELECT operation, target, TO_CHAR(start_time,'MM-DD HH24:MI') started, TO_CHAR(end_time,'MM-DD HH24:MI') ended
FROM   dba_optstat_operations WHERE start_time > SYSTIMESTAMP - INTERVAL '2' DAY ORDER BY start_time DESC;
-- parameters changed since startup
SELECT name, value, ismodified FROM v$parameter WHERE ismodified IN ('SYSTEM_MOD','MODIFIED') ORDER BY name;
-- last patches applied
SELECT patch_id, action, status, TO_CHAR(action_time,'YYYY-MM-DD HH24:MI') action_time, SUBSTR(description,1,70) description
FROM   dba_registry_sqlpatch ORDER BY action_time DESC FETCH FIRST 5 ROWS ONLY;
-- application objects altered in last 2 days (index dropped? column added?)
SELECT owner, object_name, object_type, last_ddl_time FROM dba_objects
WHERE  last_ddl_time > SYSDATE-2 AND oracle_maintained='N' ORDER BY last_ddl_time DESC FETCH FIRST 30 ROWS ONLY;
-- scheduler jobs and RMAN running right now (batch overlap / backup IO)
SELECT owner, job_name, running_instance, session_id, elapsed_time FROM dba_scheduler_running_jobs;
SELECT session_key, input_type, status, TO_CHAR(start_time,'MM-DD HH24:MI') started FROM v$rman_backup_job_details WHERE status='RUNNING';
-- invalid objects (invalid package = recompile on first call = slow, errors)
SELECT owner, COUNT(*) invalid_objects FROM dba_objects WHERE status='INVALID' AND oracle_maintained='N' GROUP BY owner;

-- =====================================================================================
-- 2. HOW TO FIND A SQL RUNNING SLOW
-- =====================================================================================

-- [2.1] Active sessions right now, longest-running first  [NONE]
SELECT s.inst_id, s.sid, s.serial# serial, s.username, s.sql_id, s.sql_child_number child,
       CASE WHEN s.state='WAITING' THEN s.event ELSE 'ON CPU' END event,
       ROUND(s.last_call_et/60,1) active_min, s.blocking_session blk_sid, s.module, s.program, s.machine,
       TO_CHAR(s.sql_exec_start,'HH24:MI:SS') sql_start
FROM   gv$session s
WHERE  s.type='USER' AND s.status='ACTIVE'
AND    NOT (s.inst_id = USERENV('INSTANCE') AND s.sid = USERENV('SID'))
ORDER  BY s.last_call_et DESC;

-- [2.2] Long operations in progress (full scans, sorts, RMAN, stats)  [NONE]
SELECT inst_id, sid, serial# serial, opname, target, sofar, totalwork,
       ROUND(100*sofar/NULLIF(totalwork,0),1) pct, ROUND(elapsed_seconds/60,1) elapsed_min,
       ROUND(time_remaining/60,1) remain_min, sql_id
FROM   gv$session_longops WHERE totalwork > 0 AND sofar < totalwork ORDER BY elapsed_seconds DESC;

-- [2.3] Full text of a SQL  [NONE]
SELECT inst_id, sql_id, parsing_schema_name, sql_fulltext FROM gv$sql WHERE sql_id='&sql_id' FETCH FIRST 1 ROW ONLY;

-- [2.4] Top SQL in the shared pool  [NONE]
-- Figures are cumulative since the cursor was loaded. Change ORDER BY to cpu_time, buffer_gets or disk_reads.
-- High ela_per_exec = individually slow. High ela_s with tiny per-exec = called too often.
SELECT sql_id, plan_hash_value phv, executions execs, ROUND(elapsed_time/1e6,1) ela_s,
       ROUND(elapsed_time/NULLIF(executions,0)/1e6,3) ela_per_exec, ROUND(cpu_time/1e6,1) cpu_s,
       buffer_gets, ROUND(buffer_gets/NULLIF(executions,0)) gets_per_exec, disk_reads,
       ROUND(rows_processed/NULLIF(executions,0),1) rows_per_exec, TO_CHAR(last_active_time,'MM-DD HH24:MI') last_active, sql_text
FROM   gv$sqlstats
WHERE  last_active_time > SYSDATE - 1/24
ORDER  BY elapsed_time DESC FETCH FIRST 15 ROWS ONLY;

-- [2.5] [DIAG] Top SQL by DB time, last 30 minutes (ASH, one sample per second = about one DB second)
-- Change the 30 to the window the customer reported. ASH in memory keeps only a few hours, use 2.9 for older.
SELECT sql_id, sql_plan_hash_value phv, COUNT(*) db_secs, ROUND(100*RATIO_TO_REPORT(COUNT(*)) OVER (),1) pct,
       SUM(CASE WHEN session_state='ON CPU' THEN 1 ELSE 0 END) on_cpu_secs,
       SUM(CASE WHEN session_state='WAITING' THEN 1 ELSE 0 END) wait_secs, MIN(module) module
FROM   gv$active_session_history
WHERE  sample_time > SYSTIMESTAMP - INTERVAL '30' MINUTE AND sql_id IS NOT NULL
GROUP  BY sql_id, sql_plan_hash_value ORDER BY db_secs DESC FETCH FIRST 10 ROWS ONLY;

-- [2.6] [DIAG] Top wait events, last 30 minutes (add a sql_id filter to profile one SQL)
SELECT NVL(event,'ON CPU') event, NVL(wait_class,'CPU') wait_class, COUNT(*) db_secs,
       ROUND(100*RATIO_TO_REPORT(COUNT(*)) OVER (),1) pct
FROM   gv$active_session_history
WHERE  sample_time > SYSTIMESTAMP - INTERVAL '30' MINUTE
-- AND sql_id = 'your_sql_id_here'      (remove the leading dashes to filter on one SQL)
GROUP  BY event, wait_class ORDER BY db_secs DESC FETCH FIRST 12 ROWS ONLY;

-- [2.7] [DIAG] When did it start? Average active sessions per minute, last 2 hours
SELECT TO_CHAR(CAST(sample_time AS DATE),'MM-DD HH24:MI') minute, ROUND(COUNT(*)/60,1) avg_active_sessions,
       ROUND(SUM(CASE WHEN session_state='ON CPU' THEN 1 ELSE 0 END)/60,1) on_cpu,
       ROUND(SUM(CASE WHEN wait_class='User I/O' THEN 1 ELSE 0 END)/60,1) user_io,
       ROUND(SUM(CASE WHEN wait_class IN ('Concurrency','Application','Cluster','Configuration','Commit') THEN 1 ELSE 0 END)/60,1) contention
FROM   gv$active_session_history WHERE sample_time > SYSTIMESTAMP - INTERVAL '2' HOUR
GROUP  BY TO_CHAR(CAST(sample_time AS DATE),'MM-DD HH24:MI') ORDER BY 1;

-- [2.8] [DIAG] Who is consuming DB time (user / module / program), last 30 minutes
SELECT u.username, h.module, h.program, COUNT(*) db_secs, ROUND(100*RATIO_TO_REPORT(COUNT(*)) OVER (),1) pct
FROM   gv$active_session_history h LEFT JOIN dba_users u ON u.user_id = h.user_id
WHERE  h.sample_time > SYSTIMESTAMP - INTERVAL '30' MINUTE
GROUP  BY u.username, h.module, h.program ORDER BY db_secs DESC FETCH FIRST 10 ROWS ONLY;

-- [2.9] [DIAG] The customer reported it AFTER the fact: top SQL and top events in a past window (AWR ASH, 10-second samples)
-- Enter times as YYYY-MM-DD HH24:MI, for example 2026-10-10 14:00 to 2026-10-10 15:00 (database time zone)
SELECT sql_id, sql_plan_hash_value phv, COUNT(*)*10 est_db_secs, MIN(module) module
FROM   dba_hist_active_sess_history
WHERE  sample_time BETWEEN TO_TIMESTAMP('&start_time','YYYY-MM-DD HH24:MI') AND TO_TIMESTAMP('&end_time','YYYY-MM-DD HH24:MI')
AND    sql_id IS NOT NULL
GROUP  BY sql_id, sql_plan_hash_value ORDER BY est_db_secs DESC FETCH FIRST 10 ROWS ONLY;
SELECT NVL(event,'ON CPU') event, COUNT(*)*10 est_db_secs, ROUND(100*RATIO_TO_REPORT(COUNT(*)) OVER (),1) pct
FROM   dba_hist_active_sess_history
WHERE  sample_time BETWEEN TO_TIMESTAMP('&start_time','YYYY-MM-DD HH24:MI') AND TO_TIMESTAMP('&end_time','YYYY-MM-DD HH24:MI')
GROUP  BY event ORDER BY est_db_secs DESC FETCH FIRST 10 ROWS ONLY;

-- [2.10] [DIAG] Snapshots available, then top SQL between two snapshots, then ONE SQL over time (spots plan change)
SELECT DISTINCT snap_id, TO_CHAR(begin_interval_time,'YYYY-MM-DD HH24:MI') begin_time, TO_CHAR(end_interval_time,'HH24:MI') end_time
FROM   dba_hist_snapshot WHERE begin_interval_time > SYSDATE - 2 ORDER BY snap_id;
SELECT sql_id, plan_hash_value phv, SUM(executions_delta) execs, ROUND(SUM(elapsed_time_delta)/1e6) ela_s,
       ROUND(SUM(elapsed_time_delta)/NULLIF(SUM(executions_delta),0)/1e6,3) ela_per_exec,
       ROUND(SUM(cpu_time_delta)/1e6) cpu_s, SUM(buffer_gets_delta) gets, SUM(disk_reads_delta) reads
FROM   dba_hist_sqlstat WHERE snap_id BETWEEN &begin_snap AND &end_snap
GROUP  BY sql_id, plan_hash_value ORDER BY ela_s DESC FETCH FIRST 15 ROWS ONLY;
-- Same SQL_ID over the last 7 days: did plan_hash_value change when it got slow?
SELECT s.snap_id, TO_CHAR(sn.begin_interval_time,'MM-DD HH24:MI') begin_time, s.instance_number inst, s.plan_hash_value phv,
       s.executions_delta execs, ROUND(s.elapsed_time_delta/NULLIF(s.executions_delta,0)/1e6,3) ela_per_exec,
       ROUND(s.buffer_gets_delta/NULLIF(s.executions_delta,0)) gets_per_exec, ROUND(s.rows_processed_delta/NULLIF(s.executions_delta,0),1) rows_per_exec
FROM   dba_hist_sqlstat s JOIN dba_hist_snapshot sn ON sn.snap_id=s.snap_id AND sn.dbid=s.dbid AND sn.instance_number=s.instance_number
WHERE  s.sql_id='&sql_id' AND sn.begin_interval_time > SYSDATE - 7 ORDER BY s.snap_id, s.instance_number;

-- [2.11] NOT licensed for Diagnostics Pack?  Use 1.5, 2.1 and 2.4 above, sampled repeatedly from the shell:
--   for i in $(seq 1 12); do sqlplus -s / as sysdba @active_sessions.sql; sleep 5; done      (active_sessions.sql = block 2.1)
--   or install and use Statspack: @?/rdbms/admin/spcreate.sql, then EXEC STATSPACK.SNAP and @?/rdbms/admin/spreport.sql

-- [2.12] ACTUAL PLAN of the slow SQL (the most important output)  [NONE]
-- Compare E-Rows (estimate) with A-Rows (actual). Estimate far below actual = bad statistics = bad plan.
-- A-Rows needs the statement run with /*+ GATHER_PLAN_STATISTICS */ or STATISTICS_LEVEL=ALL; otherwise use format 'TYPICAL +PEEKED_BINDS'.
SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY_CURSOR('&sql_id', NULL, 'ALLSTATS LAST +PEEKED_BINDS'));
-- plan from the past (AWR) for a given plan_hash_value  [DIAG]
SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY_AWR('&sql_id', &plan_hash_value, NULL, 'TYPICAL +PEEKED_BINDS'));
-- bind values captured
SELECT child_number child, name, position, datatype_string, value_string, TO_CHAR(last_captured,'MM-DD HH24:MI') captured
FROM   gv$sql_bind_capture WHERE sql_id='&sql_id' ORDER BY child_number, position;

-- [2.13] [TUNE] SQL Monitor: live plan with row counts and time per step
SELECT sql_id, sql_exec_id, status, username, ROUND(elapsed_time/1e6) ela_s, ROUND(cpu_time/1e6) cpu_s, buffer_gets, disk_reads,
       TO_CHAR(sql_exec_start,'HH24:MI:SS') started
FROM   gv$sql_monitor WHERE sql_exec_start > SYSDATE - 1/24 ORDER BY elapsed_time DESC FETCH FIRST 10 ROWS ONLY;
SELECT DBMS_SQLTUNE.REPORT_SQL_MONITOR(sql_id=>'&sql_id', type=>'TEXT', report_level=>'ALL') FROM dual;

-- [2.14] "Customer says MY report is slow": find their session by user, OS user or module  [NONE]
SELECT inst_id, sid, serial# serial, status, username, osuser, machine, program, module, action, sql_id, event, last_call_et secs_in_state
FROM   gv$session
WHERE  type='USER' AND (UPPER(username) LIKE UPPER('%&who%') OR UPPER(osuser) LIKE UPPER('%&who%') OR UPPER(module) LIKE UPPER('%&who%'))
ORDER  BY status, last_call_et DESC;

-- [2.15] Ready-made reports (run in SQL*Plus on the server)  [DIAG]
--   @?/rdbms/admin/awrrpt.sql      AWR report for a time window (RAC: awrgrpt.sql)
--   @?/rdbms/admin/awrddrpt.sql    COMPARE a good period with the bad period (best for "it was fast yesterday")
--   @?/rdbms/admin/awrsqrpt.sql    AWR report for one SQL_ID
--   @?/rdbms/admin/ashrpt.sql      ASH report for a short window (what happened between 14:05 and 14:20)
--   @?/rdbms/admin/addmrpt.sql     ADDM findings and recommendations

-- =====================================================================================
-- 3. SYMPTOMS  (match what the customer / the data shows, then go to the section 4 block)
-- =====================================================================================
--  Customer says / you see                         Evidence to confirm                      Go to
--  ---------------------------------------------   --------------------------------------   --------------------
--  Everything slow, all users, CPU high            AAS above CPU count, 'ON CPU' dominant    4.6 CPU, 4.7 parse
--  Everything slow, CPU low, disks busy            User I/O waits, read latency high         4.5 I/O
--  One report/job slow, rest fine                  One sql_id dominates (2.5)                4.3 plan, 4.4 stats
--  Slow since deploy / patch / stats / data load   plan_hash_value changed (2.10)            4.3, 4.4, 1.7
--  Screen hangs, nothing moves, CPU idle           enq: TX row lock, blocking_session set    4.2 blocking
--  Hangs on commit / many 'log file sync'          log file sync, archiver or FRA full       4.9 redo
--  Slow only on certain times (nightly, month end) overlap with batch, RMAN, auto stats      1.7, 4.13
--  RAC: slow only when users hit both nodes        gc buffer busy / gc cr waits              4.10 RAC
--  ORA-1555, ORA-1652 (temp), ORA-4031             undo too small, temp full, shared pool    4.11, 4.8, 4.7
--  Cannot connect / connect takes long             processes at limit, logon storm           4.14
--  Many near-identical SQL texts, high parse CPU   literals instead of bind variables        4.7
--
--  WAIT EVENT CHEAT SHEET (what the top event usually means)
--  db file sequential read     single-block index reads: bad/unselective index, poor clustering, slow disk
--  db file scattered read /    full table or index fast full scans: missing index, plan change, small cache
--    direct path read
--  direct path read/write temp sort or hash spilling to TEMP: big sort, low PGA, missing index
--  enq: TX - row lock          one session holds uncommitted row locks: application design, forgotten commit
--  enq: TM - contention        unindexed foreign key under DML (see 4.12)
--  log file sync               commit waits: too many commits, slow redo disk, SYNC standby network
--  log file switch (...)       redo logs too small, archiver stuck, FRA full, checkpoint not complete
--  library cache: mutex X /    hard parse storm, literals, invalidations, too many child cursors
--    cursor: pin S wait on X
--  latch: cache buffers chains hot block, repeated logical reads of the same blocks (bad nested loops)
--  buffer busy waits           many sessions on the same block: hot insert block, hot index, freelist
--  gc buffer busy / gc cr ...  RAC block shipping: hot blocks across nodes, slow interconnect
--  resmgr:cpu quantum          Resource Manager is throttling the consumer group
--  SQL*Net message from client IDLE, the session waits for the application (not a DB problem)

-- =====================================================================================
-- 4. ROOT CAUSE  (pick the block that matches the symptom)
-- =====================================================================================

-- [4.2a] BLOCKING: who is waiting on whom  [NONE]
SELECT s.inst_id, s.sid, s.serial# serial, s.username, s.event, s.blocking_instance b_inst, s.blocking_session b_sid,
       s.final_blocking_session root_sid, s.sql_id, ROUND(s.wait_time_micro/1e6/60,1) wait_min, s.module, s.machine
FROM   gv$session s WHERE s.blocking_session IS NOT NULL ORDER BY s.wait_time_micro DESC;
-- [4.2b] ROOT blockers with number of victims, and whether the blocker is idle (INACTIVE with open transaction = forgotten commit)
SELECT b.inst_id, b.sid, b.serial# serial, b.username, b.status, b.sql_id, b.prev_sql_id, ROUND(b.last_call_et/60,1) state_min,
       b.module, b.machine, COUNT(*) victims
FROM   gv$session w JOIN gv$session b ON b.inst_id = w.final_blocking_instance AND b.sid = w.final_blocking_session
WHERE  w.final_blocking_session IS NOT NULL
GROUP  BY b.inst_id, b.sid, b.serial#, b.username, b.status, b.sql_id, b.prev_sql_id, b.last_call_et, b.module, b.machine ORDER BY victims DESC;
-- [4.2c] Which objects are locked  [NONE]
SELECT lo.inst_id, lo.session_id sid, lo.oracle_username, o.owner, o.object_name, lo.locked_mode FROM gv$locked_object lo
JOIN   dba_objects o ON o.object_id = lo.object_id ORDER BY o.object_name;
-- [4.2d] [DIAG] Blocking history last 30 minutes
SELECT sql_id, event, blocking_session, COUNT(*) db_secs FROM gv$active_session_history
WHERE  sample_time > SYSTIMESTAMP - INTERVAL '30' MINUTE AND blocking_session IS NOT NULL
GROUP  BY sql_id, event, blocking_session ORDER BY db_secs DESC FETCH FIRST 10 ROWS ONLY;

-- [4.3a] PLAN PROBLEMS: several plans for the same SQL? Which is slow?  [NONE]
SELECT plan_hash_value phv, COUNT(*) children, SUM(executions) execs,
       ROUND(SUM(elapsed_time)/NULLIF(SUM(executions),0)/1e6,3) ela_per_exec,
       ROUND(SUM(buffer_gets)/NULLIF(SUM(executions),0)) gets_per_exec, MAX(TO_CHAR(last_active_time,'MM-DD HH24:MI')) last_active,
       MAX(sql_profile) sql_profile, MAX(sql_plan_baseline) baseline
FROM   gv$sql WHERE sql_id='&sql_id' GROUP BY plan_hash_value ORDER BY ela_per_exec DESC;
-- In the plan from 2.12 look for: TABLE ACCESS FULL on a big table with a selective filter, nested loops where E-Rows is tiny
-- but A-Rows is huge, Cartesian joins, FILTER operations, and the Note section (dynamic sampling, cardinality feedback, profile, baseline).

-- [4.3b] Tables used by the SQL: size, rows, stats age, stale?  [NONE]
SELECT p.object_owner, p.object_name, p.operation, p.options, t.num_rows, TO_CHAR(t.last_analyzed,'MM-DD HH24:MI') last_analyzed, t.stale_stats,
       (SELECT ROUND(SUM(bytes)/1048576) FROM dba_segments WHERE owner=p.object_owner AND segment_name=p.object_name) seg_mb
FROM  (SELECT DISTINCT object_owner, object_name, operation, options FROM gv$sql_plan WHERE sql_id='&sql_id' AND object_type LIKE 'TABLE%') p
LEFT   JOIN dba_tab_statistics t ON t.owner=p.object_owner AND t.table_name=p.object_name AND t.partition_name IS NULL
ORDER  BY seg_mb DESC NULLS LAST;
-- [4.3c] Existing indexes on a table (is there an index on the filter / join columns?)  [NONE]
SELECT index_name, column_position pos, column_name FROM dba_ind_columns WHERE table_owner=UPPER('&owner') AND table_name=UPPER('&tab') ORDER BY index_name, column_position;

-- [4.4] STATISTICS: stale or missing system-wide  [NONE]
-- (optional first: EXEC DBMS_STATS.FLUSH_DATABASE_MONITORING_INFO so the stale flag is current; harmless)
SELECT owner, SUM(CASE WHEN stale_stats='YES' THEN 1 ELSE 0 END) stale_tables, SUM(CASE WHEN last_analyzed IS NULL THEN 1 ELSE 0 END) no_stats_tables
FROM   dba_tab_statistics WHERE object_type='TABLE' AND partition_name IS NULL
AND    owner NOT IN (SELECT username FROM dba_users WHERE oracle_maintained='Y')
GROUP  BY owner HAVING SUM(CASE WHEN stale_stats='YES' THEN 1 ELSE 0 END) + SUM(CASE WHEN last_analyzed IS NULL THEN 1 ELSE 0 END) > 0 ORDER BY 2 DESC;
-- Locked statistics (the auto stats job skips these, so they can be years old). Compare num_rows with the real size. (Lab 02)
SELECT t.owner, t.table_name, t.stattype_locked, t.num_rows stats_rows, TO_CHAR(t.last_analyzed,'YYYY-MM-DD') last_analyzed,
       (SELECT ROUND(SUM(bytes)/1048576) FROM dba_segments s WHERE s.owner=t.owner AND s.segment_name=t.table_name) seg_mb
FROM   dba_tab_statistics t WHERE t.stattype_locked IS NOT NULL AND t.partition_name IS NULL
AND    t.owner NOT IN (SELECT username FROM dba_users WHERE oracle_maintained='Y') ORDER BY seg_mb DESC NULLS LAST;
-- In 23ai/26ai the plan from 2.12 may end with a "SQL Analysis Report" that names predicates which block index use. Read it. (Lab 02)

-- [4.5] I/O: latency of the key events (healthy: sequential read under about 10 ms spinning disk, 1 ms flash; log file parallel write a few ms)  [NONE]
SELECT event, total_waits, ROUND(time_waited_micro/NULLIF(total_waits,0)/1000,2) avg_ms
FROM   v$system_event
WHERE  event IN ('db file sequential read','db file scattered read','direct path read','log file sync','log file parallel write','direct path read temp')
ORDER  BY event;
-- distribution (are there many slow outliers?)
SELECT event, wait_time_milli ms_bucket, wait_count, ROUND(100*RATIO_TO_REPORT(wait_count) OVER (PARTITION BY event),1) pct
FROM   v$event_histogram WHERE event IN ('db file sequential read','log file sync','log file parallel write') ORDER BY event, wait_time_milli;
-- [4.5b] [DIAG] Hot objects by waits, last 30 minutes (which table/index is being hammered)
SELECT o.owner, o.object_name, o.object_type, NVL(h.event,'ON CPU') event, COUNT(*) db_secs
FROM   gv$active_session_history h JOIN dba_objects o ON o.object_id = h.current_obj#
WHERE  h.sample_time > SYSTIMESTAMP - INTERVAL '30' MINUTE AND h.current_obj# > 0
GROUP  BY o.owner, o.object_name, o.object_type, h.event ORDER BY db_secs DESC FETCH FIRST 15 ROWS ONLY;

-- [4.6] CPU: top consumers and where the time goes (DB CPU vs parse vs wait; cumulative since startup)  [NONE]
SELECT stat_name, ROUND(value/1e6) secs FROM v$sys_time_model
WHERE  stat_name IN ('DB time','DB CPU','sql execute elapsed time','parse time elapsed','hard parse elapsed time','PL/SQL execution elapsed time') ORDER BY value DESC;
SELECT s.inst_id, s.sid, s.serial# serial, s.username, s.sql_id, ROUND(st.value/100) cpu_secs, s.module
FROM   gv$sesstat st JOIN gv$statname n ON n.statistic#=st.statistic# AND n.inst_id=st.inst_id
JOIN   gv$session s ON s.sid=st.sid AND s.inst_id=st.inst_id
WHERE  n.name='CPU used by this session' AND s.type='USER' ORDER BY st.value DESC FETCH FIRST 10 ROWS ONLY;

-- [4.7] PARSING / LITERALS: same statement with different literals flooding the shared pool  [NONE]
SELECT force_matching_signature, COUNT(*) copies, MIN(sql_id) sample_sql_id, SUBSTR(MIN(sql_text),1,80) sample_text
FROM   v$sqlarea WHERE force_matching_signature <> 0 GROUP BY force_matching_signature HAVING COUNT(*) > 50 ORDER BY copies DESC FETCH FIRST 10 ROWS ONLY;
SELECT name, value FROM v$sysstat WHERE name IN ('parse count (total)','parse count (hard)','execute count','session cursor cache hits');
SELECT pool, name, ROUND(bytes/1048576) mb FROM v$sgastat WHERE pool='shared pool' AND name='free memory';

-- [4.8] TEMP and PGA: top temp users, PGA health  [NONE]
SELECT s.inst_id, s.sid, s.serial# serial, s.username, u.sql_id, u.tablespace, u.segtype, ROUND(u.blocks*ts.block_size/1048576) temp_mb
FROM   gv$tempseg_usage u JOIN gv$session s ON s.saddr=u.session_addr AND s.inst_id=u.inst_id
JOIN   dba_tablespaces ts ON ts.tablespace_name=u.tablespace ORDER BY temp_mb DESC FETCH FIRST 10 ROWS ONLY;
SELECT name, value, unit FROM v$pgastat WHERE name IN ('aggregate PGA target parameter','total PGA allocated','total PGA inuse','maximum PGA allocated','over allocation count','cache hit percentage');

-- [4.9] REDO / COMMIT / ARCHIVER  [NONE]
-- more than about 6 log switches per hour at peak = logs too small
SELECT TO_CHAR(first_time,'MM-DD HH24') hour, COUNT(*) log_switches FROM v$log_history WHERE first_time > SYSDATE-1 GROUP BY TO_CHAR(first_time,'MM-DD HH24') ORDER BY 1;
SELECT thread#, group#, ROUND(bytes/1048576) mb, members, status, archived FROM v$log ORDER BY thread#, group#;
SELECT dest_id, status, error FROM v$archive_dest WHERE status <> 'INACTIVE';
SELECT name, value FROM v$dataguard_stats WHERE name IN ('transport lag','apply lag');
-- FRA full: see 1.6a.   Commit rate: SELECT value FROM v$sysstat WHERE name='user commits';

-- [4.10] RAC: global cache waits (average above about 2 ms = look at interconnect and hot blocks)  [NONE]
SELECT inst_id, event, total_waits, ROUND(time_waited_micro/NULLIF(total_waits,0)/1000,2) avg_ms
FROM   gv$system_event WHERE event LIKE 'gc%' AND total_waits > 0 ORDER BY time_waited_micro DESC FETCH FIRST 10 ROWS ONLY;
SELECT * FROM gv$cluster_interconnects;

-- [4.11] UNDO and long transactions  [NONE]
SELECT s.inst_id, s.sid, s.serial# serial, s.username, s.status, t.start_time, t.used_ublk undo_blocks, t.used_urec undo_records, s.sql_id, s.machine
FROM   gv$transaction t JOIN gv$session s ON s.saddr=t.ses_addr AND s.inst_id=t.inst_id ORDER BY t.used_ublk DESC;
-- ssolderrcnt greater than 0 = ORA-1555 happening, nospaceerrcnt greater than 0 = undo full
SELECT TO_CHAR(begin_time,'HH24:MI') begin_time, undoblks, txncount, maxquerylen, ssolderrcnt, nospaceerrcnt FROM v$undostat ORDER BY begin_time DESC FETCH FIRST 12 ROWS ONLY;
-- rollback in progress (after a kill): estimated time left
SELECT usn, state, undoblocksdone, undoblockstotal, cputime FROM v$fast_start_transactions;

-- [4.12] MISSING FOREIGN-KEY INDEXES (cause of enq: TM and deadlocks). Approximate: FK first column not leading column of any index  [NONE]
SELECT c.owner, c.table_name, c.constraint_name FROM dba_constraints c
WHERE  c.constraint_type='R' AND c.owner=UPPER('&owner')
AND    NOT EXISTS (SELECT 1 FROM dba_cons_columns cc JOIN dba_ind_columns ic ON ic.table_owner=cc.owner AND ic.table_name=cc.table_name
                   AND ic.column_name=cc.column_name AND ic.column_position=1
                   WHERE cc.owner=c.owner AND cc.constraint_name=c.constraint_name AND cc.position=1);

-- [4.13] BACKGROUND LOAD: auto tasks, jobs, parallel, backups competing with users  [NONE]
SELECT client_name, status FROM dba_autotask_client;
SELECT window_name, window_active FROM dba_autotask_window_clients;
SELECT qcsid, COUNT(*) px_servers, MAX(degree) dop FROM gv$px_session WHERE qcsid IS NOT NULL GROUP BY qcsid;
-- scheduler and RMAN: see 1.7

-- [4.14] CONNECTIONS: storm or leak?  [NONE]
SELECT inst_id, COUNT(*) sessions, SUM(CASE WHEN status='ACTIVE' THEN 1 ELSE 0 END) active FROM gv$session WHERE type='USER' GROUP BY inst_id;
SELECT machine, program, COUNT(*) sessions FROM gv$session WHERE type='USER' GROUP BY machine, program ORDER BY sessions DESC FETCH FIRST 10 ROWS ONLY;
--   shell:  lsnrctl status   and   tail -200 $ORACLE_BASE/diag/tnslsnr/<host>/listener/trace/listener.log

-- =====================================================================================
-- 5. FIX  (TEMPLATES, COMMENTED OUT ON PURPOSE, run only with approval; every item shows risk and rollback)
--    Test in non-production first. Record current values before changing anything.
-- =====================================================================================
-- [5.1] Stale/missing stats.  Risk: LOW-MEDIUM (plans for that table can change; new plans use new stats)
--   Check history retention:  SELECT DBMS_STATS.GET_STATS_HISTORY_RETENTION FROM dual;
--   EXEC DBMS_STATS.GATHER_TABLE_STATS(ownname=>'&owner', tabname=>'&tab', cascade=>TRUE, estimate_percent=>DBMS_STATS.AUTO_SAMPLE_SIZE, method_opt=>'FOR ALL COLUMNS SIZE AUTO');
--   Existing cursors are invalidated gradually (AUTO_INVALIDATE). no_invalidate=>FALSE forces it now but causes a hard-parse burst.
--   Correlated columns:  SELECT DBMS_STATS.CREATE_EXTENDED_STATS('&owner','&tab','(COL1,COL2)') FROM dual;  then gather stats again.
--   ROLLBACK: EXEC DBMS_STATS.RESTORE_TABLE_STATS('&owner','&tab', SYSTIMESTAMP - INTERVAL '1' HOUR);
--   Slow dictionary / V$ queries? also consider EXEC DBMS_STATS.GATHER_DICTIONARY_STATS and GATHER_FIXED_OBJECTS_STATS (off-peak).

-- [5.2] Plan regression, force the known-good plan with SQL Plan Management.  Risk: LOW (EE feature).  Good plan must still exist.
--   From cursor cache:
--   DECLARE n PLS_INTEGER; BEGIN n := DBMS_SPM.LOAD_PLANS_FROM_CURSOR_CACHE(sql_id=>'&sql_id', plan_hash_value=>&good_phv); DBMS_OUTPUT.PUT_LINE(n||' plan(s) loaded'); END;
--   /
--   From AWR (good plan no longer in memory) [DIAG]:
--   EXEC DBMS_SQLTUNE.CREATE_SQLSET('STS_FIX');
--   DECLARE c DBMS_SQLTUNE.SQLSET_CURSOR; BEGIN
--     OPEN c FOR SELECT VALUE(p) FROM TABLE(DBMS_SQLTUNE.SELECT_WORKLOAD_REPOSITORY(begin_snap=>&begin_snap, end_snap=>&end_snap,
--                basic_filter=>'sql_id=''&sql_id'' AND plan_hash_value=&good_phv', attribute_list=>'ALL')) p;
--     DBMS_SQLTUNE.LOAD_SQLSET('STS_FIX', c); CLOSE c; END;
--   /
--   DECLARE n PLS_INTEGER; BEGIN n := DBMS_SPM.LOAD_PLANS_FROM_SQLSET(sqlset_name=>'STS_FIX'); END;
--   /
--   Verify: SELECT sql_handle, plan_name, enabled, accepted, fixed FROM dba_sql_plan_baselines ORDER BY created DESC FETCH FIRST 5 ROWS ONLY;
--   ROLLBACK: EXEC DBMS_SPM.DROP_SQL_PLAN_BASELINE(sql_handle=>'<handle>', plan_name=>'<plan_name>');

-- [5.3] SQL Tuning Advisor.  Risk: LOW to run (uses resources, run off-peak) / MEDIUM to accept a profile.  [TUNE]
--   DECLARE t VARCHAR2(64); BEGIN t := DBMS_SQLTUNE.CREATE_TUNING_TASK(sql_id=>'&sql_id', scope=>DBMS_SQLTUNE.SCOPE_COMPREHENSIVE, time_limit=>300, task_name=>'TUNE_&sql_id');
--     DBMS_SQLTUNE.EXECUTE_TUNING_TASK(t); END;
--   /
--   SELECT DBMS_SQLTUNE.REPORT_TUNING_TASK('TUNE_&sql_id') FROM dual;
--   Accept only if you understand it:  EXEC DBMS_SQLTUNE.ACCEPT_SQL_PROFILE(task_name=>'TUNE_&sql_id', name=>'PROF_&sql_id');
--   ROLLBACK: EXEC DBMS_SQLTUNE.DROP_SQL_PROFILE(name=>'PROF_&sql_id');

-- [5.4] Missing index.  Risk: MEDIUM (extra DML cost and redo, can change other plans). Test as INVISIBLE first.
--   CREATE INDEX &owner..&idx ON &owner..&tab (col1, col2) INVISIBLE ONLINE;      -- ONLINE needs Enterprise Edition
--   ALTER SESSION SET optimizer_use_invisible_indexes = TRUE;                      -- test the query in this session only, check plan and timing
--   ALTER INDEX &owner..&idx VISIBLE;                                              -- make it live only after the test passes
--   ROLLBACK: DROP INDEX &owner..&idx;
--   Unindexed foreign key found in 4.12: same pattern on the FK columns.

-- [5.5] Blocking session.  Risk: MEDIUM-HIGH. Contact the application owner first. Confirm root blocker from 4.2b (not a victim).
--   ALTER SYSTEM KILL SESSION '&sid,&serial,@&inst' IMMEDIATE;
--   Only cancel the running SQL (18c+):  ALTER SYSTEM CANCEL SQL '&sid,&serial,@&inst,&sql_id';
--   Rollback of the killed transaction takes about as long as it ran: watch 4.11 (v$fast_start_transactions). Do not kill SMON/PMON/background.
--   Not reversible: the killed work is lost.

-- [5.6] TEMP / PGA.  Risk: LOW-MEDIUM. Record the old value first (SHOW PARAMETER pga).
--   ALTER TABLESPACE temp ADD TEMPFILE SIZE 8G AUTOEXTEND ON NEXT 1G MAXSIZE 32G;      ROLLBACK: ALTER TABLESPACE temp DROP TEMPFILE '<file>';
--   ALTER SYSTEM SET pga_aggregate_target = <new> SCOPE=BOTH SID='*';                  ROLLBACK: set the old value. Check free OS memory first (1.2).

-- [5.7] Redo / archiver / FRA.  Risk: MEDIUM.
--   Logs too small (more than 6 switches per hour):  ALTER DATABASE ADD LOGFILE THREAD 1 GROUP <n> SIZE 2G;  then drop old smaller groups when INACTIVE.
--   FRA full: raise  ALTER SYSTEM SET db_recovery_file_dest_size = <bigger> SCOPE=BOTH;  Delete archivelogs ONLY after confirming they are backed up
--   and applied on every standby (RMAN: BACKUP ARCHIVELOG ALL; then DELETE ARCHIVELOG ... per your retention policy). Never rm files at OS level.

-- [5.8] Literals / parse storm.  Real fix is bind variables in the application.
--   Stopgap, Risk: MEDIUM (can change plans):  ALTER SYSTEM SET cursor_sharing = FORCE SCOPE=BOTH;     ROLLBACK: ALTER SYSTEM SET cursor_sharing = EXACT SCOPE=BOTH;

-- [5.9] Force a re-parse of ONE bad cursor (instead of flushing the whole shared pool).  Risk: LOW.
--   SELECT address, hash_value FROM v$sqlarea WHERE sql_id='&sql_id';
--   EXEC SYS.DBMS_SHARED_POOL.PURGE('&address,&hash_value','C');

-- [5.10] Deadlocks / app locking / unindexed FK / forgotten commits: fix in the application or schema (5.4); kill only as in 5.5.

-- =====================================================================================
-- 6. VALIDATION  (prove it is fixed, and that nothing else broke)
-- =====================================================================================
-- [6.1] Same SQL, per plan: elapsed and gets per execution now (compare with the "before" numbers from 2.4 / 2.10)  [NONE]
SELECT plan_hash_value phv, executions execs, ROUND(elapsed_time/NULLIF(executions,0)/1e6,3) ela_per_exec,
       ROUND(buffer_gets/NULLIF(executions,0)) gets_per_exec, sql_profile, sql_plan_baseline, TO_CHAR(last_active_time,'MM-DD HH24:MI') last_active
FROM   gv$sql WHERE sql_id='&sql_id' ORDER BY last_active_time DESC;
-- Re-run the statement yourself with SET TIMING ON and the hint /*+ GATHER_PLAN_STATISTICS */ then run 2.12: A-Time and Buffers should drop.
-- [6.2] Baseline accepted and being used?  [NONE]
SELECT sql_handle, plan_name, enabled, accepted, fixed, origin, TO_CHAR(last_executed,'MM-DD HH24:MI') last_executed
FROM   dba_sql_plan_baselines WHERE signature IN (SELECT exact_matching_signature FROM v$sql WHERE sql_id='&sql_id');
-- [6.3] System back to normal: re-run 1.3 (AAS near its usual value), 1.5 (no dominant wait), 4.2a (no rows), 1.6b (no new ORA- errors), and 2.7 (curve drops after the fix time).
-- [6.4] No collateral damage: other SQL whose plan changed in the last 24 hours  [DIAG]
SELECT sql_id, COUNT(DISTINCT plan_hash_value) plans FROM dba_hist_sqlstat
WHERE  snap_id IN (SELECT snap_id FROM dba_hist_snapshot WHERE begin_interval_time > SYSDATE-1)
GROUP  BY sql_id HAVING COUNT(DISTINCT plan_hash_value) > 1 ORDER BY plans DESC FETCH FIRST 20 ROWS ONLY;
-- [6.5] Ask the customer to repeat the exact action, note the new time, and record before/after in the ticket.
--       Watch for 1 to 2 hours (or one full business cycle): repeat 2.5 and 1.3 every 15 minutes.
--       Sign-off checklist:  [ ] timing matches the expected baseline  [ ] no blocking  [ ] no new alert-log errors
--                            [ ] FRA/tablespaces healthy  [ ] change documented with rollback  [ ] prevention item raised (section 7)

-- =====================================================================================
-- 7. PREVENTION
-- =====================================================================================
-- [7.1] Keep enough history to answer "what changed" later  [DIAG]
SELECT snap_interval, retention FROM dba_hist_wr_control;
--   EXEC DBMS_WORKLOAD_REPOSITORY.MODIFY_SNAPSHOT_SETTINGS(retention=>43200, interval=>30);   -- 30 days, 30-minute snapshots (check SYSAUX space)
--   Save a "normal" period to compare against later:
--   EXEC DBMS_WORKLOAD_REPOSITORY.CREATE_BASELINE(start_snap_id=>&b_snap, end_snap_id=>&e_snap, baseline_name=>'NORMAL_BUSINESS_HOURS');
-- [7.2] Statistics hygiene: auto stats task must be ENABLED, gather after bulk loads, lock stats on volatile staging tables  [NONE]
SELECT client_name, status FROM dba_autotask_client WHERE client_name = 'auto optimizer stats collection';
-- [7.3] Plan stability: baseline the 10 to 20 business-critical SQL (5.2), review DBA_SQL_PLAN_BASELINES monthly,
--       capture a good-plan baseline BEFORE each patch, upgrade or major release.
-- [7.4] Alert thresholds (OEM, Zabbix, Nagios, cron + health check): tablespace 85/95 percent, FRA 80 percent, AAS above 80 percent of CPU for 10 minutes,
--       log switches above 6 per hour, blocking longer than 60 seconds, processes above 85 percent of limit, standby lag, failed backups, long-running jobs.
--       Schedule DB_Health_Check.sql / db_healthcheck.sql daily and keep the output.
-- [7.5] Index hygiene: find unused indexes before adding more (12.2+), drop only after a full business cycle, test with INVISIBLE first  [NONE]
SELECT name index_name, owner, total_access_count, TO_CHAR(last_used,'YYYY-MM-DD') last_used FROM dba_index_usage WHERE owner=UPPER('&owner') ORDER BY total_access_count;
--       Re-run 4.12 for unindexed foreign keys after each schema release.
-- [7.6] Application standards: bind variables, no function on an indexed column, no implicit datatype conversion, pagination for big result sets,
--       bulk operations instead of row-by-row loops, commit at transaction boundaries only, connection pool with a sensible maximum.
--       Test releases against production-like data and statistics and compare plans before go-live (copy stats with DBMS_STATS.EXPORT_SCHEMA_STATS).
-- [7.7] Capacity and scheduling: trend data growth monthly, archive or partition old data, keep RMAN, stats and batch jobs in separate windows,
--       use Resource Manager to protect OLTP from batch, set profile limits (sessions per user, idle time) to stop connection leaks.
-- [7.8] Post-incident: write the root cause, the evidence queries (this file's block numbers), the fix and the prevention action in the ticket,
--       then add a monitor for it so the next occurrence is caught before the customer calls.
