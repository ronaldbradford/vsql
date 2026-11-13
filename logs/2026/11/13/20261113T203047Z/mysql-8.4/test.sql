-- Smoke test run against every VillageSQL variant.
-- Runs inside the database named by VSQL_DATABASE (default vsql_test).
--
-- Layout
--   1. Core server checks (version, InnoDB round trip).
--   2. One section per extension bundled with the prebuilt tarball
--      (the *.veb files in the server's veb_dir).  Every section starts with a
--      "-- [ext:<name>]" marker comment; scripts/vsql-test.sh uses those markers
--      to attribute each SQL error to an extension and to report PASS/FAIL per
--      extension, and to warn about bundled .veb files that have no section.
--   3. A final cross-check of INFORMATION_SCHEMA.EXTENSIONS.
--
-- Assertions: there is no ASSERT in SQL, so a failed check is raised as a real
-- SQL error (1242, "Subquery returns more than 1 row") using this idiom, which
-- MUST stay on a single line so the reported "at line N" is the assertion:
--     DO IF(<condition>, 1, (SELECT 'assert failed' UNION ALL SELECT 'x'));
-- The runner runs mysql with --force, so every section executes even if an
-- earlier one failed, and every "ERROR ..." line fails the variant.
--
-- To add an extension: see docs/MAINTAINING.md.

SELECT VERSION() AS version, @@version_comment AS build;

-- ---------------------------------------------------------------------------
-- Core
-- ---------------------------------------------------------------------------
-- Extensions currently installed (empty on a fresh server).
SELECT extension_name, extension_version FROM INFORMATION_SCHEMA.EXTENSIONS;

-- Basic InnoDB round trip.
CREATE TABLE smoke (
  id INT AUTO_INCREMENT PRIMARY KEY,
  label VARCHAR(50) NOT NULL,
  created TIMESTAMP DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;

INSERT INTO smoke (label) VALUES ('alpha'), ('beta'), ('gamma');
SELECT COUNT(*) AS row_count FROM smoke;
DO IF((SELECT COUNT(*) FROM smoke)=3, 1, (SELECT 'assert failed' UNION ALL SELECT 'x'));

DROP TABLE smoke;

-- The extension directory the installer populated.
SHOW VARIABLES LIKE 'veb_dir';

-- ---------------------------------------------------------------------------
-- Extensions
-- ---------------------------------------------------------------------------

-- [ext:vsql_uuid]
SELECT '=== vsql_uuid ===' AS extension_test;
INSTALL EXTENSION vsql_uuid;
DO IF((SELECT COUNT(*) FROM INFORMATION_SCHEMA.EXTENSIONS WHERE extension_name='vsql_uuid')=1, 1, (SELECT 'assert failed' UNION ALL SELECT 'x'));
SELECT UUID_V4() AS v4, UUID_VERSION(UUID_V7()) AS v7_version;
DO IF(UUID_VERSION(UUID_V4())=4 AND UUID_VERSION(UUID_V7())=7, 1, (SELECT 'assert failed' UNION ALL SELECT 'x'));
-- Name-based v5 is deterministic (well-known value for DNS/example.com).
DO IF(UUID_V5(UUID_NS_DNS(), 'example.com')='cfbff0d1-9375-5685-968c-48ce8b15ae17', 1, (SELECT 'assert failed' UNION ALL SELECT 'x'));

-- [ext:vsql_boolean]
SELECT '=== vsql_boolean ===' AS extension_test;
INSTALL EXTENSION vsql_boolean;
DROP TABLE IF EXISTS smoke_bool;
CREATE TABLE smoke_bool (id INT PRIMARY KEY, flag STRICTBOOL);
INSERT INTO smoke_bool VALUES (1,'true'), (2,'no'), (3,'yes');
SELECT boolean_sum(flag) AS true_count, boolean_avg(flag) AS true_ratio FROM smoke_bool;
DO IF((SELECT boolean_sum(flag) FROM smoke_bool)=2, 1, (SELECT 'assert failed' UNION ALL SELECT 'x'));
DROP TABLE smoke_bool;

-- [ext:vsql_crypto]
SELECT '=== vsql_crypto ===' AS extension_test;
INSTALL EXTENSION vsql_crypto;
SELECT crypto_version() AS crypto_version;
DO IF(HEX(digest('abc','sha256'))='BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD', 1, (SELECT 'assert failed' UNION ALL SELECT 'x'));
DO IF(LENGTH(gen_random_bytes(16))=16, 1, (SELECT 'assert failed' UNION ALL SELECT 'x'));
SET @smoke_hash = crypt('correct horse', gen_salt('pbkdf2-sha256', 1000));
DO IF(crypt('correct horse', @smoke_hash)=@smoke_hash, 1, (SELECT 'assert failed' UNION ALL SELECT 'x'));

-- [ext:vsql_network_address]
SELECT '=== vsql_network_address ===' AS extension_test;
INSTALL EXTENSION vsql_network_address;
SELECT inet_to_string(inet_from_string('192.168.1.5/24')) AS inet_value, cidr_to_string(cidr_from_string('10.0.0.0/8')) AS cidr_value;
DO IF(inet_to_string(inet_from_string('192.168.1.5/24'))='192.168.1.5/24', 1, (SELECT 'assert failed' UNION ALL SELECT 'x'));
DO IF(cidr_to_string(cidr_from_string('10.0.0.0/8'))='10.0.0.0/8', 1, (SELECT 'assert failed' UNION ALL SELECT 'x'));

-- [ext:vsql_cube]
SELECT '=== vsql_cube ===' AS extension_test;
INSTALL EXTENSION vsql_cube;
DROP TABLE IF EXISTS smoke_cube;
-- `cube` is a reserved word, so the type name is backtick-quoted.
CREATE TABLE smoke_cube (id INT PRIMARY KEY, c `cube`(3));
INSERT INTO smoke_cube VALUES (1,'(0,0,0)'), (2,'(3,4,0)');
SELECT id, cube_dim(c) AS dims, cube_to_string(c) AS cube_text FROM smoke_cube;
DO IF((SELECT cube_dim(c) FROM smoke_cube WHERE id=1)=3, 1, (SELECT 'assert failed' UNION ALL SELECT 'x'));
DO IF((SELECT cube_distance(a.c, b.c) FROM smoke_cube a, smoke_cube b WHERE a.id=1 AND b.id=2)=5, 1, (SELECT 'assert failed' UNION ALL SELECT 'x'));
DROP TABLE smoke_cube;

-- [ext:vsql_trgm]
SELECT '=== vsql_trgm ===' AS extension_test;
INSTALL EXTENSION vsql_trgm;
SELECT trgm_similarity('cat','car') AS similarity, trgm_similar('cat','car') AS similar;
DO IF(trgm_similarity('word','word')=1 AND trgm_similar('cat','car')=1, 1, (SELECT 'assert failed' UNION ALL SELECT 'x'));

-- [ext:vsql_fuzzystrmatch]
SELECT '=== vsql_fuzzystrmatch ===' AS extension_test;
INSTALL EXTENSION vsql_fuzzystrmatch;
SELECT vsql_fuzzystrmatch.soundex('Robert') AS soundex, vsql_fuzzystrmatch.levenshtein('kitten','sitting') AS levenshtein;
DO IF(vsql_fuzzystrmatch.soundex('Robert')='R163' AND vsql_fuzzystrmatch.levenshtein('kitten','sitting')=3, 1, (SELECT 'assert failed' UNION ALL SELECT 'x'));

-- [ext:vsql_http]
SELECT '=== vsql_http ===' AS extension_test;
INSTALL EXTENSION vsql_http;
-- Offline checks only: the test hosts have no guaranteed network access.
SELECT url_encode('a b&c') AS encoded, url_decode('a%20b') AS decoded;
DO IF(url_encode('a b&c')='a%20b%26c' AND url_decode('a%20b')='a b', 1, (SELECT 'assert failed' UNION ALL SELECT 'x'));

-- [ext:vsql_ai]
SELECT '=== vsql_ai ===' AS extension_test;
INSTALL EXTENSION vsql_ai;
-- No API keys or network: an unknown provider must return NULL (with warning 3200),
-- which proves the function loaded and ran.
SELECT ai_prompt('smoke-no-such-provider','m','k','hello') AS expect_null;
DO IF(ai_prompt('smoke-no-such-provider','m','k','hello') IS NULL, 1, (SELECT 'assert failed' UNION ALL SELECT 'x'));

-- [ext:vsql_oauth2]
SELECT '=== vsql_oauth2 ===' AS extension_test;
INSTALL EXTENSION vsql_oauth2;
-- Authentication extension: no functions, so check its system variables registered.
SELECT variable_name, variable_value FROM performance_schema.global_variables WHERE variable_name LIKE 'vsql_oauth2.%' ORDER BY variable_name LIMIT 3;
DO IF((SELECT COUNT(*) FROM performance_schema.global_variables WHERE variable_name='vsql_oauth2.username_claim')=1, 1, (SELECT 'assert failed' UNION ALL SELECT 'x'));

-- [ext:vsql_rest]
SELECT '=== vsql_rest ===' AS extension_test;
INSTALL EXTENSION vsql_rest;
-- No functions; the REST listener is off by default, so check the variables only.
SELECT variable_name, variable_value FROM performance_schema.global_variables WHERE variable_name IN ('vsql_rest.vsql_rest_enabled','vsql_rest.port');
DO IF((SELECT variable_value FROM performance_schema.global_variables WHERE variable_name='vsql_rest.vsql_rest_enabled')='OFF', 1, (SELECT 'assert failed' UNION ALL SELECT 'x'));

-- [ext:vsql_complex]
-- Example/reference extension shipped in the tarball.
SELECT '=== vsql_complex ===' AS extension_test;
INSTALL EXTENSION vsql_complex;
DROP TABLE IF EXISTS smoke_complex;
CREATE TABLE smoke_complex (id INT PRIMARY KEY, z COMPLEX);
INSERT INTO smoke_complex VALUES (1,'(3.0,4.0)');
SELECT complex_real(z) AS re, complex_imag(z) AS im, complex_abs(z) AS magnitude FROM smoke_complex;
DO IF((SELECT complex_abs(z) FROM smoke_complex WHERE id=1)=5, 1, (SELECT 'assert failed' UNION ALL SELECT 'x'));
DROP TABLE smoke_complex;

-- [ext:vsql_simple]
-- Example/reference extension shipped in the tarball.
SELECT '=== vsql_simple ===' AS extension_test;
INSTALL EXTENSION vsql_simple;
SELECT rot13('abc') = 'nop' AS rot13_ok, rot13(rot13('abc')) = 'abc' AS round_trip;
DO IF(rot13('abc')='nop' AND rot13(rot13('abc'))='abc', 1, (SELECT 'assert failed' UNION ALL SELECT 'x'));

-- ---------------------------------------------------------------------------
-- Cross-check: everything installed above is registered.
-- ---------------------------------------------------------------------------
-- [ext:(registry)]
SELECT '=== INFORMATION_SCHEMA.EXTENSIONS ===' AS extension_test;
SELECT extension_name, extension_version, pending_last_error FROM INFORMATION_SCHEMA.EXTENSIONS ORDER BY extension_name;
DO IF((SELECT COUNT(*) FROM INFORMATION_SCHEMA.EXTENSIONS WHERE pending_last_error IS NOT NULL)=0, 1, (SELECT 'assert failed' UNION ALL SELECT 'x'));
DO IF((SELECT COUNT(*) FROM INFORMATION_SCHEMA.EXTENSION_REGISTRATION)=(SELECT COUNT(*) FROM INFORMATION_SCHEMA.EXTENSIONS), 1, (SELECT 'assert failed' UNION ALL SELECT 'x'));
