-- ============================================================================
-- Enterprise Inventory Management System — Stored Procedures
-- Engine  : MySQL 8+
-- Author  : DBA Team
-- Created : 2026-06-13
-- Notes   : Every procedure uses START TRANSACTION, DECLARE EXIT HANDLER,
--           SIGNAL for validation errors, and proper COMMIT / ROLLBACK.
-- ============================================================================

DELIMITER $$

-- ────────────────────────────────────────────────────────────────────────────
-- 1. PlacePurchaseOrder
--    Creates a new PO header + line items from a JSON array.
--    p_items JSON format:
--      [{"product_id":1, "quantity":100, "unit_cost":25.5000}, ...]
-- ────────────────────────────────────────────────────────────────────────────
DROP PROCEDURE IF EXISTS `PlacePurchaseOrder`$$

CREATE PROCEDURE `PlacePurchaseOrder`(
    IN  p_supplier_id  BIGINT UNSIGNED,
    IN  p_warehouse_id BIGINT UNSIGNED,
    IN  p_items        JSON,
    IN  p_created_by   BIGINT UNSIGNED,
    OUT p_po_id        BIGINT UNSIGNED
)
proc_body: BEGIN

    DECLARE v_item_count    INT DEFAULT 0;
    DECLARE v_idx           INT DEFAULT 0;
    DECLARE v_product_id    BIGINT UNSIGNED;
    DECLARE v_quantity      INT UNSIGNED;
    DECLARE v_unit_cost     DECIMAL(13,4);
    DECLARE v_line_total    DECIMAL(13,4);
    DECLARE v_total_amount  DECIMAL(13,4) DEFAULT 0.0000;
    DECLARE v_tax_rate      DECIMAL(5,4) DEFAULT 0.1800;  -- 18 % GST
    DECLARE v_tax_amount    DECIMAL(13,4);
    DECLARE v_grand_total   DECIMAL(13,4);
    DECLARE v_po_number     VARCHAR(30);
    DECLARE v_product_exists INT DEFAULT 0;
    DECLARE v_lead_time     INT UNSIGNED DEFAULT 7;

    -- Exit handler — any SQL error rolls back
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    -- ── Validation ──────────────────────────────────────────────────────────
    IF p_supplier_id IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Validation Error: supplier_id is required.';
    END IF;

    IF p_warehouse_id IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Validation Error: warehouse_id is required.';
    END IF;

    IF p_created_by IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Validation Error: created_by (user) is required.';
    END IF;

    IF p_items IS NULL OR JSON_LENGTH(p_items) = 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Validation Error: items array must contain at least one item.';
    END IF;

    -- Check supplier exists and is active
    IF NOT EXISTS (SELECT 1 FROM suppliers WHERE supplier_id = p_supplier_id AND is_active = TRUE) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Validation Error: Supplier not found or inactive.';
    END IF;

    -- Check warehouse exists and is active
    IF NOT EXISTS (SELECT 1 FROM warehouses WHERE warehouse_id = p_warehouse_id AND is_active = TRUE) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Validation Error: Warehouse not found or inactive.';
    END IF;

    -- Get supplier lead time
    SELECT COALESCE(lead_time_days, 7)
      INTO v_lead_time
      FROM suppliers
     WHERE supplier_id = p_supplier_id;

    START TRANSACTION;

    -- Generate PO number: PO-YYYYMMDD-XXXXX
    SET v_po_number = CONCAT(
        'PO-',
        DATE_FORMAT(NOW(), '%Y%m%d'),
        '-',
        LPAD(
            (SELECT COALESCE(MAX(po_id), 0) + 1 FROM purchase_orders),
            5, '0'
        )
    );

    -- Insert PO header (totals updated after items)
    INSERT INTO purchase_orders (
        po_number, supplier_id, warehouse_id, order_date, expected_date,
        status, total_amount, tax_amount, shipping_cost, grand_total,
        notes, created_by
    ) VALUES (
        v_po_number, p_supplier_id, p_warehouse_id, NOW(),
        DATE_ADD(NOW(), INTERVAL v_lead_time DAY),
        'submitted', 0.0000, 0.0000, 0.0000, 0.0000,
        NULL, p_created_by
    );

    SET p_po_id = LAST_INSERT_ID();

    -- Insert line items
    SET v_item_count = JSON_LENGTH(p_items);

    WHILE v_idx < v_item_count DO
        SET v_product_id = JSON_UNQUOTE(JSON_EXTRACT(p_items, CONCAT('$[', v_idx, '].product_id')));
        SET v_quantity   = JSON_UNQUOTE(JSON_EXTRACT(p_items, CONCAT('$[', v_idx, '].quantity')));
        SET v_unit_cost  = JSON_UNQUOTE(JSON_EXTRACT(p_items, CONCAT('$[', v_idx, '].unit_cost')));

        -- Validate product
        SELECT COUNT(*) INTO v_product_exists
          FROM products
         WHERE product_id = v_product_id AND is_active = TRUE;

        IF v_product_exists = 0 THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'Validation Error: One or more products not found or inactive.';
        END IF;

        IF v_quantity IS NULL OR v_quantity <= 0 THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'Validation Error: Quantity must be a positive integer.';
        END IF;

        IF v_unit_cost IS NULL OR v_unit_cost <= 0 THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'Validation Error: Unit cost must be greater than zero.';
        END IF;

        SET v_line_total = v_quantity * v_unit_cost;

        INSERT INTO purchase_order_items (
            po_id, product_id, quantity_ordered, quantity_received,
            unit_cost, line_total, status
        ) VALUES (
            p_po_id, v_product_id, v_quantity, 0,
            v_unit_cost, v_line_total, 'pending'
        );

        SET v_total_amount = v_total_amount + v_line_total;
        SET v_idx = v_idx + 1;
    END WHILE;

    -- Compute tax and grand total
    SET v_tax_amount = ROUND(v_total_amount * v_tax_rate, 4);
    SET v_grand_total = v_total_amount + v_tax_amount;

    -- Update PO header with computed totals
    UPDATE purchase_orders
       SET total_amount = v_total_amount,
           tax_amount   = v_tax_amount,
           grand_total  = v_grand_total
     WHERE po_id = p_po_id;

    COMMIT;

END$$


-- ────────────────────────────────────────────────────────────────────────────
-- 2. ReceiveInventory
--    Receives goods against a PO. Updates PO item received quantities,
--    inventory on-hand, and creates inventory movement records.
--    p_items_received JSON format:
--      [{"po_item_id":1, "quantity_received":50}, ...]
-- ────────────────────────────────────────────────────────────────────────────
DROP PROCEDURE IF EXISTS `ReceiveInventory`$$

CREATE PROCEDURE `ReceiveInventory`(
    IN p_po_id           BIGINT UNSIGNED,
    IN p_items_received  JSON,
    IN p_received_by     BIGINT UNSIGNED
)
proc_body: BEGIN

    DECLARE v_item_count       INT DEFAULT 0;
    DECLARE v_idx              INT DEFAULT 0;
    DECLARE v_po_item_id       BIGINT UNSIGNED;
    DECLARE v_qty_received     INT UNSIGNED;
    DECLARE v_product_id       BIGINT UNSIGNED;
    DECLARE v_warehouse_id     BIGINT UNSIGNED;
    DECLARE v_qty_ordered      INT UNSIGNED;
    DECLARE v_qty_already_rcvd INT UNSIGNED;
    DECLARE v_new_total_rcvd   INT UNSIGNED;
    DECLARE v_po_status        VARCHAR(30);
    DECLARE v_all_received     BOOLEAN DEFAULT TRUE;
    DECLARE v_any_received     BOOLEAN DEFAULT FALSE;
    DECLARE v_item_status      VARCHAR(30);

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    -- ── Validation ──────────────────────────────────────────────────────────
    IF p_po_id IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Validation Error: po_id is required.';
    END IF;

    IF p_received_by IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Validation Error: received_by (user) is required.';
    END IF;

    IF p_items_received IS NULL OR JSON_LENGTH(p_items_received) = 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Validation Error: items_received array must contain at least one item.';
    END IF;

    -- Verify PO exists and is in a receivable status
    SELECT status, warehouse_id
      INTO v_po_status, v_warehouse_id
      FROM purchase_orders
     WHERE po_id = p_po_id;

    IF v_po_status IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Validation Error: Purchase order not found.';
    END IF;

    IF v_po_status NOT IN ('submitted', 'approved', 'partially_received') THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Validation Error: PO is not in a receivable status.';
    END IF;

    START TRANSACTION;

    SET v_item_count = JSON_LENGTH(p_items_received);

    WHILE v_idx < v_item_count DO
        SET v_po_item_id  = JSON_UNQUOTE(JSON_EXTRACT(p_items_received, CONCAT('$[', v_idx, '].po_item_id')));
        SET v_qty_received = JSON_UNQUOTE(JSON_EXTRACT(p_items_received, CONCAT('$[', v_idx, '].quantity_received')));

        IF v_qty_received IS NULL OR v_qty_received <= 0 THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'Validation Error: quantity_received must be a positive integer.';
        END IF;

        -- Get PO item details
        SELECT product_id, quantity_ordered, quantity_received
          INTO v_product_id, v_qty_ordered, v_qty_already_rcvd
          FROM purchase_order_items
         WHERE po_item_id = v_po_item_id AND po_id = p_po_id;

        IF v_product_id IS NULL THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'Validation Error: PO item not found for this purchase order.';
        END IF;

        SET v_new_total_rcvd = v_qty_already_rcvd + v_qty_received;

        IF v_new_total_rcvd > v_qty_ordered THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'Validation Error: Received quantity exceeds ordered quantity.';
        END IF;

        -- Determine item status
        IF v_new_total_rcvd = v_qty_ordered THEN
            SET v_item_status = 'received';
        ELSE
            SET v_item_status = 'partially_received';
        END IF;

        -- Update PO item
        UPDATE purchase_order_items
           SET quantity_received = v_new_total_rcvd,
               status = v_item_status
         WHERE po_item_id = v_po_item_id;

        -- Upsert inventory (INSERT ON DUPLICATE KEY UPDATE)
        INSERT INTO inventory (product_id, warehouse_id, quantity_on_hand, quantity_reserved)
        VALUES (v_product_id, v_warehouse_id, v_qty_received, 0)
        ON DUPLICATE KEY UPDATE
            quantity_on_hand = quantity_on_hand + v_qty_received;

        -- Record inventory movement
        INSERT INTO inventory_movements (
            product_id, warehouse_id, movement_type, quantity,
            reference_type, reference_id, reason, performed_by
        ) VALUES (
            v_product_id, v_warehouse_id, 'purchase_in', v_qty_received,
            'purchase_order', p_po_id,
            CONCAT('Received against PO item #', v_po_item_id),
            p_received_by
        );

        SET v_idx = v_idx + 1;
    END WHILE;

    -- Determine overall PO status
    SELECT
        CASE WHEN MIN(status) = 'received' AND MAX(status) = 'received' THEN TRUE ELSE FALSE END,
        CASE WHEN MAX(quantity_received) > 0 THEN TRUE ELSE FALSE END
      INTO v_all_received, v_any_received
      FROM purchase_order_items
     WHERE po_id = p_po_id AND status != 'cancelled';

    IF v_all_received THEN
        UPDATE purchase_orders SET status = 'received' WHERE po_id = p_po_id;
    ELSEIF v_any_received THEN
        UPDATE purchase_orders SET status = 'partially_received' WHERE po_id = p_po_id;
    END IF;

    COMMIT;

END$$


-- ────────────────────────────────────────────────────────────────────────────
-- 3. CreateSalesOrder
--    Creates a new sales order with line items. Reserves inventory.
--    p_items JSON format:
--      [{"product_id":1, "quantity":5, "unit_price":49.9900, "discount_pct":0.00}, ...]
-- ────────────────────────────────────────────────────────────────────────────
DROP PROCEDURE IF EXISTS `CreateSalesOrder`$$

CREATE PROCEDURE `CreateSalesOrder`(
    IN  p_customer_id BIGINT UNSIGNED,
    IN  p_items       JSON,
    IN  p_created_by  BIGINT UNSIGNED,
    OUT p_so_id       BIGINT UNSIGNED
)
proc_body: BEGIN

    DECLARE v_item_count     INT DEFAULT 0;
    DECLARE v_idx            INT DEFAULT 0;
    DECLARE v_product_id     BIGINT UNSIGNED;
    DECLARE v_quantity       INT UNSIGNED;
    DECLARE v_unit_price     DECIMAL(13,4);
    DECLARE v_discount_pct   DECIMAL(5,2);
    DECLARE v_line_total     DECIMAL(13,4);
    DECLARE v_subtotal       DECIMAL(13,4) DEFAULT 0.0000;
    DECLARE v_tax_rate       DECIMAL(5,4) DEFAULT 0.1800;
    DECLARE v_tax_amount     DECIMAL(13,4);
    DECLARE v_grand_total    DECIMAL(13,4);
    DECLARE v_so_number      VARCHAR(30);
    DECLARE v_available_qty  INT;
    DECLARE v_warehouse_id   BIGINT UNSIGNED;
    DECLARE v_customer_type  VARCHAR(20);

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    -- ── Validation ──────────────────────────────────────────────────────────
    IF p_customer_id IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Validation Error: customer_id is required.';
    END IF;

    IF p_created_by IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Validation Error: created_by (user) is required.';
    END IF;

    IF p_items IS NULL OR JSON_LENGTH(p_items) = 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Validation Error: items array must contain at least one item.';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM customers WHERE customer_id = p_customer_id AND is_active = TRUE) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Validation Error: Customer not found or inactive.';
    END IF;

    -- Get customer type for potential wholesale discount logic
    SELECT customer_type INTO v_customer_type
      FROM customers
     WHERE customer_id = p_customer_id;

    START TRANSACTION;

    -- Pick the primary warehouse (warehouse with most stock — simplified)
    -- In production, a warehouse selection strategy would be more sophisticated.
    SELECT warehouse_id INTO v_warehouse_id
      FROM warehouses
     WHERE is_active = TRUE
     ORDER BY warehouse_id ASC
     LIMIT 1;

    IF v_warehouse_id IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Validation Error: No active warehouse available.';
    END IF;

    -- Generate SO number: SO-YYYYMMDD-XXXXX
    SET v_so_number = CONCAT(
        'SO-',
        DATE_FORMAT(NOW(), '%Y%m%d'),
        '-',
        LPAD(
            (SELECT COALESCE(MAX(so_id), 0) + 1 FROM sales_orders),
            5, '0'
        )
    );

    -- Insert SO header
    INSERT INTO sales_orders (
        so_number, customer_id, warehouse_id, order_date,
        status, subtotal, tax_amount, discount_amount, shipping_cost, grand_total,
        notes, created_by
    ) VALUES (
        v_so_number, p_customer_id, v_warehouse_id, NOW(),
        'confirmed', 0.0000, 0.0000, 0.0000, 0.0000, 0.0000,
        NULL, p_created_by
    );

    SET p_so_id = LAST_INSERT_ID();

    -- Insert line items and reserve inventory
    SET v_item_count = JSON_LENGTH(p_items);

    WHILE v_idx < v_item_count DO
        SET v_product_id   = JSON_UNQUOTE(JSON_EXTRACT(p_items, CONCAT('$[', v_idx, '].product_id')));
        SET v_quantity     = JSON_UNQUOTE(JSON_EXTRACT(p_items, CONCAT('$[', v_idx, '].quantity')));
        SET v_unit_price   = JSON_UNQUOTE(JSON_EXTRACT(p_items, CONCAT('$[', v_idx, '].unit_price')));
        SET v_discount_pct = COALESCE(
            JSON_UNQUOTE(JSON_EXTRACT(p_items, CONCAT('$[', v_idx, '].discount_pct'))),
            0.00
        );

        -- Validate product
        IF NOT EXISTS (SELECT 1 FROM products WHERE product_id = v_product_id AND is_active = TRUE) THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'Validation Error: Product not found or inactive.';
        END IF;

        IF v_quantity IS NULL OR v_quantity <= 0 THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'Validation Error: Quantity must be a positive integer.';
        END IF;

        -- Check available inventory with PESSIMISTIC LOCKING
        SELECT COALESCE(quantity_on_hand - quantity_reserved, 0)
          INTO v_available_qty
          FROM inventory
         WHERE product_id = v_product_id AND warehouse_id = v_warehouse_id
           FOR UPDATE;

        IF v_available_qty IS NULL OR v_available_qty < CAST(v_quantity AS SIGNED) THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'Validation Error: Insufficient stock for one or more products.';
        END IF;

        -- Calculate line total after discount
        SET v_line_total = ROUND(v_quantity * v_unit_price * (1 - v_discount_pct / 100), 4);

        INSERT INTO sales_order_items (
            so_id, product_id, quantity, unit_price, discount_pct, line_total
        ) VALUES (
            p_so_id, v_product_id, v_quantity, v_unit_price, v_discount_pct, v_line_total
        );

        -- Reserve inventory
        UPDATE inventory
           SET quantity_reserved = quantity_reserved + v_quantity
         WHERE product_id = v_product_id AND warehouse_id = v_warehouse_id;

        SET v_subtotal = v_subtotal + v_line_total;
        SET v_idx = v_idx + 1;
    END WHILE;

    -- Compute tax and grand total
    SET v_tax_amount  = ROUND(v_subtotal * v_tax_rate, 4);
    SET v_grand_total = v_subtotal + v_tax_amount;

    UPDATE sales_orders
       SET subtotal    = v_subtotal,
           tax_amount  = v_tax_amount,
           grand_total = v_grand_total
     WHERE so_id = p_so_id;

    COMMIT;

END$$


-- ────────────────────────────────────────────────────────────────────────────
-- 4. GenerateInvoice
--    Creates a payment record (invoice) for a confirmed/shipped sales order.
-- ────────────────────────────────────────────────────────────────────────────
DROP PROCEDURE IF EXISTS `GenerateInvoice`$$

CREATE PROCEDURE `GenerateInvoice`(
    IN  p_sales_order_id BIGINT UNSIGNED,
    OUT p_payment_id     BIGINT UNSIGNED
)
proc_body: BEGIN

    DECLARE v_so_status      VARCHAR(30);
    DECLARE v_grand_total    DECIMAL(13,4);
    DECLARE v_created_by     BIGINT UNSIGNED;
    DECLARE v_payment_number VARCHAR(30);
    DECLARE v_existing_count INT DEFAULT 0;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    -- ── Validation ──────────────────────────────────────────────────────────
    IF p_sales_order_id IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Validation Error: sales_order_id is required.';
    END IF;

    SELECT status, grand_total, created_by
      INTO v_so_status, v_grand_total, v_created_by
      FROM sales_orders
     WHERE so_id = p_sales_order_id;

    IF v_so_status IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Validation Error: Sales order not found.';
    END IF;

    IF v_so_status NOT IN ('confirmed', 'processing', 'shipped', 'delivered') THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Validation Error: Sales order is not in an invoiceable status.';
    END IF;

    -- Check if an invoice already exists for this SO
    SELECT COUNT(*) INTO v_existing_count
      FROM payments
     WHERE reference_type = 'sales_order' AND reference_id = p_sales_order_id;

    IF v_existing_count > 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Validation Error: An invoice already exists for this sales order.';
    END IF;

    START TRANSACTION;

    -- Generate payment number: INV-YYYYMMDD-XXXXX
    SET v_payment_number = CONCAT(
        'INV-',
        DATE_FORMAT(NOW(), '%Y%m%d'),
        '-',
        LPAD(
            (SELECT COALESCE(MAX(payment_id), 0) + 1 FROM payments),
            5, '0'
        )
    );

    INSERT INTO payments (
        payment_number, reference_type, reference_id, payment_date,
        amount, payment_method, status, transaction_ref, notes, created_by
    ) VALUES (
        v_payment_number, 'sales_order', p_sales_order_id, NOW(),
        v_grand_total, 'bank_transfer', 'pending', NULL,
        CONCAT('Invoice for Sales Order #', p_sales_order_id),
        v_created_by
    );

    SET p_payment_id = LAST_INSERT_ID();

    COMMIT;

END$$


-- ────────────────────────────────────────────────────────────────────────────
-- 5. ReorderStock
--    Scans all inventory records and creates reorder requests for products
--    whose on-hand quantity has fallen below their reorder level.
-- ────────────────────────────────────────────────────────────────────────────
DROP PROCEDURE IF EXISTS `ReorderStock`$$

CREATE PROCEDURE `ReorderStock`()
proc_body: BEGIN

    DECLARE v_done            INT DEFAULT 0;
    DECLARE v_product_id      BIGINT UNSIGNED;
    DECLARE v_warehouse_id    BIGINT UNSIGNED;
    DECLARE v_qty_on_hand     INT;
    DECLARE v_reorder_level   INT UNSIGNED;
    DECLARE v_reorder_qty     INT UNSIGNED;
    DECLARE v_existing_open   INT DEFAULT 0;
    DECLARE v_requests_created INT DEFAULT 0;

    -- Cursor: all inventory records below reorder level for active products
    DECLARE cur_low_stock CURSOR FOR
        SELECT i.product_id, i.warehouse_id, i.quantity_on_hand,
               p.reorder_level, p.reorder_qty
          FROM inventory i
          JOIN products p ON p.product_id = i.product_id
         WHERE p.is_active = TRUE
           AND i.quantity_on_hand <= CAST(p.reorder_level AS SIGNED);

    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_done = 1;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    START TRANSACTION;

    OPEN cur_low_stock;

    read_loop: LOOP
        FETCH cur_low_stock INTO v_product_id, v_warehouse_id, v_qty_on_hand,
                                  v_reorder_level, v_reorder_qty;
        IF v_done THEN
            LEAVE read_loop;
        END IF;

        -- Skip if an open reorder request already exists
        SELECT COUNT(*) INTO v_existing_open
          FROM stock_reorder_requests
         WHERE product_id  = v_product_id
           AND warehouse_id = v_warehouse_id
           AND status IN ('open', 'approved');

        IF v_existing_open = 0 THEN
            INSERT INTO stock_reorder_requests (
                product_id, warehouse_id, current_qty, reorder_level,
                suggested_qty, status, requested_by
            ) VALUES (
                v_product_id, v_warehouse_id, v_qty_on_hand, v_reorder_level,
                v_reorder_qty, 'open', NULL
            );

            SET v_requests_created = v_requests_created + 1;
        END IF;

    END LOOP;

    CLOSE cur_low_stock;

    COMMIT;

    -- Return summary
    SELECT v_requests_created AS reorder_requests_created;

END$$


-- ────────────────────────────────────────────────────────────────────────────
-- 6. MonthlySalesReport
--    Returns aggregated sales data for a given year and month.
-- ────────────────────────────────────────────────────────────────────────────
DROP PROCEDURE IF EXISTS `MonthlySalesReport`$$

CREATE PROCEDURE `MonthlySalesReport`(
    IN p_year  INT,
    IN p_month INT
)
proc_body: BEGIN

    DECLARE v_start_date DATE;
    DECLARE v_end_date   DATE;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    -- ── Validation ──────────────────────────────────────────────────────────
    IF p_year IS NULL OR p_year < 2000 OR p_year > 2100 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Validation Error: year must be between 2000 and 2100.';
    END IF;

    IF p_month IS NULL OR p_month < 1 OR p_month > 12 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Validation Error: month must be between 1 and 12.';
    END IF;

    SET v_start_date = MAKEDATE(p_year, 1) + INTERVAL (p_month - 1) MONTH;
    SET v_end_date   = LAST_DAY(v_start_date);

    START TRANSACTION READ ONLY;

    -- ── Result Set 1: Summary KPIs ──────────────────────────────────────────
    SELECT
        p_year                                            AS report_year,
        p_month                                           AS report_month,
        COUNT(DISTINCT so.so_id)                          AS total_orders,
        COUNT(DISTINCT so.customer_id)                    AS unique_customers,
        SUM(so.subtotal)                                  AS total_revenue,
        SUM(so.tax_amount)                                AS total_tax,
        SUM(so.discount_amount)                           AS total_discounts,
        SUM(so.grand_total)                               AS total_grand,
        ROUND(AVG(so.grand_total), 4)                     AS avg_order_value,
        SUM(soi.quantity)                                  AS total_units_sold
      FROM sales_orders so
      JOIN sales_order_items soi ON soi.so_id = so.so_id
     WHERE so.order_date >= v_start_date
       AND so.order_date <  v_end_date + INTERVAL 1 DAY
       AND so.status NOT IN ('cancelled', 'returned');

    -- ── Result Set 2: Top 10 products by revenue ────────────────────────────
    SELECT
        p.product_id,
        p.sku,
        p.name                                             AS product_name,
        SUM(soi.quantity)                                  AS units_sold,
        SUM(soi.line_total)                                AS revenue,
        SUM(soi.quantity * p.cost_price)                   AS cost,
        SUM(soi.line_total) - SUM(soi.quantity * p.cost_price) AS gross_profit
      FROM sales_order_items soi
      JOIN sales_orders so ON so.so_id = soi.so_id
      JOIN products p      ON p.product_id = soi.product_id
     WHERE so.order_date >= v_start_date
       AND so.order_date <  v_end_date + INTERVAL 1 DAY
       AND so.status NOT IN ('cancelled', 'returned')
     GROUP BY p.product_id, p.sku, p.name
     ORDER BY revenue DESC
     LIMIT 10;

    -- ── Result Set 3: Revenue by category ───────────────────────────────────
    SELECT
        c.category_id,
        c.category_name,
        COUNT(DISTINCT so.so_id)                           AS order_count,
        SUM(soi.quantity)                                  AS units_sold,
        SUM(soi.line_total)                                AS revenue
      FROM sales_order_items soi
      JOIN sales_orders so ON so.so_id = soi.so_id
      JOIN products p      ON p.product_id = soi.product_id
      JOIN categories c    ON c.category_id = p.category_id
     WHERE so.order_date >= v_start_date
       AND so.order_date <  v_end_date + INTERVAL 1 DAY
       AND so.status NOT IN ('cancelled', 'returned')
     GROUP BY c.category_id, c.category_name
     ORDER BY revenue DESC;

    -- ── Result Set 4: Daily sales trend ─────────────────────────────────────
    SELECT
        DATE(so.order_date)            AS sale_date,
        COUNT(DISTINCT so.so_id)       AS orders,
        SUM(so.grand_total)            AS daily_revenue
      FROM sales_orders so
     WHERE so.order_date >= v_start_date
       AND so.order_date <  v_end_date + INTERVAL 1 DAY
       AND so.status NOT IN ('cancelled', 'returned')
     GROUP BY DATE(so.order_date)
     ORDER BY sale_date;

    COMMIT;

END$$

DELIMITER ;
