class OrderCancellationService
  def initialize(order, user_id = nil)
    @order = order
    @user_id = user_id
    @transaction = nil
  end

  def seller_lapse!
    @order.seller_lapse! do
      process_refund if @order.mode == Order::BUY
    end
    PostOrderNotificationJob.perform_later(@order.id, Order::CANCELED)
  ensure
    @order.transactions << @transaction if @transaction.present?
  end

  def buyer_lapse!
    @order.buyer_lapse!
    PostOrderNotificationJob.perform_later(@order.id, Order::CANCELED)
  ensure
    @order.transactions << @transaction if @transaction.present?
  end

  def reject!(rejection_reason = nil)
    @order.reject!(rejection_reason) do
      process_refund if @order.mode == Order::BUY
    end
    Exchange.dogstatsd.increment 'order.reject'
    PostOrderNotificationJob.perform_later(@order.id, Order::CANCELED, @user_id)
  ensure
    @order.transactions << @transaction if @transaction.present?
  end

  def refund!
    @order.refund! do
      process_refund
    end
    record_stats
    PostOrderNotificationJob.perform_later(@order.id, Order::REFUNDED, @user_id)
  ensure
    @order.transactions << @transaction if @transaction.present?
  end

  private

  def process_refund
    @transaction = PaymentService.refund_charge(@order.external_charge_id)
    raise Errors::ProcessingError.new(:refund_failed, @transaction.failure_data) if @transaction.failed?

    @order.line_items.each { |li| Gravity.undeduct_inventory(li) }
  end

  def record_stats
    Exchange.dogstatsd.increment 'order.refund'
    Exchange.dogstatsd.count('order.money_refunded', @order.buyer_total_cents)
  end
end
