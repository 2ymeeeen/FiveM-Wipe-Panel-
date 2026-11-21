CREATE TABLE IF NOT EXISTS `wipe_backups` (
  `id` INT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  `citizenid` VARCHAR(100) NOT NULL,
  `name` VARCHAR(100) NULL,
  `kind` VARCHAR(20) NULL,
  `data` LONGTEXT NULL,
  `admin` VARCHAR(80) NULL,
  `reason` VARCHAR(255) NULL,
  `created_at` BIGINT NULL,
  `restored` TINYINT DEFAULT 0,
  `restored_at` BIGINT NULL,
  INDEX (`citizenid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `ultimate_character_swaps` (
  `id` INT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  `first_cid` VARCHAR(50) NULL,
  `second_cid` VARCHAR(50) NULL,
  `first_license` VARCHAR(100) NULL,
  `second_license` VARCHAR(100) NULL,
  `admin` VARCHAR(100) NULL,
  `status` VARCHAR(20) DEFAULT 'pending',
  `error` TEXT NULL,
  `created_at` BIGINT NULL,
  `finished_at` BIGINT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
