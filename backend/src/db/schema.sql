CREATE TABLE users (
  id VARCHAR(64) PRIMARY KEY,
  name VARCHAR(255) NOT NULL,
  username VARCHAR(100) UNIQUE NOT NULL,
  email VARCHAR(255) UNIQUE NOT NULL,
  password_hash VARCHAR(255) NOT NULL,
  roles JSON NOT NULL,
  department_ids JSON NOT NULL,
  permissions JSON NOT NULL,
  active TINYINT(1) DEFAULT 1,
  failed_login_attempts INT DEFAULT 0,
  locked_until DATETIME NULL,
  last_login_at DATETIME NULL,
  email_verified_at DATETIME NULL,
  verification_token_hash CHAR(64) NULL,
  verification_expires_at DATETIME NULL,
  password_reset_token_hash CHAR(64) NULL,
  password_reset_expires_at DATETIME NULL,
  deactivated_at DATETIME NULL,
  deactivation_reason VARCHAR(64) NULL,
  scheduled_deletion_at DATETIME NULL,
  created_at DATETIME NOT NULL,
  INDEX idx_users_last_login (last_login_at),
  INDEX idx_users_scheduled_deletion (scheduled_deletion_at)
);

CREATE TABLE roles (
  id VARCHAR(64) PRIMARY KEY,
  name VARCHAR(100) UNIQUE NOT NULL,
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
  section VARCHAR(64) NOT NULL,
  FOREIGN KEY (location_id) REFERENCES locations(id)
);

CREATE TABLE categories (
  id VARCHAR(64) PRIMARY KEY,
  name VARCHAR(255) NOT NULL,
  parent_id VARCHAR(64) NULL,
  use_in_wardrobe BOOLEAN NOT NULL DEFAULT FALSE,
  sizes JSON NULL,
  inspection_interval_months INT NULL,
  requires_psage_inspection BOOLEAN NOT NULL DEFAULT FALSE,
  FOREIGN KEY (parent_id) REFERENCES categories(id)
);

-- Fachbereiche werden als zentrale Anwendungssammlung gespeichert. Die
-- Benutzerzuordnung liegt normalisiert am Account in department_ids.

CREATE TABLE material_items (
  id VARCHAR(64) PRIMARY KEY,
  inventory_number VARCHAR(64) UNIQUE NOT NULL,
  name VARCHAR(255) NOT NULL,
  category_code VARCHAR(8) NOT NULL,
  subcategory_code VARCHAR(8) NOT NULL,
  location_id VARCHAR(64) NOT NULL,
  status VARCHAR(64) NOT NULL,
  description TEXT NULL,
  notes TEXT NULL,
  item_type VARCHAR(16) NOT NULL DEFAULT 'individual',
  quantity DECIMAL(12,3) NOT NULL DEFAULT 1,
  issued_quantity DECIMAL(12,3) NOT NULL DEFAULT 0,
  unit VARCHAR(32) NOT NULL DEFAULT 'Stück',
  stock_structure_id VARCHAR(64) NULL,
  manufacturer VARCHAR(255) NULL,
  model VARCHAR(255) NULL,
  serial_number VARCHAR(255) NULL,
  purchase_date DATE NULL,
  purchase_price DECIMAL(12,2) NULL,
  department VARCHAR(255) NULL,
  inspection_interval_months INT NULL,
  last_inspection_date DATE NULL,
  next_inspection_date DATE NULL,
  archived TINYINT(1) NOT NULL DEFAULT 0,
  archived_at DATETIME NULL,
  archived_by VARCHAR(255) NULL,
  created_at DATETIME NOT NULL
);

CREATE TABLE material_movements (
  id VARCHAR(64) PRIMARY KEY,
  material_id VARCHAR(64) NOT NULL,
  action VARCHAR(32) NOT NULL,
  quantity DECIMAL(12,3) NOT NULL,
  recipient_type VARCHAR(32) NULL,
  recipient VARCHAR(255) NULL,
  planned_return_date DATE NULL,
  from_location_id VARCHAR(64) NULL,
  from_stock_structure_id VARCHAR(64) NULL,
  to_location_id VARCHAR(64) NULL,
  to_stock_structure_id VARCHAR(64) NULL,
  notes TEXT NULL,
  actor VARCHAR(255) NOT NULL,
  created_at DATETIME NOT NULL
);

CREATE TABLE material_inspections (
  id VARCHAR(64) PRIMARY KEY,
  material_id VARCHAR(64) NOT NULL,
  inspection_date DATE NOT NULL,
  inspector VARCHAR(255) NOT NULL,
  result VARCHAR(32) NOT NULL,
  notes TEXT NULL,
  next_inspection_date DATE NULL,
  created_at DATETIME NOT NULL
);

CREATE TABLE material_documents (
  id VARCHAR(64) PRIMARY KEY,
  material_id VARCHAR(64) NOT NULL,
  title VARCHAR(255) NOT NULL,
  document_type VARCHAR(32) NOT NULL,
  mime_type VARCHAR(128) NULL,
  file_name VARCHAR(255) NOT NULL,
  file_base64 LONGTEXT NOT NULL,
  created_at DATETIME NOT NULL
);

CREATE TABLE clothing_items (
  id VARCHAR(64) PRIMARY KEY,
  name VARCHAR(255) NOT NULL,
  category_id VARCHAR(64) NULL,
  size VARCHAR(16) NULL,
  location_id VARCHAR(64) NOT NULL,
  stock_structure_id VARCHAR(64) NULL,
  status VARCHAR(64) NOT NULL,
  assigned_person VARCHAR(255) NULL,
  inspection_interval_months INT NULL,
  last_inspection_date DATE NULL,
  next_inspection_date DATE NULL,
  created_at DATETIME NOT NULL,
  FOREIGN KEY (category_id) REFERENCES categories(id),
  FOREIGN KEY (location_id) REFERENCES locations(id),
  FOREIGN KEY (stock_structure_id) REFERENCES stock_structures(id)
);

CREATE TABLE clothing_inspections (
  id VARCHAR(64) PRIMARY KEY,
  clothing_id VARCHAR(64) NOT NULL,
  inspection_date DATE NOT NULL,
  inspector VARCHAR(255) NOT NULL,
  inspector_email VARCHAR(255) NOT NULL,
  result VARCHAR(32) NOT NULL,
  notes TEXT NULL,
  next_inspection_date DATE NULL,
  psage_inspection BOOLEAN NOT NULL DEFAULT FALSE,
  created_at DATETIME NOT NULL,
  FOREIGN KEY (clothing_id) REFERENCES clothing_items(id)
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
  defect_number VARCHAR(32) UNIQUE NOT NULL,
  entity_type VARCHAR(64) NOT NULL,
  entity_id VARCHAR(64) NOT NULL,
  affected_quantity DECIMAL(12,3) NOT NULL DEFAULT 1,
  title VARCHAR(160) NOT NULL,
  description TEXT NOT NULL,
  priority VARCHAR(32) NOT NULL DEFAULT 'Normal',
  status VARCHAR(64) NOT NULL,
  damage_type VARCHAR(120) NULL,
  cause TEXT NULL,
  measures_taken TEXT NULL,
  risk_level VARCHAR(80) NULL,
  operational_safety VARCHAR(80) NULL,
  assignee VARCHAR(255) NULL,
  responsible_department VARCHAR(255) NULL,
  contact_name VARCHAR(255) NULL,
  contact_email VARCHAR(255) NULL,
  contact_phone VARCHAR(80) NULL,
  due_date DATE NULL,
  estimated_cost DECIMAL(12,2) NULL,
  actual_cost DECIMAL(12,2) NULL,
  resolution TEXT NULL,
  reported_by VARCHAR(64) NOT NULL,
  reported_at DATETIME NOT NULL,
  details_json LONGTEXT NULL CHECK (details_json IS NULL OR JSON_VALID(details_json)),
  archived_at DATETIME NULL,
  archived_by VARCHAR(255) NULL,
  created_at DATETIME NOT NULL
);

CREATE TABLE procurement_requests (
  id VARCHAR(64) PRIMARY KEY,
  request_number VARCHAR(32) UNIQUE NOT NULL,
  title VARCHAR(255) NOT NULL,
  reason TEXT NOT NULL,
  status VARCHAR(64) NOT NULL,
  requested_by VARCHAR(255) NOT NULL,
  requested_by_email VARCHAR(255) NOT NULL,
  department VARCHAR(255) NULL,
  cost_center VARCHAR(128) NULL,
  desired_delivery_date DATE NULL,
  priority VARCHAR(32) NOT NULL DEFAULT 'Normal',
  notes TEXT NULL,
  preferred_supplier_id VARCHAR(64) NULL,
  selected_offer_id VARCHAR(64) NULL,
  offer_selection_justification TEXT NULL,
  requested_budget_gross DECIMAL(12,2) NOT NULL,
  approved_budget_gross DECIMAL(12,2) NULL,
  created_at DATETIME NOT NULL,
  updated_at DATETIME NOT NULL
);

CREATE TABLE suppliers (
  id VARCHAR(64) PRIMARY KEY,
  name VARCHAR(255) NOT NULL,
  contact VARCHAR(255) NULL,
  address TEXT NULL,
  customer_number VARCHAR(128) NULL,
  email VARCHAR(255) NULL,
  phone VARCHAR(128) NULL,
  website VARCHAR(512) NULL,
  payment_terms VARCHAR(255) NULL,
  active TINYINT(1) NOT NULL DEFAULT 1,
  created_at DATETIME NULL
);

CREATE TABLE procurement_request_items (
  id VARCHAR(64) PRIMARY KEY,
  request_id VARCHAR(64) NOT NULL,
  name VARCHAR(255) NOT NULL,
  category_id VARCHAR(64) NOT NULL,
  subcategory_id VARCHAR(64) NULL,
  size VARCHAR(32) NULL,
  quantity DECIMAL(12,3) NOT NULL,
  unit VARCHAR(32) NOT NULL,
  tax_rate DECIMAL(5,2) NOT NULL DEFAULT 19,
  notes TEXT NULL,
  FOREIGN KEY (request_id) REFERENCES procurement_requests(id),
  FOREIGN KEY (category_id) REFERENCES categories(id),
  FOREIGN KEY (subcategory_id) REFERENCES categories(id)
);

CREATE TABLE procurement_approvals (
  id VARCHAR(64) PRIMARY KEY,
  request_id VARCHAR(64) NOT NULL,
  decision VARCHAR(32) NOT NULL,
  approver_role VARCHAR(64) NOT NULL,
  approver_email VARCHAR(255) NOT NULL,
  approver_name VARCHAR(255) NOT NULL,
  notes TEXT NULL,
  board_resolution VARCHAR(255) NULL,
  approved_budget_gross DECIMAL(12,2) NULL,
  created_at DATETIME NOT NULL,
  FOREIGN KEY (request_id) REFERENCES procurement_requests(id)
);

CREATE TABLE procurement_offers (
  id VARCHAR(64) PRIMARY KEY,
  request_id VARCHAR(64) NOT NULL,
  supplier_id VARCHAR(64) NOT NULL,
  offer_number VARCHAR(128) NULL,
  offer_date DATE NULL,
  valid_until DATE NULL,
  delivery_days INT NULL,
  gross_total DECIMAL(12,2) NOT NULL,
  shipping_gross DECIMAL(12,2) NOT NULL DEFAULT 0,
  notes TEXT NULL,
  created_at DATETIME NOT NULL,
  FOREIGN KEY (request_id) REFERENCES procurement_requests(id),
  FOREIGN KEY (supplier_id) REFERENCES suppliers(id)
);

CREATE TABLE procurement_orders (
  id VARCHAR(64) PRIMARY KEY,
  order_number VARCHAR(32) UNIQUE NOT NULL,
  request_id VARCHAR(64) NOT NULL,
  supplier_id VARCHAR(64) NOT NULL,
  order_date DATE NOT NULL,
  expected_delivery_date DATE NULL,
  shipping_gross DECIMAL(12,2) NOT NULL DEFAULT 0,
  net_total DECIMAL(12,2) NULL,
  gross_total DECIMAL(12,2) NOT NULL,
  notes TEXT NULL,
  created_by VARCHAR(255) NOT NULL,
  created_at DATETIME NOT NULL,
  FOREIGN KEY (request_id) REFERENCES procurement_requests(id),
  FOREIGN KEY (supplier_id) REFERENCES suppliers(id)
);

CREATE TABLE procurement_order_items (
  id VARCHAR(64) PRIMARY KEY,
  order_id VARCHAR(64) NOT NULL,
  request_item_id VARCHAR(64) NOT NULL,
  quantity DECIMAL(12,3) NOT NULL,
  gross_unit_price DECIMAL(12,2) NOT NULL,
  gross_total DECIMAL(12,2) NOT NULL,
  delivered_quantity DECIMAL(12,3) NOT NULL DEFAULT 0,
  FOREIGN KEY (order_id) REFERENCES procurement_orders(id),
  FOREIGN KEY (request_item_id) REFERENCES procurement_request_items(id)
);

CREATE TABLE procurement_receipts (
  id VARCHAR(64) PRIMARY KEY,
  receipt_number VARCHAR(32) UNIQUE NOT NULL,
  request_id VARCHAR(64) NOT NULL,
  order_id VARCHAR(64) NOT NULL,
  delivery_note_number VARCHAR(128) NULL,
  received_at DATE NOT NULL,
  status VARCHAR(32) NOT NULL,
  complaint TEXT NULL,
  inventory_transferred TINYINT(1) NOT NULL DEFAULT 0,
  transferred_at DATETIME NULL,
  created_by VARCHAR(255) NOT NULL,
  created_at DATETIME NOT NULL,
  FOREIGN KEY (request_id) REFERENCES procurement_requests(id),
  FOREIGN KEY (order_id) REFERENCES procurement_orders(id)
);

CREATE TABLE procurement_receipt_items (
  id VARCHAR(64) PRIMARY KEY,
  receipt_id VARCHAR(64) NOT NULL,
  request_item_id VARCHAR(64) NOT NULL,
  quantity DECIMAL(12,3) NOT NULL,
  FOREIGN KEY (receipt_id) REFERENCES procurement_receipts(id),
  FOREIGN KEY (request_item_id) REFERENCES procurement_request_items(id)
);

CREATE TABLE procurement_documents (
  id VARCHAR(64) PRIMARY KEY,
  request_id VARCHAR(64) NOT NULL,
  entity_type VARCHAR(64) NOT NULL,
  entity_id VARCHAR(64) NOT NULL,
  document_type VARCHAR(64) NOT NULL,
  file_name VARCHAR(255) NOT NULL,
  mime_type VARCHAR(128) NULL,
  file_base64 LONGTEXT NOT NULL,
  created_by VARCHAR(255) NOT NULL,
  created_at DATETIME NOT NULL,
  FOREIGN KEY (request_id) REFERENCES procurement_requests(id)
);

CREATE TABLE procurement_history (
  id VARCHAR(64) PRIMARY KEY,
  request_id VARCHAR(64) NOT NULL,
  action VARCHAR(128) NOT NULL,
  actor VARCHAR(255) NOT NULL,
  details JSON NOT NULL,
  created_at DATETIME NOT NULL,
  FOREIGN KEY (request_id) REFERENCES procurement_requests(id)
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

-- Fachliche Sammlungen werden als atomare JSON-Snapshots gespeichert. Nutzer
-- und Rollen verbleiben wegen ihrer Login-/Eindeutigkeitsanforderungen in den
-- normalisierten Tabellen oben.
CREATE TABLE application_collections (
  name VARCHAR(64) PRIMARY KEY,
  data_json LONGTEXT NOT NULL,
  updated_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3)
    ON UPDATE CURRENT_TIMESTAMP(3),
  CHECK (JSON_VALID(data_json))
);

CREATE TABLE mailbox_processing_state (
  mailbox VARCHAR(255) PRIMARY KEY,
  uid_validity VARCHAR(64) NOT NULL,
  last_uid BIGINT UNSIGNED NOT NULL,
  initialized_at DATETIME NOT NULL,
  updated_at DATETIME NOT NULL
);
