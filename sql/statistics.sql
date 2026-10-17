-- vsql_statistics compatibility check (NOT a bundled extension).
-- Requires the .veb to be in veb_dir:
--   VEB=$(./scripts/fetch-statistics-veb.sh | tail -1)
--   VSQL_EXTRA_VEB="$VEB" ./scripts/vsql-test.sh sql/statistics.sql
-- Assertion idiom and "-- [ext:...]" markers: see sql/smoke.sql and docs/MAINTAINING.md.

SELECT VERSION() AS version, @@version_comment AS build;
SHOW VARIABLES LIKE 'villagesql_server_version';

-- [ext:vsql_statistics]
SELECT '=== vsql_statistics ===' AS extension_test;
INSTALL EXTENSION vsql_statistics;
SELECT extension_name, extension_version FROM INFORMATION_SCHEMA.EXTENSIONS WHERE extension_name='vsql_statistics';
-- SDK / protocol the .veb was built with, and the protocol the server negotiated.
SELECT negotiated_protocol, JSON_EXTRACT(registration_json,'$.sdk_version') AS veb_sdk_version, JSON_EXTRACT(registration_json,'$.requested_protocol') AS veb_requested_protocol, JSON_LENGTH(registration_json,'$.funcs') AS function_count FROM INFORMATION_SCHEMA.EXTENSION_REGISTRATION WHERE extension_name='vsql_statistics';
DO IF((SELECT COUNT(*) FROM INFORMATION_SCHEMA.EXTENSION_REGISTRATION WHERE extension_name='vsql_statistics')=1, 1, (SELECT 'assert failed' UNION ALL SELECT 'x'));

DROP TABLE IF EXISTS smoke_stats;
CREATE TABLE smoke_stats (grp INT, v DOUBLE);
INSERT INTO smoke_stats VALUES (1,1),(1,2),(1,2),(1,3),(1,4),(1,100),(2,2),(2,3),(2,5),(2,6),(2,7),(2,8);
SELECT STATS_IQR(v) AS iqr FROM smoke_stats;
DO IF((SELECT JSON_EXTRACT(STATS_IQR(v),'$.median') FROM smoke_stats)=3.5, 1, (SELECT 'assert failed' UNION ALL SELECT 'x'));
DO IF((SELECT JSON_EXTRACT(STATS_MODE(v),'$.min') FROM smoke_stats)=2, 1, (SELECT 'assert failed' UNION ALL SELECT 'x'));
SELECT STATS_TTEST_GROUPS(v, grp) AS ttest_groups FROM smoke_stats;
DO IF((SELECT JSON_EXTRACT(STATS_TTEST_GROUPS(v, grp),'$.n_1') FROM smoke_stats)=6, 1, (SELECT 'assert failed' UNION ALL SELECT 'x'));
DROP TABLE smoke_stats;
UNINSTALL EXTENSION vsql_statistics;
