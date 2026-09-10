const pool = require('../config/database');
const salesOrderRepository = require('../repositories/salesOrder.repository');
const inventoryRepository = require('../repositories/inventory.repository');
const paymentRepository = require('../repositories/payment.repository');
const customerRepository = require('../repositories/customer.repository');
const ApiError = require('../utils/ApiError');

class SalesOrderService {
  async getAll(filters, pagination) {
    const [data, total] = await Promise.all([
      salesOrderRepository.findAll(filters, pagination),
      salesOrderRepository.count(filters)
    ]);
    const limit = parseInt(pagination.limit) || 20;
    const page = parseInt(pagination.page) || 1;
    return { data, pagination: { page, limit, total, totalPages: Math.ceil(total / limit) } };
  }

  async getById(id) {
    const so = await salesOrderRepository.findById(id);
    if (!so) throw ApiError.notFound('Sales order not found');
    so.items = await salesOrderRepository.getItems(id);
    return so;
  }

  async create(data, userId) {
    const customer = await customerRepository.findById(data.customer_id);
    if (!customer || !customer.is_active) throw ApiError.badRequest('Invalid or inactive customer');

    const connection = await pool.getConnection();
    try {
      // Call the stored procedure: CALL CreateSalesOrder(customer_id, items_json, created_by, @out_so_id)
      const [results] = await connection.execute(
        'CALL CreateSalesOrder(?, ?, ?, @p_so_id)',
        [data.customer_id, JSON.stringify(data.items), userId]
      );
      
      // Fetch the OUT parameter (the newly created sales order ID)
      const [[{ so_id }]] = await connection.execute('SELECT @p_so_id AS so_id');
      
      return await this.getById(so_id);
    } catch (error) {
      // If the stored procedure threw a SIGNAL SQLSTATE, it will be caught here
      if (error.sqlState === '45000') {
        throw ApiError.badRequest(error.message);
      }
      throw error;
    } finally {
      connection.release();
    }
  }

  async updateStatus(soId, status, userId) {
    const so = await salesOrderRepository.findById(soId);
    if (!so) throw ApiError.notFound('Sales order not found');

    const validTransitions = {
      draft: ['confirmed', 'cancelled'],
      confirmed: ['processing', 'cancelled'],
      processing: ['shipped', 'cancelled'],
      shipped: ['delivered'],
      delivered: []
    };

    if (!validTransitions[so.status] || !validTransitions[so.status].includes(status)) {
      throw ApiError.badRequest(`Cannot transition from '${so.status}' to '${status}'`);
    }

    await salesOrderRepository.updateStatus(soId, status);
    return await this.getById(soId);
  }

  async generateInvoice(soId) {
    const so = await salesOrderRepository.findById(soId);
    if (!so) throw ApiError.notFound('Sales order not found');
    if (so.status === 'cancelled') throw ApiError.badRequest('Cannot generate invoice for cancelled order');

    const existingPayments = await paymentRepository.findByReference('sales_order', soId);
    if (existingPayments.length > 0)
      return { order: so, payment: existingPayments[0], items: await salesOrderRepository.getItems(soId) };

    const payment = await paymentRepository.create({
      reference_type: 'sales_order',
      reference_id: soId,
      amount: so.grand_total,
      payment_method: 'bank_transfer',
      status: 'pending',
      created_by: so.created_by
    });

    return { order: so, payment, items: await salesOrderRepository.getItems(soId) };
  }
}

module.exports = new SalesOrderService();
