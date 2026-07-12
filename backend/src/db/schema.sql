CREATE TABLE users (
  id VARCHAR(64) PRIMARY KEY,
  name VARCHAR(255) NOT NULL,
  email VARCHAR(255) UNIQUE NOT NULL,
  password_hash VARCHAR(255) NOT NULL,
  roles JSON NOT NULL,
  permissions JSON NOT NULL,
  active TINYINT(1) DEFAULT 1,
  failed_login_attempts INT DEFAULT 0,
  locked_until DATETIME NULL,
  created_at DATETIME NOT NULL
);

CREATE TABLE roles (
  id VARCHAR(64) PRIMARY KEY,
  name VARCHAR(100) NOT NULL,
  permissions JSON NOT NULL
);

CREATE TABLE permissions (
  id VARCHAR(64) PRIMARY KEY,
  name VARCHAR(100) UNIQUE NOT NULL
);

CREATE TABLE locations (
  id VARCHAR(64) PRIMARY KEY,
  name VARCHAR(255) NOT NULL,
  code VARCHAR(32) NOT NULL,
  type VARCHAR(64) NOT NULL
);

CREATE TABLE stock_structures (
  id VARCHAR(64) PRIMARY KEY,
  name VARCHAR(255) NOT NULL,
  location_id VARCHAR(64) NOT NULL,
  section VARCHAR(64) NOT NULL
);

CREATE TABLE categories (
  id VARCHAR(64) PRIMARY KEY,
  name VARCHAR(255) NOT NULL,
  code VARCHAR(8) NOT NULL
);

CREATE TABLE subcategories (
  id VARCHAR(64) PRIMARY KEY,
  name VARCHAR(255) NOT NULL,
  category_id VARCHAR(64) NOT NULL,
  code VARCHAR(8) NOT NULL
);

CREATE TABLE material_items (
  id VARCHAR(64) PRIMARY KEY,
  inventory_number VARCHAR(64) UNIQUE NOT NULL,
  name VARCHAR(255) NOT NULL,
  category_code VARCHAR(8) NOT NULL,
  subcategory_code VARCHAR(8) NOT NULL,
  location_id VARCHAR(64) NOT NULL,
  status VARCHAR(64) NOT NULL,
  description TEXT NULL,
  created_at DATETIME NOT NULL
);

CREATE TABLE clothing_items (
  id VARCHAR(64) PRIMARY KEY,
  name VARCHAR(255) NOT NULL,
  size VARCHAR(16) NULL,
  location_id VARCHAR(64) NOT NULL,
  status VARCHAR(64) NOT NULL,
  assigned_person VARCHAR(255) NULL,
  created_at DATETIME NOT NULL
);

CREATE TABLE issue_transactions (
  id VARCHAR(64) PRIMARY KEY,
  material_id VARCHAR(64) NULL,
  clothing_id VARCHAR(64) NULL,
  person_name VARCHAR(255) NOT NULL,
  quantity INT NOT NULL,
  action VARCHAR(32) NOT NULL,
  created_at DATETIME NOT NULL
);

CREATE TABLE defect_reports (
  id VARCHAR(64) PRIMARY KEY,
  entity_type VARCHAR(64) NOT NULL,
  entity_id VARCHAR(64) NOT NULL,
  description TEXT NOT NULL,
  status VARCHAR(64) NOT NULL,
  created_at DATETIME NOT NULL
);

CREATE TABLE procurement_requests (
  id VARCHAR(64) PRIMARY KEY,
  title VARCHAR(255) NOT NULL,
  status VARCHAR(64) NOT NULL,
  requested_by VARCHAR(255) NOT NULL,
  approval_notes TEXT NULL,
  created_at DATETIME NOT NULL
);

CREATE TABLE suppliers (
  id VARCHAR(64) PRIMARY KEY,
  name VARCHAR(255) NOT NULL,
  contact VARCHAR(255) NULL
);

CREATE TABLE documents (
  id VARCHAR(64) PRIMARY KEY,
  title VARCHAR(255) NOT NULL,
  mime_type VARCHAR(64) NULL,
  storage_path VARCHAR(255) NOT NULL,
  created_at DATETIME NOT NULL
);

CREATE TABLE audit_logs (
  id VARCHAR(64) PRIMARY KEY,
  timestamp DATETIME NOT NULL,
  actor VARCHAR(255) NOT NULL,
  action VARCHAR(64) NOT NULL,
  entity VARCHAR(64) NOT NULL,
  details JSON NOT NULL
);

CREATE TABLE export_logs (
  id VARCHAR(64) PRIMARY KEY,
  export_type VARCHAR(64) NOT NULL,
  requested_by VARCHAR(255) NOT NULL,
  created_at DATETIME NOT NULL
);
