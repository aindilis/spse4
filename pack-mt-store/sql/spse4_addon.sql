-- ====================================================================
-- spse4_addon.sql  --  MT-level metadata tables for SPSE4 v0.3.0
--
-- Apply *after* spse4_schema.sql (= prolog-mysql-store's schema.sql).
-- Provides the five small tables that store microtheory-level state
-- (registry, properties, specialization edges, ACL grants, audit
-- log).  User facts (task/edge/property assertions) ride through
-- prolog-mysql-store's `formulae` table; this addon does NOT touch
-- that.
--
-- Charset/collation match the base schema: utf8mb4 / utf8mb4_unicode_ci.
-- All tables are InnoDB so we get foreign keys + transactions.
--
-- One-liner to apply both files:
--   mysql -u root -p prolog_store < spse4_schema.sql && \
--   mysql -u root -p prolog_store < spse4_addon.sql
-- ====================================================================

-- --------------------------------------------------------------------
-- mt_registry  --  the set of known microtheories.
-- --------------------------------------------------------------------
-- One row per microtheory.  This is *separate* from prolog-mysql-store's
-- `contexts` table because:
--   - `contexts` is created lazily by store_assert (on first assert into
--     a context), but a microtheory can exist with zero asserts (e.g.
--     just-created via mt_create/1).
--   - We want mt_list/1 to enumerate microtheories, not contexts that
--     happen to have facts.
-- The mt_store_mysql backend keeps the two in sync via
-- store_ensure_context/2.

DROP TABLE IF EXISTS `mt_registry`;
CREATE TABLE `mt_registry` (
  `mt_name`     VARCHAR(100) NOT NULL,
  `created_at`  TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`mt_name`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------------------
-- mt_property  --  microtheory metadata (owner, visibility, etc.).
-- --------------------------------------------------------------------
-- prop_value is a serialized Prolog term (write_canonical/1).  Atom
-- keys are common (visibility=public, owner=andrew) but values can be
-- arbitrary terms.

DROP TABLE IF EXISTS `mt_property`;
CREATE TABLE `mt_property` (
  `mt_name`     VARCHAR(100) NOT NULL,
  `prop_key`    VARCHAR(100) NOT NULL,
  `prop_value`  TEXT         NOT NULL,
  `set_at`      TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`mt_name`, `prop_key`),
  CONSTRAINT `mt_property_ibfk_1`
    FOREIGN KEY (`mt_name`) REFERENCES `mt_registry`(`mt_name`)
    ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------------------
-- mt_specialization  --  the genlMt/specialization edges.
-- --------------------------------------------------------------------
-- Asserted edges only (the transitive closure is computed in Prolog).
-- Cycle prevention is enforced by mt_store, not by SQL constraints.

DROP TABLE IF EXISTS `mt_specialization`;
CREATE TABLE `mt_specialization` (
  `sub_name`    VARCHAR(100) NOT NULL,
  `super_name`  VARCHAR(100) NOT NULL,
  `created_at`  TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`sub_name`, `super_name`),
  KEY `idx_super` (`super_name`),
  CONSTRAINT `mt_specialization_sub_fk`
    FOREIGN KEY (`sub_name`) REFERENCES `mt_registry`(`mt_name`)
    ON DELETE CASCADE,
  CONSTRAINT `mt_specialization_super_fk`
    FOREIGN KEY (`super_name`) REFERENCES `mt_registry`(`mt_name`)
    ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------------------
-- mt_acl  --  per-user, per-microtheory access grants.
-- --------------------------------------------------------------------
-- access is read or write (write implies read at the mt_store layer,
-- but is stored as a separate explicit grant for auditability).

DROP TABLE IF EXISTS `mt_acl`;
CREATE TABLE `mt_acl` (
  `mt_name`     VARCHAR(100) NOT NULL,
  `user_name`   VARCHAR(100) NOT NULL,
  `access`      ENUM('read','write') NOT NULL,
  `granted_at`  TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`mt_name`, `user_name`, `access`),
  KEY `idx_user` (`user_name`),
  CONSTRAINT `mt_acl_ibfk_1`
    FOREIGN KEY (`mt_name`) REFERENCES `mt_registry`(`mt_name`)
    ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------------------
-- mt_audit  --  the assert/retract audit log.
-- --------------------------------------------------------------------
-- recorded_at_epoch is the Unix epoch float from get_time/1, with
-- six decimal places preserved (MySQL DOUBLE).  We also store a
-- TIMESTAMP for human-readable queries from BI tools.
--
-- An audit row is never updated; it is append-only.  We deliberately
-- do NOT add a foreign key to mt_registry here, because dropping a
-- microtheory should NOT silently erase its audit trail.  If you
-- want that behavior, add the FK manually.

DROP TABLE IF EXISTS `mt_audit`;
CREATE TABLE `mt_audit` (
  `audit_id`           BIGINT NOT NULL AUTO_INCREMENT,
  `mt_name`            VARCHAR(100) NOT NULL,
  `recorded_at_epoch`  DOUBLE       NOT NULL,
  `recorded_at`        TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `user_name`          VARCHAR(100) NOT NULL,
  `op`                 ENUM('assert','retract') NOT NULL,
  `fact`               TEXT         NOT NULL,
  PRIMARY KEY (`audit_id`),
  KEY `idx_mt_time` (`mt_name`, `recorded_at_epoch`),
  KEY `idx_user_time` (`user_name`, `recorded_at_epoch`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ====================================================================
-- end of spse4_addon.sql
-- ====================================================================
