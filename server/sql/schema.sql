-- Zelda Women Safety Guardian - Database Schema
-- *** STALE / HISTORICAL — DO NOT USE FOR NEW SETUPS ***
-- This file is legacy MySQL / MariaDB DDL and is NOT the live schema.
-- Live database is Postgres (see server/db.js pg Pool); the authoritative
-- live DDL is the migration set in this directory (server/sql/),
-- e.g. migration_20260822_nearest_police_station.sql. Apply migrations
-- against DATABASE_URL instead of this file.

CREATE DATABASE IF NOT EXISTS zelda_new CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
USE zelda_new;

DROP TABLE IF EXISTS `audit log table`;
DROP TABLE IF EXISTS `contacts table`;
DROP TABLE IF EXISTS `sos cases table`;
DROP TABLE IF EXISTS `users table`;

CREATE TABLE `users table` (
  id INT AUTO_INCREMENT PRIMARY KEY,
  Name VARCHAR(255) NOT NULL,
  Email VARCHAR(255) NOT NULL UNIQUE,
  PersonalEmail VARCHAR(255),
  Password VARCHAR(255) NOT NULL,
  Role VARCHAR(50) NOT NULL DEFAULT 'user',
  Created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
  Updated_at DATETIME DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  isVerified TINYINT(1) DEFAULT 0,
  otp VARCHAR(10),
  otpExpiry DATETIME
) ENGINE=InnoDB;

CREATE TABLE `sos cases table` (
  id INT AUTO_INCREMENT PRIMARY KEY,
  user_id INT NOT NULL,
  user_email VARCHAR(255),
  location_link TEXT,
  latitude VARCHAR(50),
  longitude VARCHAR(50),
  status VARCHAR(50) DEFAULT 'Pending',
  notes TEXT,
  video_url VARCHAR(500),
  audio_url VARCHAR(500),
  trigger_type VARCHAR(50) DEFAULT 'manual',
  created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
  updated_at DATETIME DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) ENGINE=InnoDB;

CREATE TABLE `contacts table` (
  id INT AUTO_INCREMENT PRIMARY KEY,
  user_id INT NOT NULL,
  name VARCHAR(255) NOT NULL,
  phone VARCHAR(50) NOT NULL,
  email VARCHAR(255),
  relation VARCHAR(100),
  created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
  updated_at DATETIME DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) ENGINE=InnoDB;

CREATE TABLE `audit log table` (
  id INT AUTO_INCREMENT PRIMARY KEY,
  user_id INT,
  case_id INT,
  Action VARCHAR(100),
  details TEXT,
  created_at DATETIME DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;

INSERT INTO `users table` (Name, Email, PersonalEmail, Password, Role, Created_at, Updated_at, isVerified, otp, otpExpiry) VALUES
('Police Officer', 'police@guardian.com', NULL, '$2a$10$bfA8EVj4PtNoPtWQNWOGyehpzoTH0Hp3p9nWIm4F2UI.swU0vJe9e', 'police', '2026-03-21 08:35:12', '2026-06-14 00:00:00', 1, NULL, NULL),
('Test User', 'user@guardian.com', NULL, '$2a$10$YeExqZbWQrhCxnLe7Bafru5/9tAudCRjm1s2FnSjRVah6yVmJIIFG', 'user', '2026-03-21 08:35:12', '2026-06-14 00:00:00', 1, NULL, NULL);
