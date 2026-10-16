-- Smoke test run against every VillageSQL variant.
-- Runs inside the database named by VSQL_DATABASE (default vsql_test).

SELECT VERSION() AS version, @@version_comment AS build;

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

DROP TABLE smoke;
