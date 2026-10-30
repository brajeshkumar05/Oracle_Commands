--DB Health check

--Clusterware and ASM (grid user)
# Set the Grid environment (type +ASM1 or +ASM2 when prompted for the SID)
. oraenv

# 1. Is clusterware up on every node?
crsctl check cluster -all
crsctl check crs

# 2. Node list with node number and status
olsnodes -n -s -t

# 3. All cluster resources in a table (look for anything OFFLINE or UNKNOWN that shouldnt be)
crsctl stat res -t

# 4. Lower-stack (init) resources: ohasd, cssd, crsd, evmd, gpnpd
crsctl stat res -t -init

# 5. Voting disks and OCR integrity
crsctl query css votedisk
ocrcheck

# 6. Network: interfaces, interconnect, VIPs, SCAN
oifcfg getif
srvctl status nodeapps
srvctl status scan
srvctl status scan_listener
srvctl status listener

# 7. ASM instances and disk groups
srvctl status asm
asmcmd lsdg

--crsctl check cluster -all: CRS, CSS and EVM all show “online” on every node.
--crsctl stat res -t: TARGET and STATE match (both ONLINE) for every resource.
--ocrcheck: “Cluster registry integrity check succeeded” and “Device/File integrity check succeeded”.
--asmcmd lsdg: State is MOUNTED, and Usable_file_MB is positive with a healthy free percentage.

--Database, instances and services (oracle user)
. oraenv                      # enter your database name or instance SID

# Replace <db_unique_name> with your DB (srvctl config database lists them)
srvctl config database
srvctl status database -d <db_unique_name> -v
srvctl status service  -d <db_unique_name>
srvctl config service  -d <db_unique_name>

--SQL health snapshot (RAC-wide, from any one node)
Connect with sqlplus / as sysdba

SET LINESIZE 220 PAGESIZE 100 FEEDBACK OFF VERIFY OFF TRIMSPOOL ON
COL inst_id FORMAT 99
COL instance_name FORMAT A12
COL host_name FORMAT A28
COL version FORMAT A12
COL status FORMAT A10
COL tablespace_name FORMAT A25
COL name FORMAT A32
COL value FORMAT A20
COL event FORMAT A40
COL username FORMAT A15
COL ip_address FORMAT A18

PROMPT ===== 1. Instances (all nodes) =====
SELECT inst_id, instance_name, host_name, version, status, database_status,
       TO_CHAR(startup_time,'YYYY-MM-DD HH24:MI') startup
FROM   gv$instance ORDER BY inst_id;

PROMPT ===== 2. Database =====
SELECT name, db_unique_name, database_role, open_mode, log_mode, force_logging FROM v$database;

PROMPT ===== 3. ASM disk groups =====
COL name FORMAT A15
SELECT name, state, type, total_mb, free_mb,
       ROUND(100*free_mb/NULLIF(total_mb,0),1) pct_free, usable_file_mb
FROM   v$asm_diskgroup ORDER BY name;

PROMPT ===== 4. ASM disks not ONLINE (expect no rows) =====
SELECT group_number, disk_number, name, mode_status, state, path
FROM   v$asm_disk WHERE mode_status <> 'ONLINE' OR state NOT IN ('NORMAL','MEMBER');

PROMPT ===== 5. Tablespaces above 85 percent (expect none or known) =====
SELECT tablespace_name, ROUND(used_percent,1) used_pct
FROM   dba_tablespace_usage_metrics WHERE used_percent > 85 ORDER BY 2 DESC;

PROMPT ===== 6. FRA usage =====
SELECT ROUND(space_limit/1048576) limit_mb, ROUND(space_used/1048576) used_mb,
       ROUND(100*space_used/NULLIF(space_limit,0),1) pct_used FROM v$recovery_file_dest;

PROMPT ===== 7. RMAN backups, last 48h =====
COL input_type FORMAT A12
SELECT input_type, status, TO_CHAR(end_time,'YYYY-MM-DD HH24:MI') end_time
FROM   v$rman_backup_job_details WHERE end_time > SYSDATE-2 ORDER BY end_time DESC;

PROMPT ===== 8. Sessions per instance =====
SELECT inst_id, COUNT(*) total, SUM(CASE WHEN status='ACTIVE' AND type='USER' THEN 1 ELSE 0 END) active_user
FROM   gv$session GROUP BY inst_id ORDER BY inst_id;

PROMPT ===== 9. Blocking sessions across instances (expect none) =====
SELECT inst_id, sid, serial# serial_no, username, blocking_instance, blocking_session, event, seconds_in_wait
FROM   gv$session WHERE blocking_session IS NOT NULL ORDER BY seconds_in_wait DESC;

PROMPT ===== 10. Interconnect in use =====
SELECT inst_id, name, ip_address, is_public, source FROM gv$cluster_interconnects ORDER BY inst_id;

PROMPT ===== 11. Invalid objects by owner =====
COL owner FORMAT A20
SELECT owner, COUNT(*) invalid_cnt FROM dba_objects WHERE status='INVALID'
AND owner NOT IN (SELECT username FROM dba_users WHERE oracle_maintained='Y') GROUP BY owner;

PROMPT ===== 12. Top non-idle waits (instance lifetime) =====
SELECT inst_id, event, total_waits, ROUND(time_waited_micro/1e6) secs
FROM   gv$system_event WHERE wait_class <> 'Idle'
ORDER  BY time_waited_micro DESC FETCH FIRST 10 ROWS ONLY;

--Logs (error check)
# Grid (clusterware) alert log. Look for evictions, CRS-xxxx errors, voting disk or network messages
tail -200 $ORACLE_BASE/diag/crs/$(hostname -s)/crs/trace/alert.log

# Database alert log via adrci
adrci
adrci> show homes
adrci> set home diag/rdbms/<db_unique_name>/<instance_name>
adrci> show alert -p "message_text like '%ORA-%'" -term
adrci> show problem
adrci> exit

--On a node-eviction RCA, also check ocssd.log and crsd.log under the same trace directory, 
--plus /var/log/messages around the event time.

