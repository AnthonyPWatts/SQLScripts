DECLARE @StartTime DATETIME = DATEADD(day, -30, GETDATE());
DECLARE @EndTime DATETIME   = GETDATE();

WITH SprocStats AS (
    SELECT
        OBJECT_NAME(st.objectid, st.dbid) AS sproc_name,
        qs.execution_count,
        qs.total_elapsed_time / 1000.0 AS total_elapsed_ms,
        qs.total_worker_time / 1000.0 AS total_cpu_ms,
        qs.total_logical_reads AS total_reads,
        qs.total_physical_reads AS total_physical_reads,
        qs.creation_time,
        qs.last_execution_time,
        st.text AS sql_text
    FROM sys.dm_exec_query_stats AS qs
    CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS st
    WHERE st.dbid = DB_ID()
      AND OBJECT_NAME(st.objectid, st.dbid) IS NOT NULL
      AND qs.creation_time >= @StartTime
      AND qs.last_execution_time <= @EndTime
),
-- Calculate max values to normalize sparkline bars
MaxVals AS (
    SELECT
        MAX(total_elapsed_ms / execution_count) AS max_elapsed,
        MAX(total_cpu_ms / execution_count) AS max_cpu,
        MAX(total_reads / execution_count) AS max_reads
    FROM SprocStats
),
-- Create normalized “sparklines”
Dashboard AS (
    SELECT TOP 20
        s.sproc_name,
        s.execution_count,
        s.total_elapsed_ms / s.execution_count AS avg_elapsed_ms,
        s.total_cpu_ms / s.execution_count AS avg_cpu_ms,
        s.total_reads / s.execution_count AS avg_reads_per_exec,
        
        -- Sparkline bars using ▇ Unicode block
        REPLICATE('▇', CAST(ROUND((s.total_elapsed_ms / s.execution_count) / m.max_elapsed * 20,0) AS INT)) AS elapsed_bar,
        REPLICATE('▇', CAST(ROUND((s.total_cpu_ms / s.execution_count) / m.max_cpu * 20,0) AS INT)) AS cpu_bar,
        REPLICATE('▇', CAST(ROUND((s.total_reads / s.execution_count) / m.max_reads * 20,0) AS INT)) AS reads_bar,
        
        -- Flags
        CASE 
            WHEN s.total_elapsed_ms / s.execution_count > 5000 THEN '🔥 VERY SLOW'
            WHEN s.total_elapsed_ms / s.execution_count > 2000 THEN '⚠️ Slow'
            ELSE '✅ OK'
        END AS elapsed_flag,
        
        CASE
            WHEN s.total_cpu_ms / s.execution_count > 2000 THEN '⚡ HIGH CPU'
            WHEN s.total_cpu_ms / s.execution_count > 1000 THEN '⚡ Moderate CPU'
            ELSE '✅ OK'
        END AS cpu_flag,
        
        CASE
            WHEN s.total_reads / s.execution_count > 100000 THEN '📖 HEAVY I/O'
            WHEN s.total_reads / s.execution_count > 50000 THEN '📖 Moderate I/O'
            ELSE '✅ OK'
        END AS io_flag,
        
        DATEDIFF(day, MIN(s.creation_time), MAX(s.last_execution_time)) + 1 AS active_days,
        MIN(s.creation_time) AS first_seen,
        MAX(s.last_execution_time) AS last_seen,
        s.sql_text
    FROM SprocStats s
    CROSS JOIN MaxVals m
    GROUP BY s.sproc_name, s.execution_count, s.total_elapsed_ms, s.total_cpu_ms,
             s.total_reads, s.total_physical_reads, s.creation_time, s.last_execution_time, s.sql_text,
             m.max_elapsed, m.max_cpu, m.max_reads
    ORDER BY avg_elapsed_ms DESC
)
SELECT * FROM Dashboard;