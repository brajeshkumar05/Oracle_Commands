
-- =============================================================================
-- sql_diag.sql  v2
-- Comprehensive SQL diagnostic: profiles, patches, baselines, plans, monitors
-- Usage: @sql_diag.sql
-- =============================================================================
SET PAGESIZE 200 LINESIZE 250 LONG 100000 LONGCHUNKSIZE 100000
SET SERVEROUTPUT ON SIZE UNLIMITED
SET TRIMOUT ON TRIMSPOOL ON

ACCEPT v_sqlid PROMPT 'Enter SQL_ID: '

PROMPT
PROMPT ========================================================================
PROMPT SECTION 1 - SQL TEXT
PROMPT ========================================================================

SELECT sql_id, DBMS_LOB.SUBSTR(sql_text, 2000, 1) AS sql_text_first_2k
FROM   dba_hist_sqltext
WHERE  sql_id = '&v_sqlid' AND ROWNUM = 1;

PROMPT
PROMPT ========================================================================
PROMPT SECTION 2 - SQL PROFILE / PATCH / BASELINE STATUS
PROMPT ========================================================================

SELECT name, category, status, force_matching, created
FROM   dba_sql_profiles
WHERE  name LIKE '%&v_sqlid%';

SELECT name, category, status, force_matching, created
FROM   dba_sql_patches
WHERE  name LIKE '%&v_sqlid%';

SELECT b.sql_handle, b.plan_name, b.origin, b.enabled, b.accepted,
       b.fixed, b.optimizer_cost, b.created
FROM   dba_sql_plan_baselines b
WHERE  b.sql_handle IN (
         SELECT DISTINCT q.sql_plan_baseline
         FROM   gv$sql q WHERE q.sql_id = '&v_sqlid'
         AND    q.sql_plan_baseline IS NOT NULL
       );

PROMPT
PROMPT ========================================================================
PROMPT SECTION 3 - CURRENT CURSOR CHILDREN (gv$sql)
PROMPT ========================================================================

SELECT inst_id, sql_id, child_number, plan_hash_value,
       executions, elapsed_time/GREATEST(executions,1)/1000 AS avg_ms,
       buffer_gets/GREATEST(executions,1) AS avg_gets,
       rows_processed/GREATEST(executions,1) AS avg_rows,
       sql_profile, sql_patch, sql_plan_baseline,
       is_bind_sensitive, is_bind_aware, is_shareable,
       object_status, last_active_time
FROM   gv$sql
WHERE  sql_id = '&v_sqlid'
ORDER  BY inst_id, child_number;

PROMPT
PROMPT ========================================================================
PROMPT SECTION 4 - CHILD CURSOR REASONS (why multiple children)
PROMPT ========================================================================

SELECT inst_id, child_number, reason
FROM   gv$sql_shared_cursor
WHERE  sql_id = '&v_sqlid'
AND    reason IS NOT NULL
ORDER  BY inst_id, child_number;

PROMPT
PROMPT ========================================================================
PROMPT SECTION 5 - LIVE EXECUTION PLAN (from cursor, ALLSTATS LAST)
PROMPT ========================================================================

SELECT * FROM TABLE(
  DBMS_XPLAN.DISPLAY_CURSOR('&v_sqlid', NULL, 'ALLSTATS LAST +OUTLINE +HINT_REPORT')
);

PROMPT
PROMPT ========================================================================
PROMPT SECTION 6 - ALL AWR PLAN HASH VALUES (history of plan changes)
PROMPT ========================================================================

SELECT plan_hash_value,
       MIN(snap_id) AS first_snap, MAX(snap_id) AS last_snap,
       SUM(executions_delta) AS total_execs,
       ROUND(SUM(elapsed_time_delta)/GREATEST(SUM(executions_delta),1)/1000, 2) AS avg_ms,
       ROUND(SUM(buffer_gets_delta)/GREATEST(SUM(executions_delta),1), 0) AS avg_gets,
       ROUND(SUM(clwait_delta)*100/GREATEST(SUM(elapsed_time_delta),1), 1) AS pct_cluster,
       ROUND(SUM(iowait_delta)*100/GREATEST(SUM(elapsed_time_delta),1), 1) AS pct_io,
       MIN(TO_CHAR(s.begin_interval_time,'YYYY-MM-DD HH24:MI')) AS first_seen,
       MAX(TO_CHAR(s.end_interval_time,'YYYY-MM-DD HH24:MI')) AS last_seen
FROM   dba_hist_sqlstat ss
JOIN   dba_hist_snapshot s ON s.snap_id = ss.snap_id AND s.dbid = ss.dbid
       AND s.instance_number = ss.instance_number
WHERE  ss.sql_id = '&v_sqlid'
GROUP  BY plan_hash_value
ORDER  BY total_execs DESC;

PROMPT
PROMPT ========================================================================
PROMPT SECTION 7 - AWR PLAN DETAILS (top plans by execution count)
PROMPT ========================================================================

SELECT * FROM TABLE(
  DBMS_XPLAN.DISPLAY_AWR('&v_sqlid', NULL, NULL, 'ADVANCED +OUTLINE')
)
WHERE ROWNUM <= 500;

PROMPT
PROMPT ========================================================================
PROMPT SECTION 8 - SQL MONITOR (most recent execution)
PROMPT ========================================================================

SELECT DBMS_SQLTUNE.report_sql_monitor(
         sql_id      => '&v_sqlid',
         type        => 'TEXT',
         report_level => 'ALL'
       ) AS report
FROM   dual;

PROMPT
PROMPT ========================================================================
PROMPT SECTION 9 - ASH WAIT PROFILE (last 2 hours)
PROMPT ========================================================================

SELECT wait_class, event, inst_id,
       COUNT(*) AS samples,
       ROUND(COUNT(*)*100/SUM(COUNT(*)) OVER (), 2) AS pct
FROM   gv$active_session_history
WHERE  sql_id = '&v_sqlid'
AND    sample_time > SYSDATE - INTERVAL '120' MINUTE
GROUP  BY wait_class, event, inst_id
ORDER  BY samples DESC;

PROMPT
PROMPT ========================================================================
PROMPT SECTION 10 - ACTIVE SESSIONS RIGHT NOW
PROMPT ========================================================================

SELECT s.inst_id, s.sid, s.serial#, s.status, s.event,
       s.seconds_in_wait, s.blocking_session, s.blocking_instance,
       s.sql_profile, s.sql_child_number,
       q.plan_hash_value AS cursor_phv
FROM   gv$session s
LEFT   JOIN gv$sql q
       ON q.sql_id = s.sql_id AND q.inst_id = s.inst_id
       AND q.child_number = s.sql_child_number
WHERE  s.sql_id = '&v_sqlid'
ORDER  BY s.inst_id, s.sid;

PROMPT
PROMPT ========================================================================
PROMPT SECTION 11 - BIND VALUES (from sql_monitor)
PROMPT ========================================================================

SELECT sql_exec_id, inst_id,
       TO_CHAR(sql_exec_start, 'YYYY-MM-DD HH24:MI:SS') AS exec_start,
       elapsed_time/1000000 AS elapsed_sec,
       status, sql_plan_hash_value,
       binds_xml
FROM   gv$sql_monitor
WHERE  sql_id = '&v_sqlid'
AND    sql_exec_start > SYSDATE - INTERVAL '4' HOUR
ORDER  BY sql_exec_start DESC
FETCH  FIRST 10 ROWS ONLY;

PROMPT
PROMPT ========================================================================
PROMPT SECTION 12 - RELATED INDEXES
PROMPT ========================================================================

SELECT ic.index_name, ic.column_name, ic.column_position,
       i.uniqueness, i.partitioned, i.visibility, i.status,
       CASE WHEN i.index_type LIKE '%GLOBAL%' THEN 'GLOBAL' ELSE 'LOCAL' END AS scope
FROM   dba_ind_columns ic
JOIN   dba_indexes i ON i.owner = ic.index_owner AND i.index_name = ic.index_name
WHERE  ic.table_name IN (
         SELECT DISTINCT object_name
         FROM   dba_hist_sql_plan
         WHERE  sql_id = '&v_sqlid'
         AND    object_name IS NOT NULL
       )
AND    ic.index_owner IN ('QWEB29','GRC')
ORDER  BY ic.table_name, ic.index_name, ic.column_position;

SET PAGESIZE 14 LINESIZE 80
PROMPT
PROMPT ========================================================================
PROMPT DONE
PROMPT ========================================================================
