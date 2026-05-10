-- MariaDB dump 10.19  Distrib 10.11.14-MariaDB, for debian-linux-gnu (x86_64)
--
-- Host: localhost    Database: prolog_store
-- ------------------------------------------------------
-- Server version	10.11.14-MariaDB-0+deb12u2

/*!40101 SET @OLD_CHARACTER_SET_CLIENT=@@CHARACTER_SET_CLIENT */;
/*!40101 SET @OLD_CHARACTER_SET_RESULTS=@@CHARACTER_SET_RESULTS */;
/*!40101 SET @OLD_COLLATION_CONNECTION=@@COLLATION_CONNECTION */;
/*!40101 SET NAMES utf8mb4 */;
/*!40103 SET @OLD_TIME_ZONE=@@TIME_ZONE */;
/*!40103 SET TIME_ZONE='+00:00' */;
/*!40014 SET @OLD_UNIQUE_CHECKS=@@UNIQUE_CHECKS, UNIQUE_CHECKS=0 */;
/*!40014 SET @OLD_FOREIGN_KEY_CHECKS=@@FOREIGN_KEY_CHECKS, FOREIGN_KEY_CHECKS=0 */;
/*!40101 SET @OLD_SQL_MODE=@@SQL_MODE, SQL_MODE='NO_AUTO_VALUE_ON_ZERO' */;
/*!40111 SET @OLD_SQL_NOTES=@@SQL_NOTES, SQL_NOTES=0 */;

--
-- Table structure for table `arguments_indexed`
--

DROP TABLE IF EXISTS `arguments_indexed`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8mb4 */;
CREATE TABLE `arguments_indexed` (
  `formula_id` bigint(20) NOT NULL,
  `arg_position` tinyint(3) unsigned NOT NULL,
  `arg_type` enum('atom','integer','float','string') NOT NULL,
  `atom_value` varchar(255) DEFAULT NULL,
  `int_value` bigint(20) DEFAULT NULL,
  `float_value` double DEFAULT NULL,
  `string_value` varchar(255) DEFAULT NULL,
  PRIMARY KEY (`formula_id`,`arg_position`),
  KEY `idx_atom` (`atom_value`),
  KEY `idx_int` (`int_value`),
  KEY `idx_float` (`float_value`),
  KEY `idx_string` (`string_value`),
  CONSTRAINT `arguments_indexed_ibfk_1` FOREIGN KEY (`formula_id`) REFERENCES `formulae` (`formula_id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `cache_status`
--

DROP TABLE IF EXISTS `cache_status`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8mb4 */;
CREATE TABLE `cache_status` (
  `context_id` int(11) NOT NULL,
  `functor` varchar(255) NOT NULL,
  `arity` tinyint(3) unsigned NOT NULL,
  `is_loaded` tinyint(1) DEFAULT 0,
  `load_time` timestamp NULL DEFAULT NULL,
  `fact_count` int(11) DEFAULT 0,
  PRIMARY KEY (`context_id`,`functor`,`arity`),
  CONSTRAINT `cache_status_ibfk_1` FOREIGN KEY (`context_id`) REFERENCES `contexts` (`context_id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `clause_variables`
--

DROP TABLE IF EXISTS `clause_variables`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8mb4 */;
CREATE TABLE `clause_variables` (
  `clause_id` int(11) NOT NULL,
  `var_index` int(11) NOT NULL,
  `var_name` varchar(50) DEFAULT NULL,
  `appears_in_head` tinyint(1) DEFAULT 0,
  `appears_in_body` tinyint(1) DEFAULT 0,
  `positions` text DEFAULT NULL,
  PRIMARY KEY (`clause_id`,`var_index`),
  CONSTRAINT `clause_variables_ibfk_1` FOREIGN KEY (`clause_id`) REFERENCES `formula_clauses` (`clause_id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `contexts`
--

DROP TABLE IF EXISTS `contexts`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8mb4 */;
CREATE TABLE `contexts` (
  `context_id` int(11) NOT NULL AUTO_INCREMENT,
  `context_name` varchar(100) NOT NULL,
  `description` text DEFAULT NULL,
  `created_at` timestamp NULL DEFAULT current_timestamp(),
  PRIMARY KEY (`context_id`),
  UNIQUE KEY `context_name` (`context_name`),
  KEY `idx_name` (`context_name`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `formula_clauses`
--

DROP TABLE IF EXISTS `formula_clauses`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8mb4 */;
CREATE TABLE `formula_clauses` (
  `clause_id` int(11) NOT NULL AUTO_INCREMENT,
  `context_id` int(11) NOT NULL,
  `head_functor` varchar(255) NOT NULL,
  `head_arity` int(11) NOT NULL,
  `head_repr` text NOT NULL,
  `body_repr` text DEFAULT NULL,
  `clause_type` enum('fact','rule') NOT NULL,
  `var_count` int(11) NOT NULL DEFAULT 0,
  `clause_hash` varchar(64) NOT NULL,
  `created_at` timestamp NULL DEFAULT current_timestamp(),
  PRIMARY KEY (`clause_id`),
  UNIQUE KEY `unique_clause` (`context_id`,`clause_hash`),
  KEY `idx_head` (`context_id`,`head_functor`,`head_arity`),
  KEY `idx_type` (`context_id`,`clause_type`),
  CONSTRAINT `formula_clauses_ibfk_1` FOREIGN KEY (`context_id`) REFERENCES `contexts` (`context_id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `formula_templates`
--

DROP TABLE IF EXISTS `formula_templates`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8mb4 */;
CREATE TABLE `formula_templates` (
  `template_id` int(11) NOT NULL AUTO_INCREMENT,
  `context_id` int(11) NOT NULL,
  `functor` varchar(255) NOT NULL,
  `arity` int(11) NOT NULL,
  `template_repr` text NOT NULL,
  `template_hash` varchar(64) NOT NULL,
  `var_count` int(11) NOT NULL DEFAULT 0,
  `created_at` timestamp NULL DEFAULT current_timestamp(),
  `updated_at` timestamp NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  PRIMARY KEY (`template_id`),
  UNIQUE KEY `unique_template` (`context_id`,`template_hash`),
  KEY `idx_functor_arity` (`context_id`,`functor`,`arity`),
  KEY `idx_var_count` (`context_id`,`var_count`),
  CONSTRAINT `formula_templates_ibfk_1` FOREIGN KEY (`context_id`) REFERENCES `contexts` (`context_id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `formulae`
--

DROP TABLE IF EXISTS `formulae`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8mb4 */;
CREATE TABLE `formulae` (
  `formula_id` bigint(20) NOT NULL AUTO_INCREMENT,
  `context_id` int(11) NOT NULL,
  `functor` varchar(255) NOT NULL,
  `arity` tinyint(3) unsigned NOT NULL,
  `term_canonical` text NOT NULL,
  `term_readable` text DEFAULT NULL,
  `term_hash` char(64) DEFAULT NULL,
  `created_at` timestamp NULL DEFAULT current_timestamp(),
  `updated_at` timestamp NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  PRIMARY KEY (`formula_id`),
  KEY `idx_context_functor` (`context_id`,`functor`,`arity`),
  KEY `idx_functor_arity` (`functor`,`arity`),
  KEY `idx_hash` (`term_hash`),
  CONSTRAINT `formulae_ibfk_1` FOREIGN KEY (`context_id`) REFERENCES `contexts` (`context_id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `list_elements`
--

DROP TABLE IF EXISTS `list_elements`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8mb4 */;
CREATE TABLE `list_elements` (
  `formula_id` bigint(20) NOT NULL,
  `arg_position` tinyint(3) unsigned NOT NULL,
  `element_position` smallint(5) unsigned NOT NULL,
  `element_type` enum('atom','integer','float','compound') NOT NULL,
  `element_value` varchar(255) DEFAULT NULL,
  KEY `idx_element` (`element_value`),
  KEY `idx_formula_arg` (`formula_id`,`arg_position`),
  CONSTRAINT `list_elements_ibfk_1` FOREIGN KEY (`formula_id`) REFERENCES `formulae` (`formula_id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `metadata`
--

DROP TABLE IF EXISTS `metadata`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8mb4 */;
CREATE TABLE `metadata` (
  `formula_id` bigint(20) NOT NULL,
  `meta_key` varchar(100) NOT NULL,
  `meta_value` text DEFAULT NULL,
  PRIMARY KEY (`formula_id`,`meta_key`),
  KEY `idx_key` (`meta_key`),
  CONSTRAINT `metadata_ibfk_1` FOREIGN KEY (`formula_id`) REFERENCES `formulae` (`formula_id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `predicate_stats`
--

DROP TABLE IF EXISTS `predicate_stats`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8mb4 */;
CREATE TABLE `predicate_stats` (
  `context_id` int(11) NOT NULL,
  `functor` varchar(255) NOT NULL,
  `arity` tinyint(3) unsigned NOT NULL,
  `query_count` bigint(20) DEFAULT 0,
  `assert_count` bigint(20) DEFAULT 0,
  `retract_count` bigint(20) DEFAULT 0,
  `last_accessed` timestamp NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  PRIMARY KEY (`context_id`,`functor`,`arity`),
  KEY `idx_access` (`last_accessed`),
  CONSTRAINT `predicate_stats_ibfk_1` FOREIGN KEY (`context_id`) REFERENCES `contexts` (`context_id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `template_variables`
--

DROP TABLE IF EXISTS `template_variables`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8mb4 */;
CREATE TABLE `template_variables` (
  `template_id` int(11) NOT NULL,
  `var_index` int(11) NOT NULL,
  `var_name` varchar(50) DEFAULT NULL,
  `positions` text DEFAULT NULL,
  PRIMARY KEY (`template_id`,`var_index`),
  CONSTRAINT `template_variables_ibfk_1` FOREIGN KEY (`template_id`) REFERENCES `formula_templates` (`template_id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `variable_bindings`
--

DROP TABLE IF EXISTS `variable_bindings`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8mb4 */;
CREATE TABLE `variable_bindings` (
  `binding_id` int(11) NOT NULL AUTO_INCREMENT,
  `clause_id` int(11) NOT NULL,
  `var_index` int(11) NOT NULL,
  `bound_term` text DEFAULT NULL,
  `binding_context` text DEFAULT NULL,
  `created_at` timestamp NULL DEFAULT current_timestamp(),
  PRIMARY KEY (`binding_id`),
  KEY `idx_clause_var` (`clause_id`,`var_index`),
  CONSTRAINT `variable_bindings_ibfk_1` FOREIGN KEY (`clause_id`) REFERENCES `formula_clauses` (`clause_id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;
/*!40103 SET TIME_ZONE=@OLD_TIME_ZONE */;

/*!40101 SET SQL_MODE=@OLD_SQL_MODE */;
/*!40014 SET FOREIGN_KEY_CHECKS=@OLD_FOREIGN_KEY_CHECKS */;
/*!40014 SET UNIQUE_CHECKS=@OLD_UNIQUE_CHECKS */;
/*!40101 SET CHARACTER_SET_CLIENT=@OLD_CHARACTER_SET_CLIENT */;
/*!40101 SET CHARACTER_SET_RESULTS=@OLD_CHARACTER_SET_RESULTS */;
/*!40101 SET COLLATION_CONNECTION=@OLD_COLLATION_CONNECTION */;
/*!40111 SET SQL_NOTES=@OLD_SQL_NOTES */;

-- Dump completed on 2025-10-26  8:11:07
