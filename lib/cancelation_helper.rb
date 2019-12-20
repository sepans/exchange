class CancelationHelper
  def initialize(order)
    @order = order
    @transaction = nil
    @payment_service = PaymentService.new(@order)
  end

  def process_inventory_undeduction
    @order.line_items.each { |li| UndeductLineItemInventoryJob.perform_later(li.id) }
  end

  def process_stripe_refund
    raise Errors::ValidationError.new(:unsupported_payment_method, @order.payment_method) unless @order.payment_method == Order::CREDIT_CARD

    @transaction = @payment_service.refund
    raise Errors::ProcessingError.new(:refund_failed, @transaction.failure_data) if @transaction.failed?

    @transaction
  end

  def cancel_payment_intent
    raise Errors::ValidationError.new(:unsupported_payment_method, @order.payment_method) unless @order.payment_method == Order::CREDIT_CARD

    @transaction = @payment_service.cancel_payment_intent
    raise Errors::ProcessingError.new(:refund_failed, @transaction.failure_data) if @transaction.failed?

    @transaction
  end

  def record_stats
    Exchange.dogstatsd.increment 'order.refund'
    Exchange.dogstatsd.count('order.money_refunded', @order.buyer_total_cents)
  end
end
